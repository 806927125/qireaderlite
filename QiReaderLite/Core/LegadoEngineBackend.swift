import Foundation
import LegadoCore

// ⚠️ Linux（沙盒 swiftc）上 URLSession 在 FoundationNetworking 里，iOS 上在 Foundation
//    ⇒ 条件导入，两边都能编 ✅
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 类型别名（轻阅的模型 vs 引擎的模型）

/// ⭐⭐⭐ **引擎的书源模型**（`legado-engine` 的 `BookSource`）
typealias EngineSource = LegadoCore.BookSource
/// ⭐⭐ **引擎的书模型**
typealias EngineBook = LegadoCore.Book
/// ⭐⭐ **引擎的章节模型**
typealias EngineChapter = LegadoCore.Chapter
/// ⭐⭐ **引擎的详情模型**
typealias EngineBookInfo = LegadoCore.BookInfo
/// ⭐⭐ **引擎的 cookie 罐**（⚠️ 轻阅自己也有一个 `CookieJar` ⇒ 必须带限定名）
typealias EngineCookieJar = LegadoCore.CookieJar

// MARK: - ① 传输层

/// ⭐⭐⭐ **URLSession 传输**（**同步**）
///
/// ⚠️ **同步是引擎的硬要求**（引擎内部全同步）⇒ 这里用信号量等 `URLSession` 的回调。
/// ⇒ ⚠️ **绝不能在主线程调用**（会卡死 UI）⇒ 调用方（`SourceService`）把它丢到后台队列。
///
/// ⭐ **三件必须跟老引擎对齐的事**：
/// ① **`data:` 伪 URL 绝不能真去 fetch**（站方聚合源的 bookUrl / tocUrl 是
///    `data:;base64,<载荷>,{"type":"qingtian"}` ⇒ 真 fetch 会抛
///    「illegal base64 data at input byte 9」⇒ **整本书崩**）⭐
/// ② **cookie 走系统共享罐**（`HTTPCookieStorage.shared`）⇒ 登录态自动带上 / 自动存回
/// ③ **源级请求头**由引擎塞进 `request.headers`（54 个源在用 ⇒ 缺了就 403）
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        // ⭐ cookie 走**系统共享罐** ⇒ 登录态自动带上 / Set-Cookie 自动存回
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // ⭐⭐⭐ **请求超时 30 秒 → 8 秒**（2026-10-24 真机「app 死机」）
        //   老引擎的「两遍跑」**只抓同组第一条** ⇒ 站方 8 条线路一次操作只发 1 个请求
        //   ⇒ 新引擎是「每次 java.ajax 都真发」⇒ 站方 catch 循环里 **8 条线路各发一次**
        //   ⇒ 死线路（服务器不回包）**每条 30 秒** ⇒ 8 条 = 4 分钟 ⇒ 一次发现页 = 十几分钟
        //   ⇒ 用户看到的就是「app 死机」⭐⭐⭐
        //   ⇒ 现在：**8 秒** ⇒ 8 条死线路最坏 64 秒（而且 op 本身有 60 秒兜底）
        //   ⇒ 活着���线路照旧很快（正常几百 ms）⭐
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        // ① ⭐⭐⭐ **`data:` 伪 URL** ⇒ 载荷就是「页面内容」⇒ 直接当响应体返回
        if request.url.lowercased().hasPrefix("data:") {
            let payload = Self.dataPayload(request.url)
            return HTTPResponse(statusCode: 200, headers: [:],
                                body: Data(payload.utf8), finalURL: request.url)
        }
        guard let url = URL(string: request.url) else {
            throw SourceError.requestFailed(request.url, "URL 非法")
        }
        var req = URLRequest(url: url)
        req.httpMethod = request.method
        req.timeoutInterval = request.timeout
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        // ⚠️ cookie **交给 URLSession 的共享罐**处理（`HTTPCookieStorage.shared`）
        // ⇒ 不用手工塞 Cookie 头（塞了会和共享罐打架 ⇒ 两个 Cookie 头）

        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            if let err { box.fail(err); sem.signal(); return }
            let http = resp as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                guard let k = k as? String else { continue }
                headers[k] = (v as? String) ?? String(describing: v)
            }
            box.succeed(HTTPResponse(statusCode: http?.statusCode ?? 0,
                                      headers: headers,
                                      body: data ?? Data(),
                                      finalURL: http?.url?.absoluteString))
            sem.signal()
        }.resume()
        // ⭐ 超时比请求超时多给 5 秒 ⇒ 别把「网络慢」误报成「引擎卡死」
        if sem.wait(timeout: .now() + request.timeout + 5) == .timedOut {
            throw SourceError.requestFailed(request.url, "请求超时（\(Int(request.timeout))s）")
        }
        return try box.take()
    }

    /// ⭐ **`data:` 伪 URL 的载荷**
    ///
    /// 格式：`data:;base64,<载荷>,{"type":"qingtian2"}`
    /// ⇒ 载荷在 `;base64,` 之后、**下一个逗号**之前。
    ///
    /// ⚠️ **解不了就返回原文**（不许崩、不许返回乱码）⇒ 上层至少还能显示点东西
    static func dataPayload(_ raw: String) -> String {
        let rest = String(raw.dropFirst("data:".count))
        guard let firstComma = rest.firstIndex(of: ",") else { return rest }
        let mediatype = String(rest[rest.startIndex..<firstComma])
        let isBase64 = mediatype.lowercased().contains("base64")
        var payload = String(rest[rest.index(after: firstComma)...])
        if isBase64, let comma = payload.firstIndex(of: ",") {
            payload = String(payload[payload.startIndex..<comma])
        }
        if isBase64 {
            if let d = Data(base64Encoded: payload, options: []),
               let s = String(data: d, encoding: .utf8) { return s }
            // ⚠️ 非法 base64 ⇒ **明确失败**（返回空串）而不是乱码
            //   （乱码 ⇒ 站方 JSON.parse 炸 ⇒ 整条规则挂掉）
            return ""
        }
        return payload
    }

    /// 线程安全的单值盒子（URLSession 回调 → 等待方）
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<HTTPResponse, Error>?
        func succeed(_ r: HTTPResponse) { lock.lock(); value = .success(r); lock.unlock() }
        func fail(_ e: Error) { lock.lock(); value = .failure(e); lock.unlock() }
        func take() throws -> HTTPResponse {
            lock.lock(); defer { lock.unlock() }
            switch value {
            case .success(let r): return r
            case .failure(let e): throw e
            case .none: throw SourceError.requestFailed("?", "请求没有返回结果")
            }
        }
    }
}

