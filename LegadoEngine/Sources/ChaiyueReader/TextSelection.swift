// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if os(iOS)
import ChaiyueReaderKit
import ChaiyueModels
import ChaiyueReaderServices
import UIKit

enum TextAction {
    case copy, bookmark, speak, lookUp, share
}

/// 选中的文字及其在章内的位置（稳定偏移，朗读与书签使用）
struct TextPick {
    let text: String
    let chapter: Int
    let offset: Int
}

/// 长按选字：在正文上盖一层与分页排版完全一致的透明 UITextView，选择手柄与编辑菜单都用系统的。
/// 文字用同一份富文本、同样大小的容器从章首逐页排到当前页，所以字的位置与绘制出来的页面重合
final class TextSelection: NSObject, UITextViewDelegate, UIEditMenuInteractionDelegate {
    private let model: ReaderModel
    private(set) var textView: UITextView?
    private var storage: NSTextStorage?
    private var layout: ChapterLayout?
    private var chapter = 0
    private var menu: UIEditMenuInteraction?
    /// 开始或结束选字时调用（翻页视图据此暂停翻页手势）
    var onActiveChange: ((Bool) -> Void)?

    init(model: ReaderModel) {
        self.model = model
    }

    var isActive: Bool { textView != nil }

    /// `frame` 为正文区域在 `host` 中的位置，`point` 为长按位置（`host` 坐标）
    @discardableResult
    func begin(in host: UIView, frame: CGRect, pointer: PagePointer, at point: CGPoint) -> Bool {
        end()
        guard frame.contains(point), let source = model.selectionSource(chapter: pointer.chapter) else { return false }
        let layout = source.layout
        let page = pointer.page < 0 ? layout.pageCount - 1 : min(pointer.page, layout.pageCount - 1)
        guard page >= 0 else { return false }

        let text = NSMutableAttributedString(attributedString: source.text)
        text.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(location: 0, length: text.length))
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        layout.prepare(manager)
        storage.addLayoutManager(manager)
        var container = layout.makeContainer(forPage: 0)
        for index in 0...page {
            if index > 0 { container = layout.makeContainer(forPage: index) }
            manager.addTextContainer(container)
            _ = manager.glyphRange(for: container)
        }

