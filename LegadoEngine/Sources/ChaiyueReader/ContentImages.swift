import CryptoKit
import ChaiyueModels
import UIKit
import WebKit

/// 正文插图解码：位图直接解码并缓存；SVG（UIImage 不能解码）交给 `SVGRasterizer` 按显示大小光栅化，
/// 未完成时先返回同样大小的透明占位图，排版不会因为图片到达而跳动
final class ContentImages {
    static let shared = ContentImages()

    private let decoded = NSCache<NSString, UIImage>()
    private let placeholders = NSCache<NSString, UIImage>()

    private init() {
        decoded.countLimit = 120
        placeholders.countLimit = 60
    }

    /// `maxWidth` 为正文宽度；SVG 渲染完成后调用 `onReady`，调用方据此重排
    func image(src: String, data: Data, maxWidth: CGFloat, onReady: @escaping () -> Void) -> UIImage? {
        guard SVGImage.isSVG(data) else {
            let key = (src.utf8.count > 512 ? SHA256.hash(data: Data(src.utf8)).description : src) as NSString
            if let cached = decoded.object(forKey: key) { return cached }
            guard let image = UIImage(data: data) else { return nil }
            decoded.setObject(image, forKey: key)
            return image
        }
        guard let svg = SVGImage(data: data) else { return nil }
        let size = svg.displaySize(maxWidth: maxWidth, full: InlineImageSource(src).style == .full)
        if let raster = SVGRasterizer.shared.cached(svg, size: size) { return raster }
        SVGRasterizer.shared.render(svg, size: size) { image in
            if image != nil { onReady() }
        }
        return placeholder(size)
    }

    private func placeholder(_ size: CGSize) -> UIImage {
        let key = "\(size.width)x\(size.height)" as NSString
        if let cached = placeholders.object(forKey: key) { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
        placeholders.setObject(image, forKey: key)
        return image
    }
}

/// SVG 文本与其固有尺寸
struct SVGImage {
    let markup: String
    let intrinsicSize: CGSize
    let key: String

    /// 开头 1KB 内（XML 声明、注释之后）出现 `<svg` 的文本数据；HTML 页面不算
    static func isSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
        return head.range(of: "<svg", options: .caseInsensitive) != nil && head.range(of: "<html", options: .caseInsensitive) == nil
    }

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8), let start = text.range(of: "<svg", options: .caseInsensitive),
              let close = text[start.lowerBound...].firstIndex(of: ">") else { return nil }
        let tag = String(text[start.lowerBound...close])
        let width = Self.length(Self.attribute("width", in: tag))
        let height = Self.length(Self.attribute("height", in: tag))
        let box = Self.attribute("viewBox", in: tag)?
            .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        var size = CGSize(width: 300, height: 150)
        if let width, let height {
            size = CGSize(width: width, height: height)
        } else if let box, box.count == 4, box[2] > 0, box[3] > 0 {
            let ratio = box[3] / box[2]
            if let width { size = CGSize(width: width, height: width * ratio) }
            else if let height { size = CGSize(width: height / ratio, height: height) }
            else { size = CGSize(width: box[2], height: box[3]) }
        }
        var markup = String(text[start.lowerBound...])
        // 没有 viewBox 时按固有尺寸补上，缩放显示时内容跟着缩放而不是被裁掉
        if box == nil, let width, let height {
            markup = markup.replacingCharacters(in: markup.startIndex..<markup.index(markup.startIndex, offsetBy: 4),
                                                with: "<svg viewBox=\"0 0 \(width) \(height)\"")
        }
        self.markup = markup
        intrinsicSize = size
        key = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 显示大小（点）：铺满时等于正文宽度，否则按固有尺寸、不超过正文宽度
    func displaySize(maxWidth: CGFloat, full: Bool) -> CGSize {
        let width = maxWidth > 0 ? (full ? maxWidth : min(intrinsicSize.width, maxWidth)) : intrinsicSize.width
        let height = width * intrinsicSize.height / max(1, intrinsicSize.width)
        return CGSize(width: max(1, floor(min(width, 2000))), height: max(1, floor(min(height, 4000))))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return ns.substring(with: range)
    }

    /// 只认绝对长度（无单位或 px），百分比等返回 nil
    private static func length(_ value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.hasSuffix("%") else { return nil }
        if text.hasSuffix("px") { text.removeLast(2) }
        guard let number = Double(text), number > 0 else { return nil }
        return number
    }
}