/// ⭐⭐⭐ **日志回主线程**（文件级 ⇒ 适配层里谁都能用）
///
/// ⚠️ `RuleSandbox` 是 **`@MainActor`** ⇒ 后台线程（引擎在那边跑）**不能直接调**
/// ⇒ 否则编译期就报「call to main actor-isolated instance method in a synchronous
///    nonisolated context」（**真机 CI 才暴露** ⇒ 沙盒 stub 必须也标 `@MainActor` 才拦得住）⭐

/// ⭐⭐⭐ **把引擎日志挂到「引擎日志」面板**（App 启动时挂一次 ⇒ 别处直接用 `engineLog`）
///
/// ⚠️ **为什么要挂**（2026-10-28）：诊断写在 `NSLog` 里 ⇒ **只进设备控制台，用户看不到**
///   ⇒ 真机排查只能靠「让用户去 Xcode 看控制台」⇒ 一轮一条信息 ⇒ 极慢 ⭐⭐⭐
///   ⇒ 挂上面板 ⇒ 用户「复制日志」就有 ⭐⭐⭐
enum EngineLogBootstrap {
    static func install() {
        EngineLog.sink = { message in
            Task { @MainActor in RuleSandbox.shared.appendLog(message) }
        }
    }
}

// ⭐⭐⭐ **把【引擎的诊断】送进 App 的「引擎日志」**（2026-10-24 真机栽的）
//
// ⚠️⚠️ **以前 App 没给引擎传 logger** ⇒ 引擎算出了什么、哪条规则没命中、
//   `java.ajax` 为什么失败 ⇒ **一条都看不到** ⇒ 只能靠猜 ⭐⭐
//   （真机表现：发现页冒出「未分组」假分类 ⇒ 但日志里只有 App 自己那两行）
//
// ⇒ 现在引擎的每条诊断（分支 / 失败原因 / 规则名）都会进同一个日志面板
//   ⇒ 用户把「引擎日志」贴回来 ⇒ 就是**可证伪的观测**（不用再猜）⭐
final class EngineDiagnosticLogger: EngineLogger, @unchecked Sendable {
    func log(_ message: String) { engineLog("[新引擎] " + message) }
}

// MARK: - ② 站方 JS 的宿主 API

/// ⭐⭐⭐ **站方 JS 的宿主 API**（`JSHostAPIProvider`）
///
/// 站方 JS 会调：`java.toast` / `java.log` / `java.getCookie` / `java.cacheFile` /
/// `source.getVariable` / `book.getVariable` / `chapter.xxx` …
///
/// ⚠️ **书源 / 书籍 / 章节对象由引擎自己管**（`SourceEngine.bookObject` 等）
/// ⇒ 这里直接转发给引擎 ⇒ 不会出现「两套对象、内容不一致」。
final class EngineHostAPI: JSHostAPIProvider, @unchecked Sendable {

    private let session: LegadoEngineBackend.Session

    init(session: LegadoEngineBackend.Session) { self.session = session }

    func hostObject(named name: String) -> HostObject? {
        switch name {
        case "source": return session.engine?.sourceObject
        case "book": return session.engine?.bookObject
        case "chapter": return session.engine?.chapterObject
        // ⭐⭐ **cookie 宿主对象**（站方 `cookie.*` —— 真实语料 205 处）
        case "cookie": return session.engine?.cookieObject
        default: return nil
        }
    }

    func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
        let first = args.first?.scalarString ?? ""
        switch method {
        case "toast":
            Toast.show(first)
            return .string("")
        // ⭐⭐⭐ **`java.longToast` = `java.toast` 的别名**（老引擎 `java-api.js` 里两者代码逐字相同）
        //   ⇒ 站方 125 源实测 **114 处**在用 ⇒ 不实现 ⇒ 站方 JS 第一句就 TypeError ⇒ **整条规则死定**
        //   （2026-10-25 真机实证：build247 的「发现功能」就炸在这）⭐⭐⭐
        case "longToast":
            Toast.show(first)
            return .string("")
        // ⭐⭐⭐ **`java.androidId`**（站方 125 源实测 **18 处**）
        //   老引擎：`androidId: function () { return java.deviceID(); }` ⇒ 就是 deviceID 的别名
        //   ⇒ 站方写法：`try { raw = java.androidId(); } catch (e) { try { raw = java.deviceID(); } catch (e2) {} }`
        //   ⇒ **两个都要有**（站方拿它当设备标识 ⇒ 登录态/解锁状态会绑到它上面）⭐⭐⭐
        //   ⚠️ 同步上下文 ⇒ 直接取 `identifierForVendor`（与 `RuleSandbox` 的 `deviceID` op 同源）⭐
        case "androidId":
            // ⭐⭐⭐ **设备 ID 走 `UserDefaults` 传递**（纯 Foundation ⇒ 沙盒 swift 门禁能编）
            //   ⚠️ 本文件**不许碰 UIKit / RuleSandbox**（沙盒在 Linux 上编译 ⇒ import UIKit 编不过）⭐⭐⭐
            //   ⇒ App 启动时（`RuleSandbox`，那边有 UIKit）把真设备 ID 写进来 ⭐
            return .string(UserDefaults.standard.string(forKey: "qr.deviceID") ?? "")
        // ⭐⭐ **浏览器类**（`startBrowserAwait` 27 处 / `startBrowserDp` 6 处 / `showReadingBrowser` 6 处）
        //   老引擎是**同步等用户关掉**（两遍跑机制）⇒ 新引擎是同步引擎 ⇒ 没法在这儿等
        //   ⇒ 先**触发打开**（不等）⇒ 站方第二遍再来取 cookie ⇒ 与老引擎的「两遍跑」同思路 ⭐⭐⭐
        //   ⚠️ **绝不抛**（站方不少地方没包 try/catch ⇒ 抛了整条规则死定）⭐⭐⭐
        case "startBrowserAwait", "startBrowserDp", "showReadingBrowser", "showBrowser", "startBrowser":
            // ⭐⭐⭐ **绝不抛**（站方不少地方没包 try/catch ⇒ 抛了整条规则死定）⭐⭐⭐
            //   老引擎是「同步等用户关掉」（两遍跑机制）⇒ 新引擎是同步引擎 ⇒ 这里等不了
            //   ⇒ 先只记一笔；**弹浏览器**交给 `RuleSandbox` 的 op（那边有 UIKit）⭐
            let title = args.count > 1 ? args[1].scalarString : ""
            engineLog("[宿主] \(method)：\(first) \(title)")
            // ⚠️ 本层不能碰 UIKit ⇒ 真正的「打开」由 `RuleSandbox` 的 op 负责（那边有 UIKit）⭐
            return .string("")
        case "log":
            engineLog(first)
            return .string("")
        case "getCookie":
            return .string(CookieJar.cookieString(for: first))
        case "cacheFile":
            if args.count >= 2 {
                _ = CacheFiles.write(first, args[1].scalarString)
            }
            return .string("")
        case "readFile":
            return .string(CacheFiles.read(first) ?? "")
        default:
            // ⭐ 不接管 ⇒ 落回引擎侧（md5 / base64 / ajax / getString / put …）
            return nil
        }
    }
}

// MARK: - ① 之二 cookie 服务（站方 `cookie.*` —— 真实语料 205 处）

/// ⭐⭐ **cookie 服务**（站方 `cookie.getCookie` / `setCookie` / `removeCookie` / `replaceCookie`）
///
/// ⚠️ 轻阅的 cookie 罐就是**系统共享罐**（`HTTPCookieStorage.shared`）
/// ⇒ 跟 `URLSession` 自动带的 cookie 是**同一份** ⇒ 站方改了立刻生效 ✅
final class AppCookieService: CookieService, @unchecked Sendable {

    func cookieHeader(for url: String) -> String {
        CookieJar.cookieString(for: url)
    }

    func setCookie(_ value: String, for url: String) {
        CookieJar.set(value, for: url)
    }

    func removeCookie(for url: String) {
        CookieJar.remove(for: url)
    }

    func replaceCookie(_ value: String, for url: String) {
        CookieJar.remove(for: url)
        CookieJar.set(value, for: url)
    }
}

// MARK: - ② 源级键值存储

/// ⭐⭐ **源级键值存储**（登录信息 ⇒ 站方 `source.getLoginInfoMap()` 读它）
///
/// ⚠️ 轻阅的登录信息存在 `SourceVariables`（UserDefaults）⇒ 这里直接读写它
/// ⇒ 站方 JS 改了就落盘 ⇒ 下次直接生效。
final class SourceStorage: KeyValueStorage, @unchecked Sendable {
    private let sourceUrl: String
    init(sourceUrl: String) { self.sourceUrl = sourceUrl }

    func string(forKey key: String) -> String? {
        if key == SourceEngine.loginInfoKey {
            let info = SourceVariables.loginInfo(for: sourceUrl)
            guard !info.isEmpty else { return nil }
            if let d = try? JSONSerialization.data(withJSONObject: info),
               let t = String(data: d, encoding: .utf8) { return t }
            return nil
        }
        // ⭐ **登录头**（站方 `source.getLoginHeader()` / `putLoginHeader`）
        if key == SourceEngine.loginHeaderKey {
            let h = SourceVariables.loginHeader(for: sourceUrl)
            return h.isEmpty ? nil : h
        }
        return nil
    }

    func setString(_ value: String?, forKey key: String) {
        if key == SourceEngine.loginInfoKey {
            SourceVariables.setLoginInfoJSON(value ?? "", for: sourceUrl)
        }
        if key == SourceEngine.loginHeaderKey {
            SourceVariables.setLoginHeader(value ?? "", for: sourceUrl)
        }
    }

    func removeValue(forKey key: String) {
        if key == SourceEngine.loginInfoKey {
            SourceVariables.setLoginInfoJSON("", for: sourceUrl)
        }
        if key == SourceEngine.loginHeaderKey {
            SourceVariables.setLoginHeader("", for: sourceUrl)
        }
    }

    func allKeys() -> [String] { [SourceEngine.loginInfoKey, SourceEngine.loginHeaderKey] }
}

// MARK: - ③ 后端

/// ⭐⭐⭐ **新引擎后端** —— 轻阅主链路的规则引擎。
///
/// ⚠️ **为什么要它**：老引擎是 11 个 JS 文件（9845 行）跑在 WKWebView 里（**异步**），
/// 自研引擎（`legado-engine`）是纯 Swift（**全同步**、可诊断、跨平台）⇒
///
/// ⇒ 这个类负责三件事：
/// ① **模型转换**：轻阅的 `BookSource` ⇒ 引擎的 `BookSource`
/// ② **能力接线**：URLSession 传输 / 站方 JS 的宿主 API / 源级变量
/// ③ **形状对齐**：op 的载荷与返回值，**和老引擎一模一样** ⇒ 上层（`SourceService`）不用改
///
/// ⭐ **每个源一个会话**（jsLib 定义的全局、源级变量要长期留着 ⇒ 不能每次重建）
final class LegadoEngineBackend: @unchecked Sendable {

    static let shared = LegadoEngineBackend()

    private var sessions: [String: Session] = [:]
    private let lock = NSLock()

    // MARK: 会话

    /// ⭐ **一个源的会话**（引擎 + 源级变量 + cookie 罐）
    final class Session: @unchecked Sendable {
        let engineSource: EngineSource
        /// ⭐ 引擎（**先建 API 再建引擎** ⇒ 两者互相引用）
        var engine: SourceEngine?
        let jar: EngineCookieJar
        /// ⚠️ **必须是 `var`**：它要拿 `self` 构造（`EngineHostAPI(session: self)`）
        ///   ⇒ 而那时 `let` 属性还没全初始化 ⇒ 用 `let` 编译不过（'self' used before all stored properties are initialized）
        var api: EngineHostAPI!
        /// ⭐ **源级键值存储**（登录信息 ⇒ 站方 `source.getLoginInfoMap()` 读它）
        let storage: SourceStorage
        /// ⭐⭐⭐ **站方变量槽**（Legado 语义：`source.getVariable()` = **这一串**）
        ///
        /// ⚠️⚠️ **为什么要跟「书源变量」（`source.get/put`）分开**（2026-10-27 实证）：
        ///   Legado 是两套 ⇒ 混成一套 ⇒ 站方 `setVariable(token)` 会把 `put` 存的项冲掉
        ///   ⇒ UAA 源 ⇒ 请求头 `Bearer {"androidId":…}` ⇒ 服务端 403「无效JWT」⇒ 拿不到 token ⭐⭐⭐
        ///   ⇒ **槽位是引用（class）** ⇒ 每个 op 改 `text` 即可 ⇒ 已建好的 sourceObject 也看得见 ⭐
        let sourceVariable = TextSlot()
        /// ⭐⭐⭐ **站方 jsLib**（引擎的 `BookSource` 没这个字段 ⇒ 单独带进来）
        ///
        /// ⚠️ 它定义的是**全局**（`host` / `getArguments` …）⇒ 站方规则的**前提**
        /// ⇒ 加载完必须 `markGlobalsAsBaseline()`，否则下次求值会被清掉 ⭐
        let jsLib: String?

