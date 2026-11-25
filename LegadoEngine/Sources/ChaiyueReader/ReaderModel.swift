// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if canImport(SwiftUI)
import Observation
import ChaiyueReaderKit
import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI
import UIKit

/// 页的位置。`page == -1` 表示该章最后一页（章节尚未排版时使用，排版后换算）
struct PagePointer: Hashable {
    var chapter: Int
    var page: Int
}

enum PageContent {
    case text(ChapterLayout, page: Int)
    case loading(title: String)
    case failed(title: String, message: String)
    case blank
}

/// 页面几何：整页大小与正文区域
struct PageMetrics: Equatable {
    var size: CGSize
    var textFrame: CGRect
    var headerY: CGFloat
    var footerY: CGFloat
}

enum ReaderPanel: String, Identifiable {
    case toc, style
    var id: String { rawValue }
}

@Observable
final class ReaderModel {
    let session: ReaderSession
    let settings: ReaderSettings
    private(set) var pointer: PagePointer
    var menuVisible = false
    var panel: ReaderPanel?
    /// 排版或主题变化后递增，翻页视图据此重建当前页
    private(set) var version = 0
    private(set) var theme: ReaderThemeSpec
    /// 目录滑块拖动中的预览章节
    var scrubbing: Int?

    @ObservationIgnored private var layouts: [Int: ChapterLayout] = [:]
    @ObservationIgnored private(set) var metrics: PageMetrics?
    @ObservationIgnored private var signature = ""
    /// 当前章等待排版后要定位的稳定偏移
    @ObservationIgnored private var pendingOffset: Int?
    @ObservationIgnored var onTurnRequest: ((Bool) -> Void)?
    @ObservationIgnored var onTextAction: ((TextAction, TextPick) -> Void)?
    /// 需要提示用户的消息（点按脚本出错等）
    @ObservationIgnored var onNotice: ((String) -> Void)?
    /// 退出阅读前由滚动视图交回当前看到的位置
    @ObservationIgnored var commitVisible: (() -> Void)?
    @ObservationIgnored private var pendingRelayout: Set<Int> = []
    /// 朗读句子变化时刷新可见页的高亮
    @ObservationIgnored var onSpokenChange: (() -> Void)?
    /// 正在朗读的句子（稳定偏移）
    @ObservationIgnored private(set) var spoken: (chapter: Int, range: NSRange)?
    /// 网页模式：屏幕上看到的稳定偏移范围（由网页回报）
    @ObservationIgnored private(set) var webRange: (chapter: Int, range: Range<Int>)?
    /// 目录、书签、滑块跳转时递增，网页模式据此重新定位（同一章内跳转也要生效）
    @ObservationIgnored private(set) var jumpToken = 0
    /// 网页模式下朗读需要翻到某个位置
    @ObservationIgnored var onWebFollow: ((Int, Int) -> Void)?

    init(session: ReaderSession, settings: ReaderSettings, theme: ReaderThemeSpec) {
        self.session = session
        self.settings = settings
        self.theme = theme
        pointer = PagePointer(chapter: session.position.chapterIndex, page: 0)
        pendingOffset = session.position.offset
    }

    var book: Book { session.book }
    var chapterCount: Int { session.chapters.count }

    /// 目录加载完成：会话可能按章节名校正了当前章，按校正后的位置重新定位
    func sessionOpened() {
        let position = session.position
        pointer = PagePointer(chapter: position.chapterIndex, page: 0)
        pendingOffset = position.offset
        resolvePending()
        version += 1
    }

    // MARK: - 排版

    func update(metrics newMetrics: PageMetrics) {
        guard newMetrics != metrics else { return }
        let anchor = currentAnchor()
        metrics = newMetrics
        invalidate(anchor: anchor)
    }

    func update(theme newTheme: ReaderThemeSpec) {
        guard newTheme != theme else { return }
        let anchor = currentAnchor()
        theme = newTheme
        invalidate(anchor: anchor)
    }

    /// 字号、字体、行距或字体下载状态变化
    func typographyChanged() {
        let key = typographySignature()
        guard key != signature else { return }
        let anchor = currentAnchor()
        signature = key
        invalidate(anchor: anchor)
    }

