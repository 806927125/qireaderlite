// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//   · 本文件依赖 **TextKit / AppKit**（`NSTextContainer` / `NSLayoutManager` / `NSBezierPath` …）
//   ⇒ **只有 iOS/macOS 能编** ⇒ Linux 沙盒编不到 ⇒ 用条件编译隔离 ⭐⭐⭐
//   ⇒ Apple 平台功能**完全不变**；Linux 上这些类型不存在（只有 `ChaiyueReader` 用到它们，而它本身也是 iOS-only）⭐⭐⭐
#if canImport(UIKit) || canImport(AppKit)
import Foundation
import ChaiyueModels

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 一章分页后的结果。内部持有 TextKit 对象，分页可在后台完成，之后只能在主线程绘制。
public final class ChapterLayout: @unchecked Sendable {
    public let chapterIndex: Int
    public let title: String
    public let pageSize: CGSize
    /// 每页对应的排版字符范围，首尾相接覆盖全文
    public let pageRanges: [NSRange]
    public let offsets: TextOffsetMap
    private let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let containers: [NSTextContainer]
    private let titleInset: CGFloat
    private let justifier: PageJustifier?

    init(chapterIndex: Int, title: String, pageSize: CGSize, titleInset: CGFloat, justifier: PageJustifier?,
         offsets: TextOffsetMap, storage: NSTextStorage,
         layoutManager: NSLayoutManager, containers: [NSTextContainer], pageRanges: [NSRange]) {
        self.chapterIndex = chapterIndex
        self.title = title
        self.pageSize = pageSize
        self.titleInset = titleInset
        self.justifier = justifier
        self.offsets = offsets
        self.storage = storage
        self.layoutManager = layoutManager
        self.containers = containers
        self.pageRanges = pageRanges
    }

    public var pageCount: Int { pageRanges.count }

    /// 复刻排版（选字、朗读高亮）用：与该页相同的容器，按页序加入 `prepare` 过的排版管理器即可得到相同的行位置
    public func makeContainer(forPage page: Int) -> NSTextContainer {
        ChapterPaginator.container(page: page, size: pageSize, titleInset: titleInset)
    }

    /// 复刻排版前调用，让行间增量同样生效（管理器只弱引用它，由本对象持有）
    public func prepare(_ manager: NSLayoutManager) {
        manager.delegate = justifier
    }

    /// 排版文本长度（含标题）
    public var length: Int { storage.length }

    /// 实际排版用的文本（竖向对齐会去掉页末段落的段距），复刻排版必须用它
    public var text: NSAttributedString { NSAttributedString(attributedString: storage) }

    /// 标题（含其后换行）占用的排版字符数
    public var titleLength: Int { offsets.titleLength }

    /// 包含该排版偏移的页
    public func pageIndex(forCharacterOffset offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        return pageRanges.lastIndex { $0.location <= offset } ?? 0
    }

    /// 包含该稳定偏移（章内正文位置）的页，用于恢复进度、跳到书签
    public func pageIndex(forStableOffset offset: Int) -> Int {
        pageIndex(forCharacterOffset: offsets.layoutOffset(forStable: offset))
    }

    /// 页面覆盖的稳定偏移范围，下界用于保存进度，整个范围用于书签摘录和朗读
    public func stableRange(ofPage page: Int) -> Range<Int> {
        guard pageRanges.indices.contains(page) else { return 0..<0 }
        let range = pageRanges[page]
        let lower = offsets.stableOffset(forLayout: range.location)
        let upper = offsets.stableOffset(forLayout: NSMaxRange(range))
        return lower..<max(lower, upper)
    }

    public func pageText(_ page: Int) -> String {
        guard pageRanges.indices.contains(page) else { return "" }
        return (storage.string as NSString).substring(with: pageRanges[page])
    }

