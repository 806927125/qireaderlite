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
    /// 设置面板按住下拖时的位移（跟目录的拖拽关闭一个手感）
    @State private var panelDragOffset: CGFloat = 0
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

    /// Swift 滚动阅读用的「已加载正文」集合：当前章 + 已预取的邻章。
    private var scrollLoadedTexts: [Int: String] {
        var d: [Int: String] = [:]
        let i = session.index
        if !session.chapterText.isEmpty { d[i] = session.chapterText }
        for j in (i - 2)...(i + 2) where j != i {
            if let t = session.prefetchedText(index: j) { d[j] = t.body }
        }
        return d
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

    /// 排版/主题的**统一签名** —— 任何一项变了都要立刻重排。
    ///
    /// ⚠️ 之前只挂了 `onChange(of: themeKey)` 等零散几项，结果：
    ///   · 分页模式：改字号/行距**不生效**（`syncPager` 只在尺寸/正文变化时调）
    ///   · 滚动模式：只有字号生效（`fontSize` 恰好是 @AppStorage，能触发 body 重算）
    ///   · 行距/段距/对齐/基线/字体 —— 全都不生效
    ///
    /// 合成一个签名统一监听，一次覆盖全部。
    /// ⚠️ 只能列**真实存在**的 @AppStorage（horizontalMargin 是 layoutConfig 里写死的 20，
    ///    不是 @AppStorage，引用它编译不过）。
    private var readerLayoutSig: String {
        "\(fontSize)|\(lineSpacing)|\(paraSpacing)|\(themeKey)|\(followSystemAppearance)|"
            + "\(darkScheme == .dark)|\(fontKey)|\(paraAlign)|\(verticalJustify)|"
            + "\(showBaseline)|\(baselineScope)|\(baselineColorHex)"
    }

    /// ⚠️ 换阅读设置（配色 / 字号 / 行距…）后，**两条渲染路径都要重新下发**：
    ///
    ///   ① **原生分页**：`layoutConfig` 是 computed property，主题色在里面
    ///      （`textColor: UIColor(theme.ink)` / `backgroundColor: UIColor(theme.bg)`），
    ///      但它只有被 `syncPager` 重新求值并赋给 `pager.config` 才生效。
    ///      而 `syncPager` 之前**只在尺寸变化时**被调用 → 改设置不动。
    ///      状态栏（SwiftUI 层）立刻变了，正文（pager 自己画）却没变。
    ///
    ///   ② **Swift 滚动模式**：`SwiftScrollReaderView` 靠 `config` 重排，
    ///      SwiftUI body 重算就会传新 config ✓（这里再调一次是保险）。
    ///
    /// 症状：用户说「换背景只有状态栏生效，要重进正文才变过来」。
    private func applyThemeChange() {
        // ① 原生分页：重新求值 layoutConfig → pager.config → 重排（sig 含 themeKey，不会被幂等挡掉）
        syncPager(size: pagerViewport)
        // ② WebView 滚动模式：重新下发 settings（applySettings 是幂等可重入的）
        //
        // ⚠️ 不能写 `[weak self]` —— ReaderWebView 是 **struct**（SwiftUI View），
        //    不是 class，编译报 "'weak' may only be applied to class and
        //    class-bound protocol types, not 'ReaderWebView'"。
        Task {
            let bg = await session.coverDataURL(book.coverUrl)
            session.host.setSettings(settingsPayload(coverDataURL: bg))
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
            // ⚠️ 换背景（配色 / 跟随系统深浅色）必须**立刻**生效，
            //    不能要退出重进正文才变（真机反馈）。
            // ⚠️ 任何一项排版/主题设置变了都要**立刻**生效，
            //    不能要退出重进正文才变（真机反馈）。
            //    监听**统一签名**，一次覆盖字号/行距/段距/配色/字体/对齐/基线。
            .onChange(of: readerLayoutSig) { _, _ in applyThemeChange() }
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
                    // ⚠️ Swift 原生滚动阅读 —— 替代 `reader.html` + `ReaderHost` 的
                    //    WebView 渲染。
                    //    迁移原因：WebView 那条路**阅读设置只在 session.start() 时
                    //    下发一次**，换背景/字号要退出重进正文才生效（真机反馈）；
                    //    而且正文样式要靠 CSS 跟 SwiftUI 侧各写一份，两边永远对不齐。
                    //
                    //    迁到 Swift 后排版参数只有一份（跟原生分页共用
                    //    ReaderLayoutConfig），换主题 → 改 config → 重排，立刻生效。
                    SwiftScrollReaderView(
                        chapters: session.flat,
                        currentIndex: session.index,
                        loadedTexts: scrollLoadedTexts,
                        failedChapters: [],
                        config: layoutConfig,
                        baseURL: nil,
                        onProgress: { _, ratio in saveProgress(ratio: ratio) },
                        onVisibleChapter: { ch in
                            // 滚到别的章 → 跟着走（不跳，只跟）
                            guard ch != session.index else { return }
                            session.followIndex(ch)
                        },
                        onRequestChapter: { idx in
                            // 窗口里还没加载的章 → 后台预取
                            Task { _ = await session.prefetch(index: idx) }
                        },
                        onTapCenter: {
                            withAnimation(.easeInOut(duration: 0.18)) { showChrome = true }
                        },
                        onTapEdge: { dir in session.step(dir) },
                        onSwipeUp: {
                            // ⑤ 上滑退出阅读（设置里那个开关）
                            if swipeUpExit { dismiss() }
                        },
                        swipeUpExitEnabled: swipeUpExit
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
        // 三个子页用系统 sheet（主面板是 overlay，NavigationStack 不能放里面）
        .sheet(isPresented: $showDisplaySettings) {
            NavigationStack { displaySettingsPage }
                .modifier(ClearNavigationBackground())
        }
        .sheet(isPresented: $showLayoutSettings) {
            NavigationStack { layoutSettingsPage }
                .modifier(ClearNavigationBackground())
        }
        .sheet(isPresented: $showMoreSettings) {
            NavigationStack { moreSettingsPage }
                .modifier(ClearNavigationBackground())
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
            // ⚠️ 栖阅顶栏中间是**一个圆角胶囊**，里面装着书名 + 副标题两行。
            //    我原来只是两个裸 Text，没有胶囊底 → 跟栖阅对不上。
            VStack(alignment: .leading, spacing: 1) {
                Text(book.name).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Text(book.sourceName).font(.caption2).foregroundStyle(Theme.sub).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlass(cornerRadius: 20, strength: 1.0)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // ⚠️ 栖阅是 **‹ 在最左、› 在最右**，滑块夹在中间。
            //    我之前把两个箭头都堆在左边（‹ › 滑块），跟栖阅对不上。
            HStack(spacing: 10) {
                Button { session.step(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                }
                .disabled(session.index <= 0)
                Slider(
                    value: Binding(
                        get: { Double(session.index) },
                        set: { session.jump(to: Int($0.rounded())) }),
                    in: 0...Double(max(session.flat.count - 1, 1)), step: 1)
                Button { session.step(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                }
                .disabled(session.index >= session.flat.count - 1)
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
    // ══════════════════════════════════════════════════════════════
    //  阅读设置面板 —— **严格按 ui.txt / 尺寸.txt 重做，一处不加不减**
    //
    //  面板容器（ui.txt 的 .panel）：
    //    left:14; right:14; bottom:14;
    //    background: rgba(255,255,255,.82) + blur(24);
    //    border-radius: 22px;
    //    box-shadow: 0 4px 30px rgba(0,0,0,.12);
    //    padding: 12px 14px 16px;
    //
    //  内部：
    //    .top-card { background: rgba(255,255,255,.55);
    //                 border-radius: 16px;
    //                 padding: 14px 12px 2px;
    //                 margin-bottom: 12px;
    //                 box-shadow: 0 1px 6px rgba(0,0,0,.04); }
    //      · .row-fontsize（字号 + 字体）
    //      · .divider
    //      · .theme-row × 2
    //      · .row-follow
    //      · .divider
    //      · .row-pageturn
    //    .grid（8 个宫格，独立在白块外）
    //
    //  ⚠️ CSS→SwiftUI 的层级对应（这次踩过三次，别再错）：
    //    CSS 的 `padding` 在 `background` **之内**（背景盖住 padding 区）
    //    → SwiftUI 必须 `.padding(...)` **在** `.background(...)` **之前**
    //    CSS 的 `margin` 在盒子**之外**
    //    → SwiftUI 放在 `.background(...)` **之后**
    // ══════════════════════════════════════════════════════════════

    private var settingsSheet: some View {
        settingsContent
            // ② 内部 padding（玻璃**里面**）：上 12 / 左右 14 / 下 16
            .padding(.top, 12)
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            // 面板背景 = **液态玻璃**（iOS 26 的 `.glassEffect`）。
            //
            // ⚠️⚠️ 之前在「结构还没对」的时候来回换过这个背景（.82 磨砂白 ↔
            //    .glassEffect），两边都不对 —— 其实是**结构问题**不是材质问题。
            //    现在结构对了（build120），才轮得到比材质。
            //
            // 用 `.tint(.white.opacity(0.35))` 保留白度：纯 `.glassEffect(.regular)`
            //    是全通透的，内层白块 white@.55 叠上去分不出层次；
            //    加白 tint 相当于 ui.txt 的 rgba(255,255,255,.82) 那一层，
            //    但**有折射、有 depth**，是真液态玻璃。
            .background(
                Color.clear
                    .glassEffect(.regular.tint(Color.white.opacity(0.35)),
                                 in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            // 面板阴影 0 4px 30px rgba(0,0,0,.12)
            .shadow(color: Color.black.opacity(0.12), radius: 15, x: 0, y: 4)

            // ① 定位留白（玻璃**外面**）：左右 14；底部让开 home indicator
            .padding(.horizontal, 14)
            .padding(.bottom, Self.bottomSafeInset + 14)

            .offset(y: showSettings ? panelDragOffset : sheetHeight + 48)
            .opacity(showSettings ? 1 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.86),
                       value: showSettings)
            .animation(.spring(response: 0.32, dampingFraction: 0.85),
                       value: panelDragOffset)
            .allowsHitTesting(showSettings)
            // ④ 跟目录一样：**按住往下拖**，面板跟着手指走；
            //    拖过阈值松手 → 关掉；没拖够 → 弹回去。
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        // 只往下拖，往上忽略
                        guard v.translation.height > 0 else { return }
                        panelDragOffset = min(v.translation.height, 320)
                    }
                    .onEnded { v in
                        let go = panelDragOffset > 110
                            || v.predictedEndTranslation.height > 220
                        if go { showSettings = false }
                        panelDragOffset = 0
                    }
            )
            .accessibilityIdentifier("readerSettingsPanel")
    }

    /// 底部安全区（home indicator 那条）的高度
    private static var bottomSafeInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let wins = scenes.flatMap(\.windows)
        let win = wins.first { $0.isKeyWindow } ?? wins.first
        return win?.safeAreaInsets.bottom ?? 34
    }

    /// 面板内容 —— **故意不用 NavigationStack**。
    ///
    /// ⚠️ NavigationStack 是 flexible 的：放进 overlay 里会**吃满整个屏幕**，
    ///    内容被垂直居中 → 面板变成全屏、上下各一大片空白（真机就是这样炸的）。
    ///    它也不能在「想让它贴合内容」的容器里用（ideal height 算不准）。
    ///
    /// 所以：**主面板 = 纯 VStack**（自然高度），三个子页各自用系统 `.sheet`。
    private var settingsContent: some View {
        VStack(spacing: 0) {
            panelContent
        }
        .frame(maxWidth: .infinity)
        // 内容按**自然高度**撑开
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SheetContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(SheetContentHeightKey.self) { h in
            guard h > 0 else { return }
            let screenH = UIScreen.main.bounds.height
            let hardCap = screenH * 0.80
            let target = min(max(h, 200), 900, hardCap)
            if abs(target - sheetHeight) > 1 { sheetHeight = target }
        }
    }

    /// 面板内容 = **上半白块**（top-card）+ 下面 8 个宫格
    private var panelContent: some View {
        VStack(spacing: 0) {
            // ── .top-card ──
            VStack(spacing: 0) {
                sizeRow
                hairLine
                paletteGrid
                followSystemRow
                hairLine
                pageTurnRow
            }
            .padding(EdgeInsets(top: 14, leading: 12, bottom: 2, trailing: 12))
            .background(
                Color.white.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 1)
            // margin-bottom: 12 —— 白块到宫格的**外部**距离
            .padding(.bottom, 12)

            // .grid（独立在白块外）
            featureGrid
        }
    }

    /// .divider { height:1px; background:rgba(0,0,0,.07); margin:0 2px 10px }
    ///
    /// ⚠️ **发丝线**：@3x 下 1pt = 3 个物理像素，太粗。
    ///    系统分隔线是 1 个物理像素 = `1 / UIScreen.main.scale` pt。
    private var hairLine: some View {
        Color.black.opacity(0.07)
            .frame(height: 1.0 / UIScreen.main.scale)
            .padding(.horizontal, 2)
            .padding(.bottom, 10)
    }

    // MARK: - ① 字号行

    /// .row-fontsize { display:flex; align-items:center; gap:10px; padding:0 2px 10px }
    private var sizeRow: some View {
        HStack(spacing: 10) {
            sizeKnob("小")
            QRSlider(value: $fontSize, range: 14...28, step: 1)
            sizeKnob("大")
            fontMenu
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    /// .fs-btn { width:34; height:34; border-radius:50%; background:rgba(0,0,0,.05);
    ///           font-size:14; color:#555 }
    private func sizeKnob(_ text: String) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.05))
            Text(text).font(.system(size: 14))
                .foregroundStyle(Color(white: 0x55 / 0xff))
        }
        .frame(width: 34, height: 34)
    }

    /// .font-select { padding:7px 13px; border-radius:18px; font-size:14;
    ///                color:#333; background:rgba(0,0,0,.06) }
    private var fontMenu: some View {
        Menu {
            ForEach(ReaderFont.all) { f in
                Button(f.name) { fontKey = f.raw }
            }
        } label: {
            HStack(spacing: 6) {
                Text(ReaderFont.name(for: fontKey))
                Image(systemName: "chevron.down").font(.system(size: 11))
                    .foregroundStyle(Color(white: 0x99 / 0xff))
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(white: 0x33 / 0xff))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - ③ 主题色块

    /// .theme-row { display:flex; align-items:center; gap:8px; margin-bottom:8px }
    private var paletteGrid: some View {
        VStack(spacing: 8) {
            paletteRow(ReaderTheme.light, icon: "sun.max")
            paletteRow(ReaderTheme.darkRow, icon: "moon")
        }
    }

    /// .mode-icon { width:28; font-size:17; color:#888 }
    /// .swatch { width:42; height:42; border-radius:9; border:2px solid transparent }
    /// .swatch.active { border-color:#4a90d9; box-shadow:0 0 0 1px #4a90d9 }
    private func paletteRow(_ list: [ReaderTheme], icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 17))
                .foregroundStyle(Color(white: 0x88 / 0xff))
                .frame(width: 28)
            ForEach(list) { t in
                Button { themeKey = t.key } label: {
                    Text("文")
                        .font(.system(size: 13))
                        .foregroundStyle(t.ink)
                        // 宽度用 maxWidth 均分（8 个要排得下），高度按规格 42
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(t.bg,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(themeKey == t.key
                                    ? Color(red: 74/255, green: 144/255, blue: 217/255)
                                    : .clear,
                                              lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - ④ 跟随系统深浅色

    /// .row-follow { padding:4px 2px 10px }  文字 15  .ic 18
    /// .switch { width:50; height:29; border-radius:15; background:#d8d8d8 }
    /// .switch::after { width:24; height:24; border-radius:50%; 边距 3 }
    /// .switch.on { background:#4a90d9 }  .switch.on::after { translateX(21px) }
    private var followSystemRow: some View {
        HStack {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 18)).foregroundStyle(Color(white: 0x77 / 0xff))
            Text("跟随系统深浅色").font(.system(size: 15))
                .foregroundStyle(Color(white: 0x33 / 0xff))
            Spacer()
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(followSystemAppearance
                          ? Color(red: 74/255, green: 144/255, blue: 217/255)
                          : Color(white: 0xd8 / 0xff))
                    .frame(width: 50, height: 29)
                Circle().fill(.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: Color.black.opacity(0.25), radius: 4, y: 1)
                    .offset(x: followSystemAppearance ? 23 : 3)   // 位移 20 ≈ 规格 21
            }
            .contentShape(Rectangle())
            .onTapGesture { followSystemAppearance.toggle() }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - ⑥ 翻页方式

    /// .row-pageturn { display:flex; align-items:center; gap:8px; padding:0 0 12px }
    /// .pt-icon { width:28; font-size:17; color:#888 }
    /// .pill { flex-shrink:0; padding:8px 17px; border-radius:18px; font-size:14;
    ///          background:rgba(0,0,0,.06) }
    /// .pill.active { background:#4a90d9; color:#fff }
    private var pageTurnRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "book").font(.system(size: 17))
                .foregroundStyle(Color(white: 0x88 / 0xff))
                .frame(width: 28)
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
        }
        .padding(.bottom, 12)
    }

    // MARK: - ⑦ 功能宫格（4 + 4）

    /// **照栖阅截图逐格抄的文案**：
    ///
    /// | 格 | 大字 | 小字     | 图标 |
    /// |---|---|---|---|
    /// | 1 | 大小 | 显示设置 | doc.text |
    /// | 2 | 间隔 | 间隔设置 | line.3.horizontal.decrease |
    /// | 3 | 朗读 | 朗读设置 | speaker.wave.2 |
    /// | 4 | 高亮 | 高亮设置 | highlighter |
    /// | 5 | 气泡 | 设置     | bubble.left.and.bubble.right |
    /// | 6 | 格式 | 标题样式 | **无** |
    /// | 7 | 页眉 | 页脚     | doc.text |
    /// | 8 | 更多 | 设置     | ellipsis.circle |
    ///
    /// 未实现的**只摆位不点**：灰掉、点不动（用户明确要求）。
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

    /// .grid { display:grid; grid-template-columns:repeat(4,1fr); gap:8px 8px }
    private var featureGrid: some View {
        VStack(spacing: 8) {
            tileRow(0)
            tileRow(4)
        }
    }

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

    /// .cell { background:rgba(0,0,0,.05); border-radius:12px; padding:9px 4px 8px;
    ///          display:flex; flex-direction:column; align-items:center; gap:4px }
    /// .cell .ic { font-size:18; color:#333; line-height:1 }
    /// .cell .t1 { font-size:13; color:#222 }
    private func featureTileLabel(name: String, subtitle: String?, icon: String,
                                  ready: Bool, action: @escaping () -> Void = {}) -> some View {
        Button {
            guard ready else { return }
            action()
        } label: {
            // ui.txt 的 .cell 只有**两行**：
            //     .ic  → 占图标位，这里放大字（18）
            //     .t1  → 副标题 13
            //     .t2  → display:none
            //
            // ⚠️ 我之前多画了一行 SF Symbol 图标 → 三行 81pt，
            //    规格是 9 + 18 + 4 + 13 + 8 = **52pt**。
            //    多了那一行就是「8 个按钮太大」的根因。
            VStack(spacing: 4) {
                Text(name).font(.system(size: 18, weight: .semibold))
                Text(subtitle ?? "").font(.system(size: 13))
            }
            .foregroundStyle(ready ? Color(white: 0x22 / 0xff) : Theme.sub.opacity(0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.top, 9)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .background(Color.black.opacity(0.05),
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
/// .pill { flex-shrink:0; padding:8px 17px; border-radius:18px; font-size:14;
///          background:rgba(0,0,0,.06); color:#333 }
/// .pill.active { background:#4a90d9; color:#fff }
private struct ChipButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : Color(white: 0x33 / 0xff))
                .padding(.horizontal, 17)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(selected
                             ? Color(red: 74/255, green: 144/255, blue: 217/255)
                             : Color.black.opacity(0.06))
                )
                .fixedSize()
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
