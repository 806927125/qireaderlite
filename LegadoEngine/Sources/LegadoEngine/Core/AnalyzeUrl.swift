import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URL 规则解析（语义对齐 Legado AnalyzeUrl）：模板求值、options JSON、POST/headers/charset/webView。
public final class AnalyzeUrl {
    public private(set) var url: String = ""
    public var method: String = "GET"
    public var headers: [String: String] = [:]
    public var body: String?
    public var useWebView: Bool = false
    public var webJs: String?
    public var proxy: String?
    public var charset: String?
    public var origin: String?
    public var type: String?
    public var dnsIp: String?

    public let ruleUrl: String
    public let key: String?
    public let page: Int?
    public let book: Book?
    public let chapter: BookChapter?
    public let source: BookSource?
    public let variables: RuleVariables

    private var baseUrl: String
    private var retry: Int = 0
    private var webViewDelayTime: Double = 0
    private var bodyJs: String?
    private let rateLimiter: ConcurrentRateLimiter
    private var bridge: JSBridge?
    private var options: [String: Any] = [:]

    public init(ruleUrl: String, key: String? = nil, page: Int? = nil, baseUrl: String? = nil,
                source: BookSource? = nil, book: Book? = nil, chapter: BookChapter? = nil,
                variables: RuleVariables? = nil, headerMapF: [String: String]? = nil) throws {
        self.ruleUrl = ruleUrl
        self.key = key
        self.page = page
        self.book = book
        self.chapter = chapter
        self.source = source
        self.variables = variables ?? RuleVariables()
        self.baseUrl = baseUrl ?? book?.bookUrl ?? source?.bookSourceUrl ?? ""
        if !self.baseUrl.hasSuffix("/") && !self.baseUrl.isEmpty {
            // 保留原样作为 base；绝对化时按 URL 规则处理
        }
        rateLimiter = ConcurrentRateLimiter(source)
        try analyzeJs()
        try analyzeUrl()
        try loadSourceHeaders(headerMapF)
    }

    // MARK: - 解析阶段

    private func evalJS(_ js: String, result: Any? = nil) throws -> Any? {
        if bridge == nil {
            bridge = JSBridge(source: source, book: book, chapter: chapter, variables: variables)
        }
        var bindings: [String: Any?] = ["result": result, "baseUrl": baseUrl, "key": key, "page": page]
        if let src = source { bindings["source"] = src }
        return try bridge!.eval(js, bindings: bindings)
    }

    /// key/page 占位替换 + {{}}/@js: 求值
    private func analyzeJs() throws {
        var r = ruleUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // 整段 @js:
        if r.lowercased().hasPrefix("@js:") {
            let v = try evalJS(String(r.dropFirst(4)))
            r = v.map { AnalyzeRule.stringify($0) } ?? ""
        }
        // key/page 直接替换（含 {{page-1}} 简单表达式）
        if let key {
            r = r.replacingOccurrences(of: "{{key}}", with: key)
            r = r.replacingOccurrences(of: "{{searchKey}}", with: key)
        }
        if let page {
            r = replacePageExpr(r, page: page)
            r = r.replacingOccurrences(of: "{{page}}", with: String(page))
        }
        // @get / {{...}}
        let ns = r as NSString
        let ms = AnalyzeRule.evalPattern.matches(in: r, range: NSRange(location: 0, length: ns.length))
        for m in ms.reversed() {
            let token = ns.substring(with: m.range)
            var rep = ""
            if token.hasPrefix("@get:") {
                rep = variables.get(String(token.dropFirst(6).dropLast()))
            } else {
                let expr = String(token.dropFirst(2).dropLast())
                if let v = try evalJS(expr) { rep = AnalyzeRule.stringify(v) }
            }
            r = (r as NSString).replacingCharacters(in: m.range, with: rep)
        }
        url = r
    }

