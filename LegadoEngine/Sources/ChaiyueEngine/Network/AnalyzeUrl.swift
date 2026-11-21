import Foundation

typealias StrResponse = JSResponse

/// 解析书源中的 URL 规则（JS、`{{}}`、`<页码>`、`,{选项}`）并发起请求
final class AnalyzeUrl {
    let mUrl: String
    let key: String?
    let page: Int?
    let speakText: String?
    let speakSpeed: Int?
    private(set) var baseUrl: String
    unowned let session: RuleSession
    let ruleData: VariableHolder?
    let chapter: ChapterRef?

    private(set) var ruleUrl = ""
    private(set) var url = ""
    private(set) var type: String?
    var headerMap: [String: String] = [:]
    private var body: String?
    private var urlNoQuery = ""
    private var encodedForm: String?
    private var encodedQuery: String?
    private var charset: String?
    private var method = "GET"
    private var retry = 0
    private(set) var useWebView = false
    private var webJs: String?
    private var webViewDelayTime = 0
    private(set) var serverID: Int64?
    private(set) var domain = ""

    static let pagePattern = "<(.*?)>"
    static let dataURIPattern = #"^data:.*?;base64,(.*)"#
    private static let xmlContentType = #"(?i)(application|text)/\w*\+?xml.*"#

    init(_ mUrl: String, key: String? = nil, page: Int? = nil, speakText: String? = nil, speakSpeed: Int? = nil,
         baseUrl: String = "", session: RuleSession, ruleData: VariableHolder? = nil, chapter: ChapterRef? = nil,
         headerMapF: [String: String]? = nil, hasLoginHeader: Bool = true) throws {
        self.mUrl = mUrl
        self.key = key
        self.page = page
        self.speakText = speakText
        self.speakSpeed = speakSpeed
        self.baseUrl = URLUtils.stripOptions(baseUrl)
        self.session = session
        self.ruleData = ruleData
        self.chapter = chapter
        var headers = try headerMapF ?? session.headerMap(hasLoginHeader: hasLoginHeader)
        headers.removeValue(forKey: "proxy")
        headerMap = headers
        try initUrl()
        domain = URLUtils.subDomain(session.source.key.isEmpty ? url : session.source.key)
    }

    private func initUrl() throws {
        ruleUrl = mUrl
        try analyzeJs()
        try replaceKeyPageJs()
        try analyzeUrl()
    }

    // MARK: - 规则处理

    /// `<js></js>` 与 `@js:`，前文中的 `@result` 替换为上一步结果
    private func analyzeJs() throws {
        let re = try RegexCache.shared.regex(SourceRule.jsPattern)
        let ns = ruleUrl as NSString
        var start = 0
        var result = ruleUrl
        for m in re.matches(in: ruleUrl, range: ruleUrl.fullRange) {
            if m.range.location > start {
                let text = ns.substring(with: NSRange(location: start, length: m.range.location - start)).trimmedControl
                if !text.isEmpty { result = text.replacingOccurrences(of: "@result", with: result) }
            }
            let js = ruleUrl.group(m, 2) ?? ruleUrl.group(m, 1) ?? ""
            result = Self.stringify(try evalJS(js, result: result))
            start = m.range.location + m.range.length
        }
        if ns.length > start {
            let text = ns.substring(from: start).trimmedControl
            if !text.isEmpty { result = text.replacingOccurrences(of: "@result", with: result) }
        }
        ruleUrl = result
    }

