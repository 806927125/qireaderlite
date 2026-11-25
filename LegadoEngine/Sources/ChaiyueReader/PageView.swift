// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if os(iOS)
import ChaiyueReaderKit
import UIKit

/// 一页：纸张底色 + 颗粒、页眉、正文、页脚；章节未就绪时显示加载或失败状态
final class PageView: UIView {
    private(set) var pointer: PagePointer?
    private var content: PageContent = .blank
    private var theme: ReaderThemeSpec?
    private var metrics: PageMetrics?
    private var header = ReaderChromeText()
    private var footer = ReaderChromeText()
    private var chrome: ReaderSkin.Chrome?
    private var chapterNumber = 1
    private var fontSize: CGFloat = 19
    private var stars: [CALayer] = []
    /// 朗读中的句子（正文区域坐标）
    private var spoken: [CGRect] = []
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    var onRetry: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        var config = UIButton.Configuration.plain()
        config.title = "重新加载"
        config.image = UIImage.icon("arrow.clockwise")
        config.imagePadding = 6
        config.baseForegroundColor = UIColor(hex: 0xC98A00)
        retryButton.configuration = config
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in
            guard let self, let chapter = pointer?.chapter else { return }
            onRetry?(chapter)
        }, for: .touchUpInside)
        addSubview(retryButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ pointer: PagePointer, model: ReaderModel) {
        self.pointer = pointer
        content = model.content(pointer)
        theme = model.theme
        metrics = model.metrics
        switch content {
        case .text(let layout, let page):
            header = model.headerText(for: pointer, layout: layout, page: page)
            footer = model.footerText(for: layout, page: page)
            spoken = model.spokenRects(chapter: layout.chapterIndex, page: page)
            chrome = model.chrome(for: pointer, layout: layout, page: page)
            chapterNumber = model.chapterNumber(layout.chapterIndex)
        case .loading(let title), .failed(let title, _):
            header = ReaderChromeText(left: title)
            footer = ReaderChromeText()
            spoken = []
            chrome = nil
        case .blank:
            header = ReaderChromeText()
            footer = ReaderChromeText()
            spoken = []
            chrome = nil
        }
        fontSize = CGFloat(model.settings.fontSize)
        backgroundColor = model.theme.uiBackground
        updateStars(model.theme.skin == .xing)
        if case .loading = content {
            spinner.color = model.theme.uiSecondary
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        if case .failed = content {
            retryButton.isHidden = false
        } else {
            retryButton.isHidden = true
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    func refreshSpoken(model: ReaderModel) {
        guard case .text(let layout, let page) = content else { return }
        let rects = model.spokenRects(chapter: layout.chapterIndex, page: page)
        guard rects != spoken else { return }
        spoken = rects
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retryButton.sizeToFit()
        retryButton.center = CGPoint(x: bounds.midX, y: bounds.midY + 34)
        layoutStars()
    }

    override func draw(_ rect: CGRect) {
        guard let theme, let metrics, let context = UIGraphicsGetCurrentContext() else { return }
        if let skin = theme.skin {
            theme.uiBackground.setFill()
            context.fill(bounds)
            PaperGrain.fill(bounds, strength: theme.grain, in: context)
            skin.backdrop(size: bounds.size)?.draw(at: .zero)
            drawSkin(skin, theme: theme, metrics: metrics)
            return
        }
        var page: (ChapterLayout, Int)?
        if case .text(let layout, let index) = content { page = (layout, index) }
        PagePainter.draw(in: context, bounds: bounds, theme: theme, metrics: metrics, header: header,
                         footer: page == nil ? ReaderChromeText() : footer, page: page, spoken: spoken)
        if case .failed(_, let message) = content {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: theme.uiSecondary,
                .paragraphStyle: style,
            ]
            let x = metrics.textFrame.minX, width = metrics.textFrame.width
            let box = CGRect(x: x + 10, y: bounds.midY - 80, width: width - 20, height: 90)
            (message as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attributes, context: nil)
        }
    }

    private func drawSkin(_ skin: ReaderSkin, theme: ReaderThemeSpec, metrics: PageMetrics) {
        let x = metrics.textFrame.minX
        let width = metrics.textFrame.width
        switch content {
        case .text(let layout, let page):
            if let chrome { skin.drawChrome(chrome, metrics: metrics, theme: theme, bounds: bounds) }
            if page == 0 {
                skin.drawTitleDecor(layout: layout, origin: metrics.textFrame.origin, width: width, number: chapterNumber,
                                    theme: theme, fontSize: fontSize)
            }
            SpokenMark.fill(spoken, at: metrics.textFrame.origin, color: theme.uiMark)
            layout.draw(page: page, at: metrics.textFrame.origin)
        case .failed(let title, let message):
            skin.drawChrome(.init(header: title, page: 0, pageCount: 0, progress: 0, percent: ""), metrics: metrics, theme: theme,
                            bounds: bounds)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let box = CGRect(x: x + 10, y: bounds.midY - 80, width: width - 20, height: 90)
            (message as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
                .font: UIFont.systemFont(ofSize: 14), .foregroundColor: theme.uiSecondary, .paragraphStyle: style,
            ], context: nil)
        case .loading, .blank:
            break
        }
    }

    /// 星夜：页首几颗星缓慢明灭
    private func updateStars(_ on: Bool) {
        guard on else {
            stars.forEach { $0.removeFromSuperlayer() }
            stars = []
            return
        }
        guard stars.isEmpty else { return }
        var random = SeededRandom("stars")
        for index in 0..<9 {
            let star = CALayer()
            let size: CGFloat = index % 3 == 0 ? 2.2 : 1.4
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.cornerRadius = size / 2
            star.backgroundColor = UIColor(hex: index % 4 == 0 ? 0xFFE9A8 : 0xFFFFFF).cgColor
            star.shadowColor = star.backgroundColor
            star.shadowOpacity = 0.9
            star.shadowRadius = 2
            star.shadowOffset = .zero
            star.opacity = 0
            star.name = "\(random.next()),\(random.next())"
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 0.05
            blink.toValue = 0.85
            blink.duration = 1.8 + random.next() * 2.4
            blink.beginTime = CACurrentMediaTime() + random.next() * 3
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.isRemovedOnCompletion = false
            star.add(blink, forKey: "blink")
            layer.addSublayer(star)
            stars.append(star)
        }
        setNeedsLayout()
    }

    private func layoutStars() {
        for star in stars {
            let parts = (star.name ?? "0,0").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            star.position = CGPoint(x: bounds.width * (0.06 + parts[0] * 0.88), y: bounds.height * (0.02 + parts[1] * 0.17))
        }
    }
}

