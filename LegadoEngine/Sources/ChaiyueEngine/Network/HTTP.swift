import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var followRedirects: Bool

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 30, followRedirects: Bool = true) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.followRedirects = followRedirects
    }
}

public struct HTTPResponse: Sendable {
    /// 重定向后的最终地址
    public var url: String
    public var statusCode: Int
    public var headers: [String: String]
    /// 响应中的 Set-Cookie，形如 `name=value`
    public var setCookies: [String]
    public var body: Data

    public init(url: String, statusCode: Int = 200, headers: [String: String] = [:], setCookies: [String] = [], body: Data) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.setCookies = setCookies
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// 同步 HTTP 传输层，在规则引擎工作线程上调用。测试时可注入模拟实现。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) throws -> HTTPResponse
}

/// 基于 URLSession 的实现：可按请求关闭重定向、不使用系统 Cookie
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let lock = NSLock()
    private var noRedirectTasks = Set<Int>()
    private let trustsAllCertificates: Bool

    /// `trustsAllCertificates`：书源常用自签名证书，默认不校验；带账号密码的服务（如 WebDAV）必须校验
    public init(trustsAllCertificates: Bool = true) {
        self.trustsAllCertificates = trustsAllCertificates
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        let queue = OperationQueue()
        queue.name = "RuleEngine.URLSessionTransport"
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    private final class Box: @unchecked Sendable {
        var result: Result<HTTPResponse, Error> = .failure(RuleError.network("无响应"))
    }

    public func send(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let url = Self.makeURL(request.url) else { throw RuleError.network("无效的网址：\(request.url)") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        req.httpShouldHandleCookies = false
        for (key, value) in request.headers {
            // 由系统处理压缩；CookieJar 是 Legado 内部标记
            if key.caseInsensitiveCompare("Accept-Encoding") == .orderedSame { continue }
            if key.caseInsensitiveCompare("CookieJar") == .orderedSame { continue }
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.httpBody = request.body
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let requestURL = request.url
        let task = session.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(RuleError.network(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.result = .failure(RuleError.network("无效的响应"))
                return
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                headers["\(k)"] = "\(v)"
            }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: http.url ?? url)
            box.result = .success(HTTPResponse(
                url: http.url?.absoluteString ?? requestURL,
                statusCode: http.statusCode,
                headers: headers,
                setCookies: cookies.map { "\($0.name)=\($0.value)" },
                body: data ?? Data()
            ))
        }
        if !request.followRedirects {
            lock.withLock { _ = noRedirectTasks.insert(task.taskIdentifier) }
        }
        task.resume()
        semaphore.wait()
        lock.withLock { _ = noRedirectTasks.remove(task.taskIdentifier) }
        return try box.result.get()
    }

    static func makeURL(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return string.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let blocked = lock.withLock { noRedirectTasks.contains(task.taskIdentifier) }
        completionHandler(blocked ? nil : request)
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Darwin)
        // ⭐⭐⭐ **Darwin 专属**（Linux 的 swift-corelibs-foundation 不支持 server trust）⭐⭐⭐
        if trustsAllCertificates, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}

/// 对应 Legado 书源的 `concurrentRate`：`"n"` 表示两次请求间隔 n 毫秒，`"n/ms"` 表示时间窗口内最多 n 次
final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()

    private struct Record {
        var windowStart: Date
        var count: Int
        var active: Int
    }

    private var records: [String: Record] = [:]
    private let lock = NSLock()

    /// 阻塞直到允许访问
    func acquire(key: String, rate: String?, isCancelled: () -> Bool = { false }) throws {
        guard let rate = rate?.trimmedWhitespace, !rate.isEmpty, rate != "0" else { return }
        while true {
            if isCancelled() { throw RuleError.cancelled }
            let wait: TimeInterval = lock.withLock {
                let now = Date()
                var record = records[key] ?? Record(windowStart: .distantPast, count: 0, active: 0)
                defer { records[key] = record }
                if let slash = rate.firstIndex(of: "/") {
                    let limit = Int(rate[..<slash]) ?? 1
                    let window = Double(Int(rate[rate.index(after: slash)...]) ?? 0) / 1000
                    if now >= record.windowStart.addingTimeInterval(window) {
                        record.windowStart = now
                        record.count = 1
                        return 0
                    }
                    if record.count < limit {
                        record.count += 1
                        return 0
                    }
                    return record.windowStart.addingTimeInterval(window).timeIntervalSince(now)
                }
                let interval = Double(Int(rate) ?? 0) / 1000
                if record.active > 0 { return interval }
                let next = record.windowStart.addingTimeInterval(interval)
                if now >= next {
                    record.windowStart = now
                    record.active = 1
                    return 0
                }
                return next.timeIntervalSince(now)
            }
            if wait <= 0 { return }
            Thread.sleep(forTimeInterval: min(wait, 0.5))
        }
    }

    func release(key: String, rate: String?) {
        guard let rate, !rate.isEmpty, rate != "0", !rate.contains("/") else { return }
        lock.withLock {
            if var record = records[key] {
                record.active = max(0, record.active - 1)
                records[key] = record
            }
        }
    }
}
