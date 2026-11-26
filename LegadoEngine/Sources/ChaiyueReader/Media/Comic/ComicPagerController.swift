#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/Comic/ComicPagerController.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/Comic/ComicPagerController.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import UIKit

/// 翻页：单页居中，左右拖动跟手，手感参数与正文平移翻页一致
final class ComicPagerController: ComicStageController {
    fileprivate enum Slot: Equatable {
        case page(ComicPage)
        /// 相邻章还没取到；`forward` 为进入它的方向
        case status(Int, forward: Bool)
    }

    private var currentView = ComicPageView()
    private var neighborView = ComicPageView()
    private var slot = Slot.page(ComicPage(chapter: 0, page: 0))
    private var target: (slot: Slot, forward: Bool)?
    private var animator: UIViewPropertyAnimator?
    private var rubberBanding = false
    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()

    override func viewDidLoad() {
        super.viewDidLoad()
        tap.addTarget(self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.require(toFail: edge)
        view.addGestureRecognizer(pan)
        for page in [neighborView, currentView] {
            page.frame = view.bounds
            page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.zoom.panGestureRecognizer.require(toFail: pan)
            tap.require(toFail: page.doubleTap)
            page.onRetry = { [weak self, weak page] in
                guard let self, let page, let slot = page.slot else { return }
                retry(slot)
            }
            view.addSubview(page)
        }
        neighborView.isHidden = true
        slot = .page(model.current)
        model.onChapterChange = { [weak self] chapter in self?.chapterChanged(chapter) }
        model.images.onUpdate = { [weak self] page in self?.imageUpdated(page) }
        model.onSeek = { [weak self] page in self?.seek(page) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0 else { return }
        let pixelWidth = view.bounds.width * view.traitCollection.displayScale
        guard currentView.slot == nil || model.images.pixelWidth != pixelWidth else { return }
        model.images.pixelWidth = pixelWidth
        show(slot)
    }

    override var edgeAllowed: Bool { currentView.atEdge(forward: false) }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan {
            let velocity = pan.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
            return animator?.state == .active || currentView.atEdge(forward: velocity.x < 0)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    // MARK: - 页序

    private func after(_ slot: Slot) -> Slot? {
        switch slot {
        case .page(let page):
            if let count = model.pageCount(page.chapter), page.page + 1 < count {
                return .page(ComicPage(chapter: page.chapter, page: page.page + 1))
            }
            return entry(model.neighbor(page.chapter, 1), forward: true)
        case .status(let chapter, let forward):
            return forward ? nil : entry(model.neighbor(chapter, 1), forward: true)
        }
    }

    private func before(_ slot: Slot) -> Slot? {
        switch slot {
        case .page(let page):
            if page.page > 0 { return .page(ComicPage(chapter: page.chapter, page: page.page - 1)) }
            return entry(model.neighbor(page.chapter, -1), forward: false)
        case .status(let chapter, let forward):
            return forward ? entry(model.neighbor(chapter, -1), forward: false) : nil
        }
    }

    private func entry(_ chapter: Int?, forward: Bool) -> Slot? {
        guard let chapter else { return nil }
        if let count = model.pageCount(chapter), count > 0 {
            return .page(ComicPage(chapter: chapter, page: forward ? 0 : count - 1))
        }
        model.request(chapter)
        return .status(chapter, forward: forward)
    }

    // MARK: - 显示

    private func configure(_ view: ComicPageView, _ slot: Slot) {
        switch slot {
        case .page(let page):
            view.showPage(page, image: model.images.image(page), aspect: model.images.aspect(page), failed: model.images.failed(page))
        case .status(let chapter, _):
            view.showStatus(chapter, state: model.chapters[chapter])
        }
        view.slot = slot
    }

    private func show(_ slot: Slot) {
        self.slot = slot
        configure(currentView, slot)
        didShow()
    }

    private func didShow() {
        guard case .page(let page) = slot else { return }
        model.didView(page)
        if let count = model.pageCount(page.chapter), page.page >= count - 1, let next = model.neighbor(page.chapter, 1) {
            model.request(next)
        }
        var list: [(ComicPage, String)] = []
        var cursor: Slot? = slot
        for _ in 0...6 {
            guard case .page(let p) = cursor, let src = model.source(p) else { break }
            list.append((p, src))
            cursor = peek(after: p)
        }
        if page.page > 0, let src = model.source(ComicPage(chapter: page.chapter, page: page.page - 1)) {
            list.append((ComicPage(chapter: page.chapter, page: page.page - 1), src))
        }
        model.images.want(list)
    }

    /// 只看已取到的章，不触发加载
    private func peek(after page: ComicPage) -> Slot? {
        if let count = model.pageCount(page.chapter), page.page + 1 < count {
            return .page(ComicPage(chapter: page.chapter, page: page.page + 1))
        }
        guard let next = model.neighbor(page.chapter, 1), model.pageCount(next) != nil else { return nil }
        return .page(ComicPage(chapter: next, page: 0))
    }

    private func retry(_ slot: Slot) {
        switch slot {
        case .page(let page):
            guard let src = model.source(page) else { return }
            model.images.retry(page, src: src)
        case .status(let chapter, _):
            model.retry(chapter)
        }
    }

    private func chapterChanged(_ chapter: Int) {
        if case .status(chapter, let forward) = currentView.slot, target == nil {
            if let next = entry(chapter, forward: forward), case .page = next {
                UIView.transition(with: currentView, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.show(next)
                }
                return
            }
            configure(currentView, .status(chapter, forward: forward))
        }
        if case .status(chapter, let forward) = neighborView.slot {
            configure(neighborView, .status(chapter, forward: forward))
        }
    }

    private func imageUpdated(_ page: ComicPage) {
        for view in [currentView, neighborView] where view.slot == .page(page) {
            view.showPage(page, image: model.images.image(page), aspect: model.images.aspect(page), failed: model.images.failed(page))
        }
    }

    private func seek(_ page: ComicPage) {
        guard model.pageCount(page.chapter) != nil else {
            model.jump(chapter: page.chapter, page: page.page)
            return
        }
        settle()
        show(.page(page))
    }

    // MARK: - 点按

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: view).x
        let width = view.bounds.width
        if model.menuVisible || (x > width / 3 && x < width * 2 / 3) {
            onCenterTap?()
            return
        }
        turn(forward: x >= width * 2 / 3)
    }

    private func turn(forward: Bool) {
        settle()
        guard let next = forward ? after(slot) : before(slot) else {
            bounce(forward: forward)
            return
        }
        prepare(next, forward: forward)
        finish(complete: true, velocity: 0)
    }

    private func bounce(forward: Bool) {
        let dx: CGFloat = forward ? -14 : 14
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.currentView.transform = CGAffineTransform(translationX: dx, y: 0)
        } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
                           options: .allowUserInteraction) {
                self.currentView.transform = .identity
            }
        }
    }

    // MARK: - 拖动

    private func prepare(_ next: Slot, forward: Bool) {
        target = (next, forward)
        configure(neighborView, next)
        neighborView.isHidden = false
        // 右侧那页压在左侧上，阴影落在它的左边缘
        currentView.setShadow(!forward)
        neighborView.setShadow(forward)
        if forward { view.bringSubviewToFront(neighborView) } else { view.bringSubviewToFront(currentView) }
        position(0)
    }

    /// 当前页在 x，相邻页紧贴在它旁边
    private func position(_ x: CGFloat) {
        guard let target else { return }
        let width = view.bounds.width
        currentView.transform = CGAffineTransform(translationX: x, y: 0)
        neighborView.transform = CGAffineTransform(translationX: x + (target.forward ? width : -width), y: 0)
    }

    /// 越界拖动的阻力：拖得越远越拉不动，最多走出屏宽的两成
    private func rubberBand(_ dx: CGFloat) -> CGFloat {
        let limit = view.bounds.width * 0.2
        let pulled = (1 - 1 / (abs(dx) * 0.55 / limit + 1)) * limit
        return dx < 0 ? -pulled : pulled
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let width = view.bounds.width
        let dx = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began:
            settle()
            hideMenu()
            // 方向看手指实际挪动的方向，起手瞬间的速度抖一下不会翻错
            let forward = dx != 0 ? dx < 0 : recognizer.velocity(in: view).x < 0
            guard let next = forward ? after(slot) : before(slot) else {
                rubberBanding = true
                return
            }
            prepare(next, forward: forward)
        case .changed:
            if rubberBanding {
                currentView.transform = CGAffineTransform(translationX: rubberBand(dx), y: 0)
                return
            }
            guard let target else { return }
            position(target.forward ? min(0, dx) : max(0, dx))
        case .ended, .cancelled, .failed:
            if rubberBanding {
                rubberBanding = false
                let spring = UIViewPropertyAnimator(duration: 0.5, dampingRatio: 0.78) { self.currentView.transform = .identity }
                spring.startAnimation()
                return
            }
            guard let target else { return }
            let velocity = recognizer.velocity(in: view).x
            let toward = target.forward ? -velocity : velocity
            let progress = max(0, target.forward ? -dx : dx) / width
            // 按松手速度推算页面会停在哪：过半才翻，或者是明确的快扫
            let complete = recognizer.state == .ended && toward >= -120
                && (toward > 520 || progress + toward * 0.16 / width > 0.5)
            finish(complete: complete, velocity: velocity)
        default:
            break
        }
    }

    /// 正在收尾的翻页动画立即走完
    private func settle() {
        guard let animator, animator.state == .active else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }

    private func finish(complete: Bool, velocity: CGFloat) {
        guard let target else { return }
        let width = view.bounds.width
        let finalX: CGFloat = complete ? (target.forward ? -width : width) : 0
        let done = { [weak self] in
            guard let self else { return }
            if complete {
                swap(&currentView, &neighborView)
                slot = target.slot
            }
            neighborView.reset()
            neighborView.isHidden = true
            currentView.transform = .identity
            neighborView.transform = .identity
            currentView.setShadow(false)
            neighborView.setShadow(false)
            self.target = nil
            if complete { didShow() }
        }
        let distance = finalX - currentView.transform.tx
        guard abs(distance) > 0.5 else {
            done()
            return
        }
        // 松手时的速度接进弹簧：甩得快就滑得快，慢慢放手就缓缓落定
        let relative = min(max(velocity / distance, -3), 10)
        let animator = UIViewPropertyAnimator(duration: velocity == 0 ? 0.42 : 0.48, timingParameters: UISpringTimingParameters(
            dampingRatio: 1, initialVelocity: CGVector(dx: relative, dy: 0)))
        animator.addAnimations { self.position(finalX) }
        animator.addCompletion { [weak self] _ in
            self?.animator = nil
            done()
        }
        self.animator = animator
        animator.startAnimation()
    }
}

