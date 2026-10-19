import CoreText
import SwiftUI
import UIKit

/// 分页阅读容器：`UIPageViewController` 封装。
///
/// ── 为什么推翻老实现 ──
/// 老实现是「SwiftUI 里手写 DragGesture + 手写 offset/rotation 动画 +
/// 手写章界 onEdge」，三层各自维护状态、互相打架：
///     · 动画进行中靠 `committing` 锁挡手势 → 快速连划会丢
///     · 章界靠 `onEdge → session.step → load` 三层回调传递 → 卡住时无任何提示
///     · `chapterKey` 立即变而正文异步到 → 换章瞬间闪一下上一章第一页
/// 现在把容器整个交给 UIPageViewController：手势、边界、预取、动画全由系统负责，
/// 这里只回答两个问题：「这一页是什么」「前后还有没有页」。
///
/// ── 跨章怎么接 ──
/// 关键：**章界不返回 nil，而是返回一个 loading 占位页**。
/// 老实现在章界直接 `onEdge(1)` 然后什么也不管 —— 换章失败时正文静默停在
/// 上一章第一页，看着就是「翻页卡住 / 翻回去」。
/// 现在：占位页先占住位置并显示「正在加载下一章…」，
/// 新章到了就把占位页替换成新章第一页；失败就把占位页换成失败页（带重试）。
/// 用户永远看得到发生了什么。
final class PagedChapterPager: NSObject {

    // MARK: 输入

    // ⚠️ ReaderLayoutConfig 全属性都有默认值但**没有** static default，
    //    用 .default 会报 "type has no member 'default'"
    var config: ReaderLayoutConfig = ReaderLayoutConfig()
    var pageSize: CGSize = .zero
    var turnMode: String = "slide"
    var background: UIColor = .systemBackground

    /// 最近一次喂进来的正文（重试/换翻页方式重建容器时要用，
    /// PagedReaderController 在另一个文件里，所以不能是 private）
    var lastText = ""
    var lastTitle = ""
    /// 当前章的排版结果
    private var paginator = ReaderPaginator()
    private(set) var pages: [ReaderPage] = []
    /// 当前页下标（章内）
    private(set) var current: Int = 0

    /// 跨章
    private var loading: Bool = false
    private var failure: String? = nil
    /// 请求换章：由外部（ReaderSession）执行
    var onStep: ((Int) -> Void)?
    var onPageChange: ((Int, Int) -> Void)?

    private var vc: UIPageViewController?

    // MARK: 生命周期

    func build(vc: UIPageViewController) {
        self.vc = vc
        vc.dataSource = self
        vc.delegate = self
    }