        let view = SelectionTextView(frame: frame, textContainer: container)
        view.textContainerInset = .zero
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.tintColor = UIColor(hex: 0xE0A100)
        view.delegate = self
        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)

        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let visible = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
        let index = manager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard visible.length > 0, NSLocationInRange(index, visible) else { return false }

        host.addSubview(view)
        textView = view
        self.storage = storage
        self.layout = layout
        self.menu = menu
        chapter = pointer.chapter
        view.selectedRange = Self.wordRange(at: index, in: storage.string as NSString, within: visible)
        view.becomeFirstResponder()
        onActiveChange?(true)
        DispatchQueue.main.async { [weak self] in self?.showMenu() }
        return true
    }

    func end() {
        guard let view = textView else { return }
        textView = nil
        menu?.dismissMenu()
        view.resignFirstResponder()
        view.removeFromSuperview()
        storage = nil
        layout = nil
        menu = nil
        onActiveChange?(false)
    }

    /// 长按处的词；落在标点或行尾空白上时取前面最近的词
    private static func wordRange(at index: Int, in string: NSString, within limit: NSRange) -> NSRange {
        var target = min(index, NSMaxRange(limit) - 1)
        let skipped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        while target > limit.location, let scalar = UnicodeScalar(string.character(at: target)), skipped.contains(scalar) {
            target -= 1
        }
        var found = string.rangeOfComposedCharacterSequence(at: target)
        let window = NSIntersectionRange(limit, NSRange(location: max(limit.location, target - 24), length: 48))
        string.enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(target, range) {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private var selectionRect: CGRect {
        guard let view = textView, view.selectedRange.length > 0 else { return .zero }
        let manager = view.layoutManager
        let glyphs = manager.glyphRange(forCharacterRange: view.selectedRange, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
    }

    private func showMenu() {
        guard let menu, isActive else { return }
        let rect = selectionRect
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    private func makeMenu() -> UIMenu {
        func item(_ title: String, _ symbol: String, _ action: TextAction) -> UIAction {
            UIAction(title: title, image: UIImage.icon(symbol)) { [weak self] _ in self?.perform(action) }
        }
        return UIMenu(children: [
            item("复制", "doc.on.doc", .copy),
            item("书签", "bookmark", .bookmark),
            item("朗读", "headphones", .speak),
            item("查词", "character.book.closed", .lookUp),
            item("分享", "square.and.arrow.up", .share),
        ])
    }

    private func perform(_ action: TextAction) {
        guard let view = textView, let storage, let layout else { return }
        let range = view.selectedRange
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        // 图片、段评气泡是附件字符，不算选中的文字
        let text = (storage.string as NSString).substring(with: range).replacingOccurrences(of: InlineImage.inlineMark, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pick = TextPick(text: text, chapter: chapter, offset: layout.offsets.stableOffset(forLayout: range.location))
        end()
        model.onTextAction?(action, pick)
    }

    // MARK: - UITextViewDelegate

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        makeMenu()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.selectedRange.length == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textView === textView, textView.selectedRange.length == 0 else { return }
            end()
        }
    }

    // MARK: - UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        makeMenu()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectionRect
    }
}

/// 与 ChapterLayout 排版一致的 TextKit 副本（ReaderKit 不公开排版对象），用于取某段文字在页内的位置
final class TextReplica {
    let layout: ChapterLayout
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let containers: [NSTextContainer]

    init(text: NSAttributedString, layout: ChapterLayout) {
        self.layout = layout
        storage = NSTextStorage(attributedString: text)
        layout.prepare(manager)
        storage.addLayoutManager(manager)
        containers = layout.pageRanges.indices.map { layout.makeContainer(forPage: $0) }
        // 与 ChapterPaginator 一样逐页加容器并立即排版；一次加齐再排，含图片的页断行会不同
        for container in containers {
            manager.addTextContainer(container)
            _ = manager.glyphRange(for: container)
        }
    }

    /// 整章不分页连续排版（滚动模式的页间距离以它为准；分页时页末一行的行距会被容器截掉）
    private lazy var flow: (manager: NSLayoutManager, container: NSTextContainer) = {
        let flowManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: layout.pageSize.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        flowManager.addTextContainer(container)
        storage.addLayoutManager(flowManager)
        return (flowManager, container)
    }()

    /// 连续排版时该排版偏移所在行的顶边；超出全文时为全文底边
    func flowY(atCharacter index: Int) -> CGFloat {
        let (flowManager, container) = flow
        guard index < storage.length else { return flowManager.usedRect(for: container).maxY }
        let glyph = flowManager.glyphIndexForCharacter(at: index)
        return flowManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// 排版字符范围在该页内每行一个矩形，高度取字体的上下沿，不含行距与段距
    func lineRects(for range: NSRange, page: Int) -> [CGRect] {
        guard containers.indices.contains(page), NSMaxRange(range) <= storage.length else { return [] }
        let container = containers[page]
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, owner, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard owner === container, part.length > 0 else { return }
            var box = self.manager.boundingRect(forGlyphRange: part, in: container)
            let index = self.manager.characterIndexForGlyph(at: part.location)
            if let font = self.storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont {
                let baseline = line.minY + self.manager.location(forGlyphAt: part.location).y
                box.origin.y = baseline - font.ascender
                box.size.height = font.ascender - font.descender
            }
            rects.append(box)
        }
        return rects
    }
}

/// 系统按行片段高度画选区，段末一行会把段间距也涂上；收到字形实际占用的高度
private final class SelectionTextView: UITextView {
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        super.selectionRects(for: range).map { item in
            let rect = item.rect
            guard rect.height > 0, !rect.isInfinite else { return item }
            let glyph = layoutManager.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: textContainer)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let top = max(rect.minY, used.minY), bottom = min(rect.maxY, used.maxY)
            guard bottom - top > 1, bottom - top < rect.height - 0.5 else { return item }
            return TrimmedSelectionRect(base: item, rect: CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top))
        }
    }
}

private final class TrimmedSelectionRect: UITextSelectionRect {
    private let base: UITextSelectionRect
    private let trimmed: CGRect

    init(base: UITextSelectionRect, rect: CGRect) {
        self.base = base
        trimmed = rect
    }

    override var rect: CGRect { trimmed }
    override var writingDirection: NSWritingDirection { base.writingDirection }
    override var containsStart: Bool { base.containsStart }
    override var containsEnd: Bool { base.containsEnd }
    override var isVertical: Bool { base.isVertical }
}

enum ReaderTextActions {
    static func perform(_ action: TextAction, _ pick: TextPick, app: AppModel, model: ReaderModel) {
        switch action {
        case .copy:
            UIPasteboard.general.string = pick.text
            app.island.show("doc.on.doc", "已复制")
        case .bookmark:
            model.session.addBookmark(at: ReadingPosition(chapterIndex: pick.chapter, offset: pick.offset))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            app.island.show("bookmark.fill", "已添加书签")
        case .speak:
            guard let text = model.session.text(of: pick.chapter) else { return }
            ReaderSpeech.speak(app: app, model: model, text: text, from: pick.offset)
        case .lookUp:
            guard let top = SourcePresenter.topController() else { return }
            top.present(UIReferenceLibraryViewController(term: pick.text), animated: true)
        case .share:
            Share.present([pick.text])
        }
    }
}
#endif  // #if canImport(UIKit)
