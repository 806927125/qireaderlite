import Foundation

// ⭐⭐⭐⭐⭐ **柴阅 store 键 ⇄ 轻阅存储槽 的映射（纯逻辑 ⇒ Linux 沙盒可编 ⇒ 门禁能验）**
//
// ⚠️⚠️⚠️ **这是移植里最容易出错的一层**（2026-11-21 移植柴阅实证）⭐⭐⭐
//   柴阅把状态写进 `KeyValueStore`，键名形如：
//     · `cache_sourceVariable_<源URL>`  = 站方变量（**一整串**）⭐⭐⭐
//     · `cache_v_<源URL>_<变量名>`       = 书源变量（**每 k 一项**）⭐⭐⭐
//     · `cache_userInfo_<源URL>`        = 登录信息（**AES 密文**）⭐⭐⭐
//     · `cache_loginHeader_<源URL>`     = 登录头
//     · `__deviceID`                    = 设备 ID（**无 cache_ 前缀**）⭐⭐⭐
//   而轻阅的槽是：
//     · `variablePrefix + 源URL` = 站方变量**整串**（UserDefaults）⭐⭐⭐
//     · `varsPrefix + 源URL`    = 书源变量的**一个 JSON map 串**⭐⭐⭐
//     · `loginPrefix + 源URL`   = 登录信息**明文 JSON**⭐⭐⭐
//
//   ⇒ 两边的**键结构不同、值的存储形态也不同** ⇒ 必须有一层明确映射 ⭐⭐⭐
//   ⇒ 本文件**只做纯计算**（不含 I/O、不含加密）⇒ 可以在 Linux 沙盒里逐条验 ⭐⭐⭐
public enum ChaiyueStoreMapping {
    /// 柴阅 `CacheStore` 内部加的键前缀
    public static let cachePrefix = "cache_"
    /// 柴阅 `CacheStore` 存的值格式：`deadline\u{1}value`（deadline 为毫秒时间戳，0 = 永久）
    public static let separator = "\u{1}"

    /// 柴阅 `SourceState` 的三种键前缀（不含 `cache_`）
    public static let stationVariablePrefix = "sourceVariable_"
    public static let sourceVarPrefix = "v_"
    public static let loginInfoPrefix = "userInfo_"
    public static let loginHeaderPrefix = "loginHeader_"

    /// 柴阅 `SourceEnvironment` 的设备 ID 键（**无 `cache_` 前缀** ⇒ 别按缓存处理）
    public static let deviceIDKey = "__deviceID"

    /// 柴阅的一个键落到轻阅的哪个槽
    public enum Slot: Equatable {
        /// 站方变量（`source.getVariable()` / `setVariable(str)`）—— **一整串**
        case stationVariable(sourceKey: String)
        /// 书源变量的某一项（`source.get(k)` / `put(k,v)`）—— **每 k 一项**
        case sourceVar(sourceKey: String, name: String)
        /// 登录信息（`getLoginInfoMap()`）—— 柴阅侧是**密文**
        case loginInfo(sourceKey: String)
        /// 登录头（`getLoginHeader()`）
        case loginHeader(sourceKey: String)
        /// 设备 ID
        case deviceID
        /// 其它缓存（柴阅 `cache_` 命名空间里的普通缓存项）
        case plainCache(key: String)
        /// 不认识 ⇒ 原样透传（App 侧决定存哪）
        case opaque(key: String)
    }

