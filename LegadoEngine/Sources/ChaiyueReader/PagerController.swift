// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
import ChaiyueReaderKit
import SwiftUI
import UIKit

/// 承载一页的控制器（UIPageViewController 需要）
final class PageController: UIViewController {
    let pageView = PageView()
    var pointer: PagePointer { pageView.pointer ?? PagePointer(chapter: 0, page: 0) }

    override func loadView() {
        view = pageView
    }
}

/// 分页翻页：仿真（系统卷页）、平移（横向滚动）、覆盖（当前页滑走露出下一页）、无动画
final class PagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    let model: ReaderModel
    private(set) var style: PageTurnStyle
    var onCenterTap: (() -> Void)?

    private var pageVC: UIPageViewController?
    private var topPage = PageView()
    private var bottomPage = PageView()
    private var shadow = CAGradientLayer()
    private var pan: UIPanGestureRecognizer?
    private var dragTarget: (pointer: PagePointer, forward: Bool)?
    private var busy = false
    private var animator: UIViewPropertyAnimator?
    /// 首页往前、末页往后拖：没有目标页，只做橡皮筋
    private var rubberBanding = false
    private lazy var selection = TextSelection(model: model)

    init(model: ReaderModel, style: PageTurnStyle) {
        self.model = model
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.commitVisible = nil
        view.clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.4
        press.delegate = self
        view.addGestureRecognizer(press)
        selection.onActiveChange = { [weak self] active in
            guard let self, let pageVC else { return }
            // 选字期间停用系统翻页手势，拖动选择手柄不会翻页
            pageVC.dataSource = active ? nil : self
        }
        build()
        #if DEBUG
        debugSelect()
        #endif
    }

    // MARK: - 构建

    func setStyle(_ newStyle: PageTurnStyle) {
        guard newStyle != style else { return }
        style = newStyle
        build()
    }

    private func build() {
        settleAnimation()
        selection.end()
        pageVC?.willMove(toParent: nil)
        pageVC?.view.removeFromSuperview()
        pageVC?.removeFromParent()
        pageVC = nil
        topPage.removeFromSuperview()
        bottomPage.removeFromSuperview()
        if let pan { view.removeGestureRecognizer(pan) }
        pan = nil

        switch style {
        case .curl:
            let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: nil)
            controller.isDoubleSided = false
            controller.dataSource = self
            controller.delegate = self
            addChild(controller)
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
            for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
                recognizer.isEnabled = false
            }
            pageVC = controller
            controller.setViewControllers([makePage(model.pointer)], direction: .forward, animated: false)
        case .slide, .scroll, .none, .vertical:
            for page in [bottomPage, topPage] {
                page.frame = view.bounds
                page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                page.onRetry = { [weak self] chapter in self?.model.retry(chapter) }
                view.addSubview(page)
            }
            shadow.colors = [UIColor.black.withAlphaComponent(0.2).cgColor, UIColor.black.withAlphaComponent(0.06).cgColor,
                             UIColor.clear.cgColor]
            shadow.locations = [0, 0.35, 1]
            shadow.startPoint = CGPoint(x: 0, y: 0.5)
            shadow.endPoint = CGPoint(x: 1, y: 0.5)
            shadow.opacity = 0
            topPage.layer.addSublayer(shadow)
            topPage.configure(model.pointer, model: model)
            bottomPage.isHidden = true
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            pan = recognizer
        }
    }

    private func makePage(_ pointer: PagePointer) -> PageController {
        let controller = PageController()
        controller.loadViewIfNeeded()
        controller.pageView.onRetry = { [weak self] chapter in self?.model.retry(chapter) }
        controller.pageView.configure(pointer, model: model)
        return controller
    }

    /// 排版或主题变化后重建当前页
    func reload() {
        settleAnimation()
        guard !busy else { return }
        selection.end()
        if let pageVC {
            pageVC.setViewControllers([makePage(model.pointer)], direction: .forward, animated: false)
        } else {
            topPage.frame = view.bounds
            topPage.configure(model.pointer, model: model)
            bottomPage.isHidden = true
        }
    }

    // MARK: - 点按

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if selection.isActive {
            selection.end()
            return
        }
        if !model.menuVisible, !busy, performTapTarget(recognizer) { return }
        let x = recognizer.location(in: view).x
        let width = view.bounds.width
        if model.menuVisible || (x > width / 3 && x < width * 2 / 3) {
            onCenterTap?()
            return
        }
        let forward = model.settings.tapToTurnBothSides ? true : x >= width * 2 / 3
        turn(forward: forward)
    }

    /// 点在段评气泡或带点按脚本的图片上时执行它
    private func performTapTarget(_ recognizer: UITapGestureRecognizer) -> Bool {
        let page = pageVC.flatMap { ($0.viewControllers?.first as? PageController)?.pageView } ?? topPage
        guard let pointer = page.pointer, let metrics = model.metrics,
              case .text(let layout, let index) = model.content(pointer) else { return false }
        let location = recognizer.location(in: page)
        let point = CGPoint(x: location.x - metrics.textFrame.minX, y: location.y - metrics.textFrame.minY)
        guard let target = layout.tapTarget(at: point, page: index) else { return false }
        model.perform(target, chapter: layout.chapterIndex)
        return true
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        beginSelection { recognizer.location(in: $0) }
    }

    private func beginSelection(at location: (UIView) -> CGPoint) {
        guard !model.menuVisible, !busy, let metrics = model.metrics else { return }
        let page = pageVC.flatMap { ($0.viewControllers?.first as? PageController)?.pageView } ?? topPage
        guard let pointer = page.pointer,
              selection.begin(in: page, frame: metrics.textFrame, pointer: pointer, at: location(page)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    #if DEBUG
    /// `-selectAt x,y`：正文排好后在该点模拟长按
    private func debugSelect(attempt: Int = 0) {
        guard let raw = DebugLaunch.flag("selectAt"), attempt < 90 else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if attempt >= 3, topPage.pointer != nil, model.layout(model.pointer.chapter) != nil {
                beginSelection { _ in CGPoint(x: parts[0], y: parts[1]) }
            }
            if !selection.isActive { debugSelect(attempt: attempt + 1) }
        }
    }
    #endif

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let textView = selection.textView, let touched = touch.view, touched.isDescendant(of: textView) { return false }
        return !(touch.view is UIControl)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan {
            guard !model.menuVisible, !selection.isActive, let pan else { return false }
            // 按手指已挪动的方向判断；慢慢拖时瞬时速度接近 0，按速度判断会让手势失败、页面不动
            let moved = pan.translation(in: view)
            if abs(moved.x) + abs(moved.y) > 1 { return abs(moved.x) > abs(moved.y) * 0.8 }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) >= abs(velocity.y)
        }
        return true
    }

    // MARK: - 翻页

    func refreshSpoken() {
        let pages = pageVC.map { ($0.viewControllers ?? []).compactMap { ($0 as? PageController)?.pageView } } ?? [topPage, bottomPage]
        pages.forEach { $0.refreshSpoken(model: model) }
    }

    func turn(forward: Bool) {
        // 连点时上一页的动画直接收尾，不吞掉这次点按
        settleAnimation()
        guard !busy else { return }
        selection.end()
        let current = model.pointer
        guard let target = forward ? model.next(after: current) : model.previous(before: current) else {
            bounce(forward: forward)
            return
        }
        if let pageVC {
            busy = true
            pageVC.setViewControllers([makePage(target)], direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
                guard let self else { return }
                busy = false
                model.didShow(target)
            }
            return
        }
        if style == .none {
            topPage.configure(target, model: model)
            model.didShow(target)
            return
        }
        prepareSlide(target, forward: forward)
        updateShadow(progress: 0.5)
        finishSlide(complete: true, velocity: 0)
    }

    private func bounce(forward: Bool) {
        guard pageVC == nil, !busy, style != .none else { return }
        let dx: CGFloat = forward ? -14 : 14
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.topPage.transform = CGAffineTransform(translationX: dx, y: 0)
        } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
                           options: .allowUserInteraction) {
                self.topPage.transform = .identity
            }
        }
    }

    // MARK: - UIPageViewController

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard !model.menuVisible, let page = viewController as? PageController,
              let target = model.previous(before: page.pointer) else { return nil }
        return makePage(target)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard !model.menuVisible, let page = viewController as? PageController,
              let target = model.next(after: page.pointer) else { return nil }
        return makePage(target)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        busy = true
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        busy = false
        guard completed, let page = pageViewController.viewControllers?.first as? PageController else { return }
        model.didShow(page.pointer)
    }

    // MARK: - 覆盖、平移与无动画

    /// 覆盖只动上层；平移时下层紧贴在上层右侧一起走
    private func position(_ x: CGFloat) {
        topPage.transform = CGAffineTransform(translationX: x, y: 0)
        if style == .scroll {
            bottomPage.transform = CGAffineTransform(translationX: x + view.bounds.width, y: 0)
        }
    }

    private func prepareSlide(_ target: PagePointer, forward: Bool) {
        busy = true
        dragTarget = (target, forward)
        let width = view.bounds.width
        if forward {
            bottomPage.configure(target, model: model)
            bottomPage.isHidden = false
            view.sendSubviewToBack(bottomPage)
            position(0)
        } else {
            // 上一页从左侧盖回来：交换上下层
            swap(&topPage, &bottomPage)
            topPage.configure(target, model: model)
            topPage.isHidden = false
            bottomPage.isHidden = false
            view.bringSubviewToFront(topPage)
            topPage.layer.addSublayer(shadow)
            position(-width)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.frame = CGRect(x: width, y: 0, width: 28, height: view.bounds.height)
        shadow.opacity = 0
        CATransaction.commit()
    }

    /// 阴影随拖动渐显，刚起手时不会突然冒出一条黑边
    private func updateShadow(progress: CGFloat) {
        guard style == .slide else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.opacity = Float(min(1, progress * 8) * (1 - progress * 0.4))
        CATransaction.commit()
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
            settleAnimation()
            guard !busy else { return }
            // 方向看手指实际挪动的方向，起手瞬间的速度抖一下不会翻错
            let forward = dx != 0 ? dx < 0 : recognizer.velocity(in: view).x < 0
            guard let target = forward ? model.next(after: model.pointer) : model.previous(before: model.pointer) else {
                dragTarget = nil
                rubberBanding = style != .none
                return
            }
            prepareSlide(target, forward: forward)
        case .changed:
            if rubberBanding {
                topPage.transform = CGAffineTransform(translationX: rubberBand(dx), y: 0)
                return
            }
            guard let dragTarget, style != .none else { return }
            if dragTarget.forward {
                position(min(0, dx))
                updateShadow(progress: max(0, -dx) / width)
            } else {
                position(-width + max(0, dx))
                updateShadow(progress: max(0, dx) / width)
            }
        case .ended, .cancelled, .failed:
            if rubberBanding {
                rubberBanding = false
                let spring = UIViewPropertyAnimator(duration: 0.5, dampingRatio: 0.78) { self.topPage.transform = .identity }
                spring.startAnimation()
                return
            }
            guard let dragTarget else { return }
            let velocity = recognizer.velocity(in: view).x
            let toward = dragTarget.forward ? -velocity : velocity
            let progress = max(0, dragTarget.forward ? -dx : dx) / width
            let complete: Bool
            if recognizer.state != .ended || toward < -150 {
                complete = false
            } else if style == .none {
                complete = progress > 0.1 || toward > 250
            } else {
                // 按松手速度推算页面会停在哪：轻轻一扫就翻，慢拖过四成也翻，往回甩才取消
                complete = toward > 240 || progress + max(0, toward) * 0.2 / width > 0.4
            }
            finishSlide(complete: complete, velocity: velocity)
        default:
            break
        }
    }

    /// 正在收尾的翻页动画立即走完
    private func settleAnimation() {
        guard let animator, animator.state == .active else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }

    private func finishSlide(complete: Bool, velocity: CGFloat) {
        guard let dragTarget else {
            busy = false
            return
        }
        let width = view.bounds.width
        let forward = dragTarget.forward
        let finalX: CGFloat = forward ? (complete ? -width : 0) : (complete ? 0 : -width)
        let done = { [weak self] in
            guard let self else { return }
            if complete {
                if forward {
                    swap(&topPage, &bottomPage)
                    view.bringSubviewToFront(topPage)
                }
                topPage.layer.addSublayer(shadow)
                model.didShow(dragTarget.pointer)
            } else if !forward {
                swap(&topPage, &bottomPage)
                view.bringSubviewToFront(topPage)
                topPage.layer.addSublayer(shadow)
            }
            topPage.transform = .identity
            bottomPage.transform = .identity
            bottomPage.isHidden = true
            shadow.opacity = 0
            self.dragTarget = nil
            busy = false
        }
        if style == .none {
            done()
            return
        }
        let distance = finalX - topPage.transform.tx
        guard abs(distance) > 0.5 else {
            done()
            return
        }
        // 松手时的速度接进弹簧：甩得快就滑得快；点按翻页没有初速，用更短的时长
        let relative = min(max(velocity / distance, 0), 12)
        let duration = velocity == 0 ? 0.3 : 0.34 + 0.1 * min(1, abs(distance) / width)
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UISpringTimingParameters(
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

/// SwiftUI 包装
struct PagerView: UIViewControllerRepresentable {
    let model: ReaderModel
    let style: PageTurnStyle
    let version: Int
    let onCenterTap: () -> Void

    func makeUIViewController(context: Context) -> PagerController {
        let controller = PagerController(model: model, style: style)
        controller.onCenterTap = onCenterTap
        model.onTurnRequest = { [weak controller] forward in controller?.turn(forward: forward) }
        model.onSpokenChange = { [weak controller] in controller?.refreshSpoken() }
        context.coordinator.version = version
        return controller
    }

    func updateUIViewController(_ controller: PagerController, context: Context) {
        controller.onCenterTap = onCenterTap
        if controller.style != style {
            controller.setStyle(style)
            context.coordinator.version = version
        } else if context.coordinator.version != version {
            context.coordinator.version = version
            controller.reload()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var version = 0
    }
}
#endif  // #if canImport(UIKit)