/// 用离屏 WKWebView 把 SVG 画成位图（按显示宽度与屏幕倍率），结果缓存到内存与磁盘。一次渲染一张
final class SVGRasterizer: NSObject, WKNavigationDelegate {
    static let shared = SVGRasterizer()

    private struct Job {
        let svg: SVGImage
        let size: CGSize
        var callbacks: [(UIImage?) -> Void]
        var cacheKey: String { "\(svg.key)_\(Int(size.width))x\(Int(size.height))" }
    }

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var queue: [Job] = []
    private var running: Job?
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?
    private var failures: Set<String> = []

    override private init() {
        memory.countLimit = 200
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SVGRaster", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
    }

    /// 内存或磁盘里已有的结果
    func cached(_ svg: SVGImage, size: CGSize) -> UIImage? {
        let key = Job(svg: svg, size: size, callbacks: []).cacheKey
        if let image = memory.object(forKey: key as NSString) { return image }
        guard let data = try? Data(contentsOf: file(key)),
              let image = UIImage(data: data, scale: UIScreen.main.scale) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func render(_ svg: SVGImage, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let job = Job(svg: svg, size: size, callbacks: [completion])
        if failures.contains(job.cacheKey) {
            completion(nil)
            return
        }
        if running?.cacheKey == job.cacheKey {
            running?.callbacks.append(completion)
            return
        }
        if let index = queue.firstIndex(where: { $0.cacheKey == job.cacheKey }) {
            queue[index].callbacks.append(completion)
            return
        }
        queue.append(job)
        if running == nil { Task { await drain() } }
    }

    /// 清除缓存（设置里清理缓存时调用）
    func clear() {
        memory.removeAllObjects()
        failures.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(key + ".png")
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            running = job
            let image = await rasterize(job)
            let finished = running ?? job
            running = nil
            if let image {
                memory.setObject(image, forKey: job.cacheKey as NSString)
                if let png = image.pngData() { try? png.write(to: file(job.cacheKey), options: .atomic) }
            } else {
                failures.insert(job.cacheKey)
            }
            finished.callbacks.forEach { $0(image) }
        }
        // 空闲时释放 WebView
        webView?.removeFromSuperview()
        webView = nil
    }

    private func rasterize(_ job: Job) async -> UIImage? {
        let size = job.size
        let view = prepareWebView()
        guard let window = AppearanceStore.keyWindow else { return nil }
        if view.superview !== window {
            // WKWebView 不在窗口里时快照常是空白：放进窗口最底层，几乎透明且不接收触摸
            window.insertSubview(view, at: 0)
        }
        view.frame = CGRect(origin: .zero, size: size)
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=\(Int(size.width)),initial-scale=1,user-scalable=no">\
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:\(Int(size.width))px;height:\(Int(size.height))px}\
        body>svg{display:block;width:100%;height:100%}</style></head><body>\(job.svg.markup)</body></html>
        """
        await withCheckedContinuation { continuation in
            loaded = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
        // 等两帧，确保文字与外链图片已绘制
        _ = try? await view.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))", contentWorld: .page)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.snapshotWidth = NSNumber(value: Double(size.width))
        config.afterScreenUpdates = true
        return try? await view.takeSnapshot(configuration: config)
    }

    private func prepareWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishLoading()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading()
        self.webView?.removeFromSuperview()
        self.webView = nil
    }
}