/// 普通（非皮肤）主题的一页：纸色、背景图、颗粒、页眉、正文、页脚。阅读页与主题编辑器的预览共用
enum PagePainter {
    static func draw(in context: CGContext, bounds: CGRect, theme: ReaderThemeSpec, metrics: PageMetrics,
                     header: ReaderChromeText, footer: ReaderChromeText, page: (ChapterLayout, Int)?, spoken: [CGRect] = []) {
        theme.uiBackground.setFill()
        context.fill(bounds)
        if let box = theme.style?.page, let name = box.backgroundImage, let id = theme.customID,
           let image = ReaderThemeStore.shared.image(id, named: name) {
            drawBackground(image, fit: box.backgroundFit, in: bounds, context: context)
        }
        PaperGrain.fill(bounds, strength: theme.grain, in: context)

        let style = theme.style
        let x = metrics.textFrame.minX
        let width = metrics.textFrame.width
        if !header.isEmpty {
            drawChrome(header, style: style?.header ?? ReaderTextStyle(), theme: theme,
                       frame: CGRect(x: x, y: metrics.headerY, width: width, height: 14), digits: false)
        }
        if let (layout, index) = page {
            SpokenMark.fill(spoken, at: metrics.textFrame.origin, color: theme.uiMark)
            layout.draw(page: index, at: metrics.textFrame.origin)
        }
        if !footer.isEmpty {
            drawChrome(footer, style: style?.footer ?? ReaderTextStyle(), theme: theme,
                       frame: CGRect(x: x, y: metrics.footerY, width: width, height: 14), digits: true)
        }
    }

