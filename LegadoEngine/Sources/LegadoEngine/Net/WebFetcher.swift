import Foundation

/// WebView 抓取结果。
public struct WebFetchResult {
    public var html: String
    public var url: String
}

#if canImport(WebKit) && !os(Linux)
import WebKit

/// WKWebView 抓取（webView 规则 / webJs / sourceRegex 资源嗅探）。
public enum WebFetcher {
    public static func fetch(url: String?, html: String?, headers: [String: String],
                             webJs: String?, sourceRegex: String?,
                             delay: Double, timeout: Double) async throws -> WebFetchResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let cfg = WKWebViewConfiguration()
                cfg.websiteDataStore = .default()
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
                let delegate = FetchDelegate(cont: cont, webJs: webJs, sourceRegex: sourceRegex,
                                             delay: delay, timeout: timeout)
                webView.navigationDelegate = delegate
                delegate.webView = webView
                objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
                if let html {
                    webView.loadHTMLString(html, baseURL: url.flatMap { URL(string: $0) })
                } else if let url, let u = URL(string: url) {
                    var req = URLRequest(url: u)
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    webView.load(req)
                } else {
                    cont.resume(throwing: LegadoError("WebFetcher: 无 url/html"))
                }
            }
        }
    }

    private final class FetchDelegate: NSObject, WKNavigationDelegate {
        let cont: CheckedContinuation<WebFetchResult, Error>
        let webJs: String?
        let sourceRegex: String?
        let delay: Double
        var webView: WKWebView?
        var done = false
        var timer: Timer?

        init(cont: CheckedContinuation<WebFetchResult, Error>, webJs: String?, sourceRegex: String?,
             delay: Double, timeout: Double) {
            self.cont = cont; self.webJs = webJs; self.sourceRegex = sourceRegex; self.delay = delay
            super.init()
            timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                self?.finish(error: LegadoError("WebView 加载超时"))
            }
        }

        func finish(error: Error? = nil) {
            guard !done else { return }
            done = true
            timer?.invalidate()
            if let error { cont.resume(throwing: error); return }
            guard let webView else { cont.resume(throwing: LegadoError("WebView 已释放")); return }
            let url = webView.url?.absoluteString ?? ""
            var js = "document.documentElement.outerHTML"
            if let webJs, !webJs.isEmpty {
                js = "(function(){ var result = null; try { result = (function(){ \(webJs) })(); } catch(e){} " +
                     "return result != null ? String(result) : document.documentElement.outerHTML; })()"
            }
            webView.evaluateJavaScript(js) { [weak self] value, err in
                guard let self, !self.done else { return }
                self.done = true
                self.timer?.invalidate()
                var html = (value as? String) ?? ""
                var finalUrl = url
                if let regex = self.sourceRegex, !regex.isEmpty,
                   let re = try? NSRegularExpression(pattern: regex),
                   let m = re.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                    let ns = html as NSString
                    finalUrl = ns.substring(with: m.range(at: m.numberOfRanges > 1 ? 1 : 0))
                    if html.isEmpty { html = finalUrl }
                }
                self.cont.resume(returning: WebFetchResult(html: html, url: finalUrl))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.5)) { [weak self] in
                self?.finish()
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(error: error)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(error: error)
        }
    }
}
#else
public enum WebFetcher {
    public static func fetch(url: String?, html: String?, headers: [String: String],
                             webJs: String?, sourceRegex: String?,
                             delay: Double, timeout: Double) async throws -> WebFetchResult {
        throw LegadoError("当前平台不支持 WebView 抓取（需要 WebKit）")
    }
}
#endif