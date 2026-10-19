import SwiftUI
import UIKit
import WebKit

/// 正文阅读器：栖阅的阅读界面 + 我们自己的规则引擎。
///
/// 界面那四个文件（reader.html/css/js + reader-scroll-core.js）是从栖阅 IPA 里
/// 原样搬过来的，它跟原生之间只通过 8 类消息通信，那一半桥在 ReaderHost 里。
struct ReaderWebView: View {
    @Environment(\.dismiss) private var dismiss

    let book: Book
    @State private var chapters: [Chapter]
    /// 「刷新目录」正在跑（按钮转圈 / 防连点）
    @State private var isRefreshingCatalog = false
    let start: Chapter

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 8
    @AppStorage("reader.theme") private var themeKey: String = "paper"
    /// 翻页模式：点正文左/右半边翻章、左右滑动翻章；关掉就是原来的
    /// "点一下出菜单" 行为。默认开（用户明确要的）。
    @AppStorage("reader.pageTurn") private var pageTurn: Bool = true
    /// 翻页方式，对应参考 App 的「仿真 / 滑动 / 平移 / 无动画 / 上下滚动」
    @AppStorage("reader.pageTurnMode") private var pageTurnMode: String = "slide"
    @AppStorage("reader.fontKey") private var fontKey: String = "system"
    @AppStorage("reader.followSystem") private var followSystemAppearance: Bool = false
    // ── 栖阅 ReaderLayoutSettingsView 的那几项 ──
    @AppStorage("reader.paraAlign") private var paraAlign: String = "left"
    @AppStorage("reader.paraSpacing") private var paraSpacing: Double = 10
    @AppStorage("reader.showBaseline") private var showBaseline: Bool = false
    @AppStorage("reader.baselineScope") private var baselineScope: String = "full"
    @AppStorage("reader.verticalJustify") private var verticalJustify: Bool = false
    @AppStorage("reader.tapAnywhere") private var tapAnywhereTurnsPage: Bool = true
    @AppStorage("reader.swipeUpExit") private var swipeUpExit: Bool = false
    @AppStorage("reader.twoPageSpread") private var twoPageSpread: Bool = false
    @AppStorage("reader.contentInHeaderFooter") private var contentInHeaderFooter: Bool = false
    @AppStorage("reader.baselineColor") private var baselineColorHex: String = "#B8B8B8"
    @State private var edgeToast: String?
    @State private var pageInfo: (page: Int, total: Int) = (1, 1)

    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var session: ReaderSession
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showPageDiag = false
    @State private var showChrome = false
    /// 子页：显示设置 / 间距设置
    @State private var showDisplaySettings = false
    @State private var showLayoutSettings = false
    @State private var showMoreSettings = false
    /// 面板内容实测高度，用来给 partial detent
    @State private var sheetHeight: CGFloat = 560   // 初值只是占位，首帧后被 PreferenceKey 实测值覆盖
    @State private var started = false

    /// ReaderSession 是 @MainActor 类，init 也得在主线程（Swift 5 模式强检查）
    @MainActor init(book: Book, chapters: [Chapter], start: Chapter) {
        _chapters = State(initialValue: chapters)
        self.book = book
        self.chapters = chapters
        self.start = start
        // store 在 .task 里从 EnvironmentObject 挂进来
        _session = StateObject(wrappedValue: ReaderSession(book: book, chapters: chapters, start: start))
    }

    @Environment(\.colorScheme) private var darkScheme

    /// 分页容器。
    /// ⚠️ @StateObject 要求 ObservableObject，PagedReaderController 不是
    ///    （它也不需要 —— 它的状态在 pager 里，SwiftUI 侧只做命令式调用），
    ///    所以用 @State 持有。引用类型，@State 能保住实例不被重建。
    @State private var pageCtl = PagedReaderController()

    /// 已经喂给 pager 的正文。用它判断「这一章要不要重排」——
    /// 之前老实现靠 chapterKey 变没变来判断，但那是 chapterKey 立刻变、正文异步到，
    ///    结果每次换章都先闪一下上一章第一页。
    @State private var pagedText: String = ""
    @State private var pagedTitle: String = ""
    @State private var pagedChapter: Int = -1
    @State private var pagedLayout: String = ""
    /// 真实的可视区尺寸。
    /// ⚠️ 之前 onChange(chapterText) 里直接 `syncPager(size: .zero)` ——
    ///    `pageSize(in: .zero)` 走的是 `max(80, …)`，算出 **80×80 的迷你页**，
    ///    整页正文被塞进 80×80 再拉成全屏 → 满屏米色只露几个字。
    ///    正文变了要重排，但重排必须用**当初量到的真实尺寸**，不是 .zero。
    @State private var pagerViewport: CGSize = .zero

    /// 用原生分页（CoreText 排版 + 翻页动画）还是 webview 上下滚动。
    /// 只有「上下滚动」这一种走 webview —— 栖阅也是这么分的：
    /// 它的 WebViewVerticalScrollViewController 管滚动，ReaderPaginator 管分页。
    private var useNativePaging: Bool {
        pageTurnMode != "scroll"
    }

    /// 跟着翻页模式走：原生分页接管章号，滚动模式把章号还给 WebView。
    ///
    /// ⚠️ 不能只在 `followIndex` / `jump` 里顺手置位 —— 那样用户在滚动模式下
    ///    用一次章号滑块，`pagingOwnsIndex` 就永远是 true，
    ///    WebView 的 progress 回声被丢掉，滚动模式的章号就冻住了。
    private func syncPagingOwnership() {
        let want = useNativePaging
        guard session.pagingOwnsIndex != want else { return }
        session.pagingOwnsIndex = want
    }

