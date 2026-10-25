import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var book: Book
    @State private var chapters: [Chapter] = []
    @State private var tocDiag: String?
    @State private var tocDiagBusy = false
    @State private var loading = false
    @State private var statusText = ""
    /// 目录在**后台**加载（详情页先出来，目录自己补）—— 用户要求「先出详情页再出目录」
    @State private var tocLoading = false
    @State private var showCatalog = false
    @State private var readerChapter: Chapter?
    /// 简介默认截 6 行，栖阅那个「展开全部」就是干这个的
    @State private var showAllIntro = false

    init(book: Book) { _book = State(initialValue: book) }

    private var source: BookSource? { sources.source(id: book.origin) }
    private var inShelf: Bool { library.contains(book) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionBar
                if !book.kind.isEmpty || !book.lastChapter.isEmpty { meta }
                intro
                // ⚠️ 有问题就**一直**显示，不管目录解析出多少章。
                //    原来只在 chapters.isEmpty 时显示，目录有内容但详情解析失败时反而看不见。
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // ⚠️ 原来只在 1~2 章时显示诊断按钮，**0 章反而不显示** ——
                //    而 0 章恰恰是最需要诊断的情况（toc() 成功返回但一条没解析出来，
                //    不抛错，页面上什么都看不出来）。
                // ⚠️ 目录在后台加载时，给个明确提示（别让人以为页面是空的）
                if tocLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("目录加载中…（详情已出，目录随后补上）")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                }
                if chapters.count <= 2 || !statusText.isEmpty {
                    HStack(spacing: 6) {
                        Text(chapters.isEmpty ? "目录一章都没解析出来" : "只解析出 \(chapters.count) 章，多半不对")
                            .font(.caption).foregroundStyle(.orange)
                        Button {
                            guard let src = source else { return }
                            tocDiagBusy = true
                            Task {
                                tocDiag = (try? await SourceService.shared.explainToc(
                                    source: src,
                                    tocUrl: book.tocUrl.isEmpty ? book.cleanBookUrl : book.tocUrl,
                                    bookUrl: book.cleanBookUrl,
                                    book: book)) ?? "诊断跑失败了"
                                tocDiagBusy = false
                            }
                        } label: {
                            Text(tocDiagBusy ? "诊断中…" : "点我诊断")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                Spacer(minLength: 30)
            }
            .padding(16)
        }
        .background {
            PageBackdrop()
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading { ProgressView().controlSize(.large) }
        }
        .task { await loadDetail() }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(chapters: chapters, start: readerChapter,
                         bookTitle: book.name.isEmpty ? nil : book.name,
                         sourceLabel: source?.name) { ch in
                showCatalog = false
                readerChapter = ch
            }
        }
        .fullScreenCover(item: $readerChapter) { ch in
            ReaderWebView(book: book, chapters: chapters, start: ch)
        }
        .alert("目录诊断", isPresented: Binding(
            get: { tocDiag != nil }, set: { if !$0 { tocDiag = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(tocDiag ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: book.cleanCover, width: 104, height: 140)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !book.author.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.sub)
                        Text(book.author)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                    }
                }

                // 栖阅把字数/分类/状态排成彩色胶囊
                HStack(spacing: 6) {
                    if !book.wordCount.isEmpty {
                        PillTag(text: book.wordCount, color: Theme.tagPink)
                    }
                    if !book.kind.isEmpty {
                        PillTag(text: book.kind, color: Theme.tagGreen)
                    }
                    if !book.lastChapter.isEmpty {
                        PillTag(text: book.lastChapter, color: Theme.tagOrange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                readerChapter = chapters.first(where: { !$0.isVolume })
            } label: {
                Label("开始阅读", systemImage: "book")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(chapters.isEmpty)
            .opacity(chapters.isEmpty ? 0.5 : 1)

            // 次按钮走玻璃，跟主按钮拉开层次
            Button {
                if inShelf {
                    library.remove(book.id)
                } else {
                    library.add(book)
                }
            } label: {
                Label(inShelf ? "已在书库" : "加入书库",
                      systemImage: inShelf ? "checkmark" : "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .liquidGlass(cornerRadius: 999)

            Button {
                showCatalog = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 50, height: 50)
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .liquidGlass(cornerRadius: 999)
            .disabled(chapters.isEmpty)
            .opacity(chapters.isEmpty ? 0.5 : 1)
        }
    }

    /// 栖阅那三列「分组 / 类型 / 更新」——横向分栏，各自带图标
    ///
    /// ⭐⭐⭐⭐⭐ **2026-10-25 真机修**（详情页三格一直显示「未分组 / 文本 / 未加载」）：
    /// ① 「分组」之前是**硬编码 `"未分组"`** ⇒ 站方给了分组也看不见 ⭐⭐⭐
    ///    ⇒ 现在取站方的 `ruleBookInfo.group` / `category`（引擎侧同期新增）⭐⭐⭐
    /// ② 「更新」之前是**章节数**（目录没加载就「未加载」）⇒ 跟站方的「最新章节/更新时间」不是一个东西
    ///    ⇒ 现在优先显示站方的 `lastChapter`（**最新章节 + 更新时间**）⇒ 目录没加载也有值 ⭐⭐⭐
    /// ③ 「类型」站方没给 `kind` ⇒ 仍兜底「文本」（**如实反映站方没给**，不编）⭐
    private var meta: some View {
        HStack(spacing: 0) {
            metaCell("folder.fill", "分组", book.group.isEmpty ? "未分组" : book.group, Theme.tagBlue)
            Divider().frame(height: 34)
            metaCell("doc.text.fill", "类型", book.kind.isEmpty ? "文本" : book.kind, Theme.tagPurple)
            Divider().frame(height: 34)
            metaCell("bell.fill", "更新", updateText, Theme.tagOrange)
        }
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 16)
    }

    /// ⭐⭐⭐ **「更新」那一格的值**
    ///
    /// ⇒ 优先站方的「最新章节 + 更新时间」（`lastChapter`）⇒ **目录没加载也有值** ⭐⭐⭐
    /// ⇒ 站方没给 ⇒ 退回章节数 ⇒ 还没有 ⇒ 「未加载」
    private var updateText: String {
        let latest = book.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !latest.isEmpty { return latest }
        let n = chapters.filter { !$0.isVolume }.count
        return n > 0 ? "\(n) 章" : "未加载"
    }

    private func metaCell(_ icon: String, _ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                Text("简介")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            // ⭐⭐⭐ **简介的 HTML 标签转纯文本**（2026-10-25 真机：`<p></p>` 露在界面上）
            //   ⇒ 站方的 `abstract` 带 `<p>` 段落 ⇒ 原样显示很难看 ⭐⭐⭐
            //   ⇒ 清洗放在**显示层** ⇒ 引擎输出不变 ⇒ 沙盒对拍零影响 ⭐⭐⭐
            Text(book.intro.isEmpty ? "（这本书没有简介）" : IntroHTMLCleaner.plainText(book.intro))
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineSpacing(5)
                .lineLimit(showAllIntro ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)

            if !book.intro.isEmpty && IntroHTMLCleaner.plainText(book.intro).count > 110 {
                Button {
                    withAnimation { showAllIntro.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAllIntro ? "收起" : "展开全部")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: showAllIntro ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    // MARK: 加载

    /// 详情加载超时
    struct DetailTimeout: LocalizedError {
        var errorDescription: String? {
            "加载超过 25 秒还没出来（可能是线路不通，详情页有 8 条线路的失败兜底）"
        }
    }

    /// 给一个 async 操作加 UI 级超时
    ///
    /// ⚠️ 为什么不能靠 op 的 360 秒超时：那是**兜底**，UI 会一直转圈。
    ///    站方（🍅大灰狼）的详情流程在一条线路不通时会**逐条试 8 条**，
    ///    每条等满请求超时 ⇒ 1~2 分钟起步 ⇒ 用户看到的就是「一直在转圈」。
    private static func withTimeout<T>(seconds: Double,
                                       _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DetailTimeout()
            }
            guard let first = try await group.next() else { throw DetailTimeout() }
            group.cancelAll()
            return first
        }
    }

    private func loadDetail() async {
        guard let s = source else {
            statusText = "找不到这本书对应的书源了（可能导入时覆盖过）"
            return
        }
        loading = true
        defer { loading = false }

        // 1) 详情页
        //
        // ⚠️ 原来是 `if let fresh = try? await …`，**失败被完全吞掉**：
        //    页面上看着"书名作者简介都有"，其实全是**列表页那份数据**，
        //    bookInfo 压根没跑成。tocUrl 因此是空的 → 目录去抓书籍页
        //    → 0 章。而 statusText 紧接着被清空，**屏幕上一点提示都没有**。
        //    这种"静默地错"最难查，必须把错误说出来。
        var problems: [String] = []
        do {
            // ⚠️ UI 层超时 25 秒（op 本身的超时是 360 秒 ❗）
            //    站方详情有 **8 条线路的失败兜底**，一条不通就等满请求超时
            //    ⇒ 设备上线路不通时，页面会**一直转圈一两分钟**（用户原话「一直在转圈」）
            //    ⇒ 这里先给 UI 一个明确的上限，超了就报错 + 提示换线路。
            let fresh = try await Self.withTimeout(seconds: 25) {
                try await SourceService.shared.bookInfo(
                    source: s, bookUrl: book.cleanBookUrl, fallback: book)
            }
            book = book.merged(with: fresh)
            if inShelf { library.add(book) }
            if book.tocUrl.isEmpty {
                problems.append("详情没算出 tocUrl（ruleBookInfo.tocUrl 返回空），目录只能退回书籍页")
            }
        } catch {
            problems.append("详情解析失败：\(error.localizedDescription)")
        }

        statusText = problems.joined(separator: "\n")

        // 2) 目录 —— **异步另起**，不拖住详情页 ✅
        //
        // ⚠️ 用户要求（2026-10-21）：「**先出详情页再出目录**」
        //    目录要跑站方 2000+ 章的 JS（每章一次 URL 计算）⇒ 可能十几秒到一分钟
        //    ⇒ 以前是**串行等它** ⇒ 详情页跟着一起转圈（用户原话「详情页一直在转圈」）❗
        //    ⇒ 现在：详情出来就渲染（loading 立刻结束），目录在下面自己补 ✅
        tocLoading = true
        Task { @MainActor in
            defer { tocLoading = false }
            var errs: [String] = []
            let tocURL = book.tocUrl.isEmpty ? book.cleanBookUrl : book.tocUrl
            do {
                let res = try await SourceService.shared.tocDetailed(
                    source: s, tocUrl: tocURL, bookUrl: book.cleanBookUrl, book: book)
                let list = res.chapters
                chapters = list
                if list.isEmpty {
                    // ⚠️⚠️ **提示要说人话**（2026-10-22 真机「QQ 阅读目录出不来」）：
                    //   以前一律报「chapterList 规则没命中」⇒ **误导** ——
                    //   大灰狼服务器对**它没抓到章节的书**会返回**一条占位**（title = 书名），
                    //   规则其实命中了，是**服务器没有这本书的章节** ⭐
                    if res.placeholderFiltered {
                        errs.append("站方服务器只回了这本书的卷信息、**没有章节**（它没抓到这本书）——换个书试试")
                    } else if res.rawCount == 0 {
                        errs.append("站方服务器**没有这本书的章节**（/catalog 返回空）——换个书试试")
                    } else {
                        errs.append("目录接口通了但一条章节都没解析出来（chapterList 规则没命中）")
                    }
                }
                if let last = library.item(for: book.id)?.lastChapterIndex,
                   last > 0, last < list.count {
                    readerChapter = nil   // 只是预热，不自动跳
                }
            } catch {
                errs.append("目录加载失败：\(error.localizedDescription)")
            }
            if !errs.isEmpty {
                statusText = (statusText.isEmpty ? "" : statusText + "\n") + errs.joined(separator: "\n")
            }
        }
    }
}

/// 目录面板 —— 照栖阅 `ReaderChapterListView.swift` 重做。
///
/// 从栖阅二进制里挖到的结构（strings）：
/// ```
/// /ReaderChapterListView.swift          目录视图本体
/// ChapterCacheService(Protocol)         章节缓存服务 → 已缓存章打云图标
/// _sortAscending / sortAscending        正倒序切换
/// VolumeButtonPageTurn*                 卷分组（isVolume）
/// ReaderSearchView / chapterListEmpty   目录内搜索 / 空态
/// ```
///
/// 视觉照栖阅截图：partial sheet + **系统玻璃**（iOS 26 的 `.glassEffect()`
/// 由 `LiquidGlass` 统一处理），顶部一行
/// 「胶囊按钮组 + 书名/副标题 + 关闭圆钮」，底部一个玻璃胶囊搜索框。
///
/// ⚠️ sheet 背景**不能**自己设 `presentationBackground` —— 那会把系统玻璃盖掉，
///    栖阅那种「透出后面正文」的效果就没了（设置面板已经踩过一次）。
struct CatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chapters: [Chapter]
    let start: Chapter?
    /// 顶部那一行的大字标题 —— **书名**（栖阅就显示书名，不是「目录 (N)」）
    var bookTitle: String? = nil
    /// 副标题 —— 书源名（栖阅是「🍎大灰狼聚合 5.9.30(vip完全版)」）
    /// ⚠️ 千万别把 `book.origin`（书源 **URL**）直接怼上去，
    ///    真机效果是 `https://cxb-pro.cread.com@通知` 这种没法看的东西。
    var sourceLabel: String? = nil
    /// 已预载到内存的章号集合。栖阅那边是 `ChapterCacheService` 的磁盘缓存，
    /// 轻阅还没做磁盘缓存，所以只标「内存里已有」——不假装成离线可读。
    var preloaded: Set<Int> = []
    /// 磁盘缓存还没实现 → 按钮置灰，不做假动作。
    var cacheEnabled: Bool = false
    /// 换源还没实现 → 同样置灰
    var switchSourceEnabled: Bool = false
    /// 胶囊第一个按钮：跳到全书最后一章
    var onJumpToEnd: (() -> Void)? = nil
    /// 胶囊第二个按钮：重新拉一次目录
    var onRefreshCatalog: (() -> Void)? = nil
    let onPick: (Chapter) -> Void

    @State private var filter = ""
    /// 正倒序。入口**暂时没挂** —— 栖阅那个胶囊位是「缓存 / 换源」，
    /// 自作主张塞个排序按钮进去位置就对不上了。数据层先留着，以后有地方再接。
    @State private var sortAscending = true
    /// 当前停在哪个 detent（`.medium` 对应 0.62，`.large` 是拖满屏）
    @State private var detent: PresentationDetent = .fraction(0.55)

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            searchBar
        }
        // partial sheet + 系统玻璃：不设 presentationBackground，
        // 让 iOS 26 的 glass 自己透出后面的正文。
        //
        // ⚠️ detent 列表要**保留 .large** —— 栖阅那边按住顶部横线上滑是会变大的，
        //    不是定死的。变的触发方式由 iOS 默认行为决定：
        //    **只有按住 grabber 上滑**才在 detent 之间切，拖列表内容是滚列表。
        //
        // ⚠️ 但**绝对不能开** `.presentationBackgroundInteraction(
        //        .enabled(upThrough: .fraction(0.62)))`。
        //    那个修饰符的语义就是「sheet 的背景区域也接管手势」——
        //    开了以后**随便在空白处一拖**整个 sheet 就跟着变形，
        //    用户看到的正是「目录拉一下直接变大窗口」。
        //    这就是前两轮改来改去没改对的那一个。
        .presentationDetents([.fraction(0.55), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        // 目录上滑 = 滚目录，页面尺寸不动。
        // SwiftUI 没这个开关（`prefersScrollingExpandsWhenScrolledToEdge` 默认 true），
        // 走 UIKit 设成 false。少了这行，用户往目录顶部上滑就会把 sheet 撑大。
        .background(NoScrollExpand())
    }

    // MARK: 顶部行

    private var header: some View {
        HStack(spacing: 10) {
            // 左：胶囊按钮组。**图标和顺序照栖阅截图**：
            // 第一个是「↓ 缓存全书」，第二个是「⟳ 换源」，中间一条竖分隔线。
            //
            // ⚠️ 别自作主张往里塞「正序/倒序」这种栖阅没有的按钮 —— 位置对了、
            //    图标不对，一样跟栖阅对不上。
            //    排序功能保留在代码里（sortAscending），但入口不占这个位置。
            HStack(spacing: 0) {
                // ↓ = 跳到全书最后一章（栖阅那个胶囊的语义对齐后的实际功能）
                iconInCapsule(systemName: "arrow.down", enabled: onJumpToEnd != nil) {
                    onJumpToEnd?()
                }
                Rectangle().fill(Theme.ink.opacity(0.18))
                    .frame(width: 1, height: 20)
                // ⟳ = 重新拉一次目录
                iconInCapsule(systemName: "arrow.triangle.2.circlepath",
                              enabled: onRefreshCatalog != nil) {
                    onRefreshCatalog?()
                }
            }
            // ⚠️ 只能有一层玻璃。LiquidGlass 在 iOS 26 内部就走系统 glassEffect，
            //    后面再跟一个 .glassEffectShape(.capsule) 就是玻璃套玻璃，
            //    折射叠描边 → 真机上一坨发灰的糊状物。
            .glassCapsule()

            // 中：书名 + 副标题
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let sourceLabel, !sourceLabel.isEmpty {
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：关闭
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .accessibilityLabel("关闭目录")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 栖阅这里显示的是**书名**，不是「目录 (N)」。
    /// 没传书名时才退回章节数（总得有标题）。
    private var titleText: String {
        if let t = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty { return t }
        let n = chapters.filter { !$0.isVolume }.count
        return "目录 (\(n.formatted()))"
    }

    private func iconInCapsule(systemName: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Image(systemName: systemName)
                .font(.footnote.weight(.semibold))
                // ⚠️ 未实现的功能置灰：半透明 + 弱化色，
                //    一眼能看出点不动，而不是点了给个假反馈。
                .foregroundStyle(enabled ? Theme.ink : Theme.ink.opacity(0.28))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ordered) { c in
                        row(c)
                        if c.id != ordered.last?.id {
                            Rectangle().fill(Theme.ink.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 24)
                        }
                    }
                    if ordered.isEmpty {
                        Text("没有匹配的章节")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
            }
            // ⚠️ 这两个都是 **ScrollView** 的修饰符，不能挂在外面的 VStack 上
            //    （挂错位置编译直接报 no member 'xxx'）。
            //    .basedOnSize = 内容不够高时才允许 bounce。
            .scrollBounceBehavior(.basedOnSize)
            // 栖阅目录右侧有那根细滚动条，SwiftUI 默认不画，得显式开
            .scrollIndicators(.visible)
            .onAppear {
                // 打开就停在当前章（栖阅也是这么做的）
                if let cur = start {
                    DispatchQueue.main.async {
                        proxy.scrollTo(cur.id, anchor: .center)
                    }
                }
            }
            // 搜索变了要把「当前章高亮」重新滚进视野
            .onChange(of: filter) { _, _ in resyncCurrent(proxy) }
        }
    }

    private func resyncCurrent(_ proxy: ScrollViewProxy) {
        guard let cur = start else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(cur.id, anchor: .center)
        }
    }

    private func row(_ c: Chapter) -> some View {
        let isCurrent = c.url == start?.url
        return Button {
            onPick(c)
        } label: {
            HStack(spacing: 10) {
                // 已预载标记（栖阅是云图标 = 磁盘缓存，这里是内存预载）
                if preloaded.contains(c.index) && !isCurrent {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(Theme.ink.opacity(0.35))
                }
                Text(c.title)
                    .font(c.isVolume ? .subheadline.weight(.bold) : .subheadline)
                    .foregroundStyle(isCurrent ? Theme.accent : (c.isVolume ? Theme.accent : Theme.ink))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            // 当前章：浅色圆角底 + 蓝色文字（栖阅截图就是这样，不是整行填充）
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCurrent ? Theme.accent.opacity(0.12) : .clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(c.id)
    }

    // MARK: 底部搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.55))
            TextField("搜索章节名", text: $filter)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassCapsule()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: 数据

    private var ordered: [Chapter] {
        let base = filter.isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        return sortAscending ? base : base.reversed()
    }
}
