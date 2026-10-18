import Foundation
import WebKit

/// 栖阅的阅读界面（reader.html / reader.js / reader.css / reader-scroll-core.js）
/// 原样搬过来用；它跟原生之间的桥协议在下面实现。
///
/// 协议很小：
///   JS → 原生（8 类消息）：ready / requestChapter / progress / visibleChapter
///                         tap / commentTap / commentLongPress / debugLog
///   原生 → JS（window.QiReader 5 个方法）：applySettings / setInitial / upsertChapter
///                                          refreshChapters / markChapterRequestFinished
@MainActor
final class ReaderHost: NSObject, ObservableObject {
    private(set) var web: WKWebView!

    /// 章节索引 → 章节（去掉卷标题，跟界面里的 chapterIndex 对齐）
    private(set) var chapters: [Chapter] = []
    private var currentIndex = 0
    private var settings: [String: Any] = [:]
    private var loaded: Set<Int> = []
    private var loading: Set<Int> = []

    /// JS 说"我要第 i 章" → 宿主去取正文，取完 upsertChapter 回填
    var onRequestChapter: ((Int) async -> Void)?
    /// 阅读进度（章索引 + 章内比例）
    var onProgress: ((Int, Double) -> Void)?
    /// 当前可见章节
    var onVisibleChapter: ((Int) -> Void)?
    /// 正文里点了一下（宿主可用来显/隐工具栏）
    var onTap: (() -> Void)?
    /// 翻页模式：点正文左半边 / 右半边翻上一章 / 下一章。
    /// 传 -1 表示"到头，没有下一章"，让 UI 能弹个提示而不是装没听见。
    var onTapZone: ((Double) -> Void)?
    /// 引擎调试日志
    var onDebugLog: ((String, [String: Any]) -> Void)?
    /// JS 侧 ready 了（reader.js 加载完，会先 post("ready")）
    var onReady: (() -> Void)?
    @Published private(set) var ready = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "qiReader")
        web.navigationDelegate = self
        load()
    }

    private func load() {
        guard let dir = ResourceLocator.locate("reader.html").map({ $0.deletingLastPathComponent() }),
              let html = try? String(contentsOf: dir.appendingPathComponent("reader.html"),
                                     encoding: .utf8) else {
            web.loadHTMLString("<h1>阅读界面文件缺失</h1>", baseURL: nil)
            return
        }
        // reader.html 用相对路径引 css/js，baseURL 必须指到文件所在目录
        web.loadHTMLString(html, baseURL: dir)
    }

    // MARK: - 原生 → JS

    func apply(chapters list: [Chapter], at index: Int, progress: (chapterIndex: Int, scrollRatio: Double)?) {
        chapters = list
        currentIndex = max(0, min(index, max(list.count - 1, 0)))
        loaded.removeAll(); loading.removeAll()
        let payload: [String: Any] = [
            "chapters": list.enumerated().map { i, c in chapterPayload(i, c, state: "loading") },
            "currentIndex": currentIndex,
            "progress": progress.map { ["chapterIndex": $0.chapterIndex, "scrollRatio": $0.scrollRatio] }
                ?? ["chapterIndex": currentIndex, "scrollRatio": 0.0]
        ]
        callJS("applySettings", settings)
        callJS("setInitial", payload)
    }

    func setSettings(_ s: [String: Any]) {
        settings = s
        callJS("applySettings", s)
    }

    func update(index: Int, text: String, title: String) {
        loaded.insert(index)
        loading.remove(index)
        let payload = chapterPayload(index, chapters.indices.contains(index) ? chapters[index] : Chapter(url: "", title: title, index: index),
                                     state: "loaded", text: text, title: title)
        callJS("upsertChapter", ["payload": payload, "mode": "replace"])
    }

    func fail(index: Int, message: String) {
        loaded.remove(index)
        loading.remove(index)
        let payload = chapterPayload(index, chapters.indices.contains(index) ? chapters[index] : Chapter(url: "", title: "", index: index),
                                     state: "failed", text: message)
        callJS("upsertChapter", ["payload": payload, "mode": "replace"])
    }

    private func chapterPayload(_ index: Int, _ c: Chapter,
                                state: String, text: String = "",
                                title: String? = nil) -> [String: Any] {
        ["chapterIndex": index,
         "title": title ?? c.title,
         "text": text,
         "state": state,
         "contentHash": String(abs(c.url.hashValue)),
         "chapterTitle": ["isEnabled": true, "isHTMLMode": false]]
    }

    private func callJS(_ fn: String, _ arg: Any) {
        var payload = arg
        if !(payload is [String: Any]) && !(payload is [Any]) { payload = ["value": payload] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.QiReader && window.QiReader.\(fn)(\(json));",
                                   completionHandler: nil)
    }

    /// 翻页模式需要知道"点的是正文左边还是右边"，但 reader.js 是从栖阅 IPA
    /// 原样搬来的（post("tap", {}) 不带坐标），**不改那个文件**，
    /// 用 capture 阶段的监听把 clientX 补进去，跟 reader.js 自己的 click 监听并存。
    ///
    /// 只做坐标透传、不 preventDefault，所以段评点按、文本选择、
    /// 长按选词这些 reader.js 原有的行为一律不受影响。
    private func installTapPosShim() {
        web.evaluateJavaScript(Self.tapPosShim, completionHandler: nil)
    }

    private static let tapPosShim = """
    (function () {
      if (window.__qrTapPos) return;
      window.__qrTapPos = 1;
      document.addEventListener('click', function (e) {
        var t = e.target;
        if (t && t.closest && t.closest('.comment-node')) return; // 段评交给 reader.js
        var w = (document.documentElement && document.documentElement.clientWidth) || window.innerWidth || 1;
        var x = (e.clientX || 0) / w;
        try {
          window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.qiReader &&
            window.webkit.messageHandlers.qiReader.postMessage({ type: 'tap', x: x });
        } catch (_) {}
      }, true);
    })();
    ;void 0;
    """

    // MARK: - WKScriptMessageHandler

    func handle(name: String, body: Any) {
        guard name == "qiReader",
              let m = body as? [String: Any],
              let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            installTapPosShim()
            onReady?()
            break

        case "requestChapter":
            guard let idx = number(m["chapterIndex"]) else { return }
            let mode = m["mode"] as? String ?? "append"
            guard !loading.contains(idx), !loaded.contains(idx), chapters.indices.contains(idx) else {
                callJS("markChapterRequestFinished", ["index": idx, "mode": mode])
                return
            }
            loading.insert(idx)
            Task { [weak self] in
                await self?.onRequestChapter?(idx)
                self?.callJS("markChapterRequestFinished", ["index": idx, "mode": mode])
            }

        case "progress":
            let idx = number(m["chapterIndex"]) ?? currentIndex
            let ratio = doubleOf(m["scrollRatio"]) ?? 0
            currentIndex = idx
            onProgress?(idx, ratio)

        case "visibleChapter":
            if let idx = number(m["chapterIndex"]) {
                currentIndex = idx
                onVisibleChapter?(idx)
            }

        case "tap":
            // reader.js 原样搬自栖阅，post("tap", {}) 不带坐标。
            // 由 Swift 侧注入的 tapPosShim 在 capture 阶段补上 x（0~1）。
            if let x = m["x"] as? Double {
                onTapZone?(x)
            } else {
                onTap?()
            }

        case "debugLog":
            let ev = m["event"] as? String ?? ""
            onDebugLog?(ev, m)

        default:
            break   // commentTap / commentLongPress：段评，本版本没接，先忽略
        }
    }

    private func doubleOf(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    private func number(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return nil
    }
}

extension ReaderHost: WKScriptMessageHandler {
    nonisolated func userContentController(_ c: WKUserContentController,
                                          didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor [weak self] in
            self?.handle(name: message.name, body: body)
        }
    }
}

extension ReaderHost: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 只允许本地阅读页，别让书源里的 JS 把 WebView 导航走
        decisionHandler(.allow)
    }
}