    /// 章首页标题所占的矩形（文字区域坐标），没有标题时为 nil
    public var titleRect: CGRect? {
        guard titleLength > 0, !containers.isEmpty else { return nil }
        let text = storage.string as NSString
        let length = text.character(at: titleLength - 1) == 0x0A ? titleLength - 1 : titleLength
        guard length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        var rect = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            rect = rect.union(used)
        }
        return rect.isNull ? nil : rect
    }

    /// 在当前图形上下文中绘制指定页，`origin` 为文字区域左上角
    public func draw(page: Int, at origin: CGPoint) {
        guard containers.indices.contains(page) else { return }
        let glyphRange = layoutManager.glyphRange(for: containers[page])
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
    }

    /// 页内点按位置（文字区域坐标）上的段评气泡或带点按脚本的图片；小目标四周放宽 `slop`
    public func tapTarget(at point: CGPoint, page: Int, slop: CGFloat = 10) -> ReaderTapTarget? {
        guard containers.indices.contains(page), pageRanges.indices.contains(page) else { return nil }
        let container = containers[page]
        var found: ReaderTapTarget?
        storage.enumerateAttribute(.readerTapTarget, in: pageRanges[page]) { value, range, stop in
            guard let box = value as? TapTargetBox else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let margin = rect.width < 44 || rect.height < 44 ? slop : 0
            if rect.insetBy(dx: -margin, dy: -margin).contains(point) {
                found = box.target
                stop.pointee = true
            }
        }
        return found
    }
}

/// 正文里可点按的元素
public enum ReaderTapTarget: Sendable, Equatable {
    /// 段末评论气泡
    case comment(ParagraphComment)
    /// 选项带 click/js 的图片，`source` 为图片的原始地址
    case image(source: String, action: String)
}

final class TapTargetBox: NSObject {
    let target: ReaderTapTarget
    init(_ target: ReaderTapTarget) { self.target = target }
}

extension NSAttributedString.Key {
    /// 可点按元素（值为 `TapTargetBox`），只加在附件字符上
    static let readerTapTarget = NSAttributedString.Key("ChaiyueReaderTapTarget")
}

/// 单个段落的外观（主题样式表里的 `p.类名`）；只改字形与对齐，不改行高，分页节奏不乱
public struct ParagraphLook {
    public var font: PlatformFont?
    public var color: PlatformColor?
    public var alignment: NSTextAlignment?
    /// 首行缩进（点）
    public var indent: CGFloat?
    /// 字距（点）
    public var kern: CGFloat?
    /// 斜体：中文字体大多没有斜体字形，用倾斜模拟
    public var italic = false

    public init(font: PlatformFont? = nil, color: PlatformColor? = nil, alignment: NSTextAlignment? = nil,
                indent: CGFloat? = nil, kern: CGFloat? = nil, italic: Bool = false) {
        self.font = font
        self.color = color
        self.alignment = alignment
        self.indent = indent
        self.kern = kern
        self.italic = italic
    }

    func apply(to piece: NSMutableAttributedString, base: NSParagraphStyle, fontSize: CGFloat) {
        let all = NSRange(location: 0, length: piece.length)
        if alignment != nil || indent != nil, let style = base.mutableCopy() as? NSMutableParagraphStyle {
            if let alignment { style.alignment = alignment }
            if let indent { style.firstLineHeadIndent = indent }
            piece.addAttribute(.paragraphStyle, value: style, range: all)
        }
        // 附件字符（行内图、段评气泡）保留原字体，不然会被缩放
        piece.enumerateAttribute(.attachment, in: all) { value, range, _ in
            guard value == nil else { return }
            if let font { piece.addAttribute(.font, value: font, range: range) }
            if let color { piece.addAttribute(.foregroundColor, value: color, range: range) }
            if let kern { piece.addAttribute(.kern, value: kern, range: range) }
            if italic { piece.addAttribute(.obliqueness, value: 0.18, range: range) }
        }
    }
}

/// 一章的排版文本及其与稳定偏移的对应关系
public struct ChapterAttributedText {
    public let text: NSAttributedString
    public let offsets: TextOffsetMap
}

public enum ChapterPaginator {
    /// 图片拿不到时图片段落显示的占位文字
    public static let imagePlaceholder = "［图片］"