        init(source: EngineSource, jar: EngineCookieJar, jsLib: String? = nil) throws {
            self.engineSource = source
            self.jar = jar
            self.jsLib = jsLib
            self.storage = SourceStorage(sourceUrl: source.bookSourceUrl)
            // ⚠️ 这一行**必须**在所有 `let` 初始化之后（`api` 要拿 self）
            self.api = EngineHostAPI(session: self)
            // ⭐ JSC 后端（iOS/macOS 有 JavaScriptCore ⇒ 站方 JS 规则能跑）
            #if canImport(JavaScriptCore)
            // ⭐⭐⭐ **JSC 已从 App 里删除**（2026-10-26 用户明确：「JSC 给我彻底删掉哈」）
            //   ⇒ 站方 JS 改由 **WKWebView 独立进程** 跑（跟老引擎一样）⇒ 它吃多少内存都炸不到 App ⭐⭐⭐
            let js: JSExecutor? = JSEngineFactory.make(api)
            #else
            let js: JSExecutor? = nil
            #endif
            // ⭐⭐⭐ **HTTP 缓存**（2026-10-24 真机「app 死机」的第二根因）
            //   引擎自带 `CachedTransport`（装饰器）⇒ 宿主按需启用
            //   ⚠️ 之前**没接** ⇒ 每个 op 都**重新 ajax 站方**
            //   ⇒ 大灰狼的 `exploreUrl` 每次都自己去 ajax `/discovestyle`（365 个分类）
            //   ⇒ 发现页「拉分类 → 拉书 → 翻页」= **同一个 URL 跑 3 次** ⇒ 每次都等服务器
            //   ⇒ 一次发现页 = 几十秒起步 ⇒ 用户以为 App 死了 ⭐⭐⭐
            //   ⇒ 现在：60 秒 TTL 的缓存 ⇒ 同一个响应 60 秒内只请求一次 ⭐
            //
            // ⚠️ TTL 别太长（书源内容会变）⇒ 60 秒刚好够「一次发现页」复用 ⭐
            let transport = CachedTransport(inner: URLSessionTransport(), ttl: 60, capacity: 64)
            let engine = SourceEngine(source: source,
                                      fetcher: PageFetcher(transport: transport, cookieJar: jar),
                                      js: js,
                                      storage: storage,
                                      // ⭐⭐⭐ **必须传 logger** ⇒ 引擎的诊断才看得见
                                      logger: EngineDiagnosticLogger(),
                                      cookies: AppCookieService(),
                                      // ⭐⭐⭐ 站方变量槽（Legado 两套语义）⭐
                                      sourceVariable: sourceVariable)
            self.engine = engine
            // ⭐⭐⭐ **站方 jsLib** ⇒ 加载到 JS **全局**（它定义的 `host` / `getArguments` 等
            //   是站方规则的前提）⇒ 加载完必须**重设基线**，否则下次求值会被清掉 ⭐
            //
            // ⚠️⚠️ **必须走 `loadJsLib`**（间接 eval ⇒ 全局作用域）——
            //   普通规则求值用的是 **eval 局部作用域**（防 `let device_type` 撞全局）⭐
            if let lib = jsLib, !lib.isEmpty {
                do {
                    try engine.loadJsLib(lib)
                } catch {
                    // ⚠️⚠️ **jsLib 加载失败必须「报出来」**（不能静默吞）
                    //   ⇒ 站方 jsLib 挂了 ⇒ 站方 JS 会走兜底分支 ⇒ 分类变成假分类 ⇒ 整本书打不开
                    //   ⇒ 而用户看到「失败原因」那行才知道**真凶**（2026-10-23 真机栽的）⭐
                    engineLog("[新引擎] jsLib 加载失败：\(error)")
                    throw error
                }
            }
        }
    }

    // MARK: 对外

    /// ⭐⭐⭐ **跑一个 op**
    ///
    /// - Returns: `nil` = **「这个 op 新引擎不支持」** ⇒ 调用方回退老引擎
    ///   （登录 / 诊断 / 站方变量那几类还留在老引擎上）
    /// ⭐⭐⭐ **当前正在跑的 op**（日志/桥接层要它 ⇒ 「是哪个 op 在搬大东西」一眼可见）
    private static let opLock = NSLock()
    private static var _currentOp: String = "—"
    static var currentOp: String {
        opLock.lock(); defer { opLock.unlock() }
        return _currentOp
    }
    static func setCurrentOp(_ op: String) {
        opLock.lock(); _currentOp = op; opLock.unlock()
    }

    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? {
        Self.setCurrentOp(op)
        let session = try session(for: source)
        guard let engine = session.engine else { return nil }
        // ⭐⭐⭐ **源级变量**（站方 `server` / `tab` / `sources` / `find_source` …）
        //   轻阅存在 `SourceVariables`（一个 JSON 串）⇒ 引擎存在 `varBox`（键值表）
        //   ⇒ **双向同步**：进（轻阅 → 引擎）/ 出（引擎 → 轻阅，落盘）
        Self.seedVars(from: payload, into: engine.varBox)
        // ⭐⭐⭐ **站方变量**（Legado 语义）⇒ 灌进引擎的槽位（`source.getVariable()` 读它）⭐
        //   ⚠️ 与「书源变量」（varBox）**分开** ⇒ 站方 setVariable 不会冲掉 get/put 的项 ⭐
        // ⭐⭐⭐ **记下「灌进去的是哪一串」** ⇒ 出的时候才知道**站方到底改没改** ⭐⭐⭐
        //   （判「map 形态还是凭据形态」的证据必须是「**站方自己改过**」）
        //   ⇒ 站方没改（值一模一样）⇒ 那份值可能只是**宿主灌的污染被原样弹回来**
        //   ⇒ 拿它当证据 = **自证** ⇒ 迁移永远不触发 ⇒ 真机上的污染清不掉 ⭐⭐⭐
        var seededStationVariable: String?
        if let sv = engine.sourceVariable,
           let srcDict = payload["source"] as? [String: Any],
           let text = srcDict["__variable"] as? String {
            sv.text = text
            seededStationVariable = text
        }
        // ⭐⭐⭐ **诊断**（2026-10-27 真机：Bearer 仍是污染 ⇒ 量出引擎里到底是哪一串）⭐
        NSLog("[变量] 灌进引擎的站方变量=\(String((seededStationVariable ?? "<没有这格>").prefix(60)))")
        if let sv = engine.sourceVariable {
            NSLog("[变量] 引擎槽当前=\(String(sv.text.prefix(60)))（长度 \(sv.text.count)）")
        } else {
            NSLog("[变量] ⚠️ 引擎没有站方变量槽 ⇒ getVariable() 会回退成整份书源变量")
        }
        // ⭐⭐⭐ **cookie 也要灌进引擎的罐**（2026-10-24 真机栽的 ⇒ 详见 seedCookies 的注释）
        Self.seedCookies(from: payload, into: engine.fetcher.cookieJar)
        var out: Any?
        switch op {
        case "search": out = try runSearch(session, engine, payload)
        case "explore": out = try runExplore(session, engine, payload)
        case "exploreKinds": out = try runExploreKinds(engine)
        case "bookInfo": out = try runBookInfo(session, engine, payload)
        case "toc": out = try runToc(session, engine, payload)
        case "content": out = try runContent(session, engine, payload)
        // ⭐⭐⭐ **登录也归新引擎了**（2026-10-25 老引擎退役 ⇒ 物理删除前的最后一步）
        case "login": out = try runLogin(engine, payload)
        case "loginProbe": out = try runLoginProbe(engine)
        // ⭐⭐⭐ 老引擎退役 ⇒ 这三个 op 也归新引擎（2026-10-25）
        case "sourceVars": out = ["vars": try engine.sourceVars()]
        case "sourceHosts": out = ["hosts": try engine.sourceHosts()]
        case "filterAction": out = try runFilterAction(engine, payload)
        default:
            // ⚠️ 其余 op（sourceVars / sourceHosts / filterAction / explain*）暂不接
            return nil
        }
        // ⭐ **站方 JS 改过的源级变量** ⇒ 回传给轻阅（落盘 ⇒ 下次直接生效）
        if var dict = out as? [String: Any] {
            dict["__sourceVars"] = Self.varsJSON(engine.varBox)
            // ⭐⭐⭐ 站方变量（Legado 语义）⇒ 回传给轻阅（落盘）⭐
            if let sv = engine.sourceVariable {
                dict["__sourceVariable"] = sv.text
                // ⭐⭐⭐ **站方到底改没改这一格？**（判形态的证据只认「真改过」）⭐
                //   ⇒ 没改 ⇒ 落盘时**不许**把它当成「站方自己写的」⇒ 不许拿来当证据 ⭐⭐⭐
                dict["__sourceVariableChanged"] = (sv.text != (seededStationVariable ?? ""))
            }
            out = dict
        }
        return out
    }