    /// 先替换 `{{js}}`，再替换页码 `<1,2,3>`
    private func replaceKeyPageJs() throws {
        if ruleUrl.contains("{{"), ruleUrl.contains("}}") {
            var failure: Error?
            let replaced = RuleSplitter.innerRule(ruleUrl, startStr: "{{", endStr: "}}") { js in
                guard failure == nil else { return "" }
                do {
                    return Self.stringify(try self.evalJS(js, result: nil))
                } catch {
                    failure = error
                    return ""
                }
            }
            if let failure { throw failure }
            if !replaced.isEmpty { ruleUrl = replaced }
        }
        if let page {
            let re = try RegexCache.shared.regex(Self.pagePattern)
            let snapshot = ruleUrl
            for m in re.matches(in: snapshot, range: snapshot.fullRange) {
                let whole = snapshot.substring(with: m.range)
                let pages = (snapshot.group(m, 1) ?? "").components(separatedBy: ",")
                let chosen = page < pages.count ? pages[max(page - 1, 0)] : pages[pages.count - 1]
                ruleUrl = ruleUrl.replacingOccurrences(of: whole, with: chosen.trimmedControl)
            }
        }
    }

    private func analyzeUrl() throws {
        let optionRe = try RegexCache.shared.regex(URLUtils.paramPattern)
        let ns = ruleUrl as NSString
        let match = optionRe.firstMatch(in: ruleUrl, range: ruleUrl.fullRange)
        let urlNoOption = match.map { ns.substring(to: $0.range.location) } ?? ruleUrl
        url = URLUtils.absoluteURL(base: baseUrl, relative: urlNoOption)
        if let b = URLUtils.baseUrl(url) { baseUrl = b }
        if let match {
            let optionText = ns.substring(from: match.range.location + match.range.length)
            if let option = LenientJSON.object(optionText) {
                try applyOption(option)
            }
        }
        urlNoQuery = url
        if method == "GET" {
            if let q = url.firstIndex(of: "?") {
                encodedQuery = encodeParams(String(url[url.index(after: q)...]), isQuery: true)
                urlNoQuery = String(url[..<q])
            }
        } else if let body, !body.isJson, !Self.isXml(body), header("Content-Type").isNilOrEmpty {
            encodedForm = encodeParams(body, isQuery: false)
        }
    }

    private func applyOption(_ option: [String: Any]) throws {
        if let m = option["method"] as? String, m.caseInsensitiveCompare("POST") == .orderedSame { method = "POST" }
        switch option["headers"] {
        case let dict as [String: Any]:
            for (k, v) in dict { headerMap[k] = RuleValue.jsString(v) ?? "" }
        case let text as String:
            for (k, v) in LenientJSON.stringMap(text) ?? [:] { headerMap[k] = v }
        default:
            break
        }
        switch option["body"] {
        case nil, is NSNull: break
        case let s as String: body = s
        case let other?: body = LenientJSON.serialize(other) ?? RuleValue.jsString(other)
        }
        type = (option["type"] as? String).nilIfEmpty
        charset = (option["charset"] as? String).nilIfEmpty
        retry = (option["retry"] as? NSNumber)?.intValue ?? Int(option["retry"] as? String ?? "") ?? 0
        if let webView = option["webView"] {
            switch webView {
            case let b as Bool: useWebView = b
            case let s as String: useWebView = !s.isEmpty && s != "false"
            case is NSNull: useWebView = false
            default: useWebView = true
            }
        }
        webJs = (option["webJs"] as? String).nilIfEmpty
        if let js = (option["js"] as? String).nilIfEmpty, let v = try evalJS(js, result: url) {
            url = Self.stringify(v)
        }
        serverID = (option["serverID"] as? NSNumber)?.int64Value
        webViewDelayTime = max(0, (option["webViewDelayTime"] as? NSNumber)?.intValue ?? 0)
    }

    /// 未指定编码时已编码的片段保持原样；指定编码时总是按该编码编码
    private func encodeParams(_ params: String, isQuery: Bool) -> String {
        let checkEncoded = charset.isNilOrEmpty
        func encode(_ s: String) -> String {
            if checkEncoded, Charsets.isEncodedQuery(s) { return s }
            return Charsets.urlEncode(s, charset: charset)
        }
        return params.components(separatedBy: "&").map { pair in
            guard let eq = pair.firstIndex(of: "=") else { return encode(pair) }
            return encode(String(pair[..<eq])) + "=" + encode(String(pair[pair.index(after: eq)...]))
        }.joined(separator: "&")
    }

