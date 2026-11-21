// ⭐⭐⭐⭐⭐ **移植补丁（2026-11-21）：给宿主开「公开出口」** ⭐⭐⭐
//
// ⚠️⚠️ **为什么需要**：柴阅的引擎内部（`RuleSession` / `SourceState` / `JSSource` /
//   `JSSymmetricCrypto`）**全是 internal** ⇒ 外部（轻阅宿主）拿不到 ⭐⭐⭐
//   ⇒ 而轻阅宿主需要两件事：
//     ① **导出这个源的全部书源变量**（`source.getAllVars()` 的等价物）⭐⭐⭐
//        ⇒ 柴阅**没有**这个能力（它只按 key 存取）⇒ 宿主无法把状态落盘 ⭐⭐⭐
//        ⇒ ⚠️ 而这正是 build297–302 反复踩的坑（解锁态存不下来 ⇒ 下次又交白卷）⭐⭐⭐
//     ② **登录信息的加解密**（柴阅存 AES 密文、轻阅 UI 要明文 ⇒ 必须能互转）⭐⭐⭐
//
// ⚠️⚠️ **与上游的 diff**：本文件是**新增**的 ⇒ 同步柴阅上游时保留即可（不冲突）⭐⭐⭐
import Foundation
import ChaiyueModels

// MARK: - ① 导出全部书源变量

extension CacheStore {
    /// ⭐⭐⭐ **按前缀列键**（柴阅的 `CacheStore` 没暴露 ⇒ 这里补一个）⭐⭐⭐
    /// ⚠️ 注意柴阅的 `CacheStore` 内部存的值带 `deadline\u{1}` 前缀 ⇒ 只取键名 ⭐⭐⭐
    func keys(withPrefix prefix: String) -> [String] {
        store.keys(withPrefix: prefix)
    }
}

extension SourceState {
    /// ⭐⭐⭐⭐⭐ **导出这个源的全部书源变量**（`source.getAllVars()` 的等价物）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么必须有**（移植柴阅实证）：
    ///   柴阅的书源变量按 `v_<源URL>_<变量名>` 存在 store 里 ⇒ **没有「导出全部」的入口** ⭐⭐⭐
    ///   ⇒ 宿主拿不到完整状态 ⇒ **落盘不了** ⇒ **解锁态存不下来** ⇒ 下次又是未解锁 ⭐⭐⭐
    ///   ⇒ 这正是轻阅 build297–302 反复修的那个坑 ⇒ 移植后**不能重犯** ⭐⭐⭐
    ///
    /// ⚠️ **键名切分用「最后一个下划线」**（源 URL 里可能含下划线 ⇒ 从第一个切会切错）⭐⭐⭐
    func allSourceVars() -> [String: String] {
        let prefix = "v_\(key)_"
        var out: [String: String] = [:]
        for storageKey in cache.keys(withPrefix: prefix) {
            let name = String(storageKey.dropFirst(prefix.count))
            guard !name.isEmpty else { continue }
            if let raw = cache.get(storageKey), !raw.isEmpty {
                out[name] = raw
            }
        }
        return out
    }
}

#if canImport(JavaScriptCore) && !os(Linux)
extension JSSource {
    /// ⭐⭐⭐ **JS 侧的一次性导出**（站方脚本可用 `source.getAllVars()`）⭐⭐⭐
    func getAllVars() -> [String: String] {
        session.state.allSourceVars()
    }
}
#endif

// MARK: - ③ 诊断出口（宿主 `explain` / `explainToc` op 用）

/// ⭐⭐⭐⭐⭐ **诊断出口：发一次请求，把 URL/状态/字节报出来** ⭐⭐⭐
///
/// ⚠️ **为什么需要**：轻阅的 `explain` / `explainToc` 是**诊断 op**
///   （老引擎退役后用新引擎的 `AnalyzeUrl` 复刻）⭐⭐⭐
///   ⇒ 而柴阅的 `AnalyzeUrl` 是 **internal** ⇒ 宿主拿不到 ⇒ 必须开这个出口 ⭐⭐⭐
public enum ChaiyueDiagnostics {
    /// ⭐⭐⭐ **请求一次并回报诊断信息**（键名与轻阅 UI 期望的一致）⭐⭐⭐
    public static func probe(url: String,
                             source: BookSource,
                             environment: SourceEnvironment) async throws -> [String: String] {
        let descriptor = SourceDescriptor(source)
        return try await RuleSession.run(descriptor, env: environment) { session in
            let au = try AnalyzeUrl(url, session: session)
            let res = try au.getStrResponse()
            return [
                "请求URL": url,
                "最终URL": res.url(),
                "状态码": String(res.statusCode()),
                "响应字节": String(res.body().utf8.count),
                "页面标题": "",
            ]
        }
    }
}

// MARK: - ② 登录信息加解密（柴阅的密文格式 ⇄ 明文）

/// ⭐⭐⭐⭐⭐ **柴阅的登录信息加解密（公开出口）** ⭐⭐⭐
///
/// ⚠️⚠️ **为什么必须有**：柴阅把登录信息**加密**存（`userInfo_<key>`）⇒ 轻阅的 UI（登录面板）
///   要**明文**（不改 UI）⇒ 必须能互转 ⭐⭐⭐
///   ⇒ 顺带的好处：**存储格式与柴阅一致** ⇒ 将来若直接用柴阅的 App 也兼容 ⭐⭐⭐
public enum ChaiyueLoginCrypto {
    /// ⭐⭐⭐ 柴阅的登录信息密钥来源：`androidID` 的前 16 字节 ⭐⭐⭐
    /// ⚠️ **必须与引擎一致**（否则解不开）⇒ 由宿主的 `SourceEnvironment.androidID` 派生 ⭐⭐⭐
    public static func key(fromAndroidID androidID: String) -> Data {
        Data(androidID.utf8.prefix(16))
    }

    /// ⭐⭐⭐ **明文 ⇒ 柴阅的存储形态**（Base64 密文）⭐⭐⭐
    public static func encrypt(_ plain: String, androidID: String) throws -> String {
        let crypto = JSSymmetricCrypto(transformation: "AES", key: key(fromAndroidID: androidID), iv: nil)
        let data = try crypto.encryptData(Data(plain.utf8))
        return Base64Codec.encode(data)
    }

    /// ⭐⭐⭐ **柴阅的存储形态 ⇒ 明文** ⭐⭐⭐
    public static func decrypt(_ stored: String, androidID: String) throws -> String {
        let crypto = JSSymmetricCrypto(transformation: "AES", key: key(fromAndroidID: androidID), iv: nil)
        guard Base64Codec.decode(stored) != nil else {
            throw CryptoError.failed("登录信息不是合法的 Base64")
        }
        return try crypto.decryptString(stored)
    }
}

