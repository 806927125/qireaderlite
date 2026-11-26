#if os(iOS)
// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
import CoreText
import ChaiyueReaderKit
import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// `chaiyue://` 资源：`theme/文件名` 主题素材、`image/?src=` 正文插图、`font/PostScript名` 本机字体文件
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    var themeID: String?
    var imageData: ((String) -> Data?)?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (data, mime) = resolve(url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func resolve(_ url: URL) -> (Data, String)? {
        switch url.host {
        case "theme":
            guard let id = themeID else { return nil }
            let name = url.lastPathComponent
            let file = ReaderThemeStore.shared.fileURL(id, named: name)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            return (data, Self.mime(file.pathExtension))
        case "image":
            let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "src" }?.value
            guard let src, let data = imageData?(src) else { return nil }
            return (data, Self.sniff(data))
        case "font":
            let requested = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            for name in Self.fontCandidates(requested) {
                let font = CTFontCreateWithName(name as CFString, 12, nil)
                guard CTFontCopyPostScriptName(font) as String == name,
                      let file = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                      let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
                return (data, Self.mime(file.pathExtension))
            }
            return nil
        default:
            return nil
        }
    }

    /// 楷体在新系统上去掉了连字符。样式里两种名字都认
    private static func fontCandidates(_ name: String) -> [String] {
        let alias = [
            "STKaiti-SC-Regular": "STKaitiSC-Regular",
            "STKaiti-SC-Bold": "STKaitiSC-Bold",
            "STKaiti-SC-Black": "STKaitiSC-Black",
            "STKaitiSC-Regular": "STKaiti-SC-Regular",
            "STKaitiSC-Bold": "STKaiti-SC-Bold",
            "STKaitiSC-Black": "STKaiti-SC-Black",
        ]
        if let other = alias[name], other != name { return [name, other] }
        return [name]
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "ttc", "otc": return "font/collection"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        case "css": return "text/css"
        case "js": return "text/javascript"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private static func sniff(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if head.count >= 12, head[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if let text = String(data: data.prefix(256), encoding: .utf8), text.contains("<svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}

/// 消息处理器被 WKUserContentController 强引用，经弱引用转一手避免循环
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebReaderEngine?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        target?.receive(type, body)
    }
}

/// 一个装着网页模式运行时的 WKWebView：只认 `chaiyue://` 资源，联网请求一律拦下
final class WebReaderEngine: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let schemes: ReaderSchemeHandler
    private let proxy: WeakMessageProxy
    private var rulesAdded = false
    private var shell: String?
    private(set) var ready = false
    var onMessage: ((String, [String: Any]) -> Void)?

    var themeID: String? {
        get { schemes.themeID }
        set { schemes.themeID = newValue }
    }

    var imageData: ((String) -> Data?)? {
        get { schemes.imageData }
        set { schemes.imageData = newValue }
    }

    override init() {
        let schemes = ReaderSchemeHandler()
        let proxy = WeakMessageProxy()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemes, forURLScheme: "chaiyue")
        config.userContentController.add(proxy, name: "reader")
        config.suppressesIncrementalRendering = true
        config.dataDetectorTypes = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        self.schemes = schemes
        self.proxy = proxy
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
    }

    func load(shell html: String) {
        ready = false
        shell = html
        Self.withRules { [weak self] list in
            guard let self, shell == html else { return }
            if let list, !rulesAdded {
                webView.configuration.userContentController.add(list)
                rulesAdded = true
            }
            webView.loadHTMLString(html, baseURL: URL(string: "chaiyue://theme/"))
        }
    }

    /// 调用 `reader.方法(参数…)`，参数按 JSON 传入；页面没就绪时丢弃（就绪后调用方会整体同步一次）
    /// `then` 在脚本跑完后回调，用来把「先滚到目标页再截图」接成一条链
    func call(_ method: String, _ args: Any..., then: (() -> Void)? = nil) {
        guard ready else { then?(); return }
        let encoded = args.map { arg -> String in
            if arg is NSNull { return "null" }
            guard JSONSerialization.isValidJSONObject([arg]),
                  let data = try? JSONSerialization.data(withJSONObject: [arg], options: [.fragmentsAllowed]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return String(text.dropFirst().dropLast())
        }
        webView.evaluateJavaScript("window.reader && window.reader.\(method)(\(encoded.joined(separator: ",")))") { _, _ in
            then?()
        }
    }

    /// 跑一段脚本并把返回值带回来。点按落在系统卷页上时，用来问网页这下是翻页还是贴纸
    func eval(_ script: String, then: @escaping (Any?) -> Void) {
        guard ready else { then(nil); return }
        webView.evaluateJavaScript(script) { value, _ in
            then(value)
        }
    }

    fileprivate func receive(_ type: String, _ body: [String: Any]) {
        if type == "ready" { ready = true }
        onMessage?(type, body)
    }

    // MARK: 导航

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased()
        let allowed = scheme == "chaiyue" || scheme == "about"
        decisionHandler(allowed && action.navigationType != .linkActivated ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let shell else { return }
        load(shell: shell)
    }

    // MARK: 断网规则

    private static var rules: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void]?

    private static func withRules(_ body: @escaping (WKContentRuleList?) -> Void) {
        if let rules { return body(rules) }
        if waiting != nil {
            waiting?.append(body)
            return
        }
        waiting = [body]
        let json = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp|file)://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "chaiyue.theme.offline", encodedContentRuleList: json) { list, _ in
            MainActor.assumeIsolated {
                rules = list
                let callbacks = waiting ?? []
                waiting = nil
                callbacks.forEach { $0(list) }
            }
        }
    }
}

// MARK: - 文档内容