    /// ⭐⭐⭐ **源级变量：轻阅 → 引擎**
    ///
    /// ⚠️ **不做这一步的后果**（站方聚合源）：
    ///   `server`（线路）/ `tab`（模式）/ `sources`（平台）都在变量里
    ///   ⇒ 引擎拿不到 ⇒ 站方 jsLib 读到 undefined ⇒ 请求打错地址 / 分类全空 ⭐
    /// ⭐⭐⭐ **把 App 的 cookie 罐灌进引擎的 cookie 罐**（2026-10-24 真机栽的）
    ///
    /// ⚠️⚠️ **症状**：🍅大灰狼的发现页只剩「**未分组**」一个分类 ⇒ 详情/目录/正文全断
    ///   ⇒ 查下来：站方 `exploreUrl` 的 JS **自己去 ajax `/discovestyle`** 拿真分类
    ///   ⇒ 那个 ajax 失败 ⇒ 站方只剩硬编码的 7 个筛选栏 + **一个兜底分类「未分组」**
    ///   （App 自己的代码也记着这事：`discovestyle` 返 503 时「分类只剩 2 个（正常 365 个）」）
    ///
    /// ⚠️⚠️ **为什么老引擎能、新引擎不能**：
    ///   · 老引擎的 `java.ajax` 走**原生桥** ⇒ 用的是 **App 的 cookie 罐**（**有登录态**）✅
    ///   · 新引擎的 `java.ajax` 用的是**引擎自己的罐** ⇒ 每个源**从空开始** ⇒ **登录态丢了** ❌
    ///   ⇒ 而且站方 JS 里的 `cookie.getCookie()` 读的也是**引擎的罐** ⇒ 同样看不到登录态 ⭐⭐
    ///
    /// ⇒ 修：每次 op 前把 App 的 cookie 快照（`HTTPCookieStorage.shared`）灌进引擎的罐
    ///   ⇒ 引擎的 ajax + 站方 JS 的 `cookie.*` 就都有登录态了 ⭐
    static func seedCookies(from payload: [String: Any], into jar: LegadoCore.CookieJar?) {
        guard let jar else { return }
        guard let snap = payload["cookieSnapshot"] as? [String: String] else { return }
        // ⭐ 解析在纯 Foundation 层（LegadoCompat）⇒ 沙盒里能真编真跑 ⇒ 有门禁
        for c in LegadoCompat.cookiePairs(from: snap) {
            // ⭐ domain 写 host ⇒ 该域**及其子域**都能带上（引擎的 Cookie.matches 语义）
            jar.set(LegadoCore.CookieJar.Cookie(name: c.name, value: c.value,
                                                domain: c.host, host: c.host))
        }
    }

    /// ⭐⭐⭐ **变量串的解析结果也缓存**（2026-10-24 真机「app 死机」）
    ///
    /// ⚠️ 崩溃日志里这个函数正卡在 Foundation 的 JSON 解析器上
    ///   （`seedVars` → `_NSJSONReader parseData:`）⇒ 它在**跟主线程抢 malloc 锁** ⭐
    /// ⇒ 同一个变量串**只解析一次**（按串本身做 key）
    private static let varsParseLock = NSLock()
    private static var varsParseCache: [String: [String: Any]] = [:]

    static func seedVars(from payload: [String: Any], into box: VarBox) {
        guard let srcDict = payload["source"] as? [String: Any],
              let text = srcDict["__variables"] as? String, !text.isEmpty
        else { return }
        varsParseLock.lock()
        var obj = varsParseCache[text]
        let hit = obj != nil
        varsParseLock.unlock()
        if !hit {
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            obj = parsed
            varsParseLock.lock()
            varsParseCache[text] = parsed
            if varsParseCache.count > 32 { varsParseCache.removeAll() }
            varsParseLock.unlock()
        }
        guard let obj else { return }
        for (k, v) in obj {
            if let s = v as? String { box.set(k, s) }
            else if let n = v as? NSNumber { box.set(k, n.stringValue) }
        }
    }

    /// ⭐ **源级变量：引擎 → 轻阅**（一个 JSON 串）
    static func varsJSON(_ box: VarBox) -> String {
        let all = box.all
        guard !all.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: all),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// ⭐ **拿（建）这个源的会话**
    private func session(for source: BookSource) throws -> Session {
        let key = source.bookSourceUrl
        lock.lock()
        if let s = sessions[key] { lock.unlock(); return s }
        lock.unlock()

        let engineSource = Self.convert(source)
        let jar = EngineCookieJar()
        let s = try Session(source: engineSource, jar: jar, jsLib: source.jsLib)
        lock.lock()
        // ⚠️ 可能有别的线程先建了 ⇒ 以先建的那个为准（本建的白扔）
        if let exist = sessions[key] { lock.unlock(); return exist }
        sessions[key] = s
        lock.unlock()
        return s
    }

