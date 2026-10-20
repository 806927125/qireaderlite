import SwiftUI
import WebKit

/// 内嵌浏览器 —— 书源的 `java.startBrowser` / `startBrowserAwait` 用它。
///
/// ## 为什么必须内嵌，不能跳系统 Safari
/// 聚合源的「🍅番茄登录 / 🔐注册书源 / 🏝用户后台 / 📐使用教程」这些按钮，
/// 全都是 **打开网页 → 用户扫码/授权 → 站方从页面里拿 token 或 cookie**。
/// 跳 Safari 的话，登录后的 cookie 落在 Safari 的罐里，**我们读不回来**，
/// 番茄的 token 就永远拿不到 → 番茄的书依然读不了。
///
/// ## 关键点
/// · `websiteDataStore = .default()` —— 共享 WK 的 cookie 罐，登录态留得住
/// · 关闭时把 WK 的 cookie **同步进 `HTTPCookieStorage.shared`** ——
///   引擎发请求走的是 URLSession，用的是 shared 那个罐，两边得对上
struct BrowserSheet: View {
    let url: String
    let title: String
    /// 关闭时把当前页面交回去（HTML / URL / Cookie 串）
    var onFinish: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var address = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                Divider()
                BrowserWebView(url: url,
                               webView: $webView,
                               onNav: { back, fwd in canGoBack = back; canGoForward = fwd })
            }
            .navigationTitle(title.isEmpty ? "浏览器" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { close() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!canGoBack)
                    Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!canGoForward)
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
            TextField("地址", text: $address)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { go(address) }
            Button { go(address) } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }

    private func go(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        if let u = URL(string: s) { webView?.load(URLRequest(url: u)) }
    }

    private func reload() {
        webView?.reload()
    }

    /// 关闭：把页面 HTML / 当前 URL / cookie 交回去
    private func close() {
        guard let wv = webView else {
            onFinish("", "", "")
            dismiss()
            return
        }
        let current = wv.url?.absoluteString ?? ""
        Task { @MainActor in
            let html = await Self.html(of: wv)
            let cookie = await Self.syncCookies(from: wv)
            onFinish(html, current, cookie)
            dismiss()
        }
    }

    /// 页面 HTML
    private static func html(of wv: WKWebView) async -> String {
        await withCheckedContinuation { cont in
            wv.evaluateJavaScript("document.documentElement.outerHTML") { v, _ in
                cont.resume(returning: (v as? String) ?? "")
            }
        }
    }

    /// 把 WK 的 cookie 同步进 `HTTPCookieStorage.shared`（引擎发请求用那个罐）
    private static func syncCookies(from wv: WKWebView) async -> String {
        let store = wv.configuration.websiteDataStore.httpCookieStore
        let all = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        var parts: [String] = []
        for c in all {
            // 只同步当前站点的（别把别的站的 cookie 倒过去）
            if let host = wv.url?.host, !c.domain.contains(host) && !host.contains(c.domain) { continue }
            HTTPCookieStorage.shared.setCookie(c)
            parts.append("\(c.name)=\(c.value)")
        }
        return parts.joined(separator: "; ")
    }
}

/// WKWebView 的 SwiftUI 壳
private struct BrowserWebView: UIViewRepresentable {
    let url: String
    @Binding var webView: WKWebView?
    var onNav: (Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // ⚠️ 必须是 default：共享的 cookie 罐，登录态才留得住
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        webView = wv
        if let u = URL(string: url) { wv.load(URLRequest(url: u)) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BrowserWebView
        init(_ p: BrowserWebView) { parent = p }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onNav(webView.canGoBack, webView.canGoForward)
        }
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}