    private func replacePageExpr(_ r: String, page: Int) -> String {
        let pat = try! NSRegularExpression(pattern: "\\{\\{page\\s*([+-])\\s*(\\d+)\\}\\}")
        let ns = r as NSString
        let ms = pat.matches(in: r, range: NSRange(location: 0, length: ns.length))
        var out = r
        for m in ms.reversed() {
            let op = ns.substring(with: m.range(at: 1))
            let n = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let v = op == "+" ? page + n : page - n
            out = (out as NSString).replacingCharacters(in: m.range, with: String(v))
        }
        return out
    }

    /// 拆 options（逗号后 JSON）、绝对化、POST body
    private func analyzeUrl() throws {
        var r = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // options：第一个逗号后以 { 开头（跳过 {{}} 内）
        if let comma = findOptionsComma(r) {
            let optStr = String(r[r.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            if optStr.hasPrefix("{"), let d = optStr.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                options = o
                r = String(r[..<comma]).trimmingCharacters(in: .whitespaces)
            }
        }
        // data: URI 保持原样
        if !r.lowercased().hasPrefix("data:") {
            r = NetworkUtils.absoluteURL(baseUrl.isEmpty ? nil : baseUrl, r)
        }
        url = r

        if let m = options["method"] as? String, m.uppercased() == "POST" { method = "POST" }
        if let b = options["body"] as? String { body = b }
        if let c = options["charset"] as? String { charset = c }
        if let p = options["proxy"] as? String { proxy = p }
        if let t = options["type"] as? String { type = t }
        if let d = options["dnsIp"] as? String { dnsIp = d }
        if let rt = options["retry"] as? Int { retry = rt }
        if let wv = options["webView"] {
            useWebView = (wv as? Bool) ?? ("\(wv)" == "true")
        }
        if let wj = options["webJs"] as? String { webJs = wj }
        if let js = options["js"] as? String { bodyJs = js }
        if let delay = options["webViewDelayTime"] as? Double { webViewDelayTime = delay }

        // POST：无 body 时用 query 作为表单
        if method == "POST" && body == nil {
            if let q = URL(string: url)?.query {
                body = q
                url = url.components(separatedBy: "?").first ?? url
            }
        }
        // body 模板求值
        if var b = body {
            if let key { b = b.replacingOccurrences(of: "{{key}}", with: key) }
            if let page { b = b.replacingOccurrences(of: "{{page}}", with: String(page)) }
            if b.lowercased().hasPrefix("@js:") {
                let v = try evalJS(String(b.dropFirst(4)))
                b = v.map { AnalyzeRule.stringify($0) } ?? ""
            } else {
                let ns = b as NSString
                let ms = AnalyzeRule.evalPattern.matches(in: b, range: NSRange(location: 0, length: ns.length))
                for m in ms.reversed() {
                    let token = ns.substring(with: m.range)
                    var rep = ""
                    if token.hasPrefix("@get:") {
                        rep = variables.get(String(token.dropFirst(6).dropLast()))
                    } else if let v = try evalJS(String(token.dropFirst(2).dropLast())) {
                        rep = AnalyzeRule.stringify(v)
                    }
                    b = (b as NSString).replacingCharacters(in: m.range, with: rep)
                }
            }
            body = b
        }
        if let js = bodyJs {
            let v = try evalJS(js)
            if let s = v as? String { body = s }
        }
        // origin
        origin = source?.bookSourceUrl
    }

    private func findOptionsComma(_ r: String) -> String.Index? {
        var depth = 0
        var i = r.startIndex
        while i < r.endIndex {
            let c = r[i]
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1 }
            else if c == "," && depth == 0 {
                let after = r[r.index(after: i)...].trimmingCharacters(in: .whitespaces)
                if after.hasPrefix("{") { return i }
            }
            i = r.index(after: i)
        }
        return nil
    }

