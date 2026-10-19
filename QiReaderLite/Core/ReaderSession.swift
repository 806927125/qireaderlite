import Foundation

/// 阅读会话：把「界面 ↔ 引擎 ↔ 阅读进度」三件事的接线收在一处。
///
/// 为什么要单独一个类：SwiftUI 的 View 是 struct，**不能被 [weak self] 捕获**
/// （C 里就是在这儿编译失败的）。而且闭包被 ReaderHost（类）长期持有，
/// 直接捕获 View 会连带把 @State 绑定一起拖住 —— 收进类里最干净。
@MainActor
final class ReaderSession: ObservableObject {
    let host = ReaderHost()
    let book: Book
    let flat: [Chapter]
    /// SwiftUI 的 EnvironmentObject 在 init 里拿不到，.task 里再挂进来
    private var sources: SourceStore?
    private var library: LibraryStore?
    /// 正文被点了一下（宿主用它显/隐工具栏）
    var onTap: (() -> Void)?
    /// 翻页模式回调（x 是 0~1 的横向位置）
    var onTapZone: ((Double) -> Void)?
    /// 翻页模式下翻到头/翻到尾时给 UI 的提示（nil = 不提示）
    var onPageEdge: ((String) -> Void)?

    /// 把封面抓成 data URL 喂给界面当背景图。
    /// 栖阅阅读页那个「封面虚化铺底」就是 --reader-background-image，
    /// 走的是原生下载再转 base64（WebView 里直接 fetch 会被 CORS 挡）。
    func coverDataURL(_ urlString: String) async -> String? {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let u = URL(string: raw) else { return nil }
        if raw.hasPrefix("data:") { return raw }
        var req = URLRequest(url: u)
        req.timeoutInterval = 10
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg)
        guard let (data, _) = try? await session.data(for: req), !data.isEmpty else { return nil }
        // 超过 2MB 的封面没必要当背景，太吃内存
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 qireaderlite/1.0"

    @Published var index: Int = 0
    @Published var errorText: String = ""
    /// 正在换章拉正文。UI 必须显示出来 —— 否则换章失败时正文停在上一章第一页，
    /// 看上去就是「翻页卡住 / 翻回去」，用户完全不知道发生了什么。
    @Published var loadingChapter: Bool = false
    @Published var hostReady = false
    /// 当前章正文（原生分页模式自己排版用；webview 模式不用）
    @Published var chapterText: String = ""
    /// 当前章标题
    @Published var chapterTitle: String = ""

    init(book: Book, chapters: [Chapter], start: Chapter) {
        self.book = book
        self.flat = chapters.filter { !$0.isVolume }

        let startIdx = self.flat.firstIndex(where: { $0.url == start.url }) ?? 0
        self.index = max(0, min(startIdx, max(self.flat.count - 1, 0)))

        wire()
    }

    var current: Chapter? {
        flat.indices.contains(index) ? flat[index] : flat.first
    }

    private func wire() {
        host.onReady = { [weak self] in self?.hostReady = true }

        host.onRequestChapter = { [weak self] i in
            await self?.load(index: i)
        }

        host.onProgress = { [weak self] i, ratio in
            guard let self, self.flat.indices.contains(i) else { return }
            self.index = i
            self.library?.saveProgress(bookID: self.book.id,
                                      chapterIndex: i,
                                      ratio: ratio,
                                      chapterTitle: self.flat[i].title)
        }

        host.onVisibleChapter = { [weak self] i in
            guard let self, self.flat.indices.contains(i) else { return }
            self.index = i
        }

        host.onTap = { [weak self] in
            guard let self, let cb = self.onTap else { return }
            cb()
        }

        host.onDebugLog = { [weak self] ev, payload in
            guard let self, self.errorText.isEmpty else { return }
            if ev.contains("error") || ev.contains("fail") {
                self.errorText = String(describing: payload["error"] ?? ev)
            }
        }
    }

    /// 界面 ready 之后：喂设置 + 初始章节，然后拉当前章
    func attach(sources: SourceStore, library: LibraryStore) {
        self.sources = sources
        self.library = library
    }