    /// 构建一章的富文本：标题 + 段落（段落已去掉缩进，这里通过首行缩进实现）。
    /// 图片段落用 `image` 按地址同步取图（参数为图片段落中的原始地址），取到时排成单独一段、居中的图片：
    /// 按原始宽高比缩放，宽不超过 `maxImageSize.width`、高不超过 `maxImageSize.height` 减去一行与段距的余量，小图不放大；
    /// `maxImageSize` 的某一边为 0 时不限制该边（分页时仍会缩到能放进一页）。取不到时显示占位文字。
    /// 地址选项 `style` 为 FULL 时铺满宽度（可放大），为 TEXT 时与文字同高；带 click/js 的图片可点按（见 `ChapterLayout.tapTarget`）。
    /// `extras` 中的行内小图替换段内占位字符；段评在段末接一个 `commentBadge` 画的气泡，它只占排版字符，不影响稳定偏移
    public static func attributedText(title: String, paragraphs: [String], typography t: ReaderTypography,
                                      textColor: PlatformColor, secondaryColor: PlatformColor,
                                      maxImageSize: CGSize = .zero,
                                      extras: [Int: ParagraphExtras] = [:],
                                      image: ((String) -> PlatformImage?)? = nil,
                                      commentBadge: ((ParagraphComment) -> PlatformImage?)? = nil,
                                      looks: [Int: ParagraphLook] = [:]) -> ChapterAttributedText {
        let fontSize = CGFloat(t.fontSize)
        let bodyFont = PlatformFont.readerFont(name: t.fontName, size: fontSize)
        let titleFont = PlatformFont.readerFont(name: t.fontName, size: fontSize * CGFloat(t.titleScale), bold: true)
        let kern = fontSize * CGFloat(t.letterSpacing)

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineSpacing = fontSize * 0.3
        titleStyle.paragraphSpacing = fontSize * 1.4
        titleStyle.alignment = .natural
        titleStyle.lineBreakStrategy = .standard

        let bodyStyle = NSMutableParagraphStyle()
        // 固定行高：行内图、气泡、混排的西文字体都不撑高行，行距才均匀，竖向对齐也靠它定末行位置
        let bodyLineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        bodyStyle.minimumLineHeight = bodyLineHeight
        bodyStyle.maximumLineHeight = bodyLineHeight
        bodyStyle.lineSpacing = t.lineHeight.map { max(0, fontSize * CGFloat($0) - bodyLineHeight) } ?? fontSize * CGFloat(t.lineSpacing)
        bodyStyle.paragraphSpacing = fontSize * CGFloat(t.paragraphSpacing)
        bodyStyle.firstLineHeadIndent = CGFloat(t.indent) * (fontSize + kern)
        bodyStyle.alignment = t.justified ? .justified : .natural
        bodyStyle.lineBreakStrategy = .standard

        let result = NSMutableAttributedString()
        var titleLength = 0
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            let titleText = trimmedTitle + (paragraphs.isEmpty ? "" : "\n")
            result.append(NSAttributedString(string: titleText, attributes: [
                .font: titleFont, .foregroundColor: textColor, .paragraphStyle: titleStyle, .kern: kern,
            ]))
            titleLength = (titleText as NSString).length
        }
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: textColor, .paragraphStyle: bodyStyle, .kern: kern,
        ]
        let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: secondaryColor, .paragraphStyle: bodyStyle,
        ]
        let imageStyle = NSMutableParagraphStyle()
        imageStyle.alignment = .center
        imageStyle.paragraphSpacing = bodyStyle.paragraphSpacing
        let imageAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .paragraphStyle: imageStyle]
        let imageLimit = CGSize(width: maxImageSize.width,
                                height: maxImageSize.height > 0
                                    ? max(1, maxImageSize.height - imageMargin(font: bodyFont, style: imageStyle)) : 0)

        let lineHeight = ceil(bodyFont.ascender - bodyFont.descender)

        var layoutLengths: [Int] = []
        var trailingLengths: [Int] = []
        layoutLengths.reserveCapacity(paragraphs.count)
        trailingLengths.reserveCapacity(paragraphs.count)
        for (index, paragraph) in paragraphs.enumerated() {
            let suffix = index == paragraphs.count - 1 ? "" : "\n"
            if InlineImage.isImage(paragraph) {
                let src = InlineImage.source(of: paragraph)
                let info = src.map(InlineImageSource.init)
                if let src, let info, let picture = image?(src),
                   let bounds = imageBounds(picture.size, limit: imageLimit, style: info.style, lineHeight: lineHeight) {
                    let attachment = NSTextAttachment()
                    attachment.image = picture
                    attachment.bounds = bounds
                    let piece = NSMutableAttributedString(attachment: attachment)
                    piece.append(NSAttributedString(string: suffix))
                    piece.addAttributes(imageAttributes, range: NSRange(location: 0, length: piece.length))
                    if let action = info.action {
                        piece.addAttribute(.readerTapTarget, value: TapTargetBox(.image(source: src, action: action)),
                                           range: NSRange(location: 0, length: 1))
                    }
                    result.append(piece)
                    layoutLengths.append(1)
                } else {
                    result.append(NSAttributedString(string: imagePlaceholder + suffix, attributes: placeholderAttributes))
                    layoutLengths.append((imagePlaceholder as NSString).length)
                }
                trailingLengths.append(0)
                continue
            }
            let piece = NSMutableAttributedString(string: paragraph, attributes: bodyAttributes)
            for (offset, src) in extras[index]?.inlineImages ?? [:] where offset < piece.length {
                let attachment = NSTextAttachment()
                let range = NSRange(location: offset, length: 1)
                if let picture = image?(src), picture.size.width > 0, picture.size.height > 0 {
                    attachment.image = picture
                    let width = min(lineHeight * picture.size.width / picture.size.height,
                                    imageLimit.width > 0 ? imageLimit.width : .greatestFiniteMagnitude)
                    attachment.bounds = CGRect(x: 0, y: bodyFont.descender, width: floor(width), height: lineHeight)
                    if let action = InlineImageSource(src).action {
                        piece.addAttribute(.readerTapTarget, value: TapTargetBox(.image(source: src, action: action)), range: range)
                    }
                } else {
                    attachment.image = PlatformImage()
                    attachment.bounds = .zero
                }
                piece.addAttribute(.attachment, value: attachment, range: range)
            }
            var trailing = 0
            if let comment = extras[index]?.comment, let badge = commentBadge?(comment), badge.size.width > 0 {
                let attachment = NSTextAttachment()
                attachment.image = badge
                let size = badge.size
                attachment.bounds = CGRect(x: 0, y: floor((bodyFont.capHeight - size.height) / 2), width: size.width, height: size.height)
                let bubble = NSMutableAttributedString(attachment: attachment)
                bubble.addAttributes(bodyAttributes, range: NSRange(location: 0, length: bubble.length))
                if comment.action != nil {
                    bubble.addAttribute(.readerTapTarget, value: TapTargetBox(.comment(comment)), range: NSRange(location: 0, length: 1))
                }
                piece.append(bubble)
                trailing = bubble.length
            }
            piece.append(NSAttributedString(string: suffix, attributes: bodyAttributes))
            if let look = looks[index] {
                look.apply(to: piece, base: bodyStyle, fontSize: fontSize)
            }
            result.append(piece)
            layoutLengths.append((paragraph as NSString).length + trailing)
            trailingLengths.append(trailing)
        }
        let offsets = TextOffsetMap(titleLength: titleLength, paragraphs: paragraphs, layoutLengths: layoutLengths,
                                    trailingLengths: trailingLengths)
        return ChapterAttributedText(text: result, offsets: offsets)
    }

    /// 按图片选项的排版方式计算大小：FULL 按宽铺满（可放大），TEXT 与文字同高，其余同 `imageBounds(_:limit:)`
    static func imageBounds(_ size: CGSize, limit: CGSize, style: InlineImageSource.Style?, lineHeight: CGFloat) -> CGRect? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        switch style {
        case .full where limit.width > 0:
            var scale = limit.width / size.width
            if limit.height > 0 { scale = min(scale, limit.height / size.height) }
            return CGRect(x: 0, y: 0, width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        case .text:
            return imageBounds(CGSize(width: size.width * lineHeight / size.height, height: lineHeight), limit: limit)
        default:
            return imageBounds(size, limit: limit)
        }
    }

    public static func isImageParagraph(_ paragraph: String) -> Bool {
        InlineImage.isImage(paragraph)
    }

    /// 按宽高比缩到 `limit` 以内（某一边为 0 表示不限），不放大；尺寸无效时为 nil
    static func imageBounds(_ size: CGSize, limit: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        var scale: CGFloat = 1
        if limit.width > 0 { scale = min(scale, limit.width / size.width) }
        if limit.height > 0 { scale = min(scale, limit.height / size.height) }
        return CGRect(x: 0, y: 0, width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
    }

    /// 图片行除图片本身外占用的高度：字体下沉、行高余量与段距。图片超过页高减去它时整行放不进一页，后续文字会丢失
    static func imageMargin(font: PlatformFont, style: NSParagraphStyle) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + style.paragraphSpacing + style.lineSpacing
    }

    /// 把图片缩到能放进一页（调用方没给 `maxImageSize` 或给得比页大时兜底）
    static func fitAttachments(in storage: NSTextStorage, pageSize: CGSize) {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
                ?? PlatformFont.systemFont(ofSize: 17)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                ?? NSParagraphStyle.default
            let limit = CGSize(width: pageSize.width, height: max(1, pageSize.height - imageMargin(font: font, style: style)))
            let size = attachment.bounds.size
            if size.width > limit.width || size.height > limit.height, let bounds = imageBounds(size, limit: limit) {
                attachment.bounds = bounds
            }
        }
    }

    /// 分页：文字区域大小为 `pageSize`；`titleInset` 为章首页顶部留给标题装饰的高度。
    /// `justify` 时把每页底部不足一行的余量均分到行间，除章末页外每页末行都落在页底（翻页模式用，滚动模式不用）
    public static func layout(chapterIndex: Int, title: String, content: ChapterAttributedText,
                              pageSize: CGSize, titleInset: CGFloat = 0, justify: Bool = false) -> ChapterLayout {
        let justifier = justify ? PageJustifier() : nil
        let first = paginate(content.text, pageSize: pageSize, titleInset: titleInset, justifier: justifier)
        if let justifier, let text = justifier.plan(storage: first.storage, manager: first.manager, pageSize: pageSize) {
            let second = paginate(text, pageSize: pageSize, titleInset: titleInset, justifier: justifier)
            // 拉开行距后断页变了就不用（理论上不会发生）
            if second.ranges == first.ranges {
                return ChapterLayout(chapterIndex: chapterIndex, title: title, pageSize: pageSize, titleInset: titleInset,
                                     justifier: justifier, offsets: content.offsets, storage: second.storage,
                                     layoutManager: second.manager, containers: second.containers, pageRanges: second.ranges)
            }
        }
        first.manager.delegate = nil
        return ChapterLayout(chapterIndex: chapterIndex, title: title, pageSize: pageSize, titleInset: titleInset,
                             justifier: nil, offsets: content.offsets, storage: first.storage,
                             layoutManager: first.manager, containers: first.containers, pageRanges: first.ranges)
    }

    static func container(page: Int, size: CGSize, titleInset: CGFloat) -> NSTextContainer {
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        if page == 0, titleInset > 0 {
            let band = CGRect(x: 0, y: 0, width: size.width, height: titleInset)
            #if canImport(UIKit)
            container.exclusionPaths = [UIBezierPath(rect: band)]
            #else
            container.exclusionPaths = [NSBezierPath(rect: band)]
            #endif
        }
        return container
    }

    private static func paginate(_ text: NSAttributedString, pageSize: CGSize, titleInset: CGFloat, justifier: PageJustifier?)
        -> (storage: NSTextStorage, manager: NSLayoutManager, containers: [NSTextContainer], ranges: [NSRange]) {
        let storage = NSTextStorage(attributedString: text)
        fitAttachments(in: storage, pageSize: pageSize)
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = justifier
        storage.addLayoutManager(layoutManager)

        var containers: [NSTextContainer] = []
        var ranges: [NSRange] = []
        let totalGlyphs = layoutManager.numberOfGlyphs
        while containers.count < 10_000 {
            let page = Self.container(page: containers.count, size: pageSize, titleInset: titleInset)
            layoutManager.addTextContainer(page)
            let glyphRange = layoutManager.glyphRange(for: page)
            if glyphRange.length == 0 {
                layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
                break
            }
            containers.append(page)
            ranges.append(layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil))
            if NSMaxRange(glyphRange) >= totalGlyphs { break }
        }
        if containers.isEmpty {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            ranges.append(NSRange(location: 0, length: storage.length))
        }
        return (storage, layoutManager, containers, ranges)
    }
}