enum WebReaderDocument {
    /// 主题样式里常写的中文字体名映射到本机字体文件；当前正文字体叫 ReaderFont
    static func fontFaces(current: String?) -> String {
        var faces: [(family: String, name: String, bold: Bool)] = []
        if let current { faces.append(("ReaderFont", current, false)) }
        let library = FontLibrary.shared
        if library.songtiReady {
            for family in ["Songti SC", "宋体", "STSong", "Songti"] {
                faces.append((family, FontLibrary.songti, false))
                faces.append((family, FontLibrary.songtiBold, true))
            }
        }
        if library.kaitiReady {
            let regular = FontLibrary.kaitiName(bold: false)
            let bold = FontLibrary.kaitiName(bold: true)
            for family in ["Kaiti SC", "楷体", "STKaiti", "Kaiti", "STKaitiSC"] {
                faces.append((family, regular, false))
                faces.append((family, bold, true))
            }
        }
        for font in FontStore.shared.fonts {
            faces.append((font.name, font.id, false))
            if font.id != font.name { faces.append((font.id, font.id, false)) }
        }
        return faces.map { face in
            let family = face.family.replacingOccurrences(of: "\"", with: "")
            let name = face.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? face.name
            return "@font-face{font-family:\"\(family)\";src:url(\"chaiyue://font/\(name)#\(name)\");font-weight:\(face.bold ? 700 : 400);font-display:block}"
        }.joined(separator: "\n")
    }

    /// 基础变量：排版面板的字号、字体、行距与主题配色，主题样式表可以再盖
    static func variables(typography t: ReaderTypography, theme: ReaderThemeSpec) -> [String: String] {
        let size = CGFloat(t.fontSize)
        let font = t.fontName.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
        let natural = ceil(font.ascender - font.descender + font.leading)
        let lineHeight = t.lineHeight ?? Double((natural + size * CGFloat(t.lineSpacing)) / size)
        func rgba(_ hex: UInt32, _ alpha: CGFloat) -> String {
            "rgba(\((hex >> 16) & 0xFF),\((hex >> 8) & 0xFF),\(hex & 0xFF),\(alpha))"
        }
        return [
            "--reader-font-size": "\(t.fontSize)px",
            "--reader-font": t.fontName == nil ? "-apple-system, \"PingFang SC\", sans-serif" : "\"ReaderFont\", \"PingFang SC\", serif",
            "--reader-line-height": String(format: "%.3f", lineHeight),
            "--reader-para": String(format: "%.3fem", t.paragraphSpacing),
            "--reader-indent": String(format: "%.2fem", t.indent),
            "--reader-kern": String(format: "%.3fem", t.letterSpacing),
            "--reader-align": t.justified ? "justify" : "start",
            "--reader-paper": rgba(theme.background, 1),
            "--reader-ink": rgba(theme.text, 1),
            "--reader-secondary": rgba(theme.text, theme.secondaryAlpha),
            "--reader-mark": theme.isDark ? "rgba(255,213,8,.22)" : "rgba(255,213,8,.36)",
        ]
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func imageURL(_ src: String) -> String {
        var components = URLComponents()
        components.scheme = "chaiyue"
        components.host = "image"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "src", value: src)]
        return escape(components.url?.absoluteString ?? "")
    }

    /// 一章的 HTML：章头 + 段落。段落文字与稳定文本逐字对应（行内小图各占一个字），偏移才能互换
    static func chapter(title: String, paragraphs: [String], extras: [Int: ParagraphExtras], comments: Bool) -> String {
        let name = ChapterTitle.display(title) ?? title
        let number = name == title ? nil : ChapterTitle.number(title)
        var html = "<header class=\"chap-head\">"
        if let number { html += "<div class=\"chap-no\">\(escape(number))</div>" }
        html += "<h1 class=\"chap-title\">\(escape(name))</h1></header>"
        var offset = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let length = (paragraph as NSString).length
            let attrs = "data-i=\"\(index)\" data-o=\"\(offset)\" data-len=\"\(length)\""
            if InlineImage.isImage(paragraph) {
                let img = InlineImage.source(of: paragraph).map { "<img src=\"\(imageURL($0))\" alt=\"\">" } ?? ""
                html += "<figure \(attrs)>\(img)</figure>"
            } else {
                var body = ""
                let inline = extras[index]?.inlineImages ?? [:]
                var position = 0
                let parts = paragraph.components(separatedBy: InlineImage.inlineMark)
                for (i, part) in parts.enumerated() {
                    body += escape(part)
                    position += (part as NSString).length
                    if i < parts.count - 1 {
                        let src = inline[position].map { " src=\"\(imageURL($0))\"" } ?? ""
                        body += "<img class=\"inline\"\(src) alt=\"\">"
                        position += 1
                    }
                }
                if comments, let comment = extras[index]?.comment {
                    body += "<span class=\"comment\" data-comment=\"\(index)\">\(escape(comment.count))</span>"
                }
                html += "<p \(attrs)>\(body)</p>"
            }
            offset += length + 1
        }
        return html
    }
}

// MARK: - 仿真翻页

/// 一页的截图。系统卷页卷的是这张图，背面仍是系统那层灰，和原生阅读同一套
private final class ShotPage: UIViewController {
    var index: Int
    private let imageView = UIImageView()

    init(index: Int, image: UIImage, paper: UIColor) {
        self.index = index
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = paper
        imageView.isOpaque = true
        imageView.isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = imageView
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
    }
}