// MARK: - 单页

/// 一页：可缩放的居中图片，或相邻章节的加载状态
private final class ComicPageView: UIView, UIScrollViewDelegate {
    let zoom = UIScrollView()
    let doubleTap = UITapGestureRecognizer()
    fileprivate var slot: ComicPagerController.Slot?
    var onRetry: (() -> Void)?

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let status = ComicStatusView()
    private var aspect: CGFloat = 4.0 / 3.0
    private var fittedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: -18, height: 0)
        layer.shadowRadius = 15
        layer.shadowOpacity = 0

        zoom.frame = bounds
        zoom.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoom.delegate = self
        zoom.minimumZoomScale = 1
        zoom.maximumZoomScale = 3
        zoom.contentInsetAdjustmentBehavior = .never
        zoom.showsVerticalScrollIndicator = false
        zoom.showsHorizontalScrollIndicator = false
        zoom.scrollsToTop = false
        zoom.decelerationRate = .fast
        addSubview(zoom)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        zoom.addSubview(imageView)

        spinner.color = .comicInk
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        retryButton.setImage(UIImage.icon("arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        retryButton.tintColor = .comicInk
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        addSubview(retryButton)
        status.onRetry = { [weak self] in self?.onRetry?() }
        addSubview(status)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        zoom.addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var lastBounds: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retryButton.frame = CGRect(x: bounds.midX - 30, y: bounds.midY - 30, width: 60, height: 60)
        status.frame = bounds
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            fit()
        }
        updateShadowPath()
    }

    func showPage(_ page: ComicPage, image: UIImage?, aspect: CGFloat?, failed: Bool) {
        let fresh = slot == .page(page) && imageView.image == nil && image != nil
        let newAspect = aspect ?? 4.0 / 3.0
        let reshape = abs(newAspect - self.aspect) > 0.001 || slot != .page(page)
        self.aspect = newAspect
        zoom.isHidden = false
        status.isHidden = true
        if fresh {
            UIView.transition(with: imageView, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.imageView.image = image
            }
        } else {
            imageView.image = image
        }
        imageView.backgroundColor = image == nil ? .comicHolder : .clear
        retryButton.isHidden = image != nil || !failed
        if image == nil && !failed { spinner.startAnimating() } else { spinner.stopAnimating() }
        if reshape {
            UIView.animate(withDuration: fresh ? 0.25 : 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.fit()
            }
        }
    }

    func showStatus(_ chapter: Int, state: ComicChapter?) {
        zoom.isHidden = true
        imageView.image = nil
        spinner.stopAnimating()
        retryButton.isHidden = true
        status.isHidden = false
        status.show(state)
    }

    func reset() {
        zoom.setZoomScale(1, animated: false)
    }

    /// 已在内容边缘（或没放大），可以把拖动交给翻页
    func atEdge(forward: Bool) -> Bool {
        guard zoom.zoomScale > 1.01, !zoom.isHidden else { return true }
        let x = zoom.contentOffset.x
        if forward {
            return x >= zoom.contentSize.width + zoom.contentInset.right - zoom.bounds.width - 1
        }
        return x <= -zoom.contentInset.left + 1
    }

    func setShadow(_ on: Bool) {
        if on { updateShadowPath() }
        layer.shadowOpacity = on ? 0.55 : 0
    }

    private func fit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        zoom.setZoomScale(1, animated: false)
        var size = CGSize(width: bounds.width, height: bounds.width * aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height / aspect, height: bounds.height)
        }
        fittedSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        zoom.contentSize = fittedSize
        center()
        zoom.contentOffset = CGPoint(x: -zoom.contentInset.left, y: -zoom.contentInset.top)
    }

    private func center() {
        let size = imageView.frame.size
        let horizontal = max(0, (zoom.bounds.width - size.width) / 2)
        let vertical = max(0, (zoom.bounds.height - size.height) / 2)
        zoom.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func updateShadowPath() {
        let rect = zoom.convert(imageView.frame, to: self).intersection(bounds)
        layer.shadowPath = rect.isNull ? nil : UIBezierPath(rect: rect).cgPath
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard !zoom.isHidden, imageView.image != nil else { return }
        if zoom.zoomScale > 1.01 {
            zoom.setZoomScale(1, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: zoom.bounds.width / 2, height: zoom.bounds.height / 2)
        zoom.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}

#endif  // #if os(iOS)
