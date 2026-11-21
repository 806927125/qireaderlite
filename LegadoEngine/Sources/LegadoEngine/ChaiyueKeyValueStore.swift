import Foundation
import ChaiyueModels
import ChaiyueEngine

// ⭐⭐⭐⭐⭐ **柴阅的 `KeyValueStore` ⇒ 轻阅存储槽 的适配器**（2026-11-21 移植）
//
// ⚠️⚠️⚠️ **为什么必须有它**（移植柴阅的核心接线）：
//   柴阅把书源状态写进 `KeyValueStore`，键名形如 `cache_v_<源URL>_<变量名>` ⭐⭐⭐
//   轻阅的状态在 **UserDefaults 的三个槽**（书源变量 JSON map / 站方变量整串 / 登录信息）⭐⭐⭐
//   ⇒ 两边**键结构与值的形态都不同** ⇒ 必须有一层明确映射 ⭐⭐⭐
//   ⇒ ⚠️ **漏映射的后果很隐蔽**：解锁态存不下来 ⇒ 下次又是未解锁 ⇒ **发现页 0 分类**
//     （这正是 build297–302 反复踩的坑）⇒ **这层必须有门禁** ⭐⭐⭐
//
// ⭐⭐⭐ **为什么把映射逻辑放在引擎包（而不是 App 层）**：
//   ⇒ 放在这里 ⇒ **Linux 沙盒可编** ⇒ 门禁能逐条验映射表 ⭐⭐⭐
//   ⇒ App 层只提供「槽的读写」和「loginInfo 的加解密」两个闭包 ⇒ 引擎包不依赖 App ⭐⭐⭐
public final class ChaiyueKeyValueStore: KeyValueStore, @unchecked Sendable {
    /// ⭐⭐⭐ **轻阅的槽标识（供 App 层实现读写）** —— 单一真相在 `ChaiyueStoreMapping.Slot` ⭐⭐⭐
    ///   （⚠️ 别在这里另开一份枚举 ⇒ 两份定义会漂移 ⇒ 门禁抓不到）⭐⭐⭐
    public typealias SlotRef = ChaiyueStoreMapping.Slot

    // MARK: - App 层注入的四个能力（引擎包不依赖 App ⇒ 用闭包）

    /// 读轻阅的槽
    public var readSlot: (SlotRef) -> String?
    /// 写轻阅的槽（`nil` = 删除）
    public var writeSlot: (SlotRef, String?) -> Void
    /// ⭐⭐⭐ **列出【全部】书源变量（源 URL + 变量名）** ⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么是「全量」而不是「按源查」**：
    ///   柴阅用 `keys(withPrefix: "cache_v_<源URL>_")` 枚举 ⇒ **要从前缀反推源 URL** ⭐⭐⭐
    ///   ⚠️ 但**源 URL 里可能含下划线**（如 `https://a.com/x_y`）⇒ 反推**有歧义** ⭐⭐⭐
    ///   ⇒ 正解：**全量枚举 + 前缀过滤**（不切前缀 ⇒ 无歧义）⭐⭐⭐
    public var listAllSourceVars: () -> [(sourceKey: String, name: String)]
    /// 列出某个源的**全部缓存键名**（柴阅 `cache_` 命名空间里的普通缓存）
    public var listPlainCacheKeys: (String) -> [String]
    /// ⭐⭐⭐ **loginInfo：轻阅存储形态 ⇒ 柴阅形态**（轻阅存**明文 JSON** ⇒ 柴阅要 **Base64 密文**）⭐⭐⭐
    public var loginInfoToChaiyue: (String) -> String
    /// ⭐⭐⭐ **loginInfo：柴阅形态 ⇒ 轻阅存储形态**（Base64 密文 ⇒ 明文 JSON）⭐⭐⭐
    public var loginInfoFromChaiyue: (String) -> String

    private let lock = NSLock()

    public init(readSlot: @escaping (SlotRef) -> String?,
                writeSlot: @escaping (SlotRef, String?) -> Void,
                listAllSourceVars: @escaping () -> [(sourceKey: String, name: String)],
                listPlainCacheKeys: @escaping (String) -> [String] = { _ in [] },
                loginInfoToChaiyue: @escaping (String) -> String = { $0 },
                loginInfoFromChaiyue: @escaping (String) -> String = { $0 }) {
        self.readSlot = readSlot
        self.writeSlot = writeSlot
        self.listAllSourceVars = listAllSourceVars
        self.listPlainCacheKeys = listPlainCacheKeys
        self.loginInfoToChaiyue = loginInfoToChaiyue
        self.loginInfoFromChaiyue = loginInfoFromChaiyue
    }

    // MARK: - KeyValueStore

    public func string(forKey key: String) -> String? {
        let slot = ChaiyueStoreMapping.slot(forChaiyueKey: key)
        switch slot {
        case .sourceVar(let sourceKey, let name):
            // ⭐⭐⭐ **书源变量**：轻阅那边是**一个 JSON map** ⇒ 取其中一项 ⭐⭐⭐
            guard let raw = readSlot(.sourceVar(sourceKey: sourceKey, name: name)) else { return nil }
            return raw.isEmpty ? nil : raw
        case .loginInfo(let sourceKey):
            guard let raw = readSlot(.loginInfo(sourceKey: sourceKey)) else { return nil }
            return raw.isEmpty ? nil : loginInfoToChaiyue(raw)
        default:
            return readSlot(slot)
        }
    }

    public func set(_ value: String?, forKey key: String) {
        let slot = ChaiyueStoreMapping.slot(forChaiyueKey: key)
        switch slot {
        case .sourceVar(let sourceKey, let name):
            // ⚠️⚠️ **柴阅的 `CacheStore` 存的值带 `deadline\u{1}` 前缀** ⇒ 要剥掉再落轻阅槽 ⭐⭐⭐
            //   （轻阅的槽存**纯值** ⇒ UI 读它不用解前缀 ⇒ **UI 不改** ✔）⭐⭐⭐
            let pure = value.map { ChaiyueStoreMapping.stripDeadlinePrefix($0) }
            writeSlot(.sourceVar(sourceKey: sourceKey, name: name), pure)
        case .loginInfo(let sourceKey):
            let pure = value.map { ChaiyueStoreMapping.stripDeadlinePrefix($0) }
            writeSlot(.loginInfo(sourceKey: sourceKey), pure.map { loginInfoFromChaiyue($0) })
        default:
            writeSlot(slot, value.map { ChaiyueStoreMapping.stripDeadlinePrefix($0) })
        }
    }

    public func keys(withPrefix prefix: String) -> [String] {
        // ⭐⭐⭐ **枚举**：柴阅用它扫「这个源的全部书源变量」⭐⭐⭐
        //   ⇒ 柴阅的键 = `cache_` + `v_<源URL>_<变量名>` ⇒ 我们按前缀反推 ⭐⭐⭐
        // ⭐⭐⭐ **书源变量**：全量枚举 + 前缀过滤（**不切前缀 ⇒ 无歧义**）⭐⭐⭐
        let vPrefix = ChaiyueStoreMapping.cachePrefix + ChaiyueStoreMapping.sourceVarPrefix
        if prefix.hasPrefix(vPrefix) {
            var out: [String] = []
            for item in listAllSourceVars() {
                let key = "\(vPrefix)\(item.sourceKey)_\(item.name)"
                if key.hasPrefix(prefix) { out.append(key) }
            }
            return out
        }
        // 其它命名空间：交给 App 侧列
        if prefix.hasPrefix(ChaiyueStoreMapping.cachePrefix) {
            return listPlainCacheKeys(prefix)
        }
        return []
    }
}