    /// 页眉页脚：左中右三段；只有一段时按 text-align 摆放
    private static func drawChrome(_ text: ReaderChromeText, style: ReaderTextStyle, theme: ReaderThemeSpec, frame: CGRect, digits: Bool) {
        guard style.hidden != true else { return }
        let size = CGFloat(style.fontSize?.points(fontSize: 11) ?? 11)
        let font: UIFont
        if style.fontFamily != nil || style.fontWeight != nil {
            font = ReaderThemeStore.font(style, fallbackName: nil, size: size, bold: style.isBold ?? false)
        } else {
            font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        }
        let color = style.color == nil && style.opacity == nil ? theme.uiSecondary : ReaderModel.color(style, base: theme.uiText)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
            .kern: style.letterSpacing.map { CGFloat($0.points(fontSize: Double(size))) } ?? 0.5,
        ]
        let box = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(14, ceil(font.lineHeight)))
        let parts = [text.left, text.center, text.right].filter { !$0.isEmpty }
        if parts.count == 1, text.center.isEmpty, text.right.isEmpty, let align = style.textAlign, align != .left {
            paragraph.alignment = align == .center ? .center : .right
            attributes[.paragraphStyle] = paragraph
            (text.left as NSString).draw(in: box, withAttributes: attributes)
            return
        }
        let right = text.right as NSString
        let rightWidth = ceil(right.size(withAttributes: attributes).width)
        let center = text.center as NSString
        let centerWidth = min(box.width * 0.5, ceil(center.size(withAttributes: attributes).width))
        attributes[.paragraphStyle] = paragraph
        let leftLimit = text.center.isEmpty ? box.width - rightWidth - 12 : (box.width - centerWidth) / 2 - 8
        (text.left as NSString).draw(in: CGRect(x: box.minX, y: box.minY, width: max(0, leftLimit), height: box.height),
                                     withAttributes: attributes)
        if !text.center.isEmpty {
            center.draw(in: CGRect(x: box.midX - centerWidth / 2, y: box.minY, width: centerWidth, height: box.height), withAttributes: attributes)
        }
        right.draw(at: CGPoint(x: box.maxX - rightWidth, y: box.minY), withAttributes: attributes)
    }

    private static func drawBackground(_ image: UIImage, fit: ReaderPageBox.ImageFit, in bounds: CGRect, context: CGContext) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        switch fit {
        case .repeat:
            context.saveGState()
            UIColor(patternImage: image).setFill()
            context.fill(bounds)
            context.restoreGState()
        case .cover, .contain:
            let scale = fit == .cover ? max(bounds.width / size.width, bounds.height / size.height)
                : min(bounds.width / size.width, bounds.height / size.height)
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: CGRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        }
    }
}

/// 朗读句子的底色（原型 `.s.speaking`：明黄 32% 并外扩 2pt；皮肤主题用各自的颜色）
enum SpokenMark {
    static func fill(_ rects: [CGRect], at origin: CGPoint, color: UIColor = UIColor(hex: 0xFFD508, alpha: 0.32)) {
        guard !rects.isEmpty else { return }
        color.setFill()
        for rect in rects {
            UIBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -2), cornerRadius: 3).fill()
        }
    }
}

/// 纸张颗粒：接近白色的细噪点，正片叠底时只轻微压暗；按屏幕倍率生成，颗粒落在物理像素上
enum PaperGrain {
    static let image: UIImage = {
        let size = 240
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        var random = SeededRandom("paper")
        for i in 0..<(size * size) {
            let v = UInt8(255 - random.next() * 64)
            bytes[i * 4] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }()

    /// 在当前上下文铺满颗粒
    static func fill(_ rect: CGRect, strength: Double, in context: CGContext) {
        guard strength > 0 else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setAlpha(strength * 0.45)
        UIColor(patternImage: image).setFill()
        context.fill(rect)
        context.restoreGState()
    }
}
#endif  // #if canImport(UIKit)