    /// ⭐⭐⭐ **丢掉某个源的会话**（新引擎卡死时的急救）
    ///
    /// ⚠️⚠️ **为什么必须有**（2026-10-24 真机）：
    ///   引擎的 JSC context 是**复用**的（一个源一个）⇒
    ///   站方 JS 一旦在里面死循环 ⇒ **contextLock 永远拿不到**
    ///   ⇒ 后面每一个 op 都卡在锁上 ⇒ 整个源永久报废
    ///   ⇒ 所以**超时的时候必须把会话整个换掉**（不只是放弃这一次调用）⭐
    ///   ⇒ 新的 context 是干净的 ⇒ 源立刻能用
    func dropSession(for sourceUrl: String) {
        lock.lock()
        let existed = sessions.removeValue(forKey: sourceUrl) != nil
        lock.unlock()
        if existed {
            NSLog("[engine] 丢弃卡死的会话：\(sourceUrl)")
        }
    }

    // MARK: - op 实现

    /// ⭐ **搜索**
    private func runSearch(_ session: Session, _ engine: SourceEngine,
                           _ payload: [String: Any]) throws -> Any {
        let keyword = (payload["keyword"] as? String) ?? ""
        let page = (payload["page"] as? Int) ?? 1
        let books = try engine.search(keyword, page: page)
        return Self.bookListPayload(books)
    }

    /// ⭐ **发现**
    private func runExplore(_ session: Session, _ engine: SourceEngine,
                            _ payload: [String: Any]) throws -> Any {
        let kindUrl = (payload["kindUrl"] as? String) ?? ""
        let page = (payload["page"] as? Int) ?? 1
        // ⭐⭐⭐⭐⭐ **失败时把【引擎的诊断行】带进错误**（2026-10-25 真机实证）
        //   ⇒ 以前只有「emptyResult(\"bookList\")」⇒ 用户完全看不到引擎看到了什么 ⇒ 只能猜 ⭐⭐⭐
        //   ⇒ 诊断行里有：**实际请求的 URL + 响应长度 + 响应前 200 字 + isJSON** ⇒ 一次定位 ⭐⭐⭐
        do {
            let books = try engine.explore(kindUrl, page: page)
            return Self.bookListPayload(books)
        } catch {
            throw Self.diagnose(engine, "发现页", error)
        }
    }

    /// ⭐⭐⭐⭐⭐ **把引擎的失败诊断拼进宿主错误**（真机日志能直接看出真凶）
    static func diagnose(_ engine: SourceEngine, _ what: String, _ error: Error) -> Error {
        let lines = engine.failureDiagnosticLines
        guard !lines.isEmpty else { return error }
        let detail = lines.joined(separator: " ／ ")
        return ServiceError.engineFailed("\(what)失败：\(error.localizedDescription)（引擎诊断：\(detail)）")
    }

    /// ⭐ **发现页的分类 + 筛选栏**
    /// ⭐⭐⭐ **登录**（老引擎 `engine.js` 的 `login` op 同款）
    ///
    /// ⚠️ **老引擎不是调 `login()`，而是跑【宿主传来的 action 表达式】**
    ///   （App 的登录面板把 `loginUi` 里某个按钮的 `action` 传给宿主）⇒ 这里照抄 ⭐⭐⭐
    /// ⇒ 站方只靠 `java.toast` / `java.log` 报结果 ⇒ `messages` 是**判断成败的唯一依据**⭐
    private func runLogin(_ engine: SourceEngine, _ payload: [String: Any]) throws -> Any {
        let action = payload["action"] as? String ?? ""
        let formValues = payload["formValues"] as? [String: String] ?? [:]
        let r = try engine.runLoginAction(action, formValues: formValues)
        var d: [String: Any] = ["ok": r.ok, "messages": r.messages]
        if r.ok { d["result"] = r.result } else { d["error"] = r.result }
        // 站方 `putLoginInfo` / `putLoginHeader` 写进引擎的 storage ⇒ 取回落盘 ⭐⭐⭐
        let info = engine.loadLoginInfo()
        if !info.isEmpty, let j = try? JSONSerialization.data(withJSONObject: info) {
            d["__loginInfo"] = String(data: j, encoding: .utf8)
        }
        let header = engine.currentLoginHeaderString()
        if !header.isEmpty { d["__loginHeader"] = header }
        engineLog("[新引擎] 登录动作完成：ok=\(r.ok) · 站方原文 \(r.messages.count) 条")
        return d
    }

    /// ⭐⭐⭐ **登录状态检测**（老引擎 `loginProbe` 同款）
    private func runLoginProbe(_ engine: SourceEngine) throws -> Any {
        let r = try engine.probeLoginStatus()
        engineLog("[新引擎] 登录态检测：baseUrl=\(r.baseUrl) · stationCheck=\(r.stationCheck) · 原文 \(r.messages.count) 条")
        return ["baseUrl": r.baseUrl, "messages": r.messages, "stationCheck": r.stationCheck]
    }

    /// ⭐⭐⭐ **执行发现页筛选栏的 action**（老引擎 `filterAction` 同款）
    private func runFilterAction(_ engine: SourceEngine, _ payload: [String: Any]) throws -> Any {
        let action = payload["action"] as? String ?? ""
        let title = payload["title"] as? String ?? ""
        let value = payload["value"] as? String ?? ""
        let r = try engine.runFilterAction(action: action, title: title, value: value)
        var d: [String: Any] = ["ok": r.ok]
        if !r.ok { d["error"] = r.error }
        return d
    }

    private func runExploreKinds(_ engine: SourceEngine) throws -> Any {
        // ⭐⭐⭐ 失败时带诊断（见 runExplore 的说明）⭐⭐⭐
        let kinds: [SourceCategory]; let filters: [SourceFilter]
        do {
            (kinds, filters) = try engine.exploreKinds()
        } catch {
            throw Self.diagnose(engine, "发现页分类", error)
        }
        // ⭐⭐ **把分类/筛选栏的标题记下来**（2026-10-24 真机栽的）
        //   ⭐ 站方聚合源在「ajax 失败」时会**造一个叫「未分组」的兜底分类**
        //   ⇒ 看到「未分组」就知道是**站方接口没通**，不是分类规则写错 ⭐⭐
        engineLog("[新引擎] 分类 \(kinds.count) 个 / 筛选栏 \(filters.count) 个："
                  + kinds.map(\.title).joined(separator: "、"))
        let kindList: [[String: Any]] = kinds.map { k in
            var d: [String: Any] = ["title": k.title, "url": k.url, "style": k.style ?? ""]
            d["group"] = k.group ?? ""
            return d
        }
        let filterList: [[String: Any]] = filters.map { f in
            var d: [String: Any] = ["title": f.title, "type": "select", "chars": f.chars]
            d["default"] = f.defaultValue ?? ""
            d["action"] = f.action ?? ""
            d["paramKey"] = Self.paramKey(from: f.action)
            return d
        }
        return ["kinds": kindList, "filters": filterList]
    }

