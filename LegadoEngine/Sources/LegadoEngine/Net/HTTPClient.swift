import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP 客户端（URLSession），含编码嗅探与 GB18030 容错。
public final class HTTPClient {
    public static let shared = HTTPClient()

    public struct Response {
        public var url: URL
        public var statusCode: Int
        public var headers: [String: String]
        public var data: Data
        public var body: String
        public var cookies: [String: String]
        public init(url: URL, statusCode: Int = 200, headers: [String: String] = [:],
                    data: Data = Data(), body: String = "", cookies: [String: String] = [:]) {
            self.url = url; self.statusCode = statusCode; self.headers = headers
            self.data = data; self.body = body; self.cookies = cookies
        }
    }

    let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        session = URLSession(configuration: cfg)
    }

    public func request(_ req: URLRequest, charset: String? = nil, proxy: String? = nil) async throws -> Response {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, resp, error in
                if let error { cont.resume(throwing: error); return }
                guard let http = resp as? HTTPURLResponse else {
                    cont.resume(throwing: LegadoError("无效响应")); return
                }
                let d = data ?? Data()
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers["\(k)"] = "\(v)"
                }
                let body = Self.decode(d, charset: charset, contentType: headers["Content-Type"] ?? headers["content-type"])
                var cookies: [String: String] = [:]
                if let url = http.url, let cs = HTTPCookieStorage.shared.cookies(for: url) {
                    for c in cs { cookies[c.name] = c.value }
                }
                cont.resume(returning: Response(url: http.url ?? req.url!, statusCode: http.statusCode,
                                                headers: headers, data: d, body: body, cookies: cookies))
            }
            task.resume()
        }
    }

    /// 同步请求（供 JS java.ajax 使用；勿在主线程调用）。
    public func requestSync(_ req: URLRequest, charset: String? = nil, proxy: String? = nil, followRedirects: Bool = true) -> Response? {
        let sem = DispatchSemaphore(value: 0)
        var result: Response?
        let task = session.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse else { return }
            let d = data ?? Data()
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
            let body = Self.decode(d, charset: charset, contentType: headers["Content-Type"] ?? headers["content-type"])
            var cookies: [String: String] = [:]
            if let url = http.url, let cs = HTTPCookieStorage.shared.cookies(for: url) {
                for c in cs { cookies[c.name] = c.value }
            }
            result = Response(url: http.url ?? req.url!, statusCode: http.statusCode,
                              headers: headers, data: d, body: body, cookies: cookies)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 90)
        return result
    }

    // MARK: 编码

    public static func encoding(named name: String?) -> String.Encoding? {
        guard let name, !name.isEmpty else { return nil }
        let n = name.lowercased().replacingOccurrences(of: "-", with: "")
        switch n {
        case "utf8", "utf": return .utf8
        case "gbk", "gb2312", "gb18030": return gb18030Encoding()
        case "big5": return big5Encoding()
        case "utf16", "utf16le": return .utf16LittleEndian
        case "utf16be": return .utf16BigEndian
        case "iso88591", "latin1": return .isoLatin1
        case "ascii": return .ascii
        case "shiftjis", "sjis": return .shiftJIS
        case "eucjp": return .japaneseEUC
        default: return nil
        }
    }

    static func gb18030Encoding() -> String.Encoding {
        #if canImport(CoreFoundation) && !os(Linux)
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
        #else
        return .utf8
        #endif
    }
    static func big5Encoding() -> String.Encoding {
        #if canImport(CoreFoundation) && !os(Linux)
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        return String.Encoding(rawValue: cf)
        #else
        return .utf8
        #endif
    }

    public static func decode(_ data: Data, charset: String?, contentType: String?) -> String {
        // 1. 显式 charset
        if let enc = encoding(named: charset), let s = String(data: data, encoding: enc) { return s }
        // 2. Content-Type
        if let ct = contentType, let r = ct.range(of: "charset=", options: .caseInsensitive) {
            var cs = String(ct[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let semi = cs.firstIndex(of: ";") { cs = String(cs[..<semi]) }
            cs = cs.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let enc = encoding(named: cs), let s = String(data: data, encoding: enc) { return s }
        }
        // 3. UTF-8 严格
        if let s = String(data: data, encoding: .utf8) { return s }
        // 4. HTML meta 嗅探
        if let head = String(data: data.prefix(2048), encoding: .isoLatin1) {
            let pat = try! NSRegularExpression(pattern: "charset\\s*=\\s*[\"']?([\\w-]+)", options: [.caseInsensitive])
            if let m = pat.firstMatch(in: head, range: NSRange(location: 0, length: head.utf16.count)) {
                let cs = (head as NSString).substring(with: m.range(at: 1))
                if let enc = encoding(named: cs), let s = String(data: data, encoding: enc) { return s }
            }
        }
        // 5. GB18030 容错
        let gb = gb18030Encoding()
        if let s = String(data: data, encoding: gb) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}