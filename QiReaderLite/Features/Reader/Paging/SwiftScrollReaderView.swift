import SwiftUI
import UIKit

/// Swift 原生的「滚动模式」阅读视图 —— 替代 `reader.html` + `ReaderHost` 那套 WebView 渲染。
///
/// ── 为什么迁 ──
/// WebView 渲染有个硬伤：**阅读设置只在 `session.start()` 时下发一次**，
/// 换背景/字号要退出重进正文才生效（真机反馈）。而且正文样式要靠 CSS 跟
/// SwiftUI 侧各写一份，两边永远对不齐。
///
/// 迁到 Swift 之后：
///   · 排版参数（字体/字号/行距/段距/缩进/对齐/基线/主题色）**只有一份**，
///     跟原生分页模式共用 `ReaderLayoutConfig`；
///   · 换主题 → 改 config → 重排，立刻生效；
///   · 章节窗口裁剪 / 进度节流 / 视口锚点这套逻辑是纯函数，
///     已经 1:1 翻成 `ReaderScrollCore.swift`（见 test/scroll-core-parity.swift 真对拍）。
///
/// ── 章节窗口 ──
/// 上下滚动时只保留当前章附近的若干章（`trimChapterWindow`），
/// 避免整本书都进内存；摘掉的章按方向补回来。
///
/// ── 进度上报 ──
/// 滚动时算出「当前可见章 + 章内比例」，节流 260ms 上报
/// （`ReaderScrollCore.shouldReportProgress`）。
struct SwiftScrollReaderView: UIViewRepresentable {
    /// 全部章（扁平后的书）
    let chapters: [Chapter]
    /// 当前章下标
    let currentIndex: Int
    /// 已加载正文：章下标 → 文本
    let loadedTexts: [Int: String]
    /// 加载失败的章下标
    let failedChapters: Set<Int>
    /// 排版 + 主题
    let config: ReaderLayoutConfig
    /// 行内图片的相对路径基准
    let baseURL: URL?

    /// 进度回调（章下标、章内比例）
    var onProgress: (Int, Double) -> Void
    /// 可见章变化
    var onVisibleChapter: (Int) -> Void
    /// 请求某章正文
    var onRequestChapter: (Int) -> Void
    /// 点击（出菜单）
    var onTapCenter: () -> Void
    /// 点击左侧 / 右侧
    var onTapEdge: (Int) -> Void   // -1 左 / +1 右

    /// 窗口内保留多少章
    var windowSize: Int = 5

    func makeUIView(context: Context) -> ScrollReaderUIView {
        let v = ScrollReaderUIView()
        v.delegate = context.coordinator
        v.onTapEdge = onTapEdge
        v.onTapCenter = onTapCenter
        return v
    }

    func updateUIView(_ uiView: ScrollReaderUIView, context: Context) {
        uiView.onTapEdge = onTapEdge
        uiView.onTapCenter = onTapCenter
        uiView.apply(
            chapters: chapters,
            currentIndex: currentIndex,
            loadedTexts: loadedTexts,
            failed: failedChapters,
            config: config,
            baseURL: baseURL,
            windowSize: windowSize,
            onProgress: onProgress,
            onVisibleChapter: onVisibleChapter,
            onRequestChapter: onRequestChapter
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: ScrollReaderUIViewDelegate {
        func scrollReader(_ v: ScrollReaderUIView, didReportProgress chapter: Int, ratio: Double) {}
        func scrollReader(_ v: ScrollReaderUIView, didChangeVisibleChapter chapter: Int) {}
        func scrollReader(_ v: ScrollReaderUIView, didRequestChapter index: Int) {}
    }
}

/// SwiftScrollReaderView 的回调协议。
///
/// ⚠️ 必须放在**文件顶层**：嵌套在 ScrollReaderUIView 里面的话，
///    外层的 Coordinator 拿不到这个类型（编译报
///    "cannot find type 'ScrollReaderUIViewDelegate' in scope"）。
protocol ScrollReaderUIViewDelegate: AnyObject {
    func scrollReader(_ v: ScrollReaderUIView, didReportProgress chapter: Int, ratio: Double)
    func scrollReader(_ v: ScrollReaderUIView, didChangeVisibleChapter chapter: Int)
    func scrollReader(_ v: ScrollReaderUIView, didRequestChapter index: Int)
}

/// UIKit 实现
final class ScrollReaderUIView: UIView, UIScrollViewDelegate {

    weak var delegate: ScrollReaderUIViewDelegate?
    var onTapEdge: (Int) -> Void = { _ in }
    var onTapCenter: () -> Void = {}

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    /// 章下标 → 章节视图
    private var chapterViews: [Int: ChapterBox] = [:]
    /// 窗口内章号（有序）
    private var windowIndices: [Int] = []
    /// 当前可见章（用于判断章变化）
    private var visibleChapter: Int = -1
    /// 上次上报进度的时间（秒）
    private var lastProgressAt: Double = 0
    /// 上次进度
    private var lastChapter: Int = -1
    private var lastRatio: Double = 0
    /// 本轮外部传进来的状态（供 apply 增量更新）
    private var pendingChapters: [Chapter] = []
    private var pendingLoaded: [Int: String] = [:]
    private var pendingFailed: Set<Int> = []
    private var pendingConfig: ReaderLayoutConfig?
    private var pendingBaseURL: URL?
    private var pendingCurrent = 0
    private var pendingWindowSize = 5
    private var pendingOnProgress: ((Int, Double) -> Void)?
    private var pendingOnVisible: ((Int) -> Void)?
    private var pendingOnRequest: ((Int) -> Void)?
    /// 上次 apply 的 config 签名（变了才重排）
    private var lastConfigSig: String = ""

    // MARK: - 构造

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)
        scrollView.addSubview(stack)
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 外部状态

    func apply(chapters: [Chapter],
               currentIndex: Int,
               loadedTexts: [Int: String],
               failed: Set<Int>,
               config: ReaderLayoutConfig,
               baseURL: URL?,
               windowSize: Int,
               onProgress: @escaping (Int, Double) -> Void,
               onVisibleChapter: @escaping (Int) -> Void,
               onRequestChapter: @escaping (Int) -> Void) {
        pendingChapters = chapters
        pendingLoaded = loadedTexts
        pendingFailed = failed
        pendingConfig = config
        pendingBaseURL = baseURL
        pendingCurrent = currentIndex
        pendingWindowSize = windowSize
        pendingOnProgress = onProgress
        pendingOnVisible = onVisibleChapter
        pendingOnRequest = onRequestChapter

        let sig = configSignature(config)
        let needsRebuild = sig != lastConfigSig
        lastConfigSig = sig

        let chapterChanged = currentIndex != pendingCurrent
        pendingCurrent = currentIndex
        rebuildWindowIfNeeded(currentIndex: currentIndex, force: needsRebuild)
        if needsRebuild { restackAll() }
        // 换章后视口要落到**新章的开头**，否则窗口动了、眼睛还停在老地方。
        if chapterChanged, let box = chapterViews[currentIndex] {
            let y = box.convert(box.bounds, to: scrollView).minY
            if y.isFinite { scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
        }
    }

    private func configSignature(_ c: ReaderLayoutConfig) -> String {
        "\(c.fontSize)|\(c.lineSpacing)|\(c.paragraphSpacing)|\(c.horizontalMargin)|\(c.topMargin)|\(c.bottomMargin)|\(c.firstLineIndent)|\(c.fontFamily)|\(c.textColor)|\(c.backgroundColor)|\(c.paraAlign)|\(c.verticalJustify)|\(c.showBaseline)|\(c.baselineColor)|\(c.baselineScope)"
    }

    // MARK: - 章节窗口

    private func rebuildWindowIfNeeded(currentIndex: Int, force: Bool) {
        let all = Array(pendingChapters.indices)
        guard !all.isEmpty else {
            if !windowIndices.isEmpty { clearStack() }
            return
        }
        let anchor = min(max(currentIndex, 0), all.count - 1)
        // 窗口：以当前章为中心，两边各留一半
        let half = max(1, pendingWindowSize / 2)
        let desired = Array(max(0, anchor - half)...min(all.count - 1, anchor + half))
        if desired == windowIndices && !force { return }
        // 多出来的章要补
        for idx in desired where chapterViews[idx] == nil {
            chapterViews[idx] = makeChapterBox(index: idx)
        }
        // 不在窗口里的要摘（保留 anchor，避免闪烁）
        let keep = Set(desired)
        for idx in windowIndices where !keep.contains(idx) {
            if let box = chapterViews.removeValue(forKey: idx) { box.removeFromSuperview() }
        }
        windowIndices = desired
        restackAll()
    }

    private func clearStack() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        chapterViews.removeAll()
        windowIndices = []
    }

    private func restackAll() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for idx in windowIndices {
            guard let box = chapterViews[idx] else { continue }
            stack.addArrangedSubview(box)
        }
        refreshChapterContents()
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - 章节内容

    private func makeChapterBox(index: Int) -> ChapterBox {
        let box = ChapterBox()
        box.titleLabel.numberOfLines = 0
        box.bodyView.isScrollEnabled = false
        box.bodyView.isEditable = false
        box.bodyView.isSelectable = true
        box.bodyView.backgroundColor = .clear
        box.bodyView.textContainerInset = .zero
        box.bodyView.textContainer.lineFragmentPadding = 0
        box.bodyView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return box
    }

    private func refreshChapterContents() {
        guard let config = pendingConfig else { return }
        for (idx, box) in chapterViews {
            let title = idx < pendingChapters.count ? pendingChapters[idx].title : ""
            box.titleLabel.text = title
            box.titleLabel.font = .systemFont(ofSize: max(18, config.fontSize * 1.1), weight: .bold)
            box.titleLabel.textColor = config.textColor
            box.titleLabel.isHidden = title.isEmpty

            let body: String
            if let t = pendingLoaded[idx] {
                body = t
                box.stateLabel.isHidden = true
                box.bodyView.isHidden = false
            } else {
                body = ""
                box.stateLabel.isHidden = false
                box.bodyView.isHidden = true
                box.stateLabel.text = pendingFailed.contains(idx) ? "加载失败" : "加载中…"
                box.stateLabel.textColor = config.textColor.withAlphaComponent(0.5)
                box.stateLabel.font = .systemFont(ofSize: config.fontSize)
            }
            box.bodyView.attributedText = makeBodyText(body, config: config, baseURL: pendingBaseURL)
        }
    }

    /// 正文 → NSAttributedString（段落 + 首行缩进 + 行内图片）
    private func makeBodyText(_ text: String,
                               config: ReaderLayoutConfig,
                               baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = UIFont(name: config.fontFamily, size: config.fontSize)
            ?? .systemFont(ofSize: config.fontSize)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = config.lineSpacing
        para.paragraphSpacing = config.paragraphSpacing
        para.alignment = config.paraAlign.uiAlignment
        if config.firstLineIndent > 0 {
            para.firstLineHeadIndent = config.firstLineIndent
        }
        // ⚠️ NSParagraphStyle **没有** verticalAlignment 属性（编译报
        //    "has no member 'verticalAlignment'"）。UITextView 也不支持
        //    「行内垂直两端对齐」—— 那是 CSS line-height 的行为。
        //    所以 verticalJustify 在滚动模式下**不生效**（原生分页那边
        //    用 NSLayoutManager 自己算，是生效的）。
        //    留这个字段是为了跟 config 的语义对齐，不静默吞掉。

        for (i, piece) in Self.normalizedParagraphs(text).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: nil)) }
            appendInlineImages(piece, to: out, font: font, para: para,
                               color: config.textColor, baseURL: baseURL)
        }
        return out
    }

    /// ui.txt/reader.js 的 `normalizedParagraphs`：\r\n|\r → \n，按 \n+ 拆，trim，去空
    static func normalizedParagraphs(_ text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let pieces = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? [cleaned] : pieces
    }

    /// reader.js 的 `appendTextWithImages`：把 `<img ...>` 标签拆出来变成附件
    private func appendInlineImages(_ text: String,
                                    to out: NSMutableAttributedString,
                                    font: UIFont,
                                    para: NSParagraphStyle,
                                    color: UIColor,
                                    baseURL: URL?) {
        let pattern = "<img\\b[^>]*>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            out.append(NSAttributedString(string: text,
                                         attributes: [.font: font, .paragraphStyle: para, .foregroundColor: color]))
            return
        }
        // ⚠️ cursor 用 **Int（utf16 offset）**，不能用 String.Index 去比 Int
        //    （编译报 "referencing operator function '>' on 'BinaryInteger'
        //    requires that 'String.Index' conform to 'BinaryInteger'"）。
        let ns = text as NSString
        var cursor = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let loc = m.range.location
            if loc > cursor {
                let seg = ns.substring(with: NSRange(location: cursor, length: loc - cursor))
                out.append(NSAttributedString(string: seg,
                                             attributes: [.font: font, .paragraphStyle: para, .foregroundColor: color]))
            }
            let tag = ns.substring(with: m.range)
            if let img = Self.imageTag(tag), let url = Self.resolveImageURL(img.src, baseURL: baseURL) {
                let att = NSTextAttachment()
                att.image = Self.loadImage(url)
                out.append(NSAttributedString(attachment: att))
            } else {
                out.append(NSAttributedString(string: tag,
                                             attributes: [.font: font, .paragraphStyle: para, .foregroundColor: color]))
            }
            cursor = loc + m.range.length
        }
        if cursor < ns.length {
            let seg = ns.substring(from: cursor)
            out.append(NSAttributedString(string: seg,
                                         attributes: [.font: font, .paragraphStyle: para, .foregroundColor: color]))
        }
    }

    /// 解析 `<img src="..." width="..." height="...">`
    private static func imageTag(_ tag: String) -> (src: String, width: CGFloat?, height: CGFloat?)? {
        var src = ""
        var w: CGFloat?
        var h: CGFloat?
        let attrs = tag
            .replacingOccurrences(of: "<img", with: "")
            .replacingOccurrences(of: ">", with: " ")
        for piece in attrs.split(separator: " ") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(kv[1]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") { val.removeFirst() }
            if val.hasSuffix("\"") { val.removeLast() }
            switch key {
            case "src", "data-src": if src.isEmpty { src = val }
            case "width": w = CGFloat(Double(val) ?? 0).nonZero
            case "height": h = CGFloat(Double(val) ?? 0).nonZero
            default: break
            }
        }
        guard !src.isEmpty else { return nil }
        return (src, w, h)
    }

    private static func resolveImageURL(_ raw: String, baseURL: URL?) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        if raw.hasPrefix("data:") { return URL(string: raw) }
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        if let baseURL { return URL(string: raw, relativeTo: baseURL) }
        return nil
    }

    private static func loadImage(_ url: URL) -> UIImage? {
        if url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 滚动 / 进度

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let config = pendingConfig else { return }
        let (chapter, ratio) = currentPosition()
        if chapter != visibleChapter {
            visibleChapter = chapter
            pendingOnVisible?(chapter)
            delegate?.scrollReader(self, didChangeVisibleChapter: chapter)
        }
        let now = Date().timeIntervalSince1970
        let changed = chapter != lastChapter
        if ReaderScrollCore.shouldReportProgress(includeProgress: true,
                                                chapterChanged: changed,
                                                force: false,
                                                lastProgressAt: lastProgressAt,
                                                now: now) {
            lastProgressAt = now
            lastChapter = chapter
            lastRatio = ratio
            pendingOnProgress?(chapter, ratio)
            delegate?.scrollReader(self, didReportProgress: chapter, ratio: ratio)
        }
        _ = config
    }

    /// 当前可见章 + 章内比例
    private func currentPosition() -> (Int, Double) {
        let offsetY = scrollView.contentOffset.y
        var best = (chapter: 0, ratio: 0.0)
        for idx in windowIndices {
            guard let box = chapterViews[idx] else { continue }
            let frame = box.convert(box.bounds, to: scrollView)
            let h = max(frame.height, 1)
            let ratio = min(max((offsetY - frame.minY) / h, 0), 1)
            // 取最靠近视口顶部的章
            if frame.maxY > offsetY + 1 {
                return (idx, ratio)
            }
            best = (idx, ratio)
        }
        return best
    }

    // MARK: - 点击

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        let w = bounds.width
        if p.x < w * 0.32 {
            onTapEdge(-1)
        } else if p.x > w * 0.68 {
            onTapEdge(1)
        } else {
            onTapCenter()
        }
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        for box in chapterViews.values {
            guard box.bodyView.isHidden == false else { continue }
            let target = box.bodyView.sizeThatFits(
                CGSize(width: bounds.width - 40, height: .greatestFiniteMagnitude))
            if abs(box.bodyView.frame.height - target.height) > 0.5 {
                box.bodyView.frame.size.height = target.height
            }
        }
    }
}

/// 一个章节的容器：标题 + 正文 + 状态
final class ChapterBox: UIView {
    let titleLabel = UILabel()
    let bodyView = UITextView()
    let stateLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)
        addSubview(bodyView)
        addSubview(stateLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            bodyView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            bodyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            bodyView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private extension CGFloat {
    var nonZero: CGFloat? { self > 0 ? self : nil }
}

private extension ReaderParaAlign {
    var uiAlignment: NSTextAlignment {
        switch self {
        case .center: return .center
        case .right: return .right
        default: return .left
        }
    }
}
