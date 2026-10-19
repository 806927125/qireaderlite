import CoreText
import SwiftUI
import UIKit

/// 分页阅读容器：`UIPageViewController` 封装 + 数据源。
///
/// ── 关键设计：跨章在数据源层不存在 ──
/// 用户实机报了两个 bug：
///   ① 翻到下一张一直显示「正在加载中」
///   ② 从目录点第二章可以，翻到最后一页再翻又回到第一章
///
/// 根因是同一个：**我把 `viewControllerBefore/After` 当成了命令方法，
/// 在里面调 `requestStep()` 换章。** 但它们是 UIKit 的**查询**方法 ——
/// 预取、布局、用户取消手势都会调用，**一次翻页可能触发好几次**，
/// 换章标志位因此卡在 true，再也复位不了。
///
/// 现在：全书页平铺成一条**连续序列** `[GlobalPage]`，章界就是普通的
/// 「第 N 页 → 第 N+1 页」，数据源里没有任何跨章分支，
/// 没有 loading 标志位，没有 onEdge 回调。跨章这类 bug 从根上消失。
final class PagedChapterPager: NSObject {

    // MARK: 输入

    var config: ReaderLayoutConfig = ReaderLayoutConfig()
    var pageSize: CGSize = .zero
    var turnMode: String = "slide"
    var background: UIColor = .systemBackground

    /// 页码变化（1 起）
    var onPageChange: ((Int, Int) -> Void)?
    /// 请求某章的正文。返回 false 表示到头了/取不到。
    var onNeedChapter: ((Int) -> Void)?
    /// 当前章号变化（用来让上层同步 session.index 和预取）
    var onChapterChange: ((Int) -> Void)?
    /// 章内文本到齐（数据源据此排页）。返回 nil = 加载中/失败
    var chapterTextProvider: ((Int) -> ChapterText?)?

    /// 章总数
    var chapterCount: Int = 0
    /// 当前章
    private(set) var chapter: Int = 0

    /// 全书页序列：章 → 章内页号
    private(set) var spine: [GlobalPage] = []
    /// 各章排好的文本缓存（预取来的也在这）
    private var texts: [Int: ChapterText] = [:]
    private var loadingChapters: Set<Int> = []
    private var failedChapters: Set<Int> = []
    /// 当前在全书序列里的位置
    private(set) var cursor: Int = 0
    private var vcs: [ReaderPageVC] = []
    private weak var container: UIPageViewController?

    struct GlobalPage: Hashable {
        let chapter: Int
        let page: Int
    }

    struct ChapterText {
        let title: String
        let body: String
    }

    // MARK: 生命周期

    /// ⚠️ transitionStyle / navigationOrientation 是 **get-only**，只能在 init 定
    func makeContainer(mode: String) -> UIPageViewController {
        let style: UIPageViewController.TransitionStyle = (mode == "flip") ? .pageCurl : .scroll
        let v = UIPageViewController(transitionStyle: style, navigationOrientation: .horizontal)
        v.isDoubleSided = false
        v.dataSource = self
        v.delegate = self
        container = v
        turnMode = mode
        return v
    }

