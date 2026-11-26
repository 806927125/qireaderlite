#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/Comic/ComicStripController.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/Comic/ComicStripController.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import UIKit

/// 条漫：所有已取到的章节首尾相接排成一条，只为视口附近的图创建视图；整条一起缩放
final class ComicStripController: ComicStageController, UIScrollViewDelegate {
    private enum Row: Hashable {
        case image(ComicPage)
        /// 相邻章节加载中或失败
        case status(Int)
    }

    private let scroll = UIScrollView()
    private let canvas = UIView()
    private var rows: [Row] = []
    private var tops: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var total: CGFloat = 0
    private var lower = 0
    private var upper = 0
    private var tiles: [ComicPage: ComicTileView] = [:]
    private var statuses: [Int: ComicStatusView] = [:]
    private var spare: [ComicTileView] = []
    private var width: CGFloat = 0
    private var restored = false
    private var pendingReload = false
    private var lastOffset: CGFloat = 0
    private let doubleTap = UITapGestureRecognizer()

    private static let statusHeight: CGFloat = 220
    private static let placeholderAspect: CGFloat = 4.0 / 3.0

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 3
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.scrollsToTop = false
        scroll.addSubview(canvas)
        view.addSubview(scroll)
        scroll.panGestureRecognizer.require(toFail: edge)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        doubleTap.delegate = self
        scroll.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: doubleTap)
        tap.delegate = self
        scroll.addGestureRecognizer(tap)

        lower = model.current.chapter
        upper = lower
        model.onChapterChange = { [weak self] chapter in self?.chapterChanged(chapter) }
        model.images.onUpdate = { [weak self] page in self?.imageUpdated(page) }
        model.onSeek = { [weak self] page in self?.seek(page) }
    }

    override var edgeAllowed: Bool {
        scroll.zoomScale <= 1.01 || scroll.contentOffset.x <= 1
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.width != width else { return }
        width = view.bounds.width
        model.images.pixelWidth = width * view.traitCollection.displayScale
        reload()
        if !restored {
            restored = true
            seek(model.current)
        }
    }

    // MARK: - 版面

    private func buildRows() {
        var list: [Row] = []
        if let previous = model.neighbor(lower, -1), model.chapters[previous] != nil, model.sources(previous) == nil {
            list.append(.status(previous))
        }
        for chapter in lower...upper {
            guard let sources = model.sources(chapter) else { continue }
            list += sources.indices.map { .image(ComicPage(chapter: chapter, page: $0)) }
        }
        if let next = model.neighbor(upper, 1), model.chapters[next] != nil, model.sources(next) == nil {
            list.append(.status(next))
        }
        rows = list
    }

    private func measure() {
        tops = []
        heights = []
        var y: CGFloat = 0
        for row in rows {
            let height: CGFloat
            switch row {
            case .image(let page): height = (width * (model.images.aspect(page) ?? Self.placeholderAspect)).rounded()
            case .status: height = Self.statusHeight
            }
            tops.append(y)
            heights.append(height)
            y += height
        }
        total = y
    }

    private func applySize() {
        let zoom = scroll.zoomScale
        canvas.bounds = CGRect(x: 0, y: 0, width: width, height: total)
        canvas.center = CGPoint(x: width * zoom / 2, y: total * zoom / 2)
        scroll.contentSize = CGSize(width: width * zoom, height: total * zoom)
    }

    private var viewTop: CGFloat { scroll.contentOffset.y / scroll.zoomScale }
    private var viewHeight: CGFloat { scroll.bounds.height / scroll.zoomScale }

    /// 行数变化或图片尺寸更新后重排，视口顶端那张图在屏幕上的位置保持不动
    private func reload() {
        guard width > 0 else { return }
        if scroll.isZooming || scroll.isZoomBouncing {
            pendingReload = true
            return
        }
        pendingReload = false
        let anchor = captureAnchor()
        buildRows()
        measure()
        applySize()
        if let anchor, let index = rows.firstIndex(of: anchor.row) {
            let y = tops[index] + anchor.fraction * heights[index] - anchor.gap
            setOffset(y * scroll.zoomScale)
        }
        layoutTiles()
    }

    private func captureAnchor() -> (row: Row, fraction: CGFloat, gap: CGFloat)? {
        guard !rows.isEmpty, let index = rowIndex(at: viewTop) else { return nil }
        if case .image = rows[index] {
            return (rows[index], (viewTop - tops[index]) / max(heights[index], 1), 0)
        }
        guard let next = rows[index...].firstIndex(where: { if case .image = $0 { true } else { false } }) else { return nil }
        return (rows[next], 0, tops[next] - viewTop)
    }

    private func setOffset(_ y: CGFloat) {
        var y = y
        if !scroll.isTracking {
            y = min(y, max(0, scroll.contentSize.height - scroll.bounds.height))
            y = max(0, y)
        }
        scroll.contentOffset.y = y
        lastOffset = y
    }

    private func rowIndex(at y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0, high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: - 可见格子

    private func layoutTiles() {
        guard let first = rowIndex(at: viewTop - viewHeight * 0.5) else {
            tiles.values.forEach(recycle)
            tiles.removeAll()
            statuses.values.forEach { $0.removeFromSuperview() }
            statuses.removeAll()
            return
        }
        let bottom = viewTop + viewHeight * 1.5
        var index = first
        var keepPages: Set<ComicPage> = []
        var keepStatus: Set<Int> = []
        while index < rows.count, tops[index] < bottom {
            let frame = CGRect(x: 0, y: tops[index], width: width, height: heights[index])
            switch rows[index] {
            case .image(let page):
                keepPages.insert(page)
                let tile = tiles[page] ?? dequeue(page)
                if tile.frame != frame { tile.frame = frame }
            case .status(let chapter):
                keepStatus.insert(chapter)
                let status = statuses[chapter] ?? makeStatus(chapter)
                status.frame = frame
                status.show(model.chapters[chapter])
            }
            index += 1
        }
        for (page, tile) in tiles where !keepPages.contains(page) {
            recycle(tile)
            tiles[page] = nil
        }
        for (chapter, status) in statuses where !keepStatus.contains(chapter) {
            status.removeFromSuperview()
            statuses[chapter] = nil
        }
    }

    private func dequeue(_ page: ComicPage) -> ComicTileView {
        let tile = spare.popLast() ?? ComicTileView()
        tile.onRetry = { [weak self] in
            guard let self, let src = model.source(page) else { return }
            model.images.retry(page, src: src)
        }
        tile.show(page, image: model.images.image(page), failed: model.images.failed(page))
        canvas.addSubview(tile)
        tiles[page] = tile
        return tile
    }

    private func recycle(_ tile: ComicTileView) {
        tile.removeFromSuperview()
        tile.imageView.image = nil
        if spare.count < 12 { spare.append(tile) }
    }

    private func makeStatus(_ chapter: Int) -> ComicStatusView {
        let status = ComicStatusView()
        status.onRetry = { [weak self] in self?.model.retry(chapter) }
        canvas.addSubview(status)
        statuses[chapter] = status
        return status
    }

    // MARK: - 变化

    private func chapterChanged(_ chapter: Int) {
        if model.sources(chapter) != nil {
            if chapter == model.neighbor(upper, 1) {
                upper = chapter
            } else if chapter == model.neighbor(lower, -1) {
                lower = chapter
            } else {
                return
            }
        } else if chapter != model.neighbor(upper, 1), chapter != model.neighbor(lower, -1) {
            return
        }
        reload()
        prefetch()
    }

    private func imageUpdated(_ page: ComicPage) {
        guard let index = rows.firstIndex(of: .image(page)) else { return }
        let height = (width * (model.images.aspect(page) ?? Self.placeholderAspect)).rounded()
        tiles[page]?.show(page, image: model.images.image(page), failed: model.images.failed(page))
        if abs(height - heights[index]) > 0.5 { reload() }
    }

    func seek(_ page: ComicPage) {
        guard (lower...upper).contains(page.chapter), let index = rows.firstIndex(of: .image(page)) else {
            model.jump(chapter: page.chapter, page: page.page)
            return
        }
        // 先停住惯性，否则跳转后还会继续滑走
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        setOffset(tops[index] * scroll.zoomScale)
        layoutTiles()
        report()
    }

    // MARK: - 当前位置、预取与接章

    private func report() {
        guard let index = rowIndex(at: viewTop + 1) else { return }
        var target = index
        // 拉到底时最后一张算作当前
        if scroll.contentOffset.y >= scroll.contentSize.height - scroll.bounds.height - 2,
           let last = rows.lastIndex(where: { if case .image = $0 { true } else { false } }) {
            target = last
        }
        if case .image(let page) = rows[target] {
            model.didView(page)
        } else if let next = rows[target...].first(where: { if case .image = $0 { true } else { false } }), case .image(let page) = next {
            model.didView(page)
        }
        prefetch()
    }

    private func prefetch() {
        guard let first = rowIndex(at: viewTop) else { return }
        let bottom = viewTop + viewHeight
        var visible: [Int] = []
        var index = first
        while index < rows.count, tops[index] < bottom {
            visible.append(index)
            index += 1
        }
        var order = visible
        var ahead = 0
        while index < rows.count, ahead < 6 {
            if case .image = rows[index] { order.append(index); ahead += 1 }
            index += 1
        }
        order += (max(0, first - 2)..<first).reversed()
        let list: [(ComicPage, String)] = order.compactMap { i in
            guard case .image(let page) = rows[i], let src = model.source(page) else { return nil }
            return (page, src)
        }
        model.images.want(list)
    }

    private func extendIfNeeded() {
        let top = viewTop
        if total - (top + viewHeight) < viewHeight * 1.5, let next = model.neighbor(upper, 1) {
            model.request(next)
        }
        // 往上滑才去取上一章，打开时停在章首不额外消耗正文额度
        let movingUp = scroll.contentOffset.y < lastOffset && (scroll.isTracking || scroll.isDecelerating)
        if movingUp, top < viewHeight, let previous = model.neighbor(lower, -1) {
            model.request(previous)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard restored else { return }
        layoutTiles()
        extendIfNeeded()
        lastOffset = scrollView.contentOffset.y
        report()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        hideMenu()
    }

    // MARK: - 缩放

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        layoutTiles()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if pendingReload { reload() }
        prefetch()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
            return
        }
        let point = recognizer.location(in: canvas)
        let size = CGSize(width: scroll.bounds.width / 2, height: scroll.bounds.height / 2)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc private func handleTap() {
        onCenterTap?()
    }
}

#endif  // #if os(iOS)