    private static func isXml(_ s: String) -> Bool {
        let t = s.trimmedWhitespace
        return t.hasPrefix("<") && t.hasSuffix(">")
    }

    private func header(_ name: String) -> String? {
        headerMap.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func stringify(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let s as String: return s
        case let n as NSNumber: return LenientJSON.numberString(n)
        default: return RuleValue.jsString(value) ?? ""
        }
    }

    // MARK: - JS

    func evalJS(_ js: String, result: Any?) throws -> Any? {
        var bindings = JSBindings(host: self)
        bindings.result = result
        bindings.baseUrl = baseUrl
        bindings.page = page
        bindings.key = key
        bindings.speakText = speakText
        bindings.speakSpeed = speakSpeed
        bindings.book = ruleData as? BookRef
        bindings.chapter = chapter
        return try session.evalJS(js, bindings: bindings)
    }

    // MARK: - 请求

    var requestURL: String {
        guard let encodedQuery else { return urlNoQuery }
        return urlNoQuery + "?" + encodedQuery
    }

    private var dataURLBytes: Data? {
        guard let m = urlNoQuery.firstMatch(Self.dataURIPattern), let payload = urlNoQuery.group(m, 1) else { return nil }
        return Base64Codec.decode(payload)
    }

    /// 文本响应。设置了 `type` 时返回响应字节的十六进制串。
    func getStrResponse(jsStr: String? = nil, sourceRegex: String? = nil, useWebView allowWebView: Bool = true) throws -> StrResponse {
        if type != nil {
            return StrResponse(url: url, body: Hex.encode(try getByteArray()))
        }
        if let data = dataURLBytes {
            return StrResponse(url: url, body: Charsets.decode(data, charset: charset))
        }
        return try withRateLimit {
            applyCookies()
            if useWebView, allowWebView {
                var html: String?
                var pageURL = url
                if method == "POST" {
                    let res = try perform()
                    html = Charsets.decode(res.body, charset: charset, contentType: res.header("Content-Type"))
                    pageURL = res.url
                }
                let body = try session.env.ui.renderWebView(WebViewRequest(
                    html: html, url: pageURL, js: webJs ?? jsStr, sourceKey: session.source.key,
                    headers: headerMap, sourceRegex: sourceRegex, delay: webViewDelayTime
                ))
                return StrResponse(url: pageURL, body: body)
            }
            let res = try perform()
            saveCookies(res)
            var text = Charsets.decode(res.body, charset: charset, contentType: res.header("Content-Type"))
            if let ct = res.header("Content-Type"), ct.matches(Self.xmlContentType),
               !text.trimmedWhitespace.lowercased().hasPrefix("<?xml") {
                text = "<?xml version=\"1.0\"?>" + text
            }
            return StrResponse(url: res.url, body: text, status: res.statusCode, headers: res.headers)
        }
    }

    func getByteArray() throws -> Data {
        if let data = dataURLBytes { return data }
        return try withRateLimit {
            applyCookies()
            let res = try perform()
            saveCookies(res)
            return res.body
        }
    }

    func getResponse() throws -> HTTPResponse {
        if let data = dataURLBytes { return HTTPResponse(url: url, body: data) }
        return try withRateLimit {
            applyCookies()
            let res = try perform()
            saveCookies(res)
            return res
        }
    }

    private func withRateLimit<T>(_ body: () throws -> T) throws -> T {
        let source = session.source
        try RateLimiter.shared.acquire(key: source.key, rate: source.concurrentRate, isCancelled: { self.session.isCancelled })
        defer { RateLimiter.shared.release(key: source.key, rate: source.concurrentRate) }
        return try body()
    }

