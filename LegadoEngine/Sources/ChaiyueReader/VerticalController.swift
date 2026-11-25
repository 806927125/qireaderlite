#if os(iOS)
// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
import ChaiyueReaderKit
import SwiftUI
import UIKit

/// 滚动模式：章节连续纵向排列，按页切条绘制
final class VerticalController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    let model: ReaderModel
    var onCenterTap: (() -> Void)?

    private var chapters: [Int] = []
    private var collection: UICollectionView!
    private let paper = PaperBackdrop()
    private let clip = UIView()
    private let titleLabel = UILabel()
    private let fade = CAGradientLayer()
    private var reported: PagePointer?
    private var restoring = false
    /// 正文排好后才按保存的进度滚一次；在这之前停在占位页
    private var appliedPlacement = false
    /// 用户自己滚动或点按翻页之后才允许写入进度，避免刚打开时的占位页把上次的位置盖成开头
    private var userMoved = false
    private lazy var selection = TextSelection(model: model)

    private static let topInset: CGFloat = 100
    private static let bottomInset: CGFloat = 140
    private static let chapterGap: CGFloat = 56
    private static let placeholderHeight: CGFloat = 320

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        paper.frame = view.bounds
        paper.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(paper)

        // 纸面颗粒铺在底层不随内容滚动，正文条透明；顶部用遮罩让正文淡出到纸面上
        clip.frame = view.bounds
        clip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        clip.layer.mask = fade
        view.addSubview(clip)

        collection = UICollectionView(frame: clip.bounds, collectionViewLayout: layout)
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset = UIEdgeInsets(top: Self.topInset, left: 0, bottom: Self.bottomInset, right: 0)
        collection.showsVerticalScrollIndicator = false
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(StripCell.self, forCellWithReuseIdentifier: "strip")
        clip.addSubview(collection)

        titleLabel.font = .systemFont(ofSize: 11)
        view.addSubview(titleLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        collection.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.4
        press.delegate = self
        collection.addGestureRecognizer(press)
        model.commitVisible = { [weak self] in self?.commitReadingPosition() }
        rebuild(to: model.verticalPlacement())
        #if DEBUG
        debugSelect()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = model.metrics?.headerY ?? 62
        // 章名一行之下正文完全隐去，之后在正文起点之前渐显
        let height = max(top + 24, min(top + 38, Self.topInset))
        let total = max(view.bounds.height, height + 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        fade.locations = [0, NSNumber(value: Double((top + 16) / total)), NSNumber(value: Double(height / total)), 1]
        CATransaction.commit()
        let inset = model.metrics?.textFrame.minX ?? 26
        titleLabel.frame = CGRect(x: inset, y: top, width: view.bounds.width - inset * 2, height: 14)
    }

    private func applyTheme() {
        let theme = model.theme
        view.backgroundColor = theme.uiBackground
        paper.theme = theme
        titleLabel.textColor = theme.uiSecondary
    }

    // MARK: - 数据

    /// 排版、主题或进度跳转后刷新
    func reload() {
        selection.end()
        let place = model.verticalPlacement()
        if !appliedPlacement, model.layout(place.0.chapter) != nil {
            rebuild(to: place)
            return
        }
        if let reported, reported != place.0 {
            rebuild(to: place)
        } else {
            let anchor = currentAnchor()
            applyTheme()
            collection.reloadData()
            if let anchor { restore(anchor) }
            extendIfNeeded()
        }
    }

    private func rebuild(to place: (PagePointer, CGFloat)) {
        applyTheme()
        chapters = [place.0.chapter]
        collection.reloadData()
        restore(place)
        if model.layout(place.0.chapter) != nil { appliedPlacement = true }
        extendIfNeeded()
    }

    private func items(in chapter: Int) -> Int {
        model.layout(chapter)?.pageCount ?? 1
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { chapters.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items(in: chapters[section])
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "strip", for: indexPath) as! StripCell
        let chapter = chapters[indexPath.section]
        let pointer = PagePointer(chapter: chapter, page: indexPath.item)
        let isLast = indexPath.item == items(in: chapter) - 1 && chapter + 1 < model.chapterCount
        cell.strip.configure(model.content(pointer), theme: model.theme, inset: model.metrics?.textFrame.minX ?? 26,
                             separator: isLast && model.layout(chapter) != nil ? Self.chapterGap : 0)
        cell.strip.chapterNumber = model.chapterNumber(chapter)
        cell.strip.fontSize = CGFloat(model.settings.fontSize)
        cell.strip.spoken = model.spokenRects(chapter: chapter, page: indexPath.item)
        cell.strip.onRetry = { [weak self] in self?.model.retry(chapter) }
        return cell
    }

    func refreshSpoken() {
        for case let cell as StripCell in collection.visibleCells {
            guard let indexPath = collection.indexPath(for: cell) else { continue }
            cell.strip.spoken = model.spokenRects(chapter: chapters[indexPath.section], page: indexPath.item)
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let chapter = chapters[indexPath.section]
        let width = collectionView.bounds.width
        guard let layout = model.layout(chapter), let metrics = model.metrics else {
            return CGSize(width: width, height: Self.placeholderHeight)
        }
        let pageHeight = metrics.textFrame.height
        guard indexPath.item == layout.pageCount - 1 else {
            return CGSize(width: width, height: model.flowHeight(chapter: chapter, page: indexPath.item) ?? pageHeight)
        }
        let used = model.usedHeight(chapter: chapter, page: indexPath.item) ?? pageHeight
        return CGSize(width: width, height: min(pageHeight, used + 8) + Self.chapterGap)
    }

    // MARK: - 位置

    private func pointer(at indexPath: IndexPath) -> PagePointer {
        PagePointer(chapter: chapters[indexPath.section], page: indexPath.item)
    }

    private func indexPath(for pointer: PagePointer) -> IndexPath? {
        guard let section = chapters.firstIndex(of: pointer.chapter) else { return nil }
        let count = items(in: pointer.chapter)
        let item = pointer.page < 0 ? count - 1 : min(pointer.page, count - 1)
        return IndexPath(item: max(0, item), section: section)
    }

    private func readingLine() -> CGFloat {
        collection.contentOffset.y + Self.topInset
    }

    private func currentAnchor() -> (PagePointer, CGFloat)? {
        let y = readingLine()
        let point = CGPoint(x: collection.bounds.midX, y: y)
        guard let indexPath = collection.indexPathForItem(at: point) ?? collection.indexPathsForVisibleItems.min(),
              let attributes = collection.layoutAttributesForItem(at: indexPath) else { return nil }
        return (pointer(at: indexPath), y - attributes.frame.minY)
    }

    private func restore(_ anchor: (PagePointer, CGFloat)) {
        collection.layoutIfNeeded()
        guard let indexPath = indexPath(for: anchor.0),
              let attributes = collection.layoutAttributesForItem(at: indexPath) else { return }
        restoring = true
        let maxY = max(-Self.topInset, collection.contentSize.height - collection.bounds.height + Self.bottomInset)
        collection.contentOffset.y = min(maxY, attributes.frame.minY + anchor.1 - Self.topInset)
        restoring = false
        report()
    }

    private func report() {
        guard let anchor = currentAnchor() else { return }
        titleLabel.text = model.session.chapters.indices.contains(anchor.0.chapter) ? model.session.chapters[anchor.0.chapter].title : ""
        guard anchor.0 != reported else { return }
        reported = anchor.0
        model.didShow(anchor.0)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring else { return }
        report()
        extendIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userMoved = true
        selection.end()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        commitReadingPosition()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitReadingPosition()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        commitReadingPosition()
    }

    private func commitReadingPosition() {
        guard userMoved, !restoring, let anchor = currentAnchor(), let metrics = model.metrics else { return }
        let height = model.flowHeight(chapter: anchor.0.chapter, page: max(0, anchor.0.page)) ?? metrics.textFrame.height
        model.noteVisible(chapter: anchor.0.chapter, page: anchor.0.page, y: anchor.1, height: height)
    }

    /// 接近两端时接上前后章；后面的章已排好时连续接上，短章不会把内容卡在一屏以内
    private func extendIfNeeded() {
        let height = collection.bounds.height
        while let last = chapters.last, collection.contentOffset.y + height * 2.5 > collection.contentSize.height,
              model.layout(last) != nil, last + 1 < model.chapterCount {
            chapters.append(last + 1)
            model.session.ensureLoaded(last + 1)
            let anchor = currentAnchor()
            collection.reloadData()
            if let anchor { restore(anchor) } else { collection.layoutIfNeeded() }
        }
        guard let first = chapters.first else { return }
        let offset = collection.contentOffset.y
        if offset < height * 1.5, model.layout(first) != nil, first > 0 {
            let anchor = currentAnchor()
            chapters.insert(first - 1, at: 0)
            model.session.ensureLoaded(first - 1)
            collection.reloadData()
            if let anchor { restore(anchor) }
        }
        if chapters.count > 6, let anchor = currentAnchor() {
            chapters.removeAll { abs($0 - anchor.0.chapter) > 2 }
            collection.reloadData()
            restore(anchor)
        }
    }

    // MARK: - 点按

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if selection.isActive {
            selection.end()
            return
        }
        if !model.menuVisible, performTapTarget(at: recognizer.location(in: collection)) { return }
        let y = recognizer.location(in: view).y
        let height = view.bounds.height
        if model.menuVisible || (y > height / 3 && y < height * 2 / 3) {
            onCenterTap?()
            return
        }
        userMoved = true
        let step = (height - Self.topInset - Self.bottomInset) * (y >= height * 2 / 3 ? 1 : -1)
        let maxY = max(-Self.topInset, collection.contentSize.height - height + Self.bottomInset)
        let target = min(maxY, max(-Self.topInset, collection.contentOffset.y + step))
        collection.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    /// 点在段评气泡或带点按脚本的图片上时执行它（`point` 为 collection 坐标）
    private func performTapTarget(at point: CGPoint) -> Bool {
        guard let indexPath = collection.indexPathForItem(at: point),
              let cell = collection.cellForItem(at: indexPath) as? StripCell,
              case .text(let layout, let page) = model.content(pointer(at: indexPath)) else { return false }
        let local = collection.convert(point, to: cell.strip)
        let inset = model.metrics?.textFrame.minX ?? 26
        guard let target = layout.tapTarget(at: CGPoint(x: local.x - inset, y: local.y), page: page) else { return false }
        model.perform(target, chapter: layout.chapterIndex)
        return true
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        beginSelection(at: recognizer.location(in: collection))
    }

    private func beginSelection(at point: CGPoint) {
        guard !model.menuVisible, let metrics = model.metrics,
              let indexPath = collection.indexPathForItem(at: point),
              let cell = collection.cellForItem(at: indexPath) as? StripCell else { return }
        let strip = cell.strip
        let frame = CGRect(x: metrics.textFrame.minX, y: 0, width: metrics.textFrame.width, height: strip.bounds.height)
        guard selection.begin(in: strip, frame: frame, pointer: pointer(at: indexPath), at: collection.convert(point, to: strip)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    #if DEBUG
    /// `-selectAt x,y`（屏幕坐标）：正文排好后在该点模拟长按
    private func debugSelect(attempt: Int = 0) {
        guard let raw = DebugLaunch.flag("selectAt"), attempt < 90 else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if attempt >= 3, model.layout(model.pointer.chapter) != nil {
                beginSelection(at: view.convert(CGPoint(x: parts[0], y: parts[1]), to: collection))
            }
            if !selection.isActive { debugSelect(attempt: attempt + 1) }
        }
    }
    #endif

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let textView = selection.textView, let touched = touch.view, touched.isDescendant(of: textView) { return false }
        return !(touch.view is UIControl)
    }

    /// 滚到相邻一页的顶部（朗读跟随）
    func turn(forward: Bool) {
        userMoved = true
        selection.end()
        guard let anchor = currentAnchor(), let current = indexPath(for: anchor.0) else { return }
        var target = current
        if forward {
            if current.item + 1 < collection.numberOfItems(inSection: current.section) {
                target.item += 1
            } else if current.section + 1 < collection.numberOfSections {
                target = IndexPath(item: 0, section: current.section + 1)
            } else {
                return
            }
        } else if anchor.1 <= 1 {
            if current.item > 0 {
                target.item -= 1
            } else if current.section > 0 {
                target = IndexPath(item: collection.numberOfItems(inSection: current.section - 1) - 1, section: current.section - 1)
            } else {
                return
            }
        }
        guard let attributes = collection.layoutAttributesForItem(at: target) else { return }
        let maxY = max(-Self.topInset, collection.contentSize.height - collection.bounds.height + Self.bottomInset)
        collection.setContentOffset(CGPoint(x: 0, y: min(maxY, attributes.frame.minY - Self.topInset)), animated: true)
    }
}

/// 滚动模式的纸面：底色 + 颗粒
final class PaperBackdrop: UIView {
    var theme: ReaderThemeSpec? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let theme, let context = UIGraphicsGetCurrentContext() else { return }
        theme.uiBackground.setFill()
        context.fill(bounds)
        PaperGrain.fill(bounds, strength: theme.grain, in: context)
        theme.skin?.backdrop(size: bounds.size)?.draw(at: .zero)
    }
}