/// 网页主题的仿真翻页。底下是真正的网页，上面盖着和原生一样的系统卷页。
/// 先用不刷新屏幕的方式截当前页并盖严，之后才在遮罩底下滚去截邻页，避免墨水屏整屏闪一下
final class WebPageCurl: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    weak var engine: WebReaderEngine?
    weak var host: WebHostController?
    var onMenu: () -> Void = {}
    var paper: UIColor = .white {
        didSet {
            pageVC?.view.backgroundColor = paper
            host?.view.backgroundColor = paper
        }
    }
    var menuOpen = false {
        didSet {
            guard menuOpen != oldValue, !selecting else { return }
            pageVC?.dataSource = menuOpen ? nil : self
        }
    }

    private var pageVC: UIPageViewController?
    private weak var current: ShotPage?
    private var beforePage: ShotPage?
    private var afterPage: ShotPage?
    private var cache: [Int: UIImage] = [:]
    private var resting = 0
    private var total = 1
    private var hasIndex = false
    private var enabled = false
    private var generation = 1
    private var holdToken = -1
    private var onHeld: (() -> Void)?
    private var capturing = false
    private var covering = false
    private var gesturing = false
    private var animating = false
    private var scrubbing = false
    private var selecting = false
    private var selectionActive = false
    private var needsShot = false
    private var spokenPending = false
    private var transitioned = false
    private var settling = false
    private var coverAttempts = 0
    private var reshowing = false
    private var shotSize: CGSize?
    private var queuedTurn: Bool?
    private var queuedPoint: CGPoint?
    private var lastEdge = Date.distantPast
    private var selectTask: Task<Void, Never>?

    var maskUp: Bool { pageVC != nil && pageVC?.view.isHidden != true }

    func attach(engine: WebReaderEngine, host: WebHostController) {
        self.engine = engine
        self.host = host
        host.curl = self
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            coverAttempts = 0
            return
        }
        let page = resting
        cancelWork()
        guard pageVC != nil else { return }
        guard let engine else { removePageVC(); return }
        engine.call("land", page, then: { [weak self] in
            guard let self, !self.enabled else { return }
            self.removePageVC()
        })
    }

    /// 正在截邻页时，网页报上来的位置是临时滚过去的，不能当成阅读进度
    func suppressesReadingPosition() -> Bool { capturing }

    /// 章节窗口或版式变了：页号会重排。先作废进行中的截图并滚回原页，再换内容，避免把邻章当成正在读的章
    func contentWillChange(then: (() -> Void)? = nil) {
        guard enabled else {
            then?()
            return
        }
        cancelWork()
        cache.removeAll()
        beforePage = nil
        afterPage = nil
        needsShot = true
        let min = generation
        guard let engine else {
            then?()
            return
        }
        engine.call("abortQuiet", min, then: then)
    }

    func note(index: Int, total: Int) {
        let changed = hasIndex && (index != resting || total != self.total)
        hasIndex = true
        self.total = max(1, total)
        resting = index
        guard enabled, !scrubbing, !selecting else { return }
        if pageVC == nil {
            coverIfNeeded()
        } else if pageVC?.view.isHidden == true {
            reshow()
        } else if changed || needsShot {
            if changed { cache.removeAll() }
            needsShot = false
            current?.index = index
            refreshResting()
        }
    }

    func turn(forward: Bool) {
        turn(to: resting + (forward ? 1 : -1))
    }

    func turn(to index: Int) {
        guard enabled else { return }
        let forward = index > resting
        guard maskUp else {
            queuedTurn = forward
            coverIfNeeded()
            return
        }
        if menuOpen || scrubbing || selecting { return }
        if animating || gesturing || capturing {
            queuedTurn = forward
            return
        }
        guard index >= 0, index < total, index != resting else {
            if index != resting { fireEdge(forward) }
            return
        }
        if let image = cache[index] {
            animate(to: index, image: image, forward: forward)
        } else {
            captureThen(index, forward: forward)
        }
    }

    func held(_ token: Int) {
        guard token == holdToken, token == generation else { return }
        let body = onHeld
        onHeld = nil
        holdToken = -1
        body?()
    }

    func setScrubbing(_ active: Bool) {
        if active {
            guard !scrubbing else { return }
            scrubbing = true
            queuedTurn = nil
            queuedPoint = nil
            cancelWork()
            pageVC?.dataSource = nil
            engine?.call("rest", resting, then: { [weak self] in
                guard let self, self.scrubbing else { return }
                self.pageVC?.view.isHidden = true
            })
        } else {
            guard scrubbing else { return }
            scrubbing = false
            cache.removeAll()
            pageVC?.dataSource = (menuOpen || selecting) ? nil : self
            engine?.call("publish")
        }
    }

    func setSelection(_ active: Bool) {
        selectionActive = active
        if active {
            selectTask?.cancel()
            selecting = true
            pageVC?.view.isHidden = true
            pageVC?.dataSource = nil
        } else if selecting {
            finishSelection()
        }
    }

    /// 正文重排或图片加载完了。盖着的时候在遮罩底下重截，不把网页揭开
    func invalidateShot() {
        guard enabled else { return }
        if !maskUp || gesturing || animating || scrubbing || selecting || capturing {
            needsShot = true
            return
        }
        refreshResting()
    }

    func refreshSpoken() {
        guard enabled, maskUp else { return }
        if capturing || gesturing || animating || scrubbing || selecting {
            spokenPending = true
            return
        }
        refreshResting()
    }

    func teardown() {
        enabled = false
        onMenu = {}
        selectTask?.cancel()
        cancelWork()
        removePageVC()
    }

    func layout(in bounds: CGRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        pageVC?.view.frame = bounds
        if !gesturing, !animating { bringCoverFront() }
        disarmSystemTaps()
        if let shotSize, abs(shotSize.width - bounds.width) > 1 || abs(shotSize.height - bounds.height) > 1 {
            self.shotSize = bounds.size
            cache.removeAll()
            needsShot = true
            if maskUp, !gesturing, !animating { refreshResting() }
        } else {
            self.shotSize = bounds.size
        }
        if enabled, hasIndex, pageVC == nil, !covering { coverIfNeeded() }
    }

    // MARK: 遮罩

    private func coverIfNeeded() {
        guard enabled, pageVC == nil, !covering, coverAttempts < 8 else { return }
        guard host?.view.bounds.width ?? 0 > 1, engine != nil else { return }
        covering = true
        let token = generation
        let index = resting
        snapshot(updates: false) { [weak self] image in
            guard let self else { return }
            self.covering = false
            guard token == self.generation, self.enabled, self.pageVC == nil else { return }
            guard let image else {
                self.coverAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.coverIfNeeded() }
                return
            }
            self.coverAttempts = 0
            self.cache[index] = image
            self.install(image: image, index: index)
            // 等遮罩先画到屏幕上，再在底下滚动、重截，避免这一下闪出来
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard token == self.generation, self.maskUp else { return }
                if self.needsShot {
                    self.needsShot = false
                    self.refreshResting()
                } else {
                    self.prefetch()
                }
            }
        }
    }

    private func install(image: UIImage, index: Int) {
        guard let host, pageVC == nil else { return }
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: nil)
        controller.isDoubleSided = false
        controller.dataSource = menuOpen ? nil : self
        controller.delegate = self
        controller.view.backgroundColor = paper
        controller.view.isOpaque = true
        controller.view.frame = host.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        for recognizer in controller.gestureRecognizers {
            if recognizer is UITapGestureRecognizer { recognizer.isEnabled = false }
            if let pan = recognizer as? UIPanGestureRecognizer {
                pan.addTarget(self, action: #selector(mirrorPan(_:)))
            }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        controller.view.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 12
        press.delegate = self
        controller.view.addGestureRecognizer(press)
        pageVC = controller
        let shot = ShotPage(index: index, image: image, paper: paper)
        current = shot
        controller.setViewControllers([shot], direction: .forward, animated: false)
        bringCoverFront()
    }

    private func removePageVC() {
        if let pageVC {
            for case let pan as UIPanGestureRecognizer in pageVC.gestureRecognizers {
                pan.removeTarget(self, action: #selector(mirrorPan(_:)))
            }
            pageVC.view.gestureRecognizers?.forEach { pageVC.view.removeGestureRecognizer($0) }
            pageVC.willMove(toParent: nil)
            pageVC.view.removeFromSuperview()
            pageVC.removeFromParent()
        }
        pageVC = nil
        current = nil
        beforePage = nil
        afterPage = nil
        cache.removeAll()
        needsShot = false
    }

    private func bringCoverFront() {
        guard let host, let cover = pageVC?.view, cover.superview === host.view else { return }
        if host.view.subviews.last !== cover { host.view.bringSubviewToFront(cover) }
    }

    private func disarmSystemTaps() {
        for case let tap as UITapGestureRecognizer in pageVC?.gestureRecognizers ?? [] {
            tap.isEnabled = false
        }
    }

    /// 遮罩被揭开过（拖页码、选字）。用当前画面盖回去，这一下不要求网页重画，免得闪
    private func reshow() {
        guard enabled, !reshowing, !scrubbing, !selecting, !gesturing, !animating, !covering else { return }
        reshowing = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.generation, !self.scrubbing, !self.selecting else {
                self?.reshowing = false
                return
            }
            let index = self.resting
            self.snapshot(updates: false) { image in
                self.reshowing = false
                guard token == self.generation, !self.scrubbing, !self.selecting, let image else { return }
                self.cache[index] = image
                if self.pageVC == nil {
                    self.install(image: image, index: index)
                } else if let current = self.current {
                    current.index = index
                    current.setImage(image)
                    self.pageVC?.view.isHidden = false
                } else {
                    self.showStill(image, index: index)
                }
                self.pageVC?.dataSource = self.menuOpen ? nil : self
                self.bringCoverFront()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard token == self.generation, self.maskUp else { return }
                    self.refreshResting()
                }
            }
        }
    }

    private func showStill(_ image: UIImage, index: Int) {
        guard let pageVC else { return }
        let shot = ShotPage(index: index, image: image, paper: paper)
        current = shot
        pageVC.setViewControllers([shot], direction: .forward, animated: false)
        pageVC.view.isHidden = false
    }

    // MARK: 截图

    /// 重截当前页。不再按旧页号 jump：窗口一换，同一个页号可能已经是另一章
    private func refreshResting() {
        guard let engine, enabled, maskUp, !gesturing, !animating, !scrubbing, !selecting else { return }
        if capturing {
            needsShot = true
            return
        }
        let token = generation
        let index = resting
        capturing = true
        bringCoverFront()
        engine.call("arm", true, token, then: { [weak self] in
            guard let self, token == self.generation else { return }
            self.snapshot(updates: true) { image in
                guard token == self.generation else { return }
                if let image, self.resting == index {
                    self.cache[index] = image
                    self.current?.index = index
                    self.current?.setImage(image)
                }
                engine.call("arm", false, token, then: { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.capturing = false
                    if self.needsShot || self.spokenPending {
                        let speak = self.spokenPending
                        self.needsShot = false
                        self.spokenPending = false
                        if speak { self.refreshSpoken() } else { self.refreshResting() }
                    } else {
                        self.prefetch()
                    }
                })
            }
        })
    }

    private func prefetch() {
        guard let engine, enabled, maskUp, !gesturing, !animating, !scrubbing, !selecting, !capturing else { return }
        let token = generation
        let center = resting
        cache = cache.filter { abs($0.key - center) <= 1 }
        var pages: [Int] = []
        if center + 1 < total, cache[center + 1] == nil { pages.append(center + 1) }
        if center - 1 >= 0, cache[center - 1] == nil { pages.append(center - 1) }
        guard !pages.isEmpty else {
            drain()
            if needsShot {
                needsShot = false
                refreshResting()
            }
            return
        }
        capturing = true
        bringCoverFront()
        engine.call("arm", true, token, then: { [weak self] in
            self?.capture(pages, token: token, center: center)
        })
    }

    private func capture(_ pages: [Int], token: Int, center: Int) {
        guard let engine, token == generation else { return }
        guard let index = pages.first else {
            engine.call("jump", center, token, then: { [weak self] in
                guard let self, token == self.generation else { return }
                engine.call("arm", false, token, then: { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.capturing = false
                    self.drain()
                    if self.spokenPending {
                        self.spokenPending = false
                        self.refreshSpoken()
                    } else if self.needsShot {
                        self.needsShot = false
                        self.refreshResting()
                    }
                })
            })
            return
        }
        let rest = Array(pages.dropFirst())
        holdToken = token
        onHeld = { [weak self] in
            guard let self, token == self.generation else { return }
            self.snapshot(updates: true) { image in
                guard token == self.generation else { return }
                if let image { self.cache[index] = image }
                self.capture(rest, token: token, center: center)
            }
        }
        engine.call("hold", index, token)
    }

    /// 点按时邻页还没截好：在遮罩底下截那一页，再卷过去
    private func captureThen(_ index: Int, forward: Bool) {
        guard let engine else { return }
        let token = generation
        capturing = true
        bringCoverFront()
        engine.call("arm", true, token, then: { [weak self] in
            guard let self, token == self.generation else { return }
            self.holdToken = token
            self.onHeld = { [weak self] in
                guard let self, token == self.generation else { return }
                self.snapshot(updates: true) { image in
                    guard token == self.generation else { return }
                    self.capturing = false
                    guard let image else { self.engine?.call("arm", false, token); return }
                    self.cache[index] = image
                    self.animate(to: index, image: image, forward: forward)
                }
            }
            engine.call("hold", index, token)
        })
    }

    private func snapshot(updates: Bool, _ done: @escaping (UIImage?) -> Void) {
        guard let web = engine?.webView, web.bounds.width > 1, web.bounds.height > 1 else {
            done(nil)
            return
        }
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        config.afterScreenUpdates = updates
        web.takeSnapshot(with: config) { image, _ in
            done(image)
        }
    }

    private func cancelWork() {
        generation += 1
        onHeld = nil
        holdToken = -1
        capturing = false
        covering = false
    }

    private func drain() {
        guard !capturing, !animating, !gesturing, !scrubbing, !selecting else { return }
        if let point = queuedPoint {
            queuedPoint = nil
            queuedTurn = nil
            hit(point)
            return
        }
        if let forward = queuedTurn {
            queuedTurn = nil
            turn(forward: forward)
        }
    }

    // MARK: 卷页

    private func animate(to index: Int, image: UIImage, forward: Bool) {
        guard let pageVC else { return }
        animating = true
        gesturing = true
        beforePage = nil
        afterPage = nil
        let shot = ShotPage(index: index, image: image, paper: paper)
        current = shot
        pageVC.setViewControllers([shot], direction: forward ? .forward : .reverse, animated: true) { [weak self] finished in
            guard let self else { return }
            self.animating = false
            self.gesturing = false
            if finished {
                self.commit(index)
            } else {
                self.settleBack()
            }
        }
    }

    private func commit(_ index: Int) {
        guard index != resting else { return }
        resting = index
        cache = cache.filter { abs($0.key - index) <= 1 }
        let token = generation
        engine?.call("land", index, then: { [weak self] in
            guard let self, token == self.generation, self.resting == index, !self.gesturing, !self.animating else { return }
            self.prefetch()
        })
    }

    private func settleBack() {
        guard !settling else { return }
        settling = true
        engine?.call("rest", resting, then: { [weak self] in
            self?.settling = false
            self?.prefetch()
        })
    }

    /// 松手没卷成页时，先问网页是不是真的停在轨道尽头。邻页还没截好也会弹回，那一次不能换章
    private func fireEdge(_ forward: Bool) {
        guard let engine else { return }
        let flag = forward ? "true" : "false"
        engine.eval("window.reader && window.reader.atEdge(\(flag))") { [weak self] value in
            guard let self else { return }
            let atEdge: Bool
            if let value = value as? Bool { atEdge = value }
            else if let value = value as? NSNumber { atEdge = value.boolValue }
            else { atEdge = false }
            guard atEdge else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastEdge) > 0.7 else { return }
            self.lastEdge = now
            self.engine?.call("edgeGo", forward)
        }
    }

    private func finishSelection() {
        guard selecting else { return }
        selecting = false
        selectionActive = false
        selectTask?.cancel()
        pageVC?.dataSource = menuOpen ? nil : self
        reshow()
    }

    private func beginSelection(at point: CGPoint) {
        guard !selecting, !menuOpen, !gesturing, !animating, !scrubbing else { return }
        selecting = true
        selectionActive = false
        queuedTurn = nil
        queuedPoint = nil
        cancelWork()
        pageVC?.dataSource = nil
        let x = Double(point.x)
        let y = Double(point.y)
        engine?.call("rest", resting, then: { [weak self] in
            guard let self, self.selecting else { return }
            self.pageVC?.view.isHidden = true
            self.engine?.call("selectWord", x, y, then: { [weak self] in
                guard let self else { return }
                self.selectTask?.cancel()
                self.selectTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled, !self.selectionActive else { return }
                    self.finishSelection()
                }
            })
        })
    }

    private func hit(_ point: CGPoint) {
        guard let engine else { return }
        let x = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), point.x)
        let y = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), point.y)
        engine.eval("window.reader && window.reader.hit(\(x), \(y))") { [weak self] value in
            guard let self else { return }
            switch value as? String {
            case "next": self.turn(forward: true)
            case "prev": self.turn(forward: false)
            case "menu": self.onMenu()
            case "used", "scrub": break
            default:
                let width = self.host?.view.bounds.width ?? 1
                if point.x > width / 3, point.x < width * 2 / 3 { self.onMenu() }
                else { self.turn(forward: point.x >= width * 2 / 3) }
            }
        }
    }

    // MARK: 手势

    @objc nonisolated private func mirrorPan(_ pan: UIPanGestureRecognizer) {
        MainActor.assumeIsolated { self.track(pan) }
    }

    @objc nonisolated private func handleTap(_ tap: UITapGestureRecognizer) {
        MainActor.assumeIsolated { self.tapped(tap) }
    }

    @objc nonisolated private func handlePress(_ press: UILongPressGestureRecognizer) {
        MainActor.assumeIsolated { self.pressed(press) }
    }

    private func track(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended || pan.state == .cancelled, let view = host?.view else { return }
        let moved = pan.translation(in: view)
        guard abs(moved.x) > abs(moved.y) else { return }
        let velocity = pan.velocity(in: view).x
        let forward = moved.x < -48 || velocity < -900
        let backward = moved.x > 48 || velocity > 900
        guard forward != backward else { return }
        let turned = transitioned
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let didTurn = turned || self.transitioned || self.gesturing || self.animating
            self.transitioned = false
            guard !didTurn, !self.menuOpen, !self.selecting, !self.scrubbing else { return }
            if forward, self.resting >= self.total - 1 { self.fireEdge(true) }
            if backward, self.resting <= 0 { self.fireEdge(false) }
        }
    }

    private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let host, !selecting else { return }
        let point = tap.location(in: host.view)
        if menuOpen {
            onMenu()
            return
        }
        if animating || gesturing || capturing || scrubbing {
            queuedPoint = point
            return
        }
        hit(point)
    }

    private func pressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, let host else { return }
        beginSelection(at: press.location(in: host.view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    // MARK: UIPageViewController

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard !menuOpen, !selecting, let shot = viewController as? ShotPage, shot.index > 0,
              let image = cache[shot.index - 1] else { return nil }
        if let beforePage, beforePage.index == shot.index - 1 { return beforePage }
        let page = ShotPage(index: shot.index - 1, image: image, paper: paper)
        beforePage = page
        return page
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard !menuOpen, !selecting, let shot = viewController as? ShotPage, shot.index + 1 < total,
              let image = cache[shot.index + 1] else { return nil }
        if let afterPage, afterPage.index == shot.index + 1 { return afterPage }
        let page = ShotPage(index: shot.index + 1, image: image, paper: paper)
        afterPage = page
        return page
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        transitioned = true
        gesturing = true
        queuedTurn = nil
        queuedPoint = nil
        cancelWork()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        animating = false
        gesturing = false
        beforePage = nil
        afterPage = nil
        guard completed, let shot = pageViewController.viewControllers?.first as? ShotPage else {
            settleBack()
            return
        }
        current = shot
        commit(shot.index)
    }
}