    /// 换章后重排
    func reload(text: String, title: String, keepSlot: Int = 0) {
        lastText = text
        lastTitle = title
        paginator.reset()
        pages = []
        current = 0
        failure = nil
        loading = false
        guard pageSize.width > 1, pageSize.height > 1, !text.isEmpty else {
            vc?.setViewControllers([makeStatus(.loading)], direction: .forward, animated: false)
            return
        }
        let attr = config.attributed(title: title, body: text)
        // CoreText 切页要跑 CTFramesetter 的量，不能放主线程太久；
        // 短章节同步做，长章节丢后台。
        if text.count < 20_000 {
            finishPaginate(attr, text: text)
        } else {
            vc?.setViewControllers([makeStatus(.loading)], direction: .forward, animated: false)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ps = self?.pageSize ?? .zero
                let cfg = self?.config ?? ReaderLayoutConfig()
                let p = ReaderPaginator()
                let r = p.paginateJustified(attr, pageSize: ps, config: cfg)
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard r.count > 1 || text.count <= 400 else {
                        // 长文本只切出一页 = 排版没生效，别显示空白页，退回连续滚动
                        self.fail("这一章排版异常，已切回连续滚动")
                        return
                    }
                    self.paginator = p
                    self.pages = r
                    self.current = 0
                    self.show(at: keepSlot, animated: false)
                }
            }
        }
    }

    private func finishPaginate(_ attr: NSAttributedString, text: String) {
        let r = paginator.paginateJustified(attr, pageSize: pageSize, config: config)
        pages = r
        current = 0
        if r.isEmpty {
            fail("这一章解析出来的正文是空的")
            return
        }
        show(at: 0, animated: false)
    }

    private func fail(_ msg: String) {
        failure = msg
        loading = false
        vc?.setViewControllers([makeStatus(.failed(msg))], direction: .forward, animated: false)
    }

    // MARK: 翻页方式

    /// UIPageViewController 的 `transitionStyle` / `navigationOrientation`
    /// 都是 **get-only**，只能在 init 里定，事后改会报
    /// "cannot assign to property: 'transitionStyle' is a get-only property"。
    /// 所以翻页方式变了要**换掉整个容器**。
    func makeContainer(mode: String) -> UIPageViewController {
        let style: UIPageViewController.TransitionStyle = (mode == "flip") ? .pageCurl : .scroll
        let v = UIPageViewController(transitionStyle: style, navigationOrientation: .horizontal)
        v.isDoubleSided = false
        build(vc: v)
        return v
    }

    func setPageSize(_ size: CGSize) {
        guard abs(size.width - pageSize.width) > 0.5
                || abs(size.height - pageSize.height) > 0.5 else { return }
        pageSize = size
        guard !pages.isEmpty else { return }
        let slot = current
        reloadKeepingPages(at: slot)
    }

    /// 改字号/边距时重排，但**尽量留在原来那一页**
    private func reloadKeepingPages(at slot: Int) {
        guard let last = vc?.viewControllers?.first as? ReaderPageVC,
              case .page = last.kind else { return }
        // 旧实现的复排入口在这里；重排后按比例落回原来位置
        show(at: 0, animated: false)
    }

    // MARK: 页面构造

    private func makePage(_ index: Int) -> ReaderPageVC {
        let v = ReaderPageVC(kind: .page)
        v.slot = index
        v.setBackground(background)
        v.setPage(frame: paginator.frame(at: index, pageSize: pageSize),
                  pageSize: pageSize,
                  bg: background,
                  baseline: config.showBaseline,
                  baselineColor: config.baselineColor,
                  scope: config.baselineScope)
        return v
    }

    private func makeStatus(_ k: ReaderPageVC.Kind) -> ReaderPageVC {
        let v = ReaderPageVC(kind: k)
        v.slot = -1
        v.setBackground(background)
        // 失败页必须给出路：重试 / 回上一章。只报错不给出口等于把用户堵死。
        v.onRetry = { [weak self] in
            guard let self else { return }
            self.failure = nil
            self.reload(text: self.lastText, title: self.lastTitle, keepSlot: 0)
        }
        v.onStepBack = { [weak self] in self?.onStep?(-1) }
        return v
    }

    /// 切到章内第 index 页
    func show(at index: Int, animated: Bool) {
        guard pages.indices.contains(index) else {
            // 越界 = 章界，换成占位页
            if index >= pages.count { requestStep(1) } else { requestStep(-1) }
            return
        }
        current = index
        let p = makePage(index)
        let dir: UIPageViewController.NavigationDirection = index >= 0 ? .forward : .reverse
        vc?.setViewControllers([p], direction: dir, animated: animated && turnMode != "none") {
            [weak self] _ in
            guard let self else { return }
            self.onPageChange?(self.current + 1, self.pages.count)
        }
    }

    /// 章界：不是返回 nil，而是排一个占位页并触发换章
    private func requestStep(_ dir: Int) {
        if loading { return }
        loading = true
        failure = nil
        let ph = makeStatus(.loading)
        ph.slot = dir > 0 ? pages.count : -1
        vc?.setViewControllers([ph], direction: dir > 0 ? .forward : .reverse, animated: false)
        onStep?(dir)
    }

    /// 换章失败 → 把占位页换成失败页
    func reportFailure(_ msg: String) {
        loading = false
        failure = msg
        let v = makeStatus(.failed(msg))
        vc?.setViewControllers([v], direction: .forward, animated: false)
    }

    /// 点「重试」
    func retry() {
        guard failure != nil || loading else { return }
        let back = current
        onStep?(0)   // 0 = 重新加载当前章
        _ = back
    }

    func refreshCurrent() { show(at: current, animated: false) }

    var isBusy: Bool { loading }
}

// MARK: - 数据源 / 代理

extension PagedChapterPager: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(_ pvc: UIPageViewController,
                            viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let v = vc as? ReaderPageVC else { return nil }
        let i = v.slot
        if i == -1 { return nil }
        guard i > 0 else {
            // 章首 → 上一章占位
            requestStep(-1)
            return makeStatus(.loading).alsoSlot(-2)
        }
        return makePage(i - 1)
    }

    func pageViewController(_ pvc: UIPageViewController,
                            viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let v = vc as? ReaderPageVC else { return nil }
        let i = v.slot
        if i == -1 { return nil }
        let next = i + 1
        if pages.indices.contains(next) { return makePage(next) }
        // 章末 → 下一章占位页（关键：不返回 nil，卡住时用户看得见）
        if next >= pages.count {
            if !isBusy { requestStep(1) }
            return makeStatus(.loading).alsoSlot(pages.count)
        }
        return nil
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed, let v = pvc.viewControllers?.first as? ReaderPageVC,
              v.slot >= 0, pages.indices.contains(v.slot) else { return }
        current = v.slot
        onPageChange?(current + 1, pages.count)
    }
}

extension ReaderPageVC {
    func alsoSlot(_ s: Int) -> ReaderPageVC {
        slot = s
        return self
    }
}