/// 竖向两端对齐：第一遍记下每行位置并算出每页余量，第二遍排版时把余量加到页内各行（末行除外）的行高上。
/// TextKit 按调整前的行高判断一行放不放得下，页末行的行距会被截掉而段距不会，
/// 所以目标定为末行（固定行高的正文行）字形贴到页底，页末恰是段尾时去掉该段段距
final class PageJustifier: NSObject, NSLayoutManagerDelegate, @unchecked Sendable {
    private struct Line {
        let glyph: Int
        let rect: CGRect
    }

    private var measured: [Int: [Int: Line]] = [:]
    private var extras: [Int: CGFloat] = [:]
    private var lastLines: [Int: Int] = [:]
    private var applying = false

    /// 按第一遍的结果给每页定行间增量，返回第二遍要用的文本；没有需要拉开的页时为 nil
    func plan(storage: NSTextStorage, manager: NSLayoutManager, pageSize: CGSize) -> NSAttributedString? {
        let containers = manager.textContainers
        let string = storage.string as NSString
        var trimmed: [NSRange] = []
        for page in 0..<max(0, containers.count - 1) {
            let pageGlyphs = manager.glyphRange(for: containers[page])
            let lines = (measured[page] ?? [:]).values
                .filter { NSLocationInRange($0.glyph, pageGlyphs) }
                .sorted { $0.glyph < $1.glyph }
            guard lines.count >= 4, let last = lines.last else { continue }
            let lastChar = manager.characterIndexForGlyph(at: last.glyph)
            guard let style = storage.attribute(.paragraphStyle, at: lastChar, effectiveRange: nil) as? NSParagraphStyle,
                  style.minimumLineHeight > 0 else { continue }
            let lineHeight = style.minimumLineHeight
            let leftover = pageSize.height - 0.25 - lineHeight - last.rect.minY
            // 余量超过一行多半是放不下的大图或分节，硬拉开反而难看
            let pitch = lineHeight + style.lineSpacing + style.paragraphSpacing
            guard leftover > 0.5, leftover < pitch * 1.2 else { continue }
            extras[page] = leftover / CGFloat(lines.count - 1)
            lastLines[page] = last.glyph
            let endChar = manager.characterIndexForGlyph(at: NSMaxRange(pageGlyphs) - 1)
            if style.paragraphSpacing > 0, endChar < string.length, string.character(at: endChar) == 0x0A {
                trimmed.append(string.paragraphRange(for: NSRange(location: lastChar, length: 0)))
            }
        }
        measured = [:]
        applying = true
        guard !extras.isEmpty else { return nil }
        let text = NSMutableAttributedString(attributedString: storage)
        for range in trimmed {
            text.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.paragraphSpacing = 0
                text.addAttribute(.paragraphStyle, value: style, range: part)
            }
        }
        return text
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let page = layoutManager.textContainers.firstIndex(where: { $0 === textContainer }) else { return false }
        guard applying else {
            measured[page, default: [:]][glyphRange.location] = Line(glyph: glyphRange.location, rect: lineFragmentRect.pointee)
            return false
        }
        guard let extra = extras[page], lastLines[page] != glyphRange.location else { return false }
        lineFragmentRect.pointee.size.height += extra
        return true
    }
}
#endif  // #if canImport(UIKit) || canImport(AppKit)