    /// 交给系统播放器的地址与请求头（含书源 Cookie），不发请求
    func playbackRequest() -> (url: String, headers: [String: String]) {
        applyCookies()
        return (requestURL, headerMap)
    }

    private func buildRequest() -> HTTPRequest {
        var request = HTTPRequest(url: requestURL, method: method, headers: headerMap, timeout: session.env.requestTimeout)
        if method == "POST" {
            request.url = urlNoQuery
            let contentType = header("Content-Type")
            if encodedForm != nil || body.isNilOrBlank {
                request.body = Data((encodedForm ?? "").utf8)
                if contentType.isNilOrEmpty {
                    request.headers["Content-Type"] = "application/x-www-form-urlencoded"
                }
            } else if let contentType, !contentType.isBlank {
                let enc = Charsets.encoding(named: charset) ?? .utf8
                request.body = body?.data(using: enc, allowLossyConversion: true)
            } else {
                request.body = Data((body ?? "").utf8)
                request.headers["Content-Type"] = "application/json; charset=UTF-8"
            }
        }
        return request
    }

    private func perform() throws -> HTTPResponse {
        if session.isCancelled { throw RuleError.cancelled }
        let request = buildRequest()
        var attempt = 0
        while true {
            do {
                return try session.env.http.send(request)
            } catch {
                attempt += 1
                if attempt > retry || session.isCancelled { throw error }
            }
        }
    }

    // MARK: - Cookie

    /// 存储的 Cookie 与请求头中的自定义 Cookie 合并（后者优先）
    private func applyCookies() {
        let stored = session.env.cookies.getCookie(url: domain)
        guard !stored.isEmpty else { return }
        let headerKey = headerMap.keys.first { $0.caseInsensitiveCompare("Cookie") == .orderedSame } ?? "Cookie"
        let merged = CookieStore.merge(CookieStore.cookieToMap(stored), CookieStore.cookieToMap(headerMap[headerKey] ?? ""))
        headerMap[headerKey] = CookieStore.mapToCookie(merged)
    }

    private func saveCookies(_ response: HTTPResponse) {
        guard session.source.enabledCookieJar, !response.setCookies.isEmpty else { return }
        session.env.cookies.replaceCookie(url: domain, cookie: response.setCookies.joined(separator: "; "))
    }
}

extension AnalyzeUrl: JSAnalyzerHost {
    var hostRuleData: VariableHolder? { ruleData }
    var hostChapter: ChapterRef? { chapter }

    func jsGetString(_ rule: String, content: Any?, isUrl: Bool) throws -> String {
        throw RuleError.message("URL 规则中不支持 java.getString")
    }

    func jsGetStringList(_ rule: String, content: Any?, isUrl: Bool) throws -> [String] {
        throw RuleError.message("URL 规则中不支持 java.getStringList")
    }

    func jsGetElements(_ rule: String) throws -> [Any] {
        throw RuleError.message("URL 规则中不支持 java.getElements")
    }

    func jsGetElement(_ rule: String) throws -> Any? {
        throw RuleError.message("URL 规则中不支持 java.getElement")
    }

    func jsSetContent(_ content: Any?, baseUrl: String?) throws {
        throw RuleError.message("URL 规则中不支持 java.setContent")
    }

    func jsPut(_ key: String, _ value: String) -> String {
        if let chapter {
            chapter.putVariable(key, value)
        } else if let ruleData {
            ruleData.putVariable(key, value)
        } else {
            session.sourcePut(key, value)
        }
        return value
    }

    func jsGet(_ key: String) -> String {
        switch key {
        case "bookName": if let book = ruleData as? BookRef { return book.book.name }
        case "title": if let chapter { return chapter.chapter.title }
        default: break
        }
        if let v = chapter?.getVariable(key), !v.isEmpty { return v }
        if let v = ruleData?.getVariable(key), !v.isEmpty { return v }
        return session.sourceGet(key)
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
    var isNilOrBlank: Bool { self?.isBlank ?? true }
}
