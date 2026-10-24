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
        cfg.timeoutIntervalForRequest = 30
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
func engineLog(_ message: String) {
    Task { @MainActor in RuleSandbox.shared.appendLog(message) }
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
        case "log":
            engineLog(first)
            return .string("")
        case "getCookie":
            return .string(CookieJar.cookieString(for: first))
        case "startBrowser":
            // ⚠️ 浏览器交接是**宿主的事**⇒ 这里只记一笔（真浏览器由 App 的登录面板处理）
            engineLog("[宿主] startBrowser：\(first)")
            return .string("")
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
            let js: JSExecutor? = JSCExecutor(api: api)
            #else
            let js: JSExecutor? = nil
            #endif
            let engine = SourceEngine(source: source,
                                      fetcher: PageFetcher(transport: URLSessionTransport(), cookieJar: jar),
                                      js: js,
                                      storage: storage,
                                      // ⭐⭐⭐ **必须传 logger** ⇒ 引擎的诊断才看得见
                                      logger: EngineDiagnosticLogger(),
                                      cookies: AppCookieService())
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
    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? {
        let session = try session(for: source)
        guard let engine = session.engine else { return nil }
        // ⭐⭐⭐ **源级变量**（站方 `server` / `tab` / `sources` / `find_source` …）
        //   轻阅存在 `SourceVariables`（一个 JSON 串）⇒ 引擎存在 `varBox`（键值表）
        //   ⇒ **双向同步**：进（轻阅 → 引擎）/ 出（引擎 → 轻阅，落盘）
        Self.seedVars(from: payload, into: engine.varBox)
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
        default:
            // ⚠️ 登录 / loginProbe / sourceVars / sourceHosts / filterAction / explain*
            //    ⇒ 仍走老引擎（站方 JS 交互 + 诊断面板）
            return nil
        }
        // ⭐ **站方 JS 改过的源级变量** ⇒ 回传给轻阅（落盘 ⇒ 下次直接生效）
        if var dict = out as? [String: Any] {
            dict["__sourceVars"] = Self.varsJSON(engine.varBox)
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

    static func seedVars(from payload: [String: Any], into box: VarBox) {
        guard let srcDict = payload["source"] as? [String: Any],
              let text = srcDict["__variables"] as? String,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
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
        let books = try engine.explore(kindUrl, page: page)
        return Self.bookListPayload(books)
    }

    /// ⭐ **发现页的分类 + 筛选栏**
    private func runExploreKinds(_ engine: SourceEngine) throws -> Any {
        let (kinds, filters) = try engine.exploreKinds()
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
        let info = try engine.bookInfo(book, variables: Self.variables(from: raw))
        var rawMap: [String: String] = [:]
        for (k, v) in raw { if let s = v as? String { rawMap[k] = s } }
        let out = Self.bookPayload(info.name, author: info.author, intro: info.intro,
                                   kind: info.kind, lastChapter: info.lastChapter,
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
        let chapters = try engine.toc(info, book: book, variables: Self.variables(from: raw))
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
        let text = try engine.content(chapter, book: book, variables: Self.variables(from: raw))
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
                            lastChapter: String, coverUrl: String, bookUrl: String,
                            wordCount: String, tocUrl: String,
                            raw: [String: String]) -> [String: Any] {
        var d: [String: Any] = [
            "name": name, "author": author, "intro": intro, "kind": kind,
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