    /// 目录顶部那行副标题（栖阅显示的是「🍎大灰狼聚合 5.9.30(vip完全版)」）
    /// 目录胶囊第一个按钮：直接跳到全书最后一章第一页。
    private func jumpToLastChapter() {
        // ⚠️ 别写 `!last.isEmpty` —— Chapter 是 struct 不是 String，没有 isEmpty
        guard let last = chapters.last(where: { !$0.isVolume }) else { return }
        guard let i = session.flat.firstIndex(where: { $0.url == last.url }) else { return }
        showCatalog = false
        session.jump(to: i)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            pageCtl.pager.jumpToChapter(i)
        }
    }

    /// 目录胶囊第二个按钮：重新向书源要一次目录。
    ///
    /// 小说站的目录经常半夜补章/改标题，靠刷新拿到最新的。
    /// 拉不到就保持原样 —— 宁可没反应，也不要把用户正在读的目录搞坏。
    private func refreshCatalog() {
        guard !isRefreshingCatalog else { return }
        let bk = session.book
        guard let src = sources.source(id: bk.origin) else {
            session.onPageEdge?("换源信息不全，刷新不了目录")
            return
        }
        isRefreshingCatalog = true
        Task {
            defer { isRefreshingCatalog = false }
            do {
                let fresh = try await sources.service.toc(source: src, tocUrl: bk.tocUrl, bookUrl: bk.bookUrl)
                if session.replaceChapters(fresh) {
                    chapters = fresh.filter { !$0.isVolume }
                    pageCtl.pager.adoptFreshChapterList(chapters.count)
                    session.onPageEdge?("目录已刷新，共 \(chapters.count) 章")
                } else {
                    session.onPageEdge?("目录没有变化")
                }
            } catch {
                session.onPageEdge?("刷新失败：\(error.localizedDescription)")
            }
        }
    }

    /// 目录顶部副标题 = **书源名**（`BookSource.name` 优先取 bookSourceName）。
    /// ⚠️ 别用 `book.origin` —— 那是书源 URL，真机上会显示成
    ///    `https://cxb-pro.cread.com@通知` 这种没法看的东西。
    private var sourceSubtitle: String? {
        sources.source(id: session.book.origin)?.name
    }

    /// 目录顶部大字 = 书名（栖阅就是这样，不是「目录 (N)」）
    private var catalogBookTitle: String? {
        let n = session.book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// 底线颜色：存成 hex，ColorPicker 要的是 Binding<Color>
    private var baselineColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: baselineColorHex) },
            set: { baselineColorHex = $0.hexString }
        )
    }

    /// 排版参数：跟喂给 webview 的 settingsPayload 用同一套语义
    private var layoutConfig: ReaderLayoutConfig {
        ReaderLayoutConfig(
            fontSize: CGFloat(fontSize),
            lineSpacing: CGFloat(lineSpacing),
            paragraphSpacing: CGFloat(paraSpacing),
            horizontalMargin: 20,
            topMargin: 20,
            bottomMargin: 28,
            firstLineIndent: CGFloat(fontSize) * 2,
            fontFamily: ReaderFont.family(for: fontKey),
            textColor: UIColor(theme.ink),
            backgroundColor: UIColor(theme.bg),
            paraAlign: ReaderParaAlign(raw: paraAlign) ?? .left,
            verticalJustify: verticalJustify,
            showBaseline: showBaseline,
            baselineColor: UIColor(baselineColorBinding.wrappedValue),
            baselineScope: ReaderBaselineScope(raw: baselineScope) ?? .full
        )
    }

    /// 换章加载中 / 换章失败 的提示层。
    /// 失败时给「重试」按钮 —— 只报错不给出口等于把用户堵死。
    /// 原生分页模式下的点击分发。
    /// 中间区域出目录；「点击任意位置翻到下一页」开着的话，其余位置翻页。
    /// 翻页直接调 pager.show(at:)，不碰系统手势。
    private func handleReaderTap(zone: CGFloat) {
        if showChrome {
            withAnimation(.easeInOut(duration: 0.18)) { showChrome = false }
            return
        }
        if tapAnywhereTurnsPage {
            if zone > 0.35 && zone < 0.65 {
                withAnimation(.easeInOut(duration: 0.18)) { showChrome = true }
            } else {
                pageCtl.pager.turn(zone >= 0.5 ? 1 : -1)
            }
        } else {
            if zone < 0.25 {
                pageCtl.pager.turn(-1)
            } else if zone > 0.75 {
                pageCtl.pager.turn(1)
            } else {
                withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() }
            }
        }
    }

    /// 把 SwiftUI 侧的配置和正文推进 pager。
    /// 幂等 —— 只有「章变了 / 正文变了 / 排版参数变了」才真的重排。
    private func syncPager(size: CGSize) {
        // 尺寸没量到就什么都别做：拿 .zero 去算页宽会算出 80×80 的迷你页
        guard size.width > 1, size.height > 1 else { return }
        // 章号归属跟着翻页模式走（原生分页 vs WebView 滚动，二者只能有一个写者）
        syncPagingOwnership()
        pagerViewport = size
        let c = layoutConfig
        let sig = "\(c.fontSize)|\(c.lineSpacing)|\(c.paragraphSpacing)|\(c.horizontalMargin)|\(c.topMargin)|\(c.verticalJustify)|\(c.baselineScope.raw)|\(themeKey)|\(darkScheme == .dark)"
        let pager = pageCtl.pager
        pager.config = c
        pager.background = UIColor(theme.bg)
        pageCtl.setMode(pageTurnMode)
        pager.setPageSize(c.pageSize(in: size))

        // ── 全书页平铺：换章不再发生在「用户翻页」那一刻 ──
        // 接近章尾时后台把邻章拉好；数据源那边只剩一条连续序列。
        pager.onNeedChapter = { (c: Int) in
            Task {
                let ok = await session.prefetch(index: c)
                // 邻章文本只能从 session 的预取缓存拿 ——
                // provider 回调只会给当前章，邻章永远拿不到（就会卡在加载页）
                if ok, let t = session.prefetchedText(index: c) {
                    pageCtl.pager.chapterTextArrived(
                        c, PagedChapterPager.ChapterText(title: t.title, body: t.body))
                }
            }
        }
        // 用户翻到了别的章 → 通知上层把 session.index 跟过来（**只跟，不跳**）
        pager.onChapterChange = { (c: Int) in
            guard c >= 0, session.index != c else { return }
            session.followIndex(c)
        }
        pager.onPageChange = { (p: Int, total: Int) in
            pageInfo = (p, total)
            saveProgress(ratio: total > 1 ? Double(p - 1) / Double(total) : 0)
        }

        guard !session.chapterText.isEmpty else { return }
        if session.index == pagedChapter && session.chapterText == pagedText && sig == pagedLayout {
            return
        }
        // 先记下来，下面的 chapterTextProvider 才认这一章
        pagedChapter = session.index
        pagedText = session.chapterText
        pagedTitle = session.chapterTitle
        pagedLayout = sig
        pager.chapterCount = session.flat.count
        let text = PagedChapterPager.ChapterText(title: session.chapterTitle,
                                                 body: session.chapterText)
        // 上层 push，pager 自己存 —— 不再用回调问（回调只会给当前章）
        //
        // ⚠️ 这里**不再**按 switchedChapter 调 loadChapter。
        //    spine 是全书连续的，跨章时 rebuildSpine 自动把新章纳进去，
        //    保持 cursor 就够了。loadChapter 会跳该章首页 ——
        //    现在 session.index 会跟着 pager 走（点击翻页也通知了），
        //    switchedChapter 就常为 true，用户刚点着翻到「第4章第2页」，
        //    load 一回来就被打回第1页。
        //    只有「从目录选章」才该落首页，那条路走 pager.jumpToChapter。
        pager.chapterTextArrived(session.index, text)
    }

    /// 正文到齐 / 出错 → 通知 pager 更新该章的页
    private func syncPagerFailures() {
        if session.errorText.isEmpty {
            pageCtl.pager.chapterTextArrived(
                session.index,
                PagedChapterPager.ChapterText(title: session.chapterTitle,
                                              body: session.chapterText))
        } else {
            pageCtl.pager.chapterFailed(session.index, session.errorText)
        }
    }

    /// 分页模式下把页码比例存成阅读进度
    private func saveProgress(ratio: Double) {
        library.saveProgress(bookID: book.id,
                             chapterIndex: session.index,
                             ratio: ratio,
                             chapterTitle: session.current?.title ?? "")
    }

    private var theme: ReaderTheme {
        let t = ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
        // 开了"跟随系统深浅色"但没手动选色板时，跟系统走
        if followSystemAppearance && themeKey == "auto" {
            return (darkScheme == .dark) ? .dChar : .paper
        }
        return t
    }

    var body: some View {
        // ⚠️⚠️ 这层外层 ZStack 的 alignment **必须是 .bottom**。
        //    我之前手滑写成 .top —— 外层把整个内容块（含内层 ZStack）
        //    当成一个子视图**顶到屏幕上方**，真机表现就是「面板跑到顶部、
        //    内容被裁掉一半」。内层 .bottom 是给面板贴底用的，两层都要 .bottom。
        ZStack(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                theme.bg.ignoresSafeArea()
                GlassBackdrop()
                // 幕布（scrim）：面板弹出时把后面内容压暗一层。
                //
                // ⚠️ iOS 的 detent sheet **理论上**自带 dimmed background，
                //    但 iOS 26 对 `.height()` 这类 detent 的 scrim 很淡/不显示 ——
                //    真机对比：栖阅面板上方的正文区明显压暗（还能看到后面插画），
                //    轻阅这边是正常亮度，完全没有幕布，看着像"贴了块板子上去"。
                //
                // 放在 ZStack **最底层**（正文之下、sheet 之下）：
                // 面板本身是玻璃/透明，所以这层黑会透出来。
                // `.allowsHitTesting(false)`：不能挡 sheet 的下滑关闭手势。
                Color.black.opacity(0.20)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(showSettings ? 1 : 0)
                    .animation(.easeOut(duration: 0.22), value: showSettings)
                GeometryReader { geo in
                    Color.clear
                        .onAppear { syncPager(size: geo.size) }
                        .onChange(of: geo.size) { _, s in syncPager(size: s) }
                }
                .onChange(of: session.errorText) { _, _ in syncPagerFailures() }
                .onChange(of: session.chapterText) { _, _ in syncPager(size: pagerViewport) }
                if useNativePaging {
                    // 原生分页：容器交给 UIPageViewController（系统管手势/边界/动画），
                    // CoreText 只负责把一章文本切成若干页。
                    PagedReaderUI(controller: pageCtl)
                        .ignoresSafeArea(edges: .bottom)
                        .onAppear {
                            // 点中间出目录，左右翻页。
                            // 翻页本身交给系统容器，这里只做菜单和（按设置）点两侧翻页
                            pageCtl.onTapZone = { zone in
                                handleReaderTap(zone: zone)
                            }
                        }
                } else {
                    ReaderWebContainer(
                        host: session.host,
                        pageTurn: true,
                        onSwipe: { delta in session.step(delta) }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }

            if showChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            // 翻到头 / 翻到尾时给一句提示，而不是装没听见
            if let t = edgeToast {
                Text(t)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .liquidGlass(cornerRadius: 999, strength: 1.2)
                    .padding(.top, 96)
                    .transition(.opacity)
            }

                // 面板 overlay：贴在页面底部（等价于 Positioned(bottom: 0)）
                settingsSheet
        }
        .background(theme.bg)
        .task {
            guard !started else { return }
            started = true
            session.onTap = { withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() } }
            // 翻页模式：左边上一章 / 中间出菜单 / 右边下一章
            session.onTapZone = { x in
                // 原生分页模式下正文不在 webview 里，翻页由 PagedReaderUI（UIPageViewController）管
                if useNativePaging { return }
                guard pageTurn else { showChrome = true; return }
                if x < 0.32 {
                    session.step(-1)
                } else if x > 0.68 {
                    session.step(1)
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() }
                }
            }
            // 翻页模式下，章节到边交给分页模块自己处理（它在章内翻到头/尾才抛出来）
            session.onPageEdge = { msg in
                withAnimation(.easeInOut(duration: 0.2)) { edgeToast = msg }
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if edgeToast == msg { edgeToast = nil }
                        }
                    }
                }
            }
            session.attach(sources: sources, library: library)
            let bg = await session.coverDataURL(book.coverUrl)
            await session.start(settings: settingsPayload(coverDataURL: bg))
        }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(chapters: chapters, start: session.current,
                         bookTitle: catalogBookTitle,
                         sourceLabel: sourceSubtitle,
                         preloaded: Set(pageCtl.pager.preloadedChapters()),
                         onJumpToEnd: jumpToLastChapter,
                         onRefreshCatalog: refreshCatalog) { ch in
                showCatalog = false
                if let i = session.flat.firstIndex(where: { $0.url == ch.url }) {
                    session.jump(to: i)
                    // 从目录选章 = 明确要落到该章第一页
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        pageCtl.pager.jumpToChapter(i)
                    }
                }
            }
        }
        // 面板走 overlay（在下面的 ZStack 底部），不用 .sheet
        .sheet(isPresented: $showPageDiag) {
            NavigationStack {
                ScrollView {
                    Text(pageCtl.pager.diagnose(sessionIndex: session.index,
                                                sessionChapterTitle: session.current?.title,
                                                followReceived: session.followReceived,
                                                lastFollow: session.lastFollowIndex))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("分页自检")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("好") { showPageDiag = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 顶栏 / 底栏

    /// 顶栏：圆形返回 / 中间书名+来源 / 右侧圆形封面（照栖阅截图）
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .glassCircle()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(book.name).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Text(book.sourceName).font(.caption2).foregroundStyle(Theme.sub).lineLimit(1)
            }
            Spacer(minLength: 4)
            // coverUrl 是非可选 String，别用 if let（CI 就是在这儿红的）
            if !book.coverUrl.isEmpty, let coverURL = URL(string: book.coverUrl) {
                AsyncImage(url: coverURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                .shadow(radius: 2, y: 1)
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
    }

    /// 底栏：半透明浮层 —— 章节名 + n/N、左右箭头 + 进度滑杆、四个功能键
    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.current?.title ?? "").font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                // 翻页模式下多显示一层"页码 / 总页数"
                Text(pageTurn
                     ? "\(pageInfo.page) / \(max(pageInfo.total, 1)) 页 · 第\(session.index + 1)章"
                     : "\(session.index + 1) / \(max(session.flat.count, 1))")
                    .font(.footnote).foregroundStyle(Theme.sub)
            }
            HStack(spacing: 10) {
                Button { session.step(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                }
                .disabled(session.index <= 0)
                Button { session.step(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                }
                .disabled(session.index >= session.flat.count - 1)
                Slider(
                    value: Binding(
                        get: { Double(session.index) },
                        set: { session.jump(to: Int($0.rounded())) }),
                    in: 0...Double(max(session.flat.count - 1, 1)), step: 1)
            }
            .foregroundStyle(Theme.ink)
            HStack(spacing: 0) {
                barItem("目录", "list.bullet") { showCatalog = true }
                // 朗读 / 章内搜索之前是「点了弹『还没接』」——
                // 给用户一个点下去只会挨骂的按钮，比没有更糟。先撤掉，
                // 等真接上了（正文要从 WKWebView 里取）再加回来。
                barItem("大小", "textformat.size") { showSettings = true }
                // 真机排版自检 —— 沙盒验不了 CoreText，只能让 App 自己吐状态。
                // 翻页/标题出问题时点一下截图，能省掉好几轮猜。
                barItem("自检", "stethoscope") { showPageDiag = true }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .liquidGlass(cornerRadius: 22, strength: 1.15)
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func barItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.caption2)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
        }
    }

    /// 阅读设置 —— 照栖阅那一版布局：
    ///   字号滑杆 + 字体  →  配色格子（浅色一排 / 深色一排）→ 跟随系统深浅色
    ///   →  翻页方式那一排  →  功能宫格
    /// 没接上的功能**只摆位不点**（灰掉），留着当以后的接口。
    /// 阅读设置 —— **照用户给的参考截图 1:1 复刻**。
    ///
    /// 布局（从上到下）：
    ///   ① 一张**磨砂玻璃大卡片**：字号行(小方块/滑块/大方块/字体⌄) + 分隔线
    ///      + 配色(☀ 8个 + 🌙 8个) + 跟随系统深浅色
    ///   ② 一张**磨砂玻璃卡片**：翻页方式(左侧图标 + 5 个胶囊)
    ///   ③ 功能磁贴：4 + 5，每个 = 图标 + 粗体标题(+副标题)
    ///
    /// 面板本身是**半透明磨砂**（能看到底下的正文），
    /// 高度**贴合内容**（下面不留一大块空白）。
    /// 面板 = 页面底部的 **overlay**，不是 `.sheet`。
    ///
    /// 为什么不用 sheet（绕了好几天才想明白）：
    ///   · iOS 的 sheet 活在**独立窗口**里 → 顶部**必然**留一截空，永远贴不了边；
    ///   · 面板在那个窗口里，`BackdropFilter` / `.ultraThinMaterial`
    ///     **模糊不到后面的正文和主题插画** —— 那就不是玻璃，是一块贴在屏幕上的板子。
    ///
    /// 参考实现本来就是这么摆的：
    ///     Stack(children: [
    ///       Container(decoration: BoxDecoration(image: ...wallpaper)),
    ///       Positioned(left: 0, right: 0, bottom: 0, child: ReaderPanel()),
    ///     ])
    /// 代价是失去系统 sheet 自带的下滑关闭手势 —— 下面自己实现了一个。
    private var settingsSheet: some View {
        settingsContent
            // ⚠️ overlay 没有 detent 撑着，NavigationStack 会把面板吃成**全屏**，
            //    背景铺满整屏、内容居中（真机就是这样炸的）。
            //    显式给死高度 —— sheetHeight 是用 PreferenceKey 量出来的内容真实高度。
            // ⚠️⚠️ **不许**用 `.frame(height:)` 固定内容区高度！
            //
            //    那个 frame 会把内容**裁到指定高度**—— 控件放不下就少一截，
            //    看着就是「被挡」（用户连续多轮反馈）。
            //    正确做法：`.fixedSize` 让内容按**自然高度**撑开，**一点不裁**，
            //    缺多少补多少（用户原话：「把缺的补全」）。
            //
            //    面板总高 = 内容自然高 + 内部 padding + 定位 padding，
            //    贴底对齐，超屏的风险由内容本身控制（不像 background 里
            //    那种 flexible Shape 会无脑撑满）。
            .fixedSize(horizontal: false, vertical: true)

            // ── ui.txt 的 .panel 有**两个不同层级**的留白，别写成重复的 ──
            //
            //   .panel { left:14px; right:14px; bottom:14px;   ← ① 定位：离屏幕边 14
            //            padding: 12px 14px 16px }                ← ② 内部：面板里面再留 14
            //
            // 我之前把 ① 和 ② 都写成 `.padding(.horizontal, 14)`，
            // **累加成左右各 28** → 玻璃背景跟着撑宽 → 内容溢出屏幕，
            // 真机上色块第 8 个、宫格「高亮」右边都被切掉。
            //
            // 正确层次（从内到外）：
            //   内容 → ②内部 padding → 玻璃 → ①定位留白
            //
            // ② 内部 padding（玻璃**里面**）
            //
            // 顶部 12 → 30 → 42 → 50 → **56**：用户连续要「按钮整体下移一点」。
            // 栖阅真机面板顶到「小」那行的距离约 **42pt**（截图量）。
            .padding(.top, 56)
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            // 面板背景 = **液态玻璃**（iOS 26 的 `.glassEffect`）。
            //
            // 用户明确要的：栖阅风格**液态玻璃**。build102 我拿「折射会扭掉边缘控件」
            // 把它换成磨砂白，那是**误解**了诉求 —— 折射不是问题的成因，
            // 成因是**内容区高度不够、控件被裁**（见下面 fixedSize）。
            //
            // ⚠️ 必须用 `background(_:in:)` 重载，**不能**写 `.background { Shape }`：
            //    后者闭包里的 Shape 是 flexible view，ZStack 给多大 proposal
            //    它就撑多大 → 背景铺满整屏（build88 炸过）。
            .background(
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            )

            // ① 定位留白（玻璃**外面**）：面板离屏幕左右各 14、离底 14
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            .offset(y: showSettings ? 0 : sheetHeight + 48)
            .opacity(showSettings ? 1 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.86),
                       value: showSettings)
            .allowsHitTesting(showSettings)
            // 下拉关闭：grabber 那条区域往下拖
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { v in
                        if v.translation.height > 42
                            || v.predictedEndTranslation.height > 90 {
                            showSettings = false
                        }
                    }
            )
            .accessibilityIdentifier("readerSettingsPanel")
    }

    /// 面板浅米底（参考实现 `Color(0xE6EFE7D6)`）
    private static var qrPanel: Color {
        Color(red: 239.0/255.0, green: 231.0/255.0, blue: 214.0/255.0)
            .opacity(0.90)
    }

    /// 面板内容
    private var settingsContent: some View {
        // 内容宽度锁死在可用宽内 —— 任何一行撑爆都会把整个面板顶出屏幕
        NavigationStack {
            // ⚠️⚠️ 必须用 VStack 把 panelContent + featureGrid **包起来**，
            //    再把 `.fixedSize` 和测高 GeometryReader 挂在 **VStack** 上。
            //
            //    之前是平级两个子元素，修饰符只作用于**紧挨着的那一个**
            //    （featureGrid）—— 量到的只是宫格高度（≈160pt），
            //    不是整个面板高度（≈500pt）。面板被压扁、内容溢出，就炸了。
            VStack(spacing: 0) {
                panelContent
                featureGrid
            }
            .frame(maxWidth: .infinity)
            // 固定成内容本来的高度 —— 这样量出来的才是真实高度，
            // 不会被 detent 限制（限住就成了循环依赖）
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: SheetContentHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(SheetContentHeightKey.self) { h in
                guard h > 0 else { return }
                // 导航栏整个藏了，所以不用再给它留高度（原 +56 / +46 都不需要）。
                // ⚠️ 硬上限 = 屏幕的 70%。overlay 没有 detent 兜底，
                //    万一 PreferenceKey 量到离谱的值（比如某个子视图 flexible 撑开），
                //    面板也不至于铺满全屏 —— build88 就是这么炸的。
                let screenH = UIScreen.main.bounds.height
                let hardCap = screenH * 0.70
                let target = min(max(h + 4, 260), 840, hardCap)
                if abs(target - sheetHeight) > 1 { sheetHeight = target }
            }
            // 16 / 16 / 16 / **28** —— 底部 28 是给 home indicator 让的位置，
            // 面板贴到屏边但最后一行磁贴不会压在指示条上。
            // 参考实现 padding: fromLTRB(12, 14, 12, 14)
            .padding(.horizontal, 12)
            // 顶部不再留呼吸区 —— overlay 贴底之后内容整体往下坐
            .padding(.top, 0)
            .padding(.bottom, 12)
            // ⚠️ 整个导航栏藏掉：没有「阅读设置」大标题，也没有右上角「完成」。
            //    栖阅那个面板顶部直接就是「小 ▬ 大 [系统字体]」，标题栏压根不存在。
            //    NavigationStack 还得留着 —— 子页（显示/间距/更多）是 push 进去的。
            .toolbar(.hidden, for: .navigationBar)
            // ⚠️⚠️ **这才是「面板看着是米黄色实心」的真正元凶**。
            //
            //    NavigationStack 内部的 `containerBackground` 默认是**不透明**的
            //    `systemBackground`。我只给三个**子页**写了 ClearNavigationBackground，
            //    **根页漏了** → 系统玻璃被这一层不透明底整个遮死，
            //    后面插画透不出来，面板看着像一块米黄色的板子。
            //
            //    栖阅那块能透出后面的枯枝和小熊，就是因为它没有这层底。
            //    （对照：目录面板我重写时去掉了 NavigationStack，所以它是透明的 —— 对得上）
            .modifier(ClearNavigationBackground())
            // ⚠️ 这里**没有 toolbar** —— 「完成」按钮整个去掉了。
            //    栖阅那个面板就没有右上角任何按钮，靠下拉关闭。
            //    留着它不仅占宽度，还和磁贴里那格「大小 / 显示设置」语义重复。
            // ⚠️ 根页藏了导航栏，**子页必须显式恢复** ——
            //    `.toolbar(.hidden, for: .navigationBar)` 是对整个
            //    NavigationStack 生效的，不在子页写 `.visible` 的话，
            //    push 进去导航栏也是隐的 → 连返回按钮都没有，用户出不来。
            //    子页的标题（显示设置 / 间距设置 / 更多设置）也正是这时候才有用。
            .navigationDestination(isPresented: $showDisplaySettings) {
                displaySettingsPage
                    .toolbar(.visible, for: .navigationBar)
                    // 推入的页面默认带一层不透明背景，会把 sheet 的玻璃盖掉
                    .modifier(ClearNavigationBackground())
            }
            .navigationDestination(isPresented: $showLayoutSettings) {
                layoutSettingsPage
                    .toolbar(.visible, for: .navigationBar)
                    // 推入的页面默认带一层不透明背景，会把 sheet 的玻璃盖掉
                    .modifier(ClearNavigationBackground())
            }
            .navigationDestination(isPresented: $showMoreSettings) {
                moreSettingsPage
                    .toolbar(.visible, for: .navigationBar)
                    // 推入的页面默认带一层不透明背景，会把 sheet 的玻璃盖掉
                    .modifier(ClearNavigationBackground())
            }
        }
    }

    /// 面板**上半**那块「被光打亮」的区域 —— 字号行 / 配色 / 跟随系统 /
    /// 翻页方式，全都坐在**这一块**里面。
    ///
    /// 栖阅截图的确切结构（用户圈出来的那块）：
    ///
    ///   ┌───────────────────────────────┐  ← 这块整体更亮，边缘带柔和阴影
    ///   │  小  ▬▬▬▬▬▬  大  [系统字体 ∨] │
    ///   │  ☀ 文A 文B 文C …               │
    ///   │  ◐ 跟随系统深浅色      [开关]   │
    ///   │  📄 仿真 滑动 平移 无动画 上下 │
    ///   └───────────────────────────────┘
    ///   [大小][间隔][朗读][高亮]   ← 这块是**裸的面板玻璃**，磁贴没有底
    ///   [气泡][格式][页眉][更多]       （能透出后面的插画）
    ///
    /// 走过两个弯路：
    ///   build76 — 每块各垫一层 → 太碎，8 个磁贴多出一排小卡片
    ///   build79 — 索性全删 → 删过头，上半不够「亮」，和下半糊成一片
    /// 正确的是**上半一整块亮底 + 轻阴影，下半不垫**。
    /// 面板内容 —— **没有内层白卡**。
    ///
    /// ⚠️ 我从 build82 起就以为用户说的「中间有一块阴影」= 一层白色块，
    ///    于是加了个 `white @ 0.35 / radius 22` 的内嵌卡。第 5 版参考实现说清楚了：
    ///
    ///        .panel { background: rgba(255,255,255,.82);
    ///                 backdrop-filter: blur(24px);
    ///                 box-shadow: 0 4px 30px rgba(0,0,0,.12); }
    ///
    ///    「阴影」= **这个玻璃容器自己投的 box-shadow**，
    ///    控件坐在**容器**里，不是在「容器里的白块」里。
    ///    从 build82 到 build89 一直多加了一层不该有的东西。
    private var panelContent: some View {
        VStack(spacing: 0) {
            sizeRow
            hairLine
            paletteGrid
            followSystemRow
            hairLine
            pageTurnRow
        }
    }
    /// ui.txt: .divider { height:1px; background:rgba(0,0,0,.07); margin:0 2px 10px }
    private var hairLine: some View {
        Color.black.opacity(0.07)
            .frame(height: 1)
            .padding(.horizontal, 2)
            .padding(.bottom, 10)
    }

    // MARK: - ① 字号行（小方块 + 滑块 + 大方块 + 字体下拉，全在一行）

    private var sizeRow: some View {
        // ui.txt: .row-fontsize { padding: 0 2px 10px; gap: 10 }
        // 字号滑块 14...28（ui.txt 的 min=14 max=28，不是 14...34）
        // ui.txt: .row-fontsize { gap: 10 }，滑块是 `<input type=range>`（width:100%）
        //
        // ⚠️ 但 SwiftUI 的 `Slider` 在 iOS 26 新样式下，**滑轨会画到自己 frame 之外**
        //    （两端有外延），HStack 的 spacing 只管**视图框**、管不住**绘制外延** →
        //    「小」按钮的圆形底会**盖住滑轨左端一小截**（用户反馈「滑块被挡了一点」）。
        //
        //    修法：给 Slider 留出绘制外延的空间（padding），
        //    同时把 HStack spacing 收窄，总视觉间距不变。
        // ⚠️ spacing 必须是 12（ui.txt 的 gap:10 + 一点余量）。
        //    我为了塞 thumb 把它收到 2 → 「小」按钮的圆底和滑轨**只差 2pt**，
        //    视觉上就是「滑块被小按钮压住」（用户连续三次反馈「被挡」）。
        //    自绘 QRSlider 之后 thumb 本来就两端正位，**根本不需要收窄 spacing**。
        HStack(spacing: 12) {
            sizeKnob("小", pointSize: 14)
            // ⚠️ 用自绘的 QRSlider，**不用系统 Slider**。
            //    连续两次真机反馈「滑块被挡了一点」「上面被挡」——
            //    iOS 26 的系统 Slider frame 高度比 thumb 直径小（thumb 上下溢出
            //    自己 frame 画的），跟相邻控件打架、还会被裁。
            //    QRSlider 照 ui.txt 的 `<input type=range>` 逐项自绘：
            //    轨道 6、thumb 26 白圆带阴影、已填充段 #4a90d9。
            QRSlider(value: $fontSize, range: 14...28, step: 1)
            sizeKnob("大", pointSize: 14)
            fontMenu
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    /// 小 / 大：灰底圆角方块
    private func sizeKnob(_ text: String, pointSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(width: 34, height: 34)   // ui.txt: .fs-btn { width:34; height:34; border-radius:50% }
            .background(Self.qrFill, in: Circle())
    }

    /// ui.txt: .font-select { padding:7px 13px; border-radius:18px;
    ///                     font-size:14px; color:#333; background:rgba(0,0,0,.06) }
    private var fontMenu: some View {
        Menu {
            ForEach(ReaderFont.all) { f in
                Button(f.name) { fontKey = f.raw }
            }
        } label: {
            HStack(spacing: 4) {
                Text(ReaderFont.name(for: fontKey))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(white: 0x99 / 0xff))   // ui.txt ⌄ #999
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(white: 0x33 / 0xff))            // ui.txt #333
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - ③ 配色格子

    private var paletteGrid: some View {
        VStack(spacing: 8) {
            paletteRow(ReaderTheme.light, icon: "sun.max.fill")
            paletteRow(ReaderTheme.darkRow, icon: "moon.fill")
        }
        .padding(.vertical, 8)
    }

    private func paletteRow(_ list: [ReaderTheme], icon: String) -> some View {
        // 参考实现 .swatch { width/height 42; border-radius 9 } gap 8
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.sub)
                .frame(width: 28)
            ForEach(list) { t in
                Button { themeKey = t.key } label: {
                    Text("文")
                        // 参考实现：width 42、cornerRadius 12、字号 15、
                        // 边框 = 选中 blue 2px / 否则 black @ .08 1px
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(t.ink)
                        // ⚠️⚠️ 不能用固定 `width: 42`！
                        //    8 个 × 42 + 7 个间距 × 8 + 图标槽 28 = **428pt**，
                        //    而可用宽只有 440 − 14×2(定位) − 14×2(内部) = **412pt**
                        //    → 超 16pt，整个内容被撑宽、居中后**两边都溢出被裁**
                        //    （真机：左边「小」被切、右边色块第8个/开关/「高亮」被切）
                        //
                        // 栖阅真机是 **8 个均分贴边**的，所以这里用 maxWidth:.infinity
                        // 均分，高度仍固定 42（保持方块比例）。
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(t.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(themeKey == t.key ? Theme.accent
                                              : Color.black.opacity(0.08),
                                              lineWidth: themeKey == t.key ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - ④ 跟随系统深浅色

    // ui.txt .row-follow { padding:4px 2px 10px }
    //    .label font-size:15  .ic 18  .switch 50×29 radius:15 on时 #4a90d9
    private var followSystemRow: some View {
        HStack {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 18)).foregroundStyle(Color(white: 0x77 / 0xff))
            Text("跟随系统深浅色").font(.system(size: 15))
                .foregroundStyle(Color(white: 0x33 / 0xff))
            Spacer()
            Toggle("", isOn: $followSystemAppearance).labelsHidden()
                .tint(Color(red: 74/255, green: 144/255, blue: 217/255))
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - ⑥ 翻页方式那一行

    /// 自己的底**并进 upperPanelCard** 了，这里只留内容 + 上下留白。
    private var pageTurnRow: some View {
        // ui.txt: .row-pageturn { padding:0 0 12px; gap:8 }
        //        .pt-icon { width:28; font-size:17; color:#888 }
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "book").font(.system(size: 17)).foregroundStyle(Color(white: 0x88 / 0xff))
                .frame(width: 28)
            // 参考实现：`.pill { flex-shrink:0; padding:8px 17px; radius:18; fs:14 }`
            // **不等分** —— 每个 pill 按内容宽度排，放不下就**横向滚动**。
            //
            // 我在 build86 死磕了三轮等分（fillsWidth）：
            //   ① 平分装不下「上下滚动」→ 缩字号 13→12 去补   ← 治错了
            //   ② 改 Wrap/LazyVGrid 换行 → 真机断成「无动\n画」 ← 又错
            //   ③ 现在才知道正解是**不等分 + 横向滚动**，
            //      「上下滚动」字号 14 也完整，因为没人跟它抢宽度。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PageTurnMode.all) { m in
                        ChipButton(title: m.name, selected: pageTurnMode == m.raw) {
                            pageTurnMode = m.raw
                            pageTurn = m.raw != "scroll"
                        }
                    }
                }
            }
            .scrollDisabled(false)
        }
        .padding(.bottom, 12)
    }

    // MARK: - ⑦ 功能磁贴（4 + 4，照栖阅截图）

    /// **照栖阅截图逐格抄的文案**，不是我自己起的名：
    ///
    /// | 格 | 大字 | 小字     | 图标 |
    /// |---|---|---|---|
    /// | 1 | 大小 | 显示设置 | doc.text |
    /// | 2 | 间隔 | 间隔设置 | ≡ 横线 |
    /// | 3 | 朗读 | 朗读设置 | speaker |
    /// | 4 | 高亮 | 高亮设置 | highlighter |
    /// | 5 | 气泡 | 设置     | bubble |
    /// | 6 | 格式 | 标题样式 | **无** |
    /// | 7 | 页眉 | 页脚     | doc.text |
    /// | 8 | 更多 | 设置     | ellipsis.circle |
    ///
    /// ⚠️ 必须是 **4 + 4 = 8 格**。我之前是 4 + 5（把「格式」和「标题样式」
    ///    拆成了两格），第二行比第一行长一截 —— 这就是「怪」的来源之一。
    ///    栖阅那个「格式」是大字、「标题样式」是它的小字，本来就是**一格**。
    private static let tiles: [(name: String, subtitle: String, icon: String, ready: Bool)] = [
        ("大小", "显示设置", "doc.text", true),
        ("间隔", "间隔设置", "line.3.horizontal.decrease", true),
        ("朗读", "朗读设置", "speaker.wave.2", false),
        ("高亮", "高亮设置", "highlighter", false),
        ("气泡", "设置", "bubble.left.and.bubble.right", false),
        ("格式", "标题样式", "", false),          // ← 栖阅这格**没有图标**
        ("页眉", "页脚", "doc.text", false),
        ("更多", "设置", "ellipsis.circle", true),
    ]

    private var featureGrid: some View {
        // 参考实现 .grid { gap: 8px 8px }
        VStack(spacing: 8) {
            tileRow(0)
            tileRow(4)
        }
    }

    /// 一行 4 格。⚠️ `Self.tiles` 是**元组数组**，元组不是 Identifiable，
    ///    所以这里必须显式给 `id: \.name`（内容稳定、唯一）。
    ///    之前有一条门禁要求「所有 ForEach 都不用 id: 重载」——
    ///    那条只对 `Identifiable` 元素成立，套到元组上是错的。
    private func tileRow(_ from: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.tiles[from..<min(from + 4, Self.tiles.count)]), id: \.name) { t in
                featureTileLabel(name: t.name, subtitle: t.subtitle,
                                 icon: t.icon, ready: t.ready) {
                    if t.name == "大小" { showDisplaySettings = true }
                    else if t.name == "间隔" { showLayoutSettings = true }
                    else if t.name == "更多" { showMoreSettings = true }
                }
            }
        }
    }

    // MARK: - 栖阅设计 token
    //
    // ⭐ 抄自栖阅 `designer.css` 的 `:root`，不是凭感觉定的：
    //     --r-sm: 8px;  --r-md: 12px;  --r-lg: 16px;  --r-pill: 999px;
    //     --tap: 44px;
    //     --panel:      rgba(255,255,255,0.86);
    //     --fill:       rgba(120,120,128,0.12);
    //     --fill-strong:rgba(120,120,128,0.20);
    //     --line:       rgba(60,60,67,0.12);
    //     --accent:     #0a84ff;
    //
    // ⚠️ 最容易错的是 **--fill 带蓝调**（120,120,128 是个偏冷的灰）。
    //    我之前用 `Color.gray.opacity(0.18)` —— 那是**纯灰 18%**，
    //    叠在暖色纸背景上会显脏。这就是面板看着"怪"的原因之一。

    /// --fill：控件底色（按钮、滑杆、胶囊）
    private static let qrFill = Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.12)
    /// --line：细分隔线
    private static let qrLine = Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.12)

    /// 一个磁贴（图标 + 粗体大字 + 小字副标题）。
    ///
    /// 没接的**只摆位不点**：灰掉、点不动。给用户一个点下去只会挨骂的
    /// 按钮，比没有更糟（用户明确要求过）。
    private func featureTileLabel(name: String, subtitle: String?, icon: String,
                                  ready: Bool, action: @escaping () -> Void = {}) -> some View {
        Button {
            guard ready else { return }
            action()
        } label: {
            // 参考实现是**两行文字**、没有图标行：
            //     <span class="ic">大小</span><span class="t1">显示设置</span>
            //     .cell { padding: 9px 4px 8px; border-radius: 12px; gap: 4px }
            //     .ic 18px  /  .t1 13px  /  .t2 display:none
            //
            // 所以**不需要空图标占位那个 hack**（那是我为了对齐自造图标行才加的），
            // 也**不需要固定高度** —— 内容高度自然就一样。
            // ui.txt .cell { gap:4 }  .ic 18px  .t1 13px  .t2 display:none
            // 8 格都是「图标(文字) + 副标题」，没有第三行，所以**只画两行**：
            //     第一行 .ic 实际是中文大字（"大小"/"间隔"/…）
            //     第二行 .t1 是副标题（"显示设置"/"间隔设置"/…）
            VStack(spacing: 4) {
                Text(name).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(white: 0x22 / 0xff))     // ui.txt #222
                Text(subtitle ?? "").font(.system(size: 13))
                    .foregroundStyle(Color(white: 0x99 / 0xff))     // ui.txt #999
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // 区分「已实现 / 没实现」靠**文字深浅**，不是有没有底
            .foregroundStyle(ready ? Theme.ink : Theme.sub.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background(Self.qrFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
    }

    // MARK: - 子页：显示设置

    private var displaySettingsPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                sizeRow
                hairLine
                paletteGrid
                followSystemRow
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("显示设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 子页：间距设置（栖阅 ReaderLayoutSettingsView）

    private var layoutSettingsPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                sectionHeader("行距")
                HStack {
                    Text("行间距").font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\\(Int(lineSpacing))").font(.subheadline).foregroundStyle(Theme.sub)
                    Stepper("", value: $lineSpacing, in: 0...30, step: 1).labelsHidden()
                }
                .padding(.vertical, 8)

                sectionHeader("段落")
                HStack {
                    Text("段落间空行").font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\\(Int(paraSpacing))").font(.subheadline).foregroundStyle(Theme.sub)
                    Stepper("", value: $paraSpacing, in: 0...12, step: 1).labelsHidden()
                }
                .padding(.vertical, 8)
                paraAlignRow

                sectionHeader("底线")
                settingRow(title: "行底线", icon: "line.3.horizontal",
                           subtitle: "开启后会在正文每一行底部绘制整行横线") {
                    Toggle("", isOn: $showBaseline).labelsHidden().tint(Theme.accent)
                }
                if showBaseline {
                    HStack {
                        Text("独立底线颜色").font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        ColorPicker("", selection: baselineColorBinding, supportsOpacity: true)
                            .labelsHidden()
                            .frame(width: 30, height: 24)
                    }
                    .padding(.vertical, 6)
                    baselineScopeRow
                }

                sectionHeader("对齐")
                settingRow(title: "垂直两端对齐", icon: "arrow.up.and.down",
                           subtitle: "开启后每页文字会自动调整行间距以填满页面，使底部对齐整齐") {
                    Toggle("", isOn: $verticalJustify).labelsHidden().tint(Theme.accent)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("间距设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 段落对齐那一行（单独拆出来，别跟别的塞一个表达式）
    private var paraAlignRow: some View {
        HStack(spacing: 6) {
            Text("段落对齐").font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            ForEach(ReaderParaAlign.all) { a in
                ChipButton(title: a.name, selected: paraAlign == a.raw) { paraAlign = a.raw }
            }
        }
        .padding(.vertical, 8)
    }

    /// 底线范围那一行（拆出来防类型检查超时）
    private var baselineScopeRow: some View {
        HStack(spacing: 6) {
            Text("底线范围").font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            ForEach(ReaderBaselineScope.all) { sc in
                ChipButton(title: sc.name, selected: baselineScope == sc.raw) { baselineScope = sc.raw }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - 子页：更多设置（栖阅 ReaderSettingsView 里那几项）

    /// 栖阅阅读设置页里还有几项不在参考截图上的开关，
    /// 放这里，不丢功能，主页面视觉也跟参考截图一致。
    private var moreSettingsPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                sectionHeader("阅读")
                settingRow(title: "点击页面任意位置翻到下一页", icon: "hand.tap",
                           subtitle: "中间区域仍可打开菜单") {
                    Toggle("", isOn: $tapAnywhereTurnsPage).labelsHidden().tint(Theme.accent)
                }
                settingRow(title: "上滑退出阅读", icon: "arrow.up") {
                    Toggle("", isOn: $swipeUpExit).labelsHidden().tint(Theme.accent)
                        .disabled(true)
                }
                settingRow(title: "iPad 或宽屏横屏时自动同屏显示左右两页", icon: "rectangle.split.2x1") {
                    Toggle("", isOn: $twoPageSpread).labelsHidden().tint(Theme.accent)
                        .disabled(true)
                }
                settingRow(title: "内容限制在页眉页脚之间，不遮挡", icon: "rectangle.split.2x1.bottomhalf") {
                    Toggle("", isOn: $contentInHeaderFooter).labelsHidden().tint(Theme.accent)
                        .disabled(true)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("更多设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 小组件

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.sub)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    /// 一行设置：标题 +（可选）说明 + 右边的东西
    private func settingRow<Accessory: View>(title: String,
                                              icon: String,
                                              subtitle: String? = nil,
                                              @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.sub)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(Theme.sub)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 8)
    }

    private func settingsPayload(coverDataURL: String?) -> [String: Any] {
        [
            "fontFamily": ReaderFont.family(for: fontKey),
            "fontSize": fontSize,
            "fontWeight": 0,
            "letterSpacing": 0.5,
            "lineSpacing": lineSpacing,
            "paragraphSpacing": 16,
            "textIndent": 0,
            "textColorHex": hex(theme.ink),
            "backgroundColorHex": hex(theme.bg),
            // 封面当背景：栖阅阅读页那个「虚化铺底」就是这么来的
            "hasBackgroundImage": coverDataURL != nil,
            "backgroundImageDataURL": coverDataURL ?? "",
            "isDarkMode": followSystemAppearance && (darkScheme == .dark),
            "isNightMode": ReaderTheme.isDark(theme),
            "fullScreen": false,
            "leftMargin": 20,
            "rightMargin": 20,
            "textAlign": "left",
            "highlightStyles": [],
            "fontFaceCSS": ""
        ]
    }

    private func hex(_ c: Color) -> String {
        let u = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

/// 宫格里的一项。`ready = false` = 还没接，只摆位不点。

/// 字体
struct ReaderFont: Identifiable, Hashable {
    let raw: String
    let name: String
    /// 给 reader.js 的 fontFamily
    let family: String
    var id: String { raw }

    static let all: [ReaderFont] = [
        .init(raw: "system", name: "系统字体", family: "System"),
        .init(raw: "song",   name: "宋体",     family: "Songti SC"),
        .init(raw: "hei",    name: "黑体",     family: "Heiti SC"),
        .init(raw: "kai",    name: "楷体",     family: "Kaiti SC"),
        .init(raw: "serif",  name: "衬线",     family: "Georgia")
    ]
    static func name(for raw: String) -> String {
        all.first(where: { $0.raw == raw })?.name ?? "系统字体"
    }
    static func family(for raw: String) -> String {
        all.first(where: { $0.raw == raw })?.family ?? "System"
    }
}

/// 翻页方式（对应参考 App 那一排）
struct PageTurnMode: Identifiable, Hashable {
    let raw: String
    let name: String
    var id: String { raw }

    static let all: [PageTurnMode] = [
        .init(raw: "flip",   name: "仿真"),
        .init(raw: "slide",  name: "滑动"),
        .init(raw: "flat",   name: "平移"),
        .init(raw: "none",   name: "无动画"),
        .init(raw: "scroll", name: "上下滚动")
    ]

    /// 栖阅自己的说明文案（从它的二进制字符串表里挖出来的原文）
    static func hint(for raw: String) -> String {
        switch raw {
        case "flip":   return "模拟真实翻书效果，页面卷曲翻转"
        case "slide":  return "类似 Apple Books 的左右滑动翻页"
        case "flat":   return "左右平移动画翻页"
        case "none":   return "无翻页动画，立即切换"
        case "scroll": return "上下滚动浏览，连续阅读体验"
        default:       return ""
        }
    }
}

/// WKWebView 的 SwiftUI 容器。
///
/// 额外挂一个**横向**滑动手势做翻页：
///   · 加在 WKWebView 自身（不是 SwiftUI 覆盖层）—— 覆盖层会把触摸全吃掉，
///     正文就没法上下滚了；
///   · `direction = .horizontal` 且 `cancelsTouchesInView = false`
///     —— 纵向滚动完全不受影响，iOS 自己就会把纵向手势给 web view。
struct ReaderWebContainer: UIViewRepresentable {
    @ObservedObject var host: ReaderHost
    /// 翻页模式开关（存 AppStorage，由外层传进来）
    var pageTurn: Bool
    /// 翻页回调：+1 下一章 / -1 上一章
    var onSwipe: ((Int) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let g = UISwipeGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipe(_:)))
        // ⚠️ Direction 枚举只有 left/right/up/down 四个，
        //    那个"横��"成员属于 UIScrollView，编译期就会炸。
        g.direction = [.left, .right]
        // ⚠️ 不吃掉触摸：否则 web view 收不到手势，正文滚不动
        g.cancelsTouchesInView = false
        g.delegate = context.coordinator
        host.web.addGestureRecognizer(g)
        context.coordinator.gesture = g
        context.coordinator.owner = self
        return host.web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.gesture?.isEnabled = pageTurn
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: ReaderWebContainer?
        weak var gesture: UISwipeGestureRecognizer?

        @objc func handleSwipe(_ g: UISwipeGestureRecognizer) {
            guard let o = owner, let cb = o.onSwipe else { return }
            switch g.direction {
            case .left:  cb(1)    // 左滑 = 下一章
            case .right: cb(-1)   // 右滑 = 上一章
            default: break
            }
        }

        /// 只处理横向手势，纵向留给 WKWebView 自己滚
        nonisolated func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
            guard let s = gr as? UISwipeGestureRecognizer else { return true }
            let v = s.view
            let w = v?.bounds.width ?? 0
            // 宽度都不到 200pt 的窄屏（分屏/小窗）不启用，免得误触
            return w >= 200
        }
    }
}


/// 设置项里那种小胶囊按钮。
///
/// ⚠️ 单独抽出来是有原因的：把
///   Button { } label: { Text(…).font(…).foregroundStyle(选中 ? .white : 主题色)
///                              .padding(…).background(RoundedRectangle(…).fill(选中 ? … : …)) }
/// 整坨塞进 HStack 里，Swift 的类型检查器会**超时**
/// （"unable to type-check this expression in reasonable time"）。
/// 抽成独立 View 之后每个表达式都简单了，编译就过了。
private struct ChipButton: View {
    let title: String
    let selected: Bool
    var fontSize: CGFloat = 14
    var cornerRadius: CGFloat = 18
    var fillsWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize))
                .foregroundStyle(selected ? Color.white : Theme.ink)
                // 参考实现 .pill { padding: 8px 17px; border-radius: 18px }
                .padding(.horizontal, 17)
                .padding(.vertical, 8)
                // ui.txt: .pill { background:rgba(0,0,0,.06); color:#333 }
                //        .pill.active { background:#4a90d9; color:#fff }
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selected
                             ? Color(red: 74/255, green: 144/255, blue: 217/255)
                             : Color.black.opacity(0.06))
                )
                .foregroundStyle(selected ? .white : Color(white: 0x33 / 0xff))
                .fixedSize()
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.plain)
    }
}





/// 量内容高度用的 preference
private struct SheetContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


/// 把 push 出来的页面背景清掉。
///
/// 部署目标已是 iOS 26，`containerBackground(_:for: .navigation)` 直接用。
/// （iOS 18 才引入这个 API，之前的 iOS 17 目标需要 fallback —— 现在不需要了）
private struct ClearNavigationBackground: ViewModifier {
    func body(content: Content) -> some View {
        // 部署目标 iOS 26 → 直接用，不需要 #available 分派
        content.containerBackground(.clear, for: .navigation)
    }
}
