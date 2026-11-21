import Foundation
import ChaiyueModels

/// 规则执行所需的书源信息（书源与朗读源共用）
struct SourceDescriptor: Sendable {
    let key: String
    let name: String
    let header: String?
    let loginUrl: String?
    let loginUi: String?
    let loginCheckJs: String?
    let jsLib: String?
    let concurrentRate: String?
    let enabledCookieJar: Bool
    let bookSource: BookSource?

    init(_ source: BookSource) {
        key = source.bookSourceUrl
        name = source.bookSourceName
        header = source.header
        loginUrl = source.loginUrl
        loginUi = source.loginUi
        loginCheckJs = source.loginCheckJs
        jsLib = source.jsLib
        concurrentRate = source.concurrentRate
        enabledCookieJar = source.enabledCookieJar
        bookSource = source
    }

    init(_ tts: HttpTTS) {
        key = String(tts.id)
        name = tts.name
        header = tts.header
        loginUrl = tts.loginUrl
        loginUi = tts.loginUi
        loginCheckJs = tts.loginCheckJs
        jsLib = tts.jsLib
        concurrentRate = tts.concurrentRate
        enabledCookieJar = tts.enabledCookieJar
        bookSource = nil
    }

    /// 去掉 `@js:`/`<js>` 包装后的登录脚本
    var loginJs: String? {
        guard let js = loginUrl else { return nil }
        if js.startsWith("@js:", ignoreCase: true) { return String(js.dropFirst(4)) }
        if js.startsWith("<js>", ignoreCase: true) {
            let body = js.dropFirst(4)
            if let end = body.range(of: "<", options: .backwards) { return String(body[..<end.lowerBound]) }
            return String(body)
        }
        return js
    }

    /// 整段为 `<js>…</js>` 或 `@js:…` 时取出脚本（Legado `BaseSource.extractInlineJs`）
    static func inlineJs(_ rule: String?) -> String? {
        guard let text = rule?.trimmedWhitespace, !text.isEmpty else { return nil }
        if text.startsWith("@js:", ignoreCase: true) { return String(text.dropFirst(4)).trimmedWhitespace }
        if text.startsWith("<js>", ignoreCase: true), text.lowercased().hasSuffix("</js>") {
            return String(text.dropFirst(4).dropLast(5)).trimmedWhitespace
        }
        return nil
    }
}

/// 书源的持久状态，存储键与 Legado 一致，便于书源脚本直接读写
final class SourceState {
    let key: String
    // ⭐⭐⭐ **移植补丁（2026-11-21）**：`private` → internal ⇒ 让 `Compat/LegadoPublicAPI.swift`
    //   的扩展能导出全部书源变量（`source.getAllVars()` 的等价物）⭐⭐⭐
    let cache: CacheStore
    private let cryptoKey: Data
    /// 本次会话改动过登录信息或登录头
    var loginChanged = false

    init(key: String, env: SourceEnvironment) {
        self.key = key
        cache = env.cache
        cryptoKey = Data(env.androidID.utf8.prefix(16))
    }

    var variable: String? {
        get { cache.get("sourceVariable_\(key)") }
        set {
            if let newValue { cache.put("sourceVariable_\(key)", newValue) } else { cache.delete("sourceVariable_\(key)") }
        }
    }

    var loginHeader: String? {
        get { cache.get("loginHeader_\(key)") }
        set {
            if newValue != loginHeader { loginChanged = true }
            if let newValue { cache.put("loginHeader_\(key)", newValue) } else { cache.delete("loginHeader_\(key)") }
        }
    }

    /// 登录表单数据（JSON），以 AES/ECB/PKCS5 + Base64 加密存储
    var loginInfo: String? {
        get {
            guard let stored = cache.get("userInfo_\(key)"), !stored.isEmpty else { return nil }
            let crypto = JSSymmetricCrypto(transformation: "AES", key: cryptoKey, iv: nil)
            return try? crypto.decryptString(stored)
        }
        set {
            if newValue != loginInfo { loginChanged = true }
            guard let newValue else {
                cache.delete("userInfo_\(key)")
                return
            }
            let crypto = JSSymmetricCrypto(transformation: "AES", key: cryptoKey, iv: nil)
            if let encrypted = try? crypto.encryptData(Data(newValue.utf8)) {
                cache.put("userInfo_\(key)", Base64Codec.encode(encrypted))
            }
        }
    }

    func put(_ k: String, _ value: String) { cache.put("v_\(key)_\(k)", value) }
    func get(_ k: String) -> String { cache.get("v_\(key)_\(k)") ?? "" }
}

