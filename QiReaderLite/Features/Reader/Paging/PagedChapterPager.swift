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
    /// 各章排好的结果（预取来的也在这）。
    /// ⚠️ 文本和页数**必须绑在一起缓存**：之前 pageCount 不带标题、makePage 带标题，
    ///    两边基准不一致 → 页边界和实际渲染对不上，标题页就错位了。
    private var renders: [Int: ChapterRender] = [:]
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

    /// 一章的排版结果
    struct ChapterRender {
        let title: String
        let pageCount: Int
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
        renders.removeAll()          // 页宽变了，每章页数都得重算
        let at = cursor
        rebuildSpine(around: chapter)
        // 尽量落回原来那一页
        if spine.indices.contains(at) { show(cursor: at, animated: false) }
    }

    // MARK: 灌数据

    /// 换章：重建 spine，落在该章第一页
    /// **真正换章**：落在该章第一页。
    /// 只有从目录跳、或首帧时才用这个。
    func loadChapter(_ c: Int) {
        chapter = c
        renders.removeValue(forKey: c)
        render(c)
        failedChapters.remove(c)
        rebuildSpine(around: c)
        show(cursor: firstIndex(ofChapter: c), animated: false)
        onChapterChange?(c)
    }

    /// 章文本到齐 → 重排 spine，但**保持当前页**。
    ///
    /// ⚠️ 之前这里直接 `show(cursor: firstIndex(ofChapter:))`，等于「文本一到就跳首页」。
    ///    而 chapterText 是异步到的（换章时章号先变、文本后到），于是：
    ///      ① 章号切到新章但 chapterText 还是旧的 → 拿旧文本排新章的页
    ///      ② 旧文本到齐 → 强制跳到该章第一页 → 底部控件页码/章号乱跳
    ///    这就是用户报的「下面控件上的目录显示乱跳」。
    func chapterTextArrived(_ c: Int) {
        loadingChapters.remove(c)
        renders.removeValue(forKey: c)   // 尺寸/排版可能变了，重算
        render(c)
        failedChapters.remove(c)
        let at = cursor
        rebuildSpine(around: chapter)
        // 位置不变，只在越界时才夹回来
        if spine.indices.contains(at) {
            refresh(at: at)
        } else {
            show(cursor: min(max(at, 0), max(spine.count - 1, 0)), animated: false)
        }
    }

    /// 原地重画当前页（不换页）
    private func refresh(at idx: Int) {
        guard spine.indices.contains(idx) else { return }
        cursor = idx
        container?.setViewControllers([makePage(spine[idx], slot: idx)],
                                      direction: .forward, animated: false)
        report()
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
    private func pageCount(of c: Int) -> Int { renders[c]?.pageCount ?? 1 }

    /// 排一章（**带标题**），缓存结果。标题只在章首页，所以只有 page 0 的
    /// 帧要带标题 —— 但页数必须按「带标题」那个基准算，否则页边界对不上。
    @discardableResult
    private func render(_ c: Int) -> ChapterRender? {
        if let r = renders[c] { return r }
        guard let t = chapterTextProvider?(c), !t.body.isEmpty,
              pageSize.width > 1, pageSize.height > 1 else { return nil }
        let attr = config.attributed(title: t.title, body: t.body)
        let p = ReaderPaginator()
        let n = max(1, p.paginateJustified(attr, pageSize: pageSize, config: config).count)
        let r = ChapterRender(title: t.title, pageCount: n)
        renders[c] = r
        return r
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
        guard renders[target] == nil, !loadingChapters.contains(target) else { return }
        loadingChapters.insert(target)
        onNeedChapter?(target)
    }

    // MARK: 页面构造

    private func makePage(_ gp: GlobalPage, slot: Int) -> ReaderPageVC {
        // 该章文本还没到 / 取失败 → 占位页
        if renders[gp.chapter] == nil {
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
        let r = renders[gp.chapter]!
        // 标题只出现在该章首页，所以只有 page 0 带标题；
        // 但页数是按「带标题」算的，两边基准一致，不会错位。
        let t = chapterTextProvider?(gp.chapter)
        let attr = config.attributed(title: gp.page == 0 ? r.title : "",
                                     body: t?.body ?? "")
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