/// 页码条落在系统卷页上面时，把这块的触摸交回网页
private final class WebCurlHostView: UIView {
    weak var controller: WebHostController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let controller else { return super.hitTest(point, with: event) }
        if let rect = controller.scrubRect, controller.curl?.maskUp == true, rect.contains(point) {
            let web = controller.engine.webView
            return web.hitTest(web.convert(point, from: self), with: event) ?? web
        }
        return super.hitTest(point, with: event)
    }
}

/// 阅读区容器。系统卷页盖在网页上面
final class WebHostController: UIViewController {
    let engine: WebReaderEngine
    weak var curl: WebPageCurl?
    var scrubRect: CGRect?

    init(engine: WebReaderEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = WebCurlHostView()
        host.controller = self
        host.clipsToBounds = true
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let web = engine.webView
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        engine.webView.frame = view.bounds
        curl?.layout(in: view.bounds)
    }
}

// MARK: - 阅读页

/// 网页模式的阅读区。仿真翻页时上面再盖一层和原生一样的系统卷页
struct WebReaderView: UIViewControllerRepresentable {
    let model: ReaderModel
    let version: Int
    let size: CGSize
    let insets: EdgeInsets
    let menuVisible: Bool
    let onCenterTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> WebHostController {
        let host = WebHostController(engine: context.coordinator.engine)
        context.coordinator.attach(host: host, model: model, onCenterTap: onCenterTap)
        return host
    }