    private func loadSourceHeaders(_ headerMapF: [String: String]?) throws {
        var h: [String: String] = [:]
        // source.header（JSON 或 @js:）
        if var hs = source?.header, !hs.isEmpty {
            hs = hs.trimmingCharacters(in: .whitespacesAndNewlines)
            if hs.lowercased().hasPrefix("@js:") {
                if let v = try evalJS(String(hs.dropFirst(4))) { hs = AnalyzeRule.stringify(v) }
            } else if hs.hasPrefix("<js>") {
                if let v = try evalJS(hs) { hs = AnalyzeRule.stringify(v) }
            }
            if let d = hs.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { h[k] = "\(v)" }
            }
        }
        if let oh = options["headers"] as? [String: Any] {
            for (k, v) in oh { h[k] = "\(v)" }
        }
        if let fm = headerMapF { for (k, v) in fm { h[k] = v } }
        if h.keys.first(where: { $0.lowercased() == "user-agent" }) == nil {
            h["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }
        headers = h
    }

    // MARK: - 请求

    public func makeRequest() throws -> URLRequest {
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            throw LegadoError("url 解析失败: \(url)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            let enc = HTTPClient.encoding(named: charset) ?? .utf8
            req.httpBody = body.data(using: enc) ?? body.data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil && method == "POST" {
                let isJson = body.trimmingCharacters(in: .whitespaces).hasPrefix("{")
                req.setValue(isJson ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        if source?.enabledCookieJar == false {
            req.setValue(nil, forHTTPHeaderField: "Cookie")
            req.httpShouldHandleCookies = false
        }
        return req
    }

    /// data: URI 直接构造响应
    private func dataUriResponse() -> HTTPClient.Response? {
        guard url.lowercased().hasPrefix("data:") else { return nil }
        let rest = String(url.dropFirst(5))
        var isB64 = false
        var payload = rest
        if let comma = rest.firstIndex(of: ",") {
            let meta = rest[..<comma]
            isB64 = meta.lowercased().contains("base64")
            payload = String(rest[rest.index(after: comma)...])
        }
        let data: Data
        if isB64 {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8) ?? Data()
        }
        let body = HTTPClient.decode(data, charset: charset, contentType: nil)
        return HTTPClient.Response(url: URL(string: "data:")!, statusCode: 200, data: data, body: body)
    }

    public func fetch(webJs: String? = nil, sourceRegex: String? = nil) async throws -> HTTPClient.Response {
        await rateLimiter.wait()
        if let resp = dataUriResponse() { return try postProcess(resp) }
        var lastError: Error?
        for _ in 0...(max(0, retry)) {
            do {
                var resp: HTTPClient.Response
                if useWebView {
                    let r = try await WebFetcher.fetch(url: url, html: nil, headers: headers,
                                                       webJs: webJs ?? self.webJs, sourceRegex: sourceRegex,
                                                       delay: webViewDelayTime, timeout: 60)
                    resp = HTTPClient.Response(url: URL(string: r.url) ?? URL(string: url)!,
                                               data: r.html.data(using: .utf8) ?? Data(), body: r.html)
                } else {
                    resp = try await HTTPClient.shared.request(try makeRequest(), charset: charset, proxy: proxy)
                }
                return try postProcess(resp)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LegadoError("请求失败: \(url)")
    }

    public func fetchSync() -> HTTPClient.Response? {
        if let resp = dataUriResponse() { return try? postProcess(resp) }
        guard let req = try? makeRequest() else { return nil }
        guard var resp = HTTPClient.shared.requestSync(req, charset: charset, proxy: proxy) else { return nil }
        resp = (try? postProcess(resp)) ?? resp
        return resp
    }

    /// loginCheckJs
    private func postProcess(_ resp: HTTPClient.Response) throws -> HTTPClient.Response {
        if let js = source?.loginCheckJs, !js.isEmpty {
            _ = try evalJS(js, result: resp.body)
        }
        return resp
    }
}