#if canImport(WebKit) && !os(Linux)
import Foundation
import ChaiyueEngine
import WebKit

/// 离屏 WebView 渲染（书源 `webView:true`、`java.webView`），行为与 Legado BackstageWebView 一致：
/// - 页面加载完成后等待 1000 + delay 毫秒执行 webJs（为空时取整页源码）；结果为 null/undefined 时每秒重试，最多 30 次；
/// - `sourceRegex` 不为空时为嗅探模式：第一个完整匹配正则的资源地址即为结果，webJs 照常执行但忽略结果；
/// - 加载前写入引擎 Cookie，每次加载完成把 WebView 的 Cookie 合并回引擎（保存在书源名下）。
@MainActor
public final class WebViewRenderer: NSObject, WKNavigationDelegate {
    public static let maxRetries = 30

    private static var active: Set<WebViewRenderer> = []

    private let request: WebViewRequest
    private let environment: SourceEnvironment
    private let dataStore: WKWebsiteDataStore
    private let completion: @Sendable (Result<String, Error>) -> Void
    private let sniffer: NSRegularExpression?
    private var webView: WKWebView?
    private var finished = false
    private var retries = 0
    private var evaluation: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []

    private init(request: WebViewRequest, environment: SourceEnvironment, dataStore: WKWebsiteDataStore,
                 completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        self.request = request
        self.environment = environment
        self.dataStore = dataStore
        self.completion = completion
        sniffer = request.sourceRegex.flatMap { $0.isEmpty ? nil : try? NSRegularExpression(pattern: $0) }
    }

    /// 渲染并回调结果；`dataStore` 为空时使用默认数据存储
    public static func render(_ request: WebViewRequest, environment: SourceEnvironment, timeout: Duration = .seconds(60),
                              dataStore: WKWebsiteDataStore? = nil,
                              completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        let renderer = WebViewRenderer(request: request, environment: environment, dataStore: dataStore ?? .default(),
                                       completion: completion)
        active.insert(renderer)
        renderer.start(timeout: timeout)
    }

    public static func render(_ request: WebViewRequest, environment: SourceEnvironment, timeout: Duration = .seconds(60),
                              dataStore: WKWebsiteDataStore? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            render(request, environment: environment, timeout: timeout, dataStore: dataStore) { continuation.resume(with: $0) }
        }
    }

    // MARK: - 流程

    private var userAgent: String {
        request.headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
            ?? environment.webViewUserAgent
    }

    private var script: String? {
        guard let js = request.js?.trimmingCharacters(in: .whitespacesAndNewlines), !js.isEmpty else { return nil }
        return js
    }

    private func start(timeout: Duration) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = userAgent
        self.webView = webView

        spawn { [self] in
            if let url = request.url, !url.isEmpty {
                await CookieSync.push(url, from: environment.cookies, to: dataStore.httpCookieStore)
            }
            load()
        }
        spawn { [self] in
            try? await Task.sleep(for: timeout)
            finish(.failure(RuleError.message("WebView 加载超时")))
        }
        if sniffer != nil {
            spawn { [self] in await pollResources() }
        }
    }

    private func load() {
        guard !finished, let webView else { return }
        let base = request.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if let html = request.html, !html.isEmpty {
            webView.loadHTMLString(html, baseURL: base)
        } else if let base {
            var urlRequest = URLRequest(url: base)
            for (key, value) in request.headers where key.caseInsensitiveCompare("User-Agent") != .orderedSame {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
            webView.load(urlRequest)
        } else {
            finish(.failure(RuleError.message("WebView 地址为空")))
        }
    }

    /// 每次页面加载完成都重新计时（重定向、跳转后以最后一次为准），重试次数累计
    private func pageFinished() {
        guard !finished else { return }
        let pageURL = webView?.url?.absoluteString ?? request.url ?? ""
        spawn { [self] in
            await CookieSync.pull(pageURL, into: environment.cookies, key: request.sourceKey, from: dataStore.httpCookieStore)
        }
        if sniffer != nil, script == nil { return }
        evaluation?.cancel()
        let delay = 1000 + max(0, request.delay)
        evaluation = spawn { [self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await evaluate()
        }
    }

    private func evaluate() async {
        let script = script ?? "document.documentElement.outerHTML"
        while !finished, !Task.isCancelled, let webView {
            let value = await webView.evaluateString(script)
            if sniffer != nil { return }
            if let value {
                finish(.success(value))
                return
            }
            if retries >= Self.maxRetries {
                finish(.failure(RuleError.message("js执行超时")))
                return
            }
            retries += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - 嗅探

    private func pollResources() async {
        let probe = "JSON.stringify([location.href].concat(performance.getEntriesByType('resource').map(function(e){return e.name})))"
        while !finished, !Task.isCancelled, let webView {
            if let json = await webView.evaluateString(probe),
               let urls = try? JSONDecoder().decode([String].self, from: Data(json.utf8)),
               let hit = urls.first(where: matchesSniffer) {
                finish(.success(hit))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func matchesSniffer(_ url: String) -> Bool {
        guard let sniffer else { return false }
        let range = NSRange(url.startIndex..., in: url)
        return sniffer.firstMatch(in: url, options: .anchored, range: range)?.range == range
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url?.absoluteString, matchesSniffer(url) {
            decisionHandler(.cancel)
            finish(.success(url))
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageFinished()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !Self.isCancellation(error) { pageFinished() }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !Self.isCancellation(error) { finish(.failure(error)) }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    // MARK: - 收尾

    @discardableResult
    private func spawn(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { @MainActor in await body() }
        tasks.append(task)
        return task
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        for task in tasks { task.cancel() }
        tasks = []
        evaluation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        Self.active.remove(self)
        completion(result)
    }
}

extension WKWebView {
    /// 执行脚本，结果转成字符串；undefined、null 或脚本出错时返回 nil
    func evaluateString(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: Self.stringify(value))
            }
        }
    }

    nonisolated static func stringify(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let object?:
            if JSONSerialization.isValidJSONObject(object),
               let data = try? JSONSerialization.data(withJSONObject: object) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: object)
        }
    }
}

#endif  // #if canImport(WebKit) && !os(Linux)