    /// ⭐⭐⭐ **柴阅键 ⇒ 轻阅槽**（唯一入口 ⇒ 门禁直接验这张表）
    ///
    /// ⚠️⚠️ **顺序很重要**：`v_` 必须**先于**其它前缀判断
    ///   （`v_` 最短且最泛 ⇒ 放最后会漏判）⭐⭐⭐
    public static func slot(forChaiyueKey key: String) -> Slot {
        // ① 设备 ID（**无 cache_ 前缀** ⇒ 必须最先判）
        if key == deviceIDKey { return .deviceID }

        // ② 非缓存命名空间 ⇒ 原样透传
        guard key.hasPrefix(cachePrefix) else { return .opaque(key: key) }

        let name = String(key.dropFirst(cachePrefix.count))

        // ③ 站方变量（一整串）
        if name.hasPrefix(stationVariablePrefix) {
            return .stationVariable(sourceKey: String(name.dropFirst(stationVariablePrefix.count)))
        }
        // ④ 登录信息（密文）
        if name.hasPrefix(loginInfoPrefix) {
            return .loginInfo(sourceKey: String(name.dropFirst(loginInfoPrefix.count)))
        }
        // ⑤ 登录头
        if name.hasPrefix(loginHeaderPrefix) {
            return .loginHeader(sourceKey: String(name.dropFirst(loginHeaderPrefix.count)))
        }
        // ⑥ 书源变量（**每 k 一项**）⇒ 形如 `v_<源URL>_<变量名>`
        //    ⚠️⚠️ **源URL 里可能有下划线** ⇒ 必须从**最后一个**下划线处切分 ⭐⭐⭐
        //      （从第一个切会把 `https://a.com/x` 切成源=`https://a` 名字=`com/x` ⇒ 写错槽）⭐⭐⭐
        if name.hasPrefix(sourceVarPrefix) {
            let rest = String(name.dropFirst(sourceVarPrefix.count))
            guard let sep = rest.lastIndex(of: "_") else {
                return .opaque(key: key)
            }
            let sourceKey = String(rest[rest.startIndex..<sep])
            let varName = String(rest[rest.index(after: sep)...])
            guard !sourceKey.isEmpty, !varName.isEmpty else { return .opaque(key: key) }
            return .sourceVar(sourceKey: sourceKey, name: varName)
        }
        // ⑦ 其它缓存
        return .plainCache(key: key)
    }

    // MARK: - 值的编解码（柴阅 `CacheStore` 的 `deadline\u{1}value` 格式）

    /// ⭐⭐⭐ **写入轻阅槽前的值编码**（柴阅 `CacheStore` 期望 `deadline\u{1}value`）
    ///
    /// ⚠️ 柴阅的 `CacheStore.put` 会自己拼 `"\(deadline)\u{1}\(value)"` ⇒ **我们的 store 实现
    ///   收到的就是带前缀的串** ⇒ 落到轻阅槽前要**剥掉**前缀（轻阅槽存纯值）⭐⭐⭐
    ///   ⇒ 轻阅槽存纯值 ⇒ UI 侧读它不用解前缀 ⇒ **UI 不改** ✔ ⭐⭐⭐
    public static func stripDeadlinePrefix(_ raw: String) -> String {
        guard let sep = raw.firstIndex(of: "\u{1}") else { return raw }
        return String(raw[raw.index(after: sep)...])
    }

    /// ⭐⭐⭐ **从轻阅槽读出后、交给柴阅前的值编码**（补回 `deadline\u{1}`）
    ///
    /// ⚠️ 柴阅的 `CacheStore.get` 期望值形如 `deadline\u{1}value` ⇒ 我们从轻阅槽拿到纯值
    ///   ⇒ 要补 `0\u{1}`（0 = 永久）⇒ 柴阅才认得出分隔符 ⭐⭐⭐
    public static func addDeadlinePrefix(_ value: String) -> String {
        "0" + separator + value
    }

    /// ⭐⭐⭐ **书源变量名 ⇒ 轻阅 map 的项名**（不做任何变换；这里只提供恒等映射以便门禁对照）
    public static func sourceVarItemName(_ name: String) -> String { name }

    /// ⭐⭐⭐ **书源变量的 map 项 ⇒ 柴阅的一次 put**（轻阅 map 里加一项）
    ///
    /// ⚠️⚠️ **必须保留轻阅 map 里的其它项**（宿主写入的线路表等）⭐⭐⭐
    ///   ⇒ 柴阅的 `put(k,v)` 只改一项 ⇒ 轻阅侧也要只改一项 ⭐⭐⭐
    public static func applyingSourceVar(_ name: String, _ value: String, intoMap map: [String: String]) -> [String: String] {
        var out = map
        if value.isEmpty { out.removeValue(forKey: name) }
        else { out[name] = value }
        return out
    }
}