    /// 章节正文加载完成或失败
    func chaptersChanged() {
        for index in Array(layouts.keys) where session.text(of: index) != sources[index] {
            layouts[index] = nil
            texts[index] = nil
            sources[index] = nil
        }
        resolvePending()
        version += 1
    }

    private func typographySignature() -> String {
        let t = settings.typography(for: theme)
        let fonts = FontLibrary.shared
        return "\(t.fontSize)|\(t.fontName ?? "-")|\(t.lineSpacing)|\(t.lineHeight ?? 0)|\(t.paragraphSpacing)|\(t.indent)"
            + "|\(t.letterSpacing)|\(t.justified)|\(t.titleScale)|\(fonts.songtiReady)|\(fonts.kaitiReady)|\(settings.paragraphComments)"
            + "|\(settings.pageStyle == .vertical)|\(FontStore.shared.version)"
    }

    /// SVG 插图画好后重排该章（占位图与成图大小相同，分页不变）；同一轮里多张图只重排一次
    private func imageRendered(_ chapter: Int) {
        guard pendingRelayout.insert(chapter).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let chapters = pendingRelayout
            pendingRelayout = []
            guard chapters.contains(where: { layouts[$0] != nil }) else { return }
            let anchor = currentAnchor()
            for index in chapters {
                layouts[index] = nil
                texts[index] = nil
                sources[index] = nil
                bottoms[index] = nil
            }
            if chapters.contains(pointer.chapter), pointer.page != -1 {
                pendingOffset = anchor ?? 0
                pointer.page = 0
            }
            resolvePending()
            version += 1
        }
    }

    // MARK: - 点按动作

    /// 执行段评气泡或图片的点按脚本（书源环境，带本书与该章）
    func perform(_ target: ReaderTapTarget, chapter: Int) {
        let script: String
        let failure: String
        switch target {
        case .comment(let comment):
            guard let action = comment.action else { return }
            script = action
            failure = "无法打开段评"
        case .image(_, let action):
            script = action
            failure = "图片动作执行失败"
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let session = session
        Task { [weak self] in
            do {
                try await session.runContentAction(script, chapter: chapter)
            } catch {
                self?.onNotice?("\(failure)：\(error.localizedDescription)")
            }
        }
    }

    private func currentAnchor() -> Int? {
        if theme.web, let webRange, webRange.chapter == pointer.chapter { return webRange.range.lowerBound }
        guard pointer.page >= 0, let layout = layouts[pointer.chapter] else { return pendingOffset }
        return layout.stableRange(ofPage: min(pointer.page, layout.pageCount - 1)).lowerBound
    }

    private func invalidate(anchor: Int?) {
        layouts = [:]
        texts = [:]
        sources = [:]
        replicas = [:]
        bottoms = [:]
        signature = typographySignature()
        if pointer.page != -1 {
            pendingOffset = anchor ?? 0
            pointer.page = 0
        }
        resolvePending()
        version += 1
    }

    func layout(_ chapter: Int) -> ChapterLayout? {
        if let layout = layouts[chapter] { return layout }
        guard let metrics, let text = session.text(of: chapter) else { return nil }
        let typography = settings.typography(for: theme)
        let skin = theme.skin
        let width = metrics.textFrame.width
        let theme = self.theme
        let badge: ((ParagraphComment) -> UIImage?)? = settings.paragraphComments ? { comment in
            CommentBadge.image(for: comment, fontSize: CGFloat(typography.fontSize), color: theme.uiSecondary, isDark: theme.isDark)
        } : nil
        var classes: [Int: String] = [:]
        if let style = theme.style, !style.classes.isEmpty, let script = themeScript, script.hasParagraphClass {
            classes = script.paragraphClasses(text.paragraphs)
        }
        let content = Self.compose(title: text.title, paragraphs: text.paragraphs, extras: text.extras, typography: typography,
                                   theme: theme, maxImageSize: metrics.textFrame.size, classes: classes,
                                   image: { [session, weak self] src in
                                       guard let data = session.imageData(for: src) else { return nil }
                                       return ContentImages.shared.image(src: src, data: data, maxWidth: width) { self?.imageRendered(chapter) }
                                   },
                                   badge: badge)
        let layout = ChapterPaginator.layout(chapterIndex: chapter, title: text.title, content: content,
                                             pageSize: metrics.textFrame.size,
                                             titleInset: skin?.titleInset(fontSize: typography.fontSize) ?? 0,
                                             justify: settings.pageStyle != .vertical)
        layouts[chapter] = layout
        texts[chapter] = layout.text
        sources[chapter] = text
        bottoms[chapter] = nil
        if layouts.count > 6 {
            for key in Array(layouts.keys) where abs(key - pointer.chapter) > 2 {
                layouts[key] = nil
                texts[key] = nil
                sources[key] = nil
            }
        }
        return layout
    }

    /// 长按选字：该章排版用的富文本与分页结果
    func selectionSource(chapter: Int) -> (text: NSAttributedString, layout: ChapterLayout)? {
        guard let layout = layout(chapter), let text = texts[chapter] else { return nil }
        return (text, layout)
    }

    @ObservationIgnored private var texts: [Int: NSAttributedString] = [:]
    @ObservationIgnored private var sources: [Int: ChapterText] = [:]
    @ObservationIgnored private var replicas: [Int: TextReplica] = [:]
    @ObservationIgnored private var bottoms: [Int: [Int: CGFloat]] = [:]

    /// 该章排版的 TextKit 副本，排版重建后随之重建
    private func replica(_ chapter: Int) -> TextReplica? {
        guard let layout = layouts[chapter], let text = texts[chapter] else { return nil }
        if let cached = replicas[chapter], cached.layout === layout { return cached }
        let made = TextReplica(text: text, layout: layout)
        replicas = replicas.filter { layouts[$0.key] != nil }
        replicas[chapter] = made
        return made
    }

    /// 连续排版时本页首行到下一页首行（末页为到全文末尾）的距离
    private func span(chapter: Int, page: Int) -> CGFloat? {
        if let cached = bottoms[chapter]?[page] { return cached }
        guard let layout = layouts[chapter], layout.pageRanges.indices.contains(page), let replica = replica(chapter) else { return nil }
        let next = page + 1 < layout.pageCount ? layout.pageRanges[page + 1].location : Int.max
        let value = ceil(replica.flowY(atCharacter: next) - replica.flowY(atCharacter: layout.pageRanges[page].location))
        bottoms[chapter, default: [:]][page] = value
        return value
    }

    /// 章末页正文实际占用的高度（滚动模式据此收紧章与章的间隔）
    func usedHeight(chapter: Int, page: Int) -> CGFloat? {
        span(chapter: chapter, page: page)
    }

    /// 滚动模式里本页条带的高度：让下一页首行落在连续排版时的位置，分页处不留空白
    func flowHeight(chapter: Int, page: Int) -> CGFloat? {
        guard let layout = layouts[chapter], let metrics, layout.pageRanges.indices.contains(page + 1),
              let value = span(chapter: chapter, page: page),
              value > 0, value <= metrics.textFrame.height + 1 else { return nil }
        return value
    }

    /// 当前自定义主题的脚本（内置主题或没写脚本时为 nil）
    var themeScript: ReaderThemeScript? {
        let store = ReaderThemeStore.shared
        return store.theme(theme.customID).flatMap { store.script(for: $0) }
    }

    /// 一章的排版文本：章头、正文与段落类样式。主题编辑器的预览也用它，保证预览与阅读页一致
    static func compose(title: String, paragraphs: [String], extras: [Int: ParagraphExtras] = [:], typography: ReaderTypography,
                        theme: ReaderThemeSpec, maxImageSize: CGSize, classes: [Int: String] = [:],
                        image: ((String) -> UIImage?)? = nil,
                        badge: ((ParagraphComment) -> UIImage?)? = nil) -> ChapterAttributedText {
        let skin = theme.skin
        let style = theme.style
        // 皮肤主题把「第 N 章」交给装饰去画，标题只留章名；默认版式拆成小字序号一行、大字章名一行
        let name = ChapterTitle.display(title) ?? title
        var number = name == title ? nil : ChapterTitle.number(title)
        if style?.chapterNumber.hidden == true { number = nil }
        var shownTitle = skin != nil ? name : number.map { "\($0)\n\(name)" } ?? title
        if style?.chapterTitle.hidden == true { shownTitle = number ?? "" }
        var looks: [Int: ParagraphLook] = [:]
        if let style {
            for (index, name) in classes {
                guard let item = style.classes[name] else { continue }
                looks[index] = look(item, typography: typography, base: theme.uiText)
            }
        }
        let content = ChapterPaginator.attributedText(
            title: shownTitle, paragraphs: paragraphs, typography: typography,
            textColor: theme.uiText, secondaryColor: theme.uiSecondary, maxImageSize: maxImageSize, extras: extras,
            image: image, commentBadge: badge, looks: looks)
        let numberLength = skin == nil ? number.map { ($0 as NSString).length + 1 } ?? 0 : 0
        emboldenTitle(content, typography: typography, skin: skin, numberLength: numberLength, theme: theme)
        return content
    }

    private static func look(_ item: ReaderTextStyle, typography: ReaderTypography, base: UIColor) -> ParagraphLook {
        let size = CGFloat(typography.fontSize)
        var look = ParagraphLook()
        if item.fontFamily != nil || item.fontWeight != nil {
            look.font = ReaderThemeStore.font(item, fallbackName: typography.fontName, size: size, bold: item.isBold ?? false)
        }
        if item.color != nil || item.opacity != nil { look.color = color(item, base: base) }
        look.alignment = item.textAlign.map(alignment)
        look.indent = item.textIndent.map { CGFloat($0.points(fontSize: typography.fontSize)) }
        look.kern = item.letterSpacing.map { CGFloat($0.points(fontSize: typography.fontSize)) }
        look.italic = item.italic ?? false
        return look
    }

    static func color(_ item: ReaderTextStyle, base: UIColor) -> UIColor {
        let color = item.color?.platform ?? base
        guard let opacity = item.opacity else { return color }
        var alpha: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return color.withAlphaComponent(alpha * opacity)
    }

    static func alignment(_ align: ReaderTextAlign) -> NSTextAlignment {
        switch align {
        case .left: .left
        case .right: .right
        case .center: .center
        case .justify: .justified
        }
    }

    /// 标题换成同字族粗体并加字距（ReaderKit 对自定义字体不区分粗细）
    /// 章头：原型 `.rp-chap-no`（0.68 字号、次要色；字距比原型的 0.4em 收小，否则多位数字会被拆开）+ `.rp-chap-title`（粗体、字距 1.5、下距约 1.8 字号）。
    /// 自定义主题的 `.chap-no` / `.chap-title` 逐项覆盖这些默认值（em 相对元素自身字号，字号的 em 相对正文）。
    /// `numberLength` 为标题开头序号行（含换行）的长度，0 表示只有一行章名
    private static func emboldenTitle(_ content: ChapterAttributedText, typography: ReaderTypography, skin: ReaderSkin?,
                                      numberLength: Int, theme: ReaderThemeSpec) {
        guard let text = content.text as? NSMutableAttributedString, content.offsets.titleLength > 0 else { return }
        let size = CGFloat(typography.fontSize * typography.titleScale)
        let titleStyle = theme.style?.chapterTitle ?? ReaderTextStyle()
        let font = ReaderThemeStore.font(titleStyle, fallbackName: typography.fontName, size: size, bold: titleStyle.isBold ?? true)
        let range = NSRange(location: 0, length: min(content.offsets.titleLength, text.length))
        guard let skin else {
            let body = CGFloat(typography.fontSize)
            let numbered = min(numberLength, range.length)
            let nameRange = NSRange(location: numbered, length: range.length - numbered)
            let nameStyle = NSMutableParagraphStyle()
            nameStyle.lineSpacing = 0
            nameStyle.paragraphSpacing = titleStyle.marginBottom.map { CGFloat($0.points(fontSize: Double(size))) } ?? round(body * 1.8)
            nameStyle.paragraphSpacingBefore = titleStyle.marginTop.map { CGFloat($0.points(fontSize: Double(size))) } ?? 0
            nameStyle.alignment = titleStyle.textAlign.map(alignment) ?? .natural
            nameStyle.lineBreakStrategy = .standard
            var nameAttributes: [NSAttributedString.Key: Any] = [
                .font: font, .kern: titleStyle.letterSpacing.map { CGFloat($0.points(fontSize: Double(size))) } ?? 1.5,
                .paragraphStyle: nameStyle,
            ]
            if titleStyle.color != nil || titleStyle.opacity != nil { nameAttributes[.foregroundColor] = color(titleStyle, base: theme.uiText) }
            text.addAttributes(nameAttributes, range: nameRange)
            guard numbered > 0 else { return }
            let numberStyle = theme.style?.chapterNumber ?? ReaderTextStyle()
            let small = numberStyle.fontSize.map { CGFloat($0.points(fontSize: typography.fontSize)) } ?? round(body * 0.68)
            let numberFont = ReaderThemeStore.font(numberStyle, fallbackName: typography.fontName, size: small,
                                                   bold: numberStyle.isBold ?? false)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = numberStyle.marginTop.map { CGFloat($0.points(fontSize: Double(small))) } ?? round(body * 0.6)
            paragraph.paragraphSpacing = numberStyle.marginBottom.map { CGFloat($0.points(fontSize: Double(small))) } ?? round(body * 0.5)
            paragraph.alignment = numberStyle.textAlign.map(alignment) ?? .natural
            text.addAttributes([
                .font: numberFont,
                .kern: numberStyle.letterSpacing.map { CGFloat($0.points(fontSize: Double(small))) } ?? small * 0.15,
                .foregroundColor: color(numberStyle, base: numberStyle.color == nil ? theme.uiSecondary : theme.uiText),
                .paragraphStyle: paragraph,
            ], range: NSRange(location: 0, length: numbered))
            return
        }
        let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.alignment = skin.titleAlignment
        style.tailIndent = -skin.titleTrailing
        text.addAttributes([.font: font, .kern: size * skin.titleKern, .paragraphStyle: style], range: range)
    }

    private func resolvePending() {
        guard let layout = layout(pointer.chapter) else { return }
        if pointer.page == -1 {
            pointer.page = max(0, layout.pageCount - 1)
            pendingOffset = nil
            savePosition()
            return
        }
        if let offset = pendingOffset {
            let page = layout.pageIndex(forStableOffset: offset)
            pointer.page = page
            pendingOffset = nil
            let range = layout.stableRange(ofPage: page)
            let kept = range.isEmpty ? offset : min(max(offset, range.lowerBound), max(range.lowerBound, range.upperBound - 1))
            session.updatePosition(ReadingPosition(chapterIndex: pointer.chapter, offset: kept))
            return
        }
        pointer.page = min(pointer.page, max(0, layout.pageCount - 1))
        savePosition()
    }

    /// 滚动模式恢复时，页码加上这一页里已经读下去的距离
    func verticalPlacement() -> (PagePointer, CGFloat) {
        let page = PagePointer(chapter: pointer.chapter, page: max(0, pointer.page))
        guard let layout = layout(page.chapter), let metrics else { return (page, 0) }
        let index = min(page.page, max(0, layout.pageCount - 1))
        let placed = PagePointer(chapter: page.chapter, page: index)
        let range = layout.stableRange(ofPage: index)
        let span = range.upperBound - range.lowerBound
        let pos = session.position.offset
        guard span > 0, pos > range.lowerBound else { return (placed, 0) }
        let fraction = min(1, CGFloat(pos - range.lowerBound) / CGFloat(span))
        let height = flowHeight(chapter: placed.chapter, page: index) ?? metrics.textFrame.height
        return (placed, fraction * max(0, height - 1))
    }

    /// 滚动停住或退出时，把这一页里看到的位置换算成正文字符偏移
    func noteVisible(chapter: Int, page: Int, y: CGFloat, height: CGFloat) {
        guard pendingOffset == nil || pendingOffset == 0 else { return }
        guard session.chapters.indices.contains(chapter), let layout = layout(chapter), height > 1 else { return }
        let index = page < 0 ? max(0, layout.pageCount - 1) : min(page, max(0, layout.pageCount - 1))
        let range = layout.stableRange(ofPage: index)
        let fraction = min(max(y / height, 0), 0.98)
        let offset = range.lowerBound + Int((Double(range.upperBound - range.lowerBound) * Double(fraction)).rounded(.down))
        let kept = max(range.lowerBound, offset)
        let next = PagePointer(chapter: chapter, page: index)
        guard next != pointer || session.position.offset != kept else { return }
        pointer = next
        pendingOffset = nil
        session.updatePosition(ReadingPosition(chapterIndex: chapter, offset: kept))
    }

    /// 离开阅读器前把屏幕上正在看的位置写进进度
    func commitVisiblePosition() {
        if let commitVisible {
            commitVisible()
            return
        }
        guard pendingOffset == nil else { return }
        savePosition()
    }

    // MARK: - 翻页

    func content(_ p: PagePointer) -> PageContent {
        guard session.chapters.indices.contains(p.chapter) else { return .blank }
        if let layout = layout(p.chapter) {
            let page = p.page < 0 ? layout.pageCount - 1 : min(p.page, layout.pageCount - 1)
            return .text(layout, page: page)
        }
        let title = session.chapters[p.chapter].title
        if case .failed(let message) = session.chapterStates[p.chapter] {
            return .failed(title: title, message: message)
        }
        session.ensureLoaded(p.chapter)
        return .loading(title: title)
    }

    func next(after p: PagePointer) -> PagePointer? {
        if let layout = layout(p.chapter), p.page >= 0, p.page + 1 < layout.pageCount {
            return PagePointer(chapter: p.chapter, page: p.page + 1)
        }
        guard session.chapters.indices.contains(p.chapter + 1) else { return nil }
        session.ensureLoaded(p.chapter + 1)
        return PagePointer(chapter: p.chapter + 1, page: 0)
    }

    func previous(before p: PagePointer) -> PagePointer? {
        if layout(p.chapter) != nil, p.page > 0 {
            return PagePointer(chapter: p.chapter, page: p.page - 1)
        }
        guard p.chapter > 0, session.chapters.indices.contains(p.chapter - 1) else { return nil }
        session.ensureLoaded(p.chapter - 1)
        if let layout = layout(p.chapter - 1) {
            return PagePointer(chapter: p.chapter - 1, page: layout.pageCount - 1)
        }
        return PagePointer(chapter: p.chapter - 1, page: -1)
    }

    /// 翻页完成后由翻页视图调用。正文还没排好时，不用占位的第 0 页盖掉正在恢复的进度
    func didShow(_ p: PagePointer) {
        guard session.chapters.indices.contains(p.chapter) else { return }
        if let pending = pendingOffset, pending > 0, p.chapter == pointer.chapter, p.page == 0 { return }
        guard let layout = layout(p.chapter) else {
            guard p != pointer else { return }
            let previous = pointer.chapter
            pointer = p
            if p.chapter != previous { pendingOffset = nil }
            return
        }
        var resolved = p
        resolved.page = p.page < 0 ? layout.pageCount - 1 : min(p.page, layout.pageCount - 1)
        pendingOffset = nil
        guard resolved != pointer else { return }
        pointer = resolved
        savePosition()
        prewarm(around: resolved, pageCount: layout.pageCount)
    }

    /// 快到章首章尾时趁空闲先排好相邻章，翻过去的那一下不用现场排版；上一章只排已下载的，不为它额外请求正文
    private func prewarm(around p: PagePointer, pageCount: Int) {
        var chapters: [Int] = []
        if p.page >= pageCount - 3, session.chapters.indices.contains(p.chapter + 1) {
            session.ensureLoaded(p.chapter + 1)
            chapters.append(p.chapter + 1)
        }
        if p.page <= 2, p.chapter > 0 { chapters.append(p.chapter - 1) }
        for chapter in chapters where layouts[chapter] == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(pointer.chapter - chapter) == 1 else { return }
                _ = layout(chapter)
            }
        }
    }

    private func savePosition() {
        guard session.chapters.indices.contains(pointer.chapter) else { return }
        let offset: Int
        if theme.web, let webRange, webRange.chapter == pointer.chapter {
            offset = webRange.range.lowerBound
        } else if let pending = pendingOffset, pending > 0, pointer.page <= 0 {
            offset = pending
        } else if let layout = layouts[pointer.chapter], pointer.page >= 0 {
            offset = layout.stableRange(ofPage: min(pointer.page, layout.pageCount - 1)).lowerBound
        } else if pointer.page == -1 {
            offset = Int.max
        } else {
            offset = pendingOffset ?? 0
        }
        session.updatePosition(ReadingPosition(chapterIndex: pointer.chapter, offset: offset))
    }

    /// 跳到某章的指定位置（目录、书签、滑块）
    func jump(chapter: Int, offset: Int = 0) {
        guard session.chapters.indices.contains(chapter) else { return }
        pointer = PagePointer(chapter: chapter, page: 0)
        pendingOffset = offset
        webRange = nil
        jumpToken += 1
        session.updatePosition(ReadingPosition(chapterIndex: chapter, offset: offset))
        resolvePending()
        version += 1
    }

    // MARK: - 网页模式

    /// 网页翻页或滚动停住后回报看到的范围
    func noteWeb(chapter: Int, range: Range<Int>) {
        guard session.chapters.indices.contains(chapter) else { return }
        webRange = (chapter, range)
        pendingOffset = nil
        // 只在换章时动 pointer：每页都改会让阅读页整体重新求值，拖慢网页的系统滚动
        if chapter != pointer.chapter { pointer = PagePointer(chapter: chapter, page: 0) }
        session.updatePosition(ReadingPosition(chapterIndex: chapter, offset: range.lowerBound))
    }

    /// 网页翻过章首章尾：换到相邻章，`offset` 为 `Int.max` 时停在章末
    func webMove(to chapter: Int, offset: Int) {
        guard session.chapters.indices.contains(chapter) else { return }
        webRange = nil
        pointer = PagePointer(chapter: chapter, page: 0)
        pendingOffset = offset
        session.updatePosition(ReadingPosition(chapterIndex: chapter, offset: offset))
        session.ensureLoaded(chapter)
        if chapter + 1 < chapterCount { session.ensureLoaded(chapter + 1) }
    }

    func retry(_ chapter: Int) {
        Task {
            await session.load(chapter, refresh: true)
            chaptersChanged()
        }
    }

    // MARK: - 显示信息

    func header(for p: PagePointer, page: Int) -> String {
        guard session.chapters.indices.contains(p.chapter) else { return book.name }
        return page == 0 ? book.name : (session.text(of: p.chapter)?.title ?? session.chapters[p.chapter].title)
    }

    /// 皮肤页眉页脚需要的信息
    func chrome(for pointer: PagePointer, layout: ChapterLayout, page: Int) -> ReaderSkin.Chrome {
        let count = max(1, chapterCount)
        let fraction = (Double(layout.chapterIndex) + Double(page + 1) / Double(max(1, layout.pageCount))) / Double(count)
        return ReaderSkin.Chrome(header: header(for: pointer, page: page), page: page, pageCount: layout.pageCount,
                                 progress: min(1, fraction), percent: footer(for: layout, page: page).1)
    }

    /// 章节序号：优先取章节名里的「第 N 章」，没有时用目录位置
    func chapterNumber(_ chapter: Int) -> Int {
        let title = session.text(of: chapter)?.title ?? (session.chapters.indices.contains(chapter) ? session.chapters[chapter].title : nil)
        return ChapterTitle.value(title) ?? chapter + 1
    }

    func footer(for layout: ChapterLayout, page: Int) -> (String, String) {
        let count = max(1, chapterCount)
        let fraction = (Double(layout.chapterIndex) + Double(page + 1) / Double(max(1, layout.pageCount))) / Double(count)
        return ("\(page + 1) / \(layout.pageCount)", String(format: "%.1f%%", min(100, fraction * 100)))
    }

    /// 页眉：主题脚本的 `header(ctx)`，没有时为书名 / 章名
    func headerText(for p: PagePointer, layout: ChapterLayout, page: Int) -> ReaderChromeText {
        if let script = themeScript, script.hasHeader, let value = script.header(scriptContext(layout: layout, page: page)) {
            return value
        }
        return ReaderChromeText(left: header(for: p, page: page))
    }

    /// 页脚：主题脚本的 `footer(ctx)`，没有时左边页码、右边全书进度
    func footerText(for layout: ChapterLayout, page: Int) -> ReaderChromeText {
        if let script = themeScript, script.hasFooter, let value = script.footer(scriptContext(layout: layout, page: page)) {
            return value
        }
        let value = footer(for: layout, page: page)
        return ReaderChromeText(left: value.0, right: value.1)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func scriptContext(layout: ChapterLayout, page: Int) -> ReaderScriptContext {
        let count = max(1, chapterCount)
        let fraction = (Double(layout.chapterIndex) + Double(page + 1) / Double(max(1, layout.pageCount))) / Double(count)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        let chapter = session.text(of: layout.chapterIndex)?.title
            ?? (session.chapters.indices.contains(layout.chapterIndex) ? session.chapters[layout.chapterIndex].title : "")
        return ReaderScriptContext(book: book.name, author: book.author, chapter: chapter, chapterIndex: layout.chapterIndex,
                                   chapterCount: count, page: page + 1, pages: layout.pageCount,
                                   percent: min(100, fraction * 100), time: Self.clock.string(from: Date()),
                                   battery: level < 0 ? -1 : Int((level * 100).rounded()))
    }

    var currentTitle: String {
        guard session.chapters.indices.contains(pointer.chapter) else { return book.name }
        return session.chapters[pointer.chapter].title
    }

    /// 当前页的稳定偏移范围（朗读起点、书签）
    var currentRange: Range<Int>? {
        if theme.web, let webRange, webRange.chapter == pointer.chapter { return webRange.range }
        guard pointer.page >= 0, let layout = layouts[pointer.chapter] else { return nil }
        return layout.stableRange(ofPage: pointer.page)
    }

    /// 朗读进行到某个偏移时，若已超出当前页则翻到所在页（下一页用翻页动画）
    func follow(spoken offset: Int, chapter: Int) {
        if theme.web, let onWebFollow {
            onWebFollow(chapter, offset)
            return
        }
        guard let layout = layouts[chapter] else { return }
        let page = layout.pageIndex(forStableOffset: offset)
        if chapter == pointer.chapter, page == pointer.page { return }
        if chapter == pointer.chapter, page == pointer.page + 1, let onTurnRequest {
            onTurnRequest(true)
            return
        }
        pointer = PagePointer(chapter: chapter, page: page)
        savePosition()
        version += 1
    }

    func setSpoken(_ range: NSRange?, chapter: Int) {
        if let range, let spoken, spoken.chapter == chapter, spoken.range == range { return }
        if range == nil, spoken == nil { return }
        spoken = range.map { (chapter, $0) }
        onSpokenChange?()
    }

    /// 朗读句子落在该页的部分，每行一个矩形（正文区域坐标，高度取字面）
    func spokenRects(chapter: Int, page: Int) -> [CGRect] {
        guard let spoken, spoken.chapter == chapter, let layout = layouts[chapter], let text = texts[chapter],
              layout.pageRanges.indices.contains(page) else { return [] }
        let string = text.string as NSString
        let start = layout.offsets.layoutOffset(forStable: spoken.range.location)
        var end = min(layout.offsets.layoutOffset(forStable: NSMaxRange(spoken.range)), string.length)
        while end > start, let scalar = UnicodeScalar(string.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end -= 1
        }
        guard end > start else { return [] }
        let range = NSIntersectionRange(NSRange(location: start, length: end - start), layout.pageRanges[page])
        guard range.length > 0 else { return [] }
        return replica(chapter)?.lineRects(for: range, page: page) ?? []
    }

    func isBookmarked(in marks: [Bookmark]) -> Bool {
        guard let range = currentRange else { return false }
        return marks.contains { $0.chapterIndex == pointer.chapter && (range.contains($0.chapterPos) || range.lowerBound == $0.chapterPos) }
    }
}
#endif  // #if canImport(UIKit)