    /// 视口变了 → 页大小变 → spine 里每章的页数都得重算
    func setPageSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - pageSize.width) > 0.5
                || abs(size.height - pageSize.height) > 0.5 else { return }
        pageSize = size
        guard chapterCount > 0 else { return }
        let at = cursor
        rebuildSpine(around: chapter)
        // 尽量落回原来那一页
        if spine.indices.contains(at) { show(cursor: at, animated: false) }
    }

    // MARK: 灌数据

    /// 换章：重建 spine，落在该章第一页
    func loadChapter(_ c: Int) {
        chapter = c
        // ⚠️ 字典下标赋值不接受 Optional：chapterTextProvider?() 出来是
        //    ChapterText??，必须 if let 摊平，否则报
        //    "type of expression is ambiguous without a type annotation"
        if texts[c] == nil, let t = chapterTextProvider?(c) { texts[c] = t }
        failedChapters.remove(c)
        rebuildSpine(around: c)
        show(cursor: firstIndex(ofChapter: c), animated: false)
        onChapterChange?(c)
    }

    /// 章文本到齐（首次加载完 / 预取完）→ 重排该章在 spine 里的页
    func chapterTextArrived(_ c: Int) {
        if let t = chapterTextProvider?(c) { texts[c] = t }
        loadingChapters.remove(c)
        rebuildSpine(around: chapter)
    }

    func chapterFailed(_ c: Int, _ msg: String) {
        failedChapters.insert(c)
        loadingChapters.remove(c)
        failureMessage = msg
        show(cursor: cursor, animated: false)
    }

    private var failureMessage: String?

    /// 重新铺 spine：当前章用缓存文本，其它章沿用已有页数
    private func rebuildSpine(around keep: Int) {
        var out: [GlobalPage] = []
        var c = 0
        while c < chapterCount {
            let pages = pageCount(of: c)
            for p in 0..<max(1, pages) { out.append(GlobalPage(chapter: c, page: p)) }
            c += 1
        }
        spine = out
    }

    /// 某章有几页。没缓存文本的按 1 页算（占位），到齐了会 rebuild 纠正。
    private func pageCount(of c: Int) -> Int {
        guard let t = texts[c], !t.body.isEmpty else { return 1 }
        guard pageSize.width > 1, pageSize.height > 1 else { return 1 }
        let attr = config.attributed(title: "", body: t.body)
        let p = ReaderPaginator()
        return max(1, p.paginateJustified(attr, pageSize: pageSize, config: config).count)
    }

    private func firstIndex(ofChapter c: Int) -> Int {
        spine.firstIndex(where: { $0.chapter == c }) ?? cursor
    }

    // MARK: 切页

    func show(cursor idx: Int, animated: Bool) {
        guard spine.indices.contains(idx) else { return }
        let target = spine[idx]
        cursor = idx
        let v = makePage(target, slot: idx)
        container?.setViewControllers([v],
                                      direction: target.page == 0 ? .forward : .reverse,
                                      animated: animated && turnMode != "none") { [weak self] _ in
            self?.report()
        }
        report()
        ensureNeighbor(for: target, forward: true)
    }

    func turn(_ delta: Int) {
        let idx = cursor + delta
        if spine.indices.contains(idx) {
            show(cursor: idx, animated: turnMode != "none")
        } else {
            // 全书到头：提示一次
            onChapterChange?(delta > 0 ? -1 : -2)
        }
    }

    private func report() {
        onPageChange?(cursor + 1, spine.count)
    }

    /// 邻近章提前把文本拉好，章界那一页才是现成的
    private func ensureNeighbor(for gp: GlobalPage, forward: Bool) {
        let c = gp.chapter
        let forwardNeed = gp.page >= pageCount(of: c) - 1
        let backNeed = gp.page == 0
        guard forwardNeed || backNeed else { return }
        let target = forward ? c + 1 : c - 1
        guard target >= 0, target < chapterCount else { return }
        guard texts[target] == nil, !loadingChapters.contains(target) else { return }
        loadingChapters.insert(target)
        onNeedChapter?(target)
    }

    // MARK: 页面构造

    private func makePage(_ gp: GlobalPage, slot: Int) -> ReaderPageVC {
        // 该章文本还没到 / 取失败 → 占位页
        if texts[gp.chapter] == nil {
            let v = ReaderPageVC(kind: .loading)
            v.slot = slot
            v.background = background
            if failedChapters.contains(gp.chapter), let m = failureMessage {
                v.showFailure(m, retry: { [weak self] in
                    self?.loadingChapters.remove(gp.chapter)
                    self?.onNeedChapter?(gp.chapter)
                }, stepBack: { [weak self] in self?.turn(-1) })
            }
            return v
        }
        let v = ReaderPageVC(kind: .page)
        v.slot = slot
        v.background = background
        let t = texts[gp.chapter]!
        let attr = config.attributed(title: gp.page == 0 ? t.title : "", body: t.body)
        let fr = ReaderPaginator.oneOffFrame(at: gp.page, pageSize: pageSize, attributed: attr)
        v.setPage(frame: fr, pageSize: pageSize, bg: background,
                  baseline: config.showBaseline, baselineColor: config.baselineColor,
                  scope: config.baselineScope)
        return v
    }
}

// MARK: - 数据源 / 代理

extension PagedChapterPager: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    /// 全书序列里的一页接一页 —— 这里**没有任何跨章分支**，
    /// 章界就是 idx+1，`onEdge` 之类的回调一个都不需要。
    func pageViewController(_ pvc: UIPageViewController,
                            viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let v = vc as? ReaderPageVC, spine.indices.contains(v.slot - 1) else { return nil }
        let target = spine[v.slot - 1]
        let out = makePage(target, slot: v.slot - 1)
        ensureNeighbor(for: target, forward: false)
        return out
    }

    func pageViewController(_ pvc: UIPageViewController,
                            viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let v = vc as? ReaderPageVC, spine.indices.contains(v.slot + 1) else { return nil }
        let target = spine[v.slot + 1]
        let out = makePage(target, slot: v.slot + 1)
        ensureNeighbor(for: target, forward: true)
        return out
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed, let v = pvc.viewControllers?.first as? ReaderPageVC,
              spine.indices.contains(v.slot) else { return }
        cursor = v.slot
        let gp = spine[cursor]
        // 翻到了别的章 → 通知上层把 session.index 跟过来（换章不再靠 onEdge）
        if gp.chapter != chapter {
            chapter = gp.chapter
            onChapterChange?(gp.chapter)
        }
        report()
        ensureNeighbor(for: gp, forward: gp.page == 0 ? false : true)
    }
}