/// 取消标记，在异步任务取消时由外部设置
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// 一次书源操作（搜索、详情、目录、正文、登录）的执行上下文。只在单个工作线程上使用。
final class RuleSession {
    let source: SourceDescriptor
    let env: SourceEnvironment
    let state: SourceState
    private let cancelFlag: CancellationFlag?
    private var runtime: JSRuntime?
    private var evaluatingHeader = false
    private var derivingLoginInfo = false
    /// 最近一次 `java.webSocket` 得到的音频与错误。JS 异常只保留文字，朗读流程据此还原原始结果
    var webSocketAudio: TTSAudio?
    var webSocketError: Error?

    init(source: SourceDescriptor, env: SourceEnvironment, cancel: CancellationFlag? = nil) {
        self.source = source
        self.env = env
        state = SourceState(key: source.key, env: env)
        cancelFlag = cancel
    }

    /// 在独立线程上创建会话并同步执行，任务取消时设置取消标记。
    /// 执行中改了登录信息、登录头（`watchCookies` 时还包括任意 Cookie）就通知登录状态变化，结束前发出，调用方返回时各入口已可读到
    static func run<T: Sendable>(_ descriptor: SourceDescriptor, env: SourceEnvironment, watchCookies: Bool = false,
                                 _ body: @escaping @Sendable (RuleSession) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let thread = Thread {
                    let session = RuleSession(source: descriptor, env: env, cancel: flag)
                    let cookies = watchCookies ? env.cookies.digest() : nil
                    let result = Result { try body(session) }
                    if session.state.loginChanged || (cookies != nil && cookies != env.cookies.digest()) {
                        env.sourceLoginDidChange(descriptor.key)
                    }
                    continuation.resume(with: result)
                }
                // JS 与深层规则递归需要更大的栈
                thread.stackSize = 8 << 20
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            flag.cancel()
        }
    }

    var isCancelled: Bool { cancelFlag?.isCancelled ?? false }

    func checkCancelled() throws {
        if isCancelled { throw RuleError.cancelled }
    }

    var js: JSRuntime {
        if let runtime { return runtime }
        let created = JSRuntime(session: self)
        runtime = created
        return created
    }

    // MARK: - JS

    func evalJS(_ script: String, bindings: JSBindings) throws -> Any? {
        try checkCancelled()
        return try js.eval(script, bindings: bindings)
    }

    /// 以书源为上下文执行（Legado `BaseSource.evalJS`）：baseUrl 为书源 key
    func evalSourceJS(_ script: String, extra: [String: Any] = [:], result: Any? = nil) throws -> Any? {
        var bindings = JSBindings(host: nil)
        bindings.baseUrl = source.key
        bindings.result = result
        bindings.extra = extra
        return try evalJS(script, bindings: bindings)
    }

    func sourcePut(_ key: String, _ value: String) { state.put(key, value) }
    func sourceGet(_ key: String) -> String { state.get(key) }

    // MARK: - 请求头

    /// 书源请求头：支持 JS 生成，缺省补充 UA，按需合并登录头（仅 JSON 形式）
    func headerMap(hasLoginHeader: Bool) throws -> [String: String] {
        var map: [String: String] = [:]
        if let header = source.header, !header.isBlank, !evaluatingHeader {
            var text = header
            if header.startsWith("@js:", ignoreCase: true) || header.startsWith("<js>", ignoreCase: true) {
                var script = String(header.dropFirst(4))
                if header.startsWith("<js>", ignoreCase: true), let end = script.range(of: "<", options: .backwards) {
                    script = String(script[..<end.lowerBound])
                }
                evaluatingHeader = true
                defer { evaluatingHeader = false }
                text = AnalyzeUrl.stringify(try evalSourceJS(script))
            }
            for (k, v) in LenientJSON.stringMap(text) ?? [:] { map[k] = v }
        }
        if !map.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            map["User-Agent"] = env.userAgent
        }
        if hasLoginHeader, let login = state.loginHeader, let loginMap = LenientJSON.stringMap(login) {
            for (k, v) in loginMap { map[k] = v }
        }
        return map
    }

    // MARK: - 登录

    func runLogin() throws {
        guard let loginJs = source.loginJs, !loginJs.isBlank else { return }
        let js = loginJs + "\nif(typeof login=='function'){login.apply(this);}else{throw('Function login not implements!!!')}"
        _ = try withLoginExtensions { try evalSourceJS(js) }
    }

    /// `source.getLoginInfoMap()`：未保存时取登录界面非按钮控件的默认值并保存（Legado `BaseSource.getLoginInfoMap`），
    /// 生成默认值的脚本里再次读取时返回空表
    func loginInfoMap() -> [String: Any] {
        if let info = state.loginInfo { return LenientJSON.object(info) ?? [:] }
        guard let ui = source.loginUi, !ui.isBlank, !derivingLoginInfo else { return [:] }
        derivingLoginInfo = true
        defer { derivingLoginInfo = false }
        var text = ui
        if let js = SourceDescriptor.inlineJs(ui) {
            var bindings = JSBindings(host: nil)
            bindings.baseUrl = source.key
            bindings.result = JavaMap([:])
            do {
                text = AnalyzeUrl.stringify(try evalJS((source.loginJs ?? "") + "\n" + js, bindings: bindings))
            } catch {
                env.log(source.key, "loginUi 脚本出错：\(error)")
                return [:]
            }
        }
        var map: [String: String] = [:]
        for row in WebBook.parseLoginRows(text) where row.type != .button {
            map[row.name] = row.defaultValue ?? ""
        }
        if !map.isEmpty { state.loginInfo = LenientJSON.serialize(map) }
        return map
    }

    /// 登录界面按钮：执行 `loginJs + action`，表单数据绑定为 `result`
    func runLoginAction(_ action: String, formData: [String: String]) throws {
        let loginJs = source.loginJs ?? ""
        _ = try withLoginExtensions { try evalSourceJS(loginJs + "\n" + action, result: JavaMap(formData)) }
    }

    // MARK: - 网络（供 java.* 使用）

    func ajax(_ url: String, host: JSAnalyzerHost?) -> String {
        do {
            let analyzeUrl = try AnalyzeUrl(url, session: self, ruleData: host?.hostRuleData)
            return try analyzeUrl.getStrResponse().body()
        } catch {
            env.log(source.key, "ajax(\(url)) error: \(error)")
            return "\(error)"
        }
    }

    func connect(_ url: String, header: String?, host: JSAnalyzerHost?) -> JSResponse {
        let headers = header.flatMap { LenientJSON.stringMap($0) }
        do {
            let analyzeUrl = try AnalyzeUrl(url, session: self, ruleData: host?.hostRuleData, headerMapF: headers)
            return try analyzeUrl.getStrResponse()
        } catch {
            env.log(source.key, "connect(\(url)) error: \(error)")
            return JSResponse(url: url, body: "\(error)", status: 500)
        }
    }

    /// `java.get/post/head`：不带书源请求头、不跟随重定向，4xx/5xx 抛出异常（与 Jsoup 一致）
    func rawRequest(method: String, url: String, body: String?, headers: [String: String], timeout: Int?) throws -> JSResponse {
        try checkCancelled()
        var request = HTTPRequest(url: url, method: method, headers: headers, body: body.map { Data($0.utf8) },
                                  timeout: timeout.map { Double($0) / 1000 } ?? env.requestTimeout, followRedirects: false)
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            request.headers["User-Agent"] = env.userAgent
        }
        if method == "POST", !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            request.headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        }
        try RateLimiter.shared.acquire(key: source.key, rate: source.concurrentRate, isCancelled: { self.isCancelled })
        defer { RateLimiter.shared.release(key: source.key, rate: source.concurrentRate) }
        let res = try env.http.send(request)
        if source.enabledCookieJar, !res.setCookies.isEmpty {
            env.cookies.replaceCookie(url: url, cookie: res.setCookies.joined(separator: "; "))
        }
        if res.statusCode >= 400 {
            throw RuleError.network("HTTP error fetching URL. Status=\(res.statusCode), URL=[\(url)]")
        }
        let text = Charsets.decode(res.body, contentType: res.header("Content-Type"))
        return JSResponse(url: res.url, body: text, status: res.statusCode, headers: res.headers)
    }

    func fetchText(url: String) throws -> String {
        try AnalyzeUrl(url, session: self).getStrResponse().body()
    }

    /// 下载并缓存文本（`java.cacheFile`/`java.importScript`）
    func cacheFile(url: String, saveTime: Int) throws -> String {
        let key = "cacheFile_" + String(Hex.encode(Digests.digest("MD5", Data(url.utf8)) ?? Data()).dropFirst(8).prefix(16))
        if let cached = env.cache.get(key), !cached.isEmpty { return cached }
        let text = try fetchText(url: url)
        if !text.isEmpty { env.cache.put(key, text, saveTime: saveTime) }
        return text
    }
}

/// 以 Java Map 形式传入 JS 的字典（支持 `get`/`put` 等方法与下标访问）
struct JavaMap {
    let dict: [String: Any]
    init(_ dict: [String: Any]) { self.dict = dict }
}
