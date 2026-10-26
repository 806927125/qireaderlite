import Foundation
import WebKit
import LegadoCore

/// ⭐⭐⭐⭐⭐ **JS 宿主：WKWebView**（2026-10-26 · 跟老引擎一样）
///
/// ⭐⭐⭐ **为什么要它（老引擎为什么免疫闪退）**：
///   老引擎的 JS 跑在 **WKWebView 的 WebContent 独立进程** ⇒
///   站方脚本再野（死循环 / 一次吃几 GB）⇒ **炸的也是那个进程** ⇒ **App 进程不受影响** ⭐⭐⭐
///   而新引擎用 **JSC（进程内）** ⇒ 站方脚本的每一次分配都算 **App 进程**的 ⇒
///   ⇒ jetsam 判杀的正是 App 进程 ⇒ **6.8GB ⇒ 秒杀**（现象 = 闪退 + 没有 .ips）⭐⭐⭐
///   ⇒ **本类就是把新引擎的 JS 搬回独立进程**（老引擎的路子）⭐⭐⭐
///
/// ⭐⭐⭐ **跟老引擎同款的三件事**：
///   ① **一台** WKWebView（不是每源一台）⇒ 内存有界 + 串行（老引擎同款）
///   ② **同步通道** = `window.prompt`（老引擎的 `__qrSync` 同款）
///      ⇒ 站方 JS 里 `java.ajax(...)` 这类**同步**调用能拿到返回值（JSC 版的语义不能丢）⭐⭐⭐
///   ③ **可重建**：换掉 WKWebView = 换掉那条卡死的 JS 线程（老引擎同款急救手段）⭐
///
/// ⚠️⚠️ **同步通道会占用主线程**（prompt 的回调在主线程）⇒ 站方 JS 里的同步网络请求期间 UI 会卡
///   （老引擎同款行为）⇒ 真要流畅得把引擎调用整体挪到后台（已经是了：见 `withRealTimeout`）⭐
@MainActor
final class WebViewJSHost: NSObject, WKNavigationDelegate, WKUIDelegate {

    static let shared = WebViewJSHost()

    /// 同步通道前缀（JS 侧 `prompt("__qrSync:" + payload)`）
    static let syncPrefix = "__qrSync:"

    private(set) var webView: WKWebView?
    private(set) var booted = false
    private(set) var lastError: String?

    /// ⭐ 宿主调用分发（由 `WebViewJSExecutor` 注册）：`(object, method, argsJSON)` ⇒ JSON 文本
    var syncHandler: ((String, String, String) -> String)?

    private var pendingBoot: (() -> Void)?

    // MARK: - 启动

    func boot() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isHidden = true
        webView = wv
        pendingBoot = { [weak self] in self?.injectBootJS() }
        wv.loadHTMLString("<html><head><meta name='viewport' content='width=device-width'></head><body></body></html>",
                          baseURL: nil)
    }

    /// ⭐⭐⭐ **重建**（老引擎同款急救）：换掉 WKWebView = 换掉那条卡死的 JS 线程
    func rebuild() {
        lastError = nil
        booted = false
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        boot()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingBoot?()
        pendingBoot = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastError = "页面加载失败：\(error.localizedDescription)"
    }

    // MARK: - 注入（一次性）

    /// ⭐ 引擎的 JS 兼容层 + 宿主对象包装 + document 替身 + org.jsoup + 同步通道
    private func injectBootJS() {
        var parts: [String] = []
        // ① Java 兼容层（`JavaImporter` / `Packages.*` / 站方 jsLib 的地基）
        parts.append(contentsOf: JavaCompat.sources)
        // ② 宿主对象包装（`source.getVariable` / `java.*` … 全部走 `__hostJSON`）
        parts.append(contentsOf: JSHostAPI.hostWrappers())
        // ③ `document` 替身（站方 jsLib 有 117 处 `document.` ⇒ 缺了整条链死）
        parts.append(JSScopeBuilder.documentStub)
        // ④ `org.jsoup` 兼容层（43 处 `org.jsoup.Jsoup.parse`）
        parts.append(OrgJsoupCompat.source)
        // ⑤ ⭐ 同步通道（老引擎同款：`prompt` 往返）
        parts.append(Self.syncBridgeJS)
        // ⑥ ⭐⭐ **在 JS 里顺手拍一张「启动后的全局」**（`invalidate()` 据此还原）
        //   ⇒ 为什么在 JS 里拍：**主线程不能同步等自己**（那叫死锁）⇒ 不能在这儿回读 ⭐⭐⭐
        parts.append("globalThis.__qrBootGlobals = Object.getOwnPropertyNames(globalThis);")

        let js = parts.joined(separator: "\n")
        evaluate(js) { [weak self] result in
            switch result {
            case .success:
                self?.booted = true
                self?.lastError = nil
            case .failure(let e):
                self?.lastError = "JS 宿主注入失败：\(e.localizedDescription)"
            }
        }
    }

    /// ⭐ `__hostJSON` 的实现：**只做转发**（真正的分发在 Swift 侧 ⇒ 语义与 JSC 版同源）
    private static let syncBridgeJS = """
    (function(){
      if (typeof globalThis.__hostJSON === 'function') { return; }
      globalThis.__hostJSON = function(object, method, argsJSON){
        var payload = JSON.stringify({ o: object, m: method, a: argsJSON });
        var raw = prompt('\(syncPrefix)' + payload);
        if (raw === null || raw === undefined) { return 'null'; }
        return raw;
      };
    })();
    """

    // MARK: - 求值

    /// ⭐ 求值一段 JS ⇒ 完成值必须是 **String**（对象/函数桥接不过去 ⇒ 统一在 JS 侧 `JSON.stringify`）
    func evaluate(_ js: String, completion: @escaping (Result<String?, Error>) -> Void) {
        guard let wv = webView else {
            completion(.failure(NSError(domain: "WebViewJSHost", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "JS 宿主还没起来"])))
            return
        }
        wv.evaluateJavaScript(js) { value, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(value as? String))
            }
        }
    }

    // MARK: - 同步通道（prompt）

    public func webView(_ webView: WKWebView,
                        runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping (String?) -> Void) {
        guard prompt.hasPrefix(Self.syncPrefix) else {
            // 真实网页的 prompt（站方网页自己弹的）⇒ 不接管
            completionHandler(defaultText)
            return
        }
        let payload = String(prompt.dropFirst(Self.syncPrefix.count))
        completionHandler(syncHandler?(payload) ?? #"{"__qrNotImplemented":true}"#)
    }
}