    /// ⭐ **详情**
    private func runBookInfo(_ session: Session, _ engine: SourceEngine,
                             _ payload: [String: Any]) throws -> Any {
        let bookUrl = (payload["bookUrl"] as? String) ?? ""
        let raw = (payload["book"] as? [String: Any]) ?? [:]
        let book = Self.book(from: raw, bookUrl: bookUrl)
        let info: EngineBookInfo
        do {
            info = try engine.bookInfo(book, variables: Self.variables(from: raw))
        } catch {
            // ⭐⭐⭐⭐⭐ **失败时把引擎的诊断带出来**（2026-10-25 真机教训）
            //   以前错误只说「书名/书 URL 是空的」⇒ 用户**完全不知道该查哪** ⇒ 白等一轮 ⭐⭐⭐
            //   ⇒ 引擎明明知道「哪条规则走的哪个分支、为什么失败」⇒ 把它带出来 ⭐⭐⭐
            let lines = engine.failureDiagnosticLines
            // ⚠️ `ServiceError` 现在在**文件顶层**（不依赖 `@MainActor` 类）⇒ 两边都能引用 ⭐⭐⭐
            throw Self.diagnose(engine, "详情页", error)
        }
        var rawMap: [String: String] = [:]
        for (k, v) in raw { if let s = v as? String { rawMap[k] = s } }
        let out = Self.bookPayload(info.name, author: info.author, intro: info.intro,
                                   kind: info.kind, group: info.group, lastChapter: info.lastChapter,
                                   coverUrl: info.coverUrl, bookUrl: info.bookUrl,
                                   wordCount: info.wordCount, tocUrl: info.tocUrl,
                                   raw: rawMap)
        return ["book": out]
    }

    /// ⭐ **目录**
    private func runToc(_ session: Session, _ engine: SourceEngine,
                        _ payload: [String: Any]) throws -> Any {
        let tocUrl = (payload["tocUrl"] as? String) ?? ""
        let bookUrl = (payload["bookUrl"] as? String) ?? ""
        let raw = (payload["book"] as? [String: Any]) ?? [:]
        let book = Self.book(from: raw, bookUrl: bookUrl)
        var info = EngineBookInfo()
        info.bookUrl = bookUrl
        // ⚠️ tocUrl 为空 ⇒ 目录规则跑在**详情页**上（Legado 语义）
        info.tocUrl = tocUrl
        let chapters: [EngineChapter]
        do {
            chapters = try engine.toc(info, book: book, variables: Self.variables(from: raw))
        } catch {
            throw Self.diagnose(engine, "目录", error)
        }
        let list: [[String: Any]] = chapters.map { c in
            ["url": c.url, "title": c.name, "index": c.index, "isVolume": c.isVolume, "tag": ""]
        }
        var out: [String: Any] = ["chapters": list, "rawCount": chapters.count]
        out["bookName"] = book.name
        return out
    }

    /// ⭐ **正文**
    private func runContent(_ session: Session, _ engine: SourceEngine,
                            _ payload: [String: Any]) throws -> Any {
        let chapterUrl = (payload["chapterUrl"] as? String) ?? ""
        let chapterDict = (payload["chapter"] as? [String: Any]) ?? [:]
        let title = (chapterDict["title"] as? String) ?? ""
        let raw = (payload["book"] as? [String: Any]) ?? [:]
        let book = Self.book(from: raw, bookUrl: (raw["bookUrl"] as? String) ?? "")
        var chapter = EngineChapter()
        chapter.name = title
        chapter.url = chapterUrl
        let text: String
        do {
            text = try engine.content(chapter, book: book, variables: Self.variables(from: raw))
        } catch {
            throw Self.diagnose(engine, "正文", error)
        }
        return ["title": title, "content": text, "nextUrl": ""]
    }

    // MARK: - 形状对齐

    /// ⭐ **书单**（老引擎的形状）
    static func bookListPayload(_ books: [EngineBook]) -> [String: Any] {
        let list: [[String: Any]] = books.map { b in
            bookPayload(b.name, author: b.author, intro: b.intro, kind: b.kind,
                        lastChapter: b.lastChapter, coverUrl: b.coverUrl,
                        bookUrl: b.bookUrl, wordCount: b.wordCount, tocUrl: "",
                        raw: b.raw)
        }
        return ["books": list, "total": list.count, "nextUrl": ""]
    }

    /// ⭐ **一本书**（老引擎的形状）
    static func bookPayload(_ name: String, author: String, intro: String, kind: String,
                            group: String = "", lastChapter: String, coverUrl: String, bookUrl: String,
                            wordCount: String, tocUrl: String,
                            raw: [String: String]) -> [String: Any] {
        var d: [String: Any] = [
            "name": name, "author": author, "intro": intro, "kind": kind,
            "group": group,
            "lastChapter": lastChapter, "coverUrl": coverUrl, "bookUrl": bookUrl,
            "wordCount": wordCount, "tocUrl": tocUrl,
        ]
        if !raw.isEmpty { d["raw"] = raw }
        return d
    }

    /// ⭐ **站方 action 里的源级变量名**（`show(infoMap['平台'],'find_source')` ⇒ `find_source`）
    static func paramKey(from action: String?) -> String {
        guard let action, !action.isEmpty else { return "" }
        // 取最后一对单引号里的内容
        let parts = action.split(separator: "'")
        guard parts.count >= 4 else { return "" }
        return String(parts[parts.count - 2])
    }

    /// ⭐ **书（从老引擎的 book 字典还原）**
    static func book(from raw: [String: Any], bookUrl: String) -> EngineBook {
        var b = EngineBook()
        b.name = (raw["name"] as? String) ?? ""
        b.author = (raw["author"] as? String) ?? ""
        b.intro = (raw["intro"] as? String) ?? ""
        b.kind = (raw["kind"] as? String) ?? ""
        b.lastChapter = (raw["lastChapter"] as? String) ?? ""
        b.coverUrl = (raw["coverUrl"] as? String) ?? ""
        b.bookUrl = (raw["bookUrl"] as? String) ?? bookUrl
        b.wordCount = (raw["wordCount"] as? String) ?? ""
        var raws: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { raws[k] = s }
        }
        b.raw = raws
        return b
    }

    /// ⭐ **书籍变量**（站方 `book.getVariable('custom')` 要读它）
    static func variables(from raw: [String: Any]) -> [String: String] {
        guard let vars = raw["variables"] as? [String: String] else { return [:] }
        return vars
    }

    /// ⭐⭐ **把登录头并进源级 header**
    ///
    /// ⚠️ 源级 header 有三种写法（JSON 对象 / JSON 字符串 / `key: value` 换行）
    /// ⇒ 这里统一转成 **JSON 对象**（引擎认得）⇒ 别把原样丢给引擎
    static func mergeHeader(_ raw: String?, loginHeader: String) -> String {
        var headers: [String: String] = [:]
        if let raw, !raw.isEmpty {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") {
                if let d = t.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    for (k, v) in obj { headers[k] = (v as? String) ?? String(describing: v) }
                }
            } else if t.hasPrefix("\"") {
                if let d = t.data(using: .utf8),
                   let inner = try? JSONSerialization.jsonObject(with: d) as? String {
                    return mergeHeader(inner, loginHeader: loginHeader)
                }
            } else {
                for line in t.components(separatedBy: .newlines) {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard let c = l.firstIndex(of: ":") else { continue }
                    let k = String(l[l.startIndex..<c]).trimmingCharacters(in: .whitespaces)
                    let v = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty { headers[k] = v }
                }
            }
        }
        // 登录头是 `key: value` 形式
        if let c = loginHeader.firstIndex(of: ":") {
            let k = String(loginHeader[loginHeader.startIndex..<c]).trimmingCharacters(in: .whitespaces)
            let v = String(loginHeader[loginHeader.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { headers[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let text = String(data: data, encoding: .utf8) else { return raw ?? "" }
        return text
    }

    // MARK: - 源转换

    /// ⭐⭐⭐ **轻阅的 BookSource ⇒ 引擎的 BookSource**
    ///
    /// ⚠️ **规则字段的形状不一样**：
    /// - 轻阅：`RuleValue`（字符串 / **字符串数组** / 没有）⇒ 数组要**合并成换行**（站方多规则写法）
    /// - 引擎：`String?`
    static func convert(_ s: BookSource) -> EngineSource {
        var out = EngineSource(bookSourceName: s.bookSourceName, bookSourceUrl: s.bookSourceUrl)
        out.bookSourceGroup = s.bookSourceGroup
        out.bookSourceComment = s.bookSourceComment
        out.header = s.header
        // ⭐⭐ **登录头**（栖阅机制：`loginHeader` 自动注入到每次请求头）
        //   ⇒ 不带 ⇒ 登录态的请求会被站方拒 ⇒ **登录过的源突然全挂**
        let loginHeader = SourceVariables.loginHeader(for: s.bookSourceUrl)
        if !loginHeader.isEmpty {
            out.header = Self.mergeHeader(out.header, loginHeader: loginHeader)
        }
        out.exploreUrl = s.exploreUrl
        out.searchUrl = s.searchUrl
        out.loginUrl = s.loginUrl
        out.loginUi = s.loginUi
        out.enabled = s.enabled
        out.enabledExplore = s.enabledExplore

        out.ruleSearch = listRule(s.ruleSearch)
        out.ruleExplore = listRule(s.ruleExplore)
        out.ruleBookInfo = bookInfoRule(s.ruleBookInfo)
        out.ruleToc = tocRule(s.ruleToc)
        out.ruleContent = contentRule(s.ruleContent)
        return out
    }

    /// ⭐ **规则字段 ⇒ 字符串**（数组 ⇒ 换行合并）
    static func ruleText(_ v: RuleValue?) -> String? {
        guard let v else { return nil }
        switch v {
        case .none: return nil
        case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        case .list(let a):
            let lines = a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// ⭐ **列表规则**（`ruleSearch` / `ruleExplore`）
    static func listRule(_ r: ListRule) -> LegadoCore.RuleFields {
        var f = LegadoCore.RuleFields()
        f.bookList = ruleText(r.bookList)
        f.name = ruleText(r.name)
        f.author = ruleText(r.author)
        f.intro = ruleText(r.intro)
        f.kind = ruleText(r.kind)
        f.lastChapter = ruleText(r.lastChapter)
        f.coverUrl = ruleText(r.coverUrl)
        f.bookUrl = ruleText(r.bookUrl)
        f.wordCount = ruleText(r.wordCount)
        f.searchUrl = ruleText(r.searchUrl)
        // ⭐⭐ **`ruleExplore.exploreUrl`** —— 站方把发现页 URL 写在规则块里的那种
        //   ⇒ 引擎的 exploreKinds 兜底要读它（顶层空 ⇒ 试它）
        f.exploreUrl = ruleText(r.exploreUrl)
        return f
    }

    /// ⭐ **详情规则**（`ruleBookInfo`）—— ⭐ 含 `init`
    static func bookInfoRule(_ r: BookInfoRule) -> LegadoCore.RuleFields {
        var f = LegadoCore.RuleFields()
        f.name = ruleText(r.name)
        f.author = ruleText(r.author)
        f.intro = ruleText(r.intro)
        f.kind = ruleText(r.kind)
        f.lastChapter = ruleText(r.lastChapter)
        f.coverUrl = ruleText(r.coverUrl)
        f.tocUrl = ruleText(r.tocUrl)
        f.wordCount = ruleText(r.wordCount)
        // ⭐⭐⭐ **`init` 规则**（JSON 接口源几乎全靠它）⇒ 属性名是 `initRule`（`init` 是保留字）
        f.initRule = ruleText(r.initRule)
        return f
    }

    /// ⭐ **目录规则**（`ruleToc`）
    static func tocRule(_ r: TocRule) -> LegadoCore.RuleFields {
        var f = LegadoCore.RuleFields()
        f.chapterList = ruleText(r.chapterList)
        f.chapterName = ruleText(r.chapterName)
        f.chapterUrl = ruleText(r.chapterUrl)
        f.isVolume = ruleText(r.isVolume)
        f.isVip = ruleText(r.isVip)
        f.nextTocUrl = ruleText(r.nextTocUrl)
        return f
    }

    /// ⭐ **正文规则**（`ruleContent`）
    static func contentRule(_ r: ContentRule) -> LegadoCore.RuleFields {
        var f = LegadoCore.RuleFields()
        f.content = ruleText(r.content)
        f.nextContentUrl = ruleText(r.nextContentUrl)
        f.replaceRegex = ruleText(r.replaceRegex)
        f.sourceRegex = ruleText(r.sourceRegex)
        return f
    }
}