final class StripCell: UICollectionViewCell {
    let strip = StripView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        strip.frame = contentView.bounds
        strip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 滚动模式的一条：一页正文，章末附分隔线
final class StripView: UIView {
    private var content: PageContent = .blank
    private var theme: ReaderThemeSpec?
    private var inset: CGFloat = 26
    private var separator: CGFloat = 0
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    var onRetry: (() -> Void)?
    var chapterNumber = 1
    var fontSize: CGFloat = 19
    /// 朗读中的句子（正文区域坐标）
    var spoken: [CGRect] = [] {
        didSet { if spoken != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        var config = UIButton.Configuration.plain()
        config.title = "重新加载"
        config.image = UIImage.icon("arrow.clockwise")
        config.imagePadding = 6
        config.baseForegroundColor = UIColor(hex: 0xC98A00)
        retry.configuration = config
        retry.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        addSubview(retry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: PageContent, theme: ReaderThemeSpec, inset: CGFloat, separator: CGFloat) {
        self.content = content
        self.theme = theme
        self.inset = inset
        self.separator = separator
        if case .loading = content {
            spinner.color = theme.uiSecondary
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        if case .failed = content { retry.isHidden = false } else { retry.isHidden = true }
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retry.sizeToFit()
        retry.center = CGPoint(x: bounds.midX, y: bounds.midY + 30)
    }

    override func draw(_ rect: CGRect) {
        guard let theme, let context = UIGraphicsGetCurrentContext() else { return }
        switch content {
        case .text(let layout, let page):
            if page == 0, let skin = theme.skin {
                skin.drawTitleDecor(layout: layout, origin: CGPoint(x: inset, y: 0), width: bounds.width - inset * 2,
                                    number: chapterNumber, theme: theme, fontSize: fontSize)
            }
            SpokenMark.fill(spoken, at: CGPoint(x: inset, y: 0), color: theme.uiMark)
            layout.draw(page: page, at: CGPoint(x: inset, y: 0))
            if separator > 0 {
                theme.uiSecondary.withAlphaComponent(0.35).setFill()
                let y = bounds.height - separator / 2
                context.fill(CGRect(x: bounds.midX - 18, y: y, width: 36, height: 1 / UIScreen.main.scale * 2))
            }
        case .loading(let title), .failed(let title, _):
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (title as NSString).draw(in: CGRect(x: inset, y: bounds.midY - 64, width: bounds.width - inset * 2, height: 24),
                                     withAttributes: [.font: UIFont.serif(17, bold: true), .foregroundColor: theme.uiText, .paragraphStyle: style])
        case .blank:
            break
        }
    }
}

struct VerticalReaderView: UIViewControllerRepresentable {
    let model: ReaderModel
    let version: Int
    let onCenterTap: () -> Void

    func makeUIViewController(context: Context) -> VerticalController {
        let controller = VerticalController(model: model)
        controller.onCenterTap = onCenterTap
        model.onTurnRequest = { [weak controller] forward in controller?.turn(forward: forward) }
        model.onSpokenChange = { [weak controller] in controller?.refreshSpoken() }
        context.coordinator.version = version
        return controller
    }

    func updateUIViewController(_ controller: VerticalController, context: Context) {
        controller.onCenterTap = onCenterTap
        guard context.coordinator.version != version else { return }
        context.coordinator.version = version
        controller.reload()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var version = 0
    }
}
#endif  // #if os(iOS)
