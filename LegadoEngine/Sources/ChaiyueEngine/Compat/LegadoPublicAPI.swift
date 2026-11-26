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

// ⭐⭐⭐⭐⭐ **探索（explore）的诊断出口**（2026-11-21 真机「explore 结果不可信：书单 0 本」实证）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么必须有它**：
//   轻阅对 explore 的判定只有「返回 0 本 ⇒ 不可信」⇒ **分不清**下面三种 ⭐⭐⭐
//     ① **站方真的没数据**（源站挂了 / 该分类为空 / 要令牌）⇒ **书源/站方问题** ⭐⭐⭐
//     ② **站方有数据但规则没匹配上**（站方改版 ⇒ `ruleExplore.bookList` 过时）⇒ **书源问题** ⭐⭐⭐
//     ③ **URL 本身错了**（分类 URL 没求值 / 参数错）⇒ **引擎/宿主问题** ⭐⭐⭐
//   ⇒ 光看「0 本」**无法定责** ⇒ 必须让引擎**一次性把事实摆出来** ⭐⭐⭐
//
// ⭐⭐⭐ **本出口只发【一次】请求** ⇒ 书单与诊断来自**同一份响应**（不重复请求）⭐⭐⭐
extension WebBook {
    /// ⭐⭐⭐⭐⭐ **探索 + 诊断**（一次请求 ⇒ 书单 + 站方状态 + 字节数 + 规则是否命中）⭐⭐⭐
    public func exploreBookWithDiagnostics(url: String, page: Int = 1) async throws -> ([SearchBook], [String: String]) {
        try await RuleSession.run(SourceDescriptor(source), env: environment) { session in
            let ruleData = RuleData()
            let analyzeUrl = try AnalyzeUrl(url, page: page, baseUrl: session.source.key, session: session, ruleData: ruleData)
            let res = try WebBook.loginCheck(session, analyzeUrl, try analyzeUrl.getStrResponse())
            let body = res.body()

            // ── 诊断（只打键名/数字，**不打正文**，正文可能很大且含敏感信息）⭐⭐⭐
            var diag: [String: String] = [:]
            diag["请求URL"] = url
            diag["最终URL"] = res.url()
            diag["状态码"] = String(res.statusCode())
            diag["响应字节"] = String(body.utf8.count)
            let rule = self.source.exploreRule.bookList ?? ""
            diag["规则长度"] = String(rule.count)
            diag["规则是不是JS"] = (rule.hasPrefix("@js:") || rule.hasPrefix("<js>")) ? "是" : "否"
            diag["规则首段"] = String(rule.prefix(48)).replacingOccurrences(of: "\n", with: " ")

            let books = try BookListParser.analyze(session: session, ruleData: ruleData, analyzeUrl: analyzeUrl,
                                                   baseUrl: res.url(), body: body, isSearch: false,
                                                   isRedirect: res.url() != analyzeUrl.url)
            diag["解析出"] = "\(books.count) 本"
            // ⭐⭐⭐ **区分「站方没数据」与「规则没匹配上」** ⭐⭐⭐
            //   · 响应几乎为空 ⇒ 站方没给内容（站方/源站问题）⭐⭐⭐
            //   · 响应有内容但解析 0 条 ⇒ **规则没匹配上**（站方改版 ⇒ 书源规则过时）⭐⭐⭐
            let looksEmpty = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // ⭐⭐⭐⭐⭐ **站方错误信封识别**（2026-11-26 真机「书源规则过时」误报实证）⭐⭐⭐⭐⭐
            //   站方（大灰狼这类聚合源）失败时回的是 **JSON 错误信封**：
            //     {"code":-1,"msg":"Get \"https://api-bc.wtzw.com/...\": EOF","data":null}
            //   ⇒ 这**不是**「书源规则过时」，而是**站方自己连不上上游** ⇒ 必须分开报 ⭐⭐⭐
            var stationCode: Int?
            var stationMsg: String?
            if let data = body.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let n = obj["code"] as? NSNumber { stationCode = n.intValue }
                if let m = obj["msg"] as? String { stationMsg = m }
            }
            if let code = stationCode, code != 0 {
                diag["站方code"] = String(code)
                diag["站方msg"] = stationMsg ?? ""
                diag["判定"] = "站方接口报错：\(stationMsg ?? "（无 msg）")"
            } else {
                diag["判定"] = books.isEmpty
                    ? (looksEmpty ? "站方返回空内容（源站/站方问题）" : "站方有内容但规则未匹配（书源规则过时）")
                    : "正常"
            }
            return (books, diag)
        }
    }
}


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