    func updateUIViewController(_ host: WebHostController, context: Context) {
        let coordinator = context.coordinator
        coordinator.host = host
        host.curl = coordinator.pageCurl
        coordinator.onCenterTap = onCenterTap
        coordinator.size = size
        coordinator.insets = insets
        coordinator.menuVisible = menuVisible
        coordinator.sync()
    }

    static func dismantleUIViewController(_ host: WebHostController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        let engine = WebReaderEngine()
        let pageCurl = WebPageCurl()
        weak var host: WebHostController?
        weak var model: ReaderModel?
        var onCenterTap: () -> Void = {}
        var size: CGSize = .zero
        var insets = EdgeInsets()
        var menuVisible = false
        private var shellKey = ""
        private var fontKey = ""
        private var configKey = ""
        private var windowKey = ""
        private var jumpToken = -1
        /// 下次推送章节窗口时定位到阅读进度（打开、目录跳转、滚动模式跨章）
        private var forceFocus = true
        /// 拖页码条时每过一页轻震一下
        private let selection = UISelectionFeedbackGenerator()

        func attach(host: WebHostController, model: ReaderModel, onCenterTap: @escaping () -> Void) {
            self.host = host
            self.model = model
            self.onCenterTap = onCenterTap
            pageCurl.attach(engine: engine, host: host)
            pageCurl.onMenu = { [weak self] in self?.onCenterTap() }
            let session = model.session
            engine.imageData = { [weak session] src in session?.imageData(for: src) }
            engine.onMessage = { [weak self] type, body in self?.handle(type, body) }
            model.onTurnRequest = { [weak self] forward in self?.engine.call("turn", forward) }
            model.commitVisible = {}
            model.onWebFollow = { [weak self] chapter, offset in self?.follow(chapter: chapter, offset: offset) }
            model.onSpokenChange = { [weak self] in self?.pushSpoken() }
        }

        func detach() {
            pageCurl.teardown()
            guard let model else { return }
            model.onWebFollow = nil
            model.commitVisible = nil
            model.onSpokenChange = nil
            model.onTurnRequest = nil
        }

        func sync() {
            guard let model, size.width > 0 else { return }
            let theme = model.theme
            let store = ReaderThemeStore.shared
            guard let id = theme.customID, let custom = store.theme(id) else { return }
            let settings = model.settings
            let typography = settings.typography
            let faces = WebReaderDocument.fontFaces(current: typography.fontName)
            engine.webView.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
            engine.webView.backgroundColor = theme.uiBackground
            engine.webView.scrollView.backgroundColor = theme.uiBackground
            host?.view.backgroundColor = theme.uiBackground
            pageCurl.paper = theme.uiBackground
            let shell = "\(id)|\(custom.updated.timeIntervalSince1970)|\(store.revision)"
            if shell != shellKey {
                shellKey = shell
                fontKey = faces
                configKey = ""
                windowKey = ""
                forceFocus = true
                engine.themeID = id
                pageCurl.contentWillChange()
                engine.load(shell: WebReaderRuntime.shell(css: custom.css, js: custom.js, html: custom.html, fontFaces: faces))
                return
            }
            guard engine.ready else { return }
            if faces != fontKey {
                fontKey = faces
                engine.call("setFonts", faces)
            }

            pageCurl.menuOpen = menuVisible
            pageCurl.setEnabled(settings.pageStyle == .curl)
            let config: [String: Any] = [
                "mode": settings.pageStyle == .vertical ? "scroll" : "page",
                "turn": settings.pageStyle == .curl ? "curl" : (settings.pageStyle == .none ? "none" : "slide"),
                "safeTop": insets.top, "safeBottom": insets.bottom,
                "menu": menuVisible, "tapBoth": settings.tapToTurnBothSides, "interactive": true,
                "vars": WebReaderDocument.variables(typography: typography, theme: theme),
            ]
            let key = "\(config["mode"]!)|\(config["turn"]!)|\(size)|\(insets.top)|\(insets.bottom)|\(settings.tapToTurnBothSides)|\(config["vars"]!)"
            if key != configKey {
                configKey = key
                pageCurl.contentWillChange { [weak self] in
                    guard let self else { return }
                    self.engine.call("configure", config, then: { [weak self] in
                        self?.engine.call("publish")
                    })
                }
            }
            engine.call("setMenu", menuVisible)
            pushWindow()
        }

        /// 把上一章、本章、下一章交给网页；没加载好的章先放占位页并开始加载
        private func pushWindow() {
            guard let model else { return }
            let session = model.session
            let current = model.pointer.chapter
            guard session.chapters.indices.contains(current) else { return }
            if model.jumpToken != jumpToken {
                jumpToken = model.jumpToken
                forceFocus = true
            }
            let comments = model.settings.paragraphComments
            let window = [current - 1, current, current + 1].filter { session.chapters.indices.contains($0) }
            let keys = window.map { index -> String in
                if let text = session.text(of: index) { return "\(index)|\(text.hashValue)|\(comments)" }
                if case .failed(let message) = session.chapterStates[index] { return "p|\(index)|\(message)" }
                return "p|\(index)"
            }
            let key = keys.joined(separator: ",")
            guard key != windowKey || forceFocus else { return }
            windowKey = key
            var items: [[String: Any]] = []
            for (index, itemKey) in zip(window, keys) {
                var meta = self.meta(chapter: index)
                if let text = session.text(of: index) {
                    meta["length"] = text.length
                    items.append(["key": itemKey, "meta": meta,
                                  "html": WebReaderDocument.chapter(title: text.title, paragraphs: text.paragraphs, extras: text.extras,
                                                                    comments: comments)])
                } else {
                    let failed: String?
                    if case .failed(let message) = session.chapterStates[index] { failed = message } else { failed = nil }
                    meta["length"] = 0
                    meta["placeholder"] = true
                    items.append(["key": itemKey, "meta": meta,
                                  "placeholder": ["title": session.chapters[index].title, "message": failed ?? "正在加载…",
                                                  "failed": failed != nil]])
                    if failed == nil { session.ensureLoaded(index) }
                }
            }
            let focus: [String: Any] = ["chapter": current, "offset": min(session.position.offset, Int(Int32.max)), "force": forceFocus]
            forceFocus = false
            pageCurl.contentWillChange { [weak self] in
                guard let self else { return }
                self.engine.call("setChapters", items, focus, then: { [weak self] in
                    self?.engine.call("publish")
                })
            }
        }

        private func meta(chapter: Int) -> [String: Any] {
            guard let model else { return [:] }
            let device = UIDevice.current
            if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
            let level = device.batteryLevel
            let session = model.session
            return [
                "index": chapter, "title": session.text(of: chapter)?.title ?? session.chapters[chapter].title,
                "book": model.book.name, "author": model.book.author, "chapterCount": model.chapterCount,
                "battery": level < 0 ? -1 : Int((level * 100).rounded()),
                "hasNext": chapter + 1 < model.chapterCount, "hasPrev": chapter > 0,
            ]
        }

        private func handle(_ type: String, _ body: [String: Any]) {
            guard let model else { return }
            switch type {
            case "ready":
                configKey = ""
                windowKey = ""
                forceFocus = true
                sync()
                pushSpoken()
            case "position":
                if pageCurl.suppressesReadingPosition() { return }
                guard let chapter = body["chapter"] as? Int, model.session.chapters.indices.contains(chapter),
                      let start = body["start"] as? Int, let end = body["end"] as? Int else { return }
                // 翻一页最多跨到相邻章。差出两章以上是截图或重排把进度报错了
                if abs(chapter - model.pointer.chapter) > 1 { return }
                let moved = chapter != model.pointer.chapter
                model.noteWeb(chapter: chapter, range: start..<max(start + 1, end))
                // 滑进了相邻章：窗口跟着挪一章（网页里已有的章原样保留，不会闪）
                if moved { pushWindow() }
            case "curl":
                guard (body["phase"] as? String) == "tap", let to = Self.int(body["to"]) else { return }
                pageCurl.turn(to: to)
            case "held":
                pageCurl.held(Self.int(body["token"]) ?? 0)
            case "pages":
                guard let index = Self.int(body["index"]), let total = Self.int(body["total"]) else { return }
                pageCurl.note(index: index, total: total)
            case "repaint":
                pageCurl.invalidateShot()
            case "scrubbox":
                if Self.flag(body["hidden"]) {
                    host?.scrubRect = nil
                } else if let x = Self.number(body["x"]), let y = Self.number(body["y"]),
                          let w = Self.number(body["w"]), let h = Self.number(body["h"]), w > 1, h > 1 {
                    host?.scrubRect = CGRect(x: x, y: y, width: w, height: h)
                }
            case "scrubbing":
                pageCurl.setScrubbing(Self.flag(body["active"]))
            case "selection":
                pageCurl.setSelection(Self.flag(body["active"]))
            case "edge":
                let forward = body["dir"] as? String == "next"
                let target = model.pointer.chapter + (forward ? 1 : -1)
                guard model.session.chapters.indices.contains(target) else {
                    engine.call("settle")
                    return
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                model.webMove(to: target, offset: forward ? 0 : Int.max)
                forceFocus = true
                pushWindow()
            case "menu":
                onCenterTap()
            case "tick":
                selection.selectionChanged()
                selection.prepare()
            case "action":
                let chapter = model.pointer.chapter
                guard let paragraph = body["paragraph"] as? Int,
                      let comment = model.session.text(of: chapter)?.extras[paragraph]?.comment else { return }
                model.perform(.comment(comment), chapter: chapter)
            case "retry":
                windowKey = ""
                model.retry(model.pointer.chapter)
            default:
                #if DEBUG
                if let message = body["message"] { print("网页主题 \(type)：\(message)") }
                #endif
            }
        }

        private static func flag(_ value: Any?) -> Bool {
            if let value = value as? Bool { return value }
            if let value = value as? Int { return value != 0 }
            if let value = value as? Double { return value != 0 }
            return false
        }

        private static func int(_ value: Any?) -> Int? {
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            return nil
        }

        private static func number(_ value: Any?) -> CGFloat? {
            if let number = value as? Double { return CGFloat(number) }
            if let number = value as? Int { return CGFloat(number) }
            return nil
        }

        private func follow(chapter: Int, offset: Int) {
            guard let model else { return }
            if abs(chapter - model.pointer.chapter) <= 1, model.session.text(of: chapter) != nil {
                engine.call("reveal", chapter, offset)
            } else {
                model.webMove(to: chapter, offset: offset)
                forceFocus = true
                pushWindow()
            }
        }

        private func pushSpoken() {
            let done: () -> Void = { [weak self] in self?.pageCurl.refreshSpoken() }
            guard let spoken = model?.spoken else {
                engine.call("speak", NSNull(), 0, 0, then: done)
                return
            }
            engine.call("speak", spoken.chapter, spoken.range.location, NSMaxRange(spoken.range), then: done)
        }
    }
}

// MARK: - 编辑器预览

/// 主题编辑器里的网页预览：与阅读页同一套运行时，正文是示例章节
struct WebThemePreview: UIViewRepresentable {
    let themeID: String
    let css: String
    let js: String
    let html: String
    let dark: Bool
    let page: Int
    let size: CGSize
    let insets: EdgeInsets
    let typography: ReaderTypography
    let theme: ReaderThemeSpec
    let title: String
    let paragraphs: [String]
    var interactive = false
    var onIssue: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.engine.onMessage = { [weak coordinator] type, body in coordinator?.handle(type, body) }
        let view = coordinator.engine.webView
        view.isUserInteractionEnabled = interactive
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator {
        let engine = WebReaderEngine()
        var parent: WebThemePreview?
        private var shellKey = ""
        private var stateKey = ""

        func sync() {
            guard let p = parent else { return }
            engine.themeID = p.themeID
            engine.webView.overrideUserInterfaceStyle = p.dark ? .dark : .light
            let faces = WebReaderDocument.fontFaces(current: p.typography.fontName)
            let shell = WebReaderRuntime.shell(css: p.css, js: p.js, html: p.html, fontFaces: faces)
            let key = "\(shell.hashValue)|\(ReaderThemeStore.shared.revision)"
            if key != shellKey {
                shellKey = key
                stateKey = ""
                engine.load(shell: shell)
                return
            }
            guard engine.ready else { return }
            let state = "\(p.dark)|\(p.page)|\(p.size)|\(p.typography.fontSize)"
            guard state != stateKey else { return }
            stateKey = state
            engine.call("configure", [
                "mode": "page", "safeTop": p.insets.top, "safeBottom": p.insets.bottom, "menu": false,
                "tapBoth": false, "interactive": p.interactive,
                "vars": WebReaderDocument.variables(typography: p.typography, theme: p.theme),
            ] as [String: Any])
            let meta: [String: Any] = ["index": 11, "title": p.title, "book": "雨夜来客", "author": "柴阅", "chapterCount": 120,
                                       "battery": 80, "hasNext": false, "hasPrev": false,
                                       "length": p.paragraphs.reduce(0) { $0 + ($1 as NSString).length + 1 }]
            let item: [String: Any] = ["key": "sample", "meta": meta,
                                       "html": WebReaderDocument.chapter(title: p.title, paragraphs: p.paragraphs, extras: [:], comments: false)]
            engine.call("setChapters", [item], ["chapter": 11, "offset": 0, "force": true] as [String: Any])
            engine.call("goPage", p.page)
        }

        func handle(_ type: String, _ body: [String: Any]) {
            switch type {
            case "ready":
                stateKey = ""
                sync()
            case "error":
                parent?.onIssue?("脚本：\(body["message"] as? String ?? "错误")")
            case "log":
                parent?.onIssue?("log：\(body["message"] as? String ?? "")")
            default:
                break
            }
        }
    }
}
#endif  // #if os(iOS)