    func start(settings: [String: Any]) async {
        for _ in 0..<60 where !hostReady {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        host.setSettings(settings)
        host.apply(chapters: flat, at: index, progress: library?.progress(bookID: book.id))
        await load(index: index)
    }

    /// 翻页：向右滑 / 点右半边 = 下一章，向左滑 / 点左半边 = 上一章。
    /// 到头了回调 onPageEdge 提示一句，别装没听见。
    func step(_ delta: Int) {
        let next = index + delta
        if next < 0 {
            onPageEdge?("已经是第一章")
        } else if next >= flat.count {
            onPageEdge?("已经是最后一章")
        } else {
            jump(to: next)
        }
    }

    func jump(to i: Int) {
        guard flat.indices.contains(i) else { return }
        index = i
        host.apply(chapters: flat, at: i, progress: nil)
        Task { await load(index: i) }
    }

    /// 只把 index 跟到 pager 的当前位置并把正文取过来。
    ///
    /// ⚠️ 不能用 jump(to:) —— 那边会重新 load，而 pager 侧 chapterText 到位后
    ///    又会触发一次重排，两边互相触发就是用户看到的「控件乱跳」。
    ///    这里只做「同步章号 + 拉文本」，不碰分页器。
    func followIndex(_ i: Int) {
        guard flat.indices.contains(i) else { return }
        index = i
        host.apply(chapters: flat, at: i, progress: nil)
        Task { await load(index: i) }
    }

    /// 预取指定章（不改变 index，不更新 chapterText）
    ///
    /// ⚠️ 为什么要预取：pager 的 `viewControllerBefore/After` 是 UIKit 的
    ///    **查询**方法 —— 预取、布局、cancel 都会调，**不能在里面做换章这种副作用**。
    ///    所以改成「接近章尾时后台把下一章拉好、排好页」，
    ///    数据源那边就只剩一条连续的书页序列，章界不再是特殊边界。
    @discardableResult
    func prefetch(index i: Int) async -> Bool {
        guard flat.indices.contains(i), i != index else { return false }
        guard let s = sources?.source(id: book.origin) else { return false }
        do {
            let dto = try await SourceService.shared.content(source: s, chapter: flat[i])
            return !dto.content.isEmpty
        } catch {
            return false
        }
    }

    /// 重试当前章（「重试」按钮走这条）
    func reloadCurrent() async {
        let i = index
        errorText = ""
        chapterText = ""
        await load(index: i)
    }

    /// 拉第 i 章正文。
    ///
    /// ⚠️ 竞态：快速连划时 load(2) / load(3) 会同时在飞，网络返回顺序不保证。
    ///    旧的结果后到就会把 chapterText 覆盖成**上一章**的内容 ——
    ///    表现是「翻到第 N 章末尾，再往下翻回到第 N 章开始」且内容还是第 N 章。
    ///    所以落地前必须校验 index 没被后续翻页改掉，改掉了就丢弃。
    func load(index i: Int) async {
        guard flat.indices.contains(i),
              let s = sources?.source(id: book.origin) else { return }
        let ch = flat[i]
        loadingChapter = true
        defer { if self.index == i { loadingChapter = false } }
        do {
            let dto = try await SourceService.shared.content(source: s, chapter: ch)
            // 用户已经翻到别的章了，这份结果作废
            guard self.index == i else { return }
            host.update(index: i, text: dto.content,
                        title: dto.title.isEmpty ? ch.title : dto.title)
            // 原生分页模式要用纯文本自己排版
            chapterText = dto.content
            chapterTitle = dto.title.isEmpty ? ch.title : dto.title
            errorText = ""
        } catch {
            guard self.index == i else { return }
            host.fail(index: i, message: error.localizedDescription)
            errorText = error.localizedDescription
            // 换章失败必须让用户看见。不给正文就是「静默停在上一章」，
            // 跟「翻页坏了」在用户眼里一模一样。
            chapterText = ""
        }
    }
}
