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

    // ⭐⭐⭐⭐⭐ **默认 20（柴阅）** ⭐⭐⭐⭐⭐
    @AppStorage("reader.fontSize") private var fontSize: Double = 20
    // ⭐⭐⭐⭐⭐ **默认 11（柴阅 0.55×字号）** ⭐⭐⭐⭐⭐
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 11
    @AppStorage("reader.theme") private var themeKey: String = "paper"
    /// 翻页模式：点正文左/右半边翻章、左右滑动翻章；关掉就是原来的
    /// "点一下出菜单" 行为。默认开（用户明确要的）。
    @AppStorage("reader.pageTurn") private var pageTurn: Bool = true
    /// 翻页方式，对应参考 App 的「仿真 / 滑动 / 平移 / 无动画 / 上下滚动」
    @AppStorage("reader.pageTurnMode") private var pageTurnMode: String = "slide"
    @AppStorage("reader.fontKey") private var fontKey: String = "system"
    @AppStorage("reader.followSystem") private var followSystemAppearance: Bool = false
    // ── 栖阅 ReaderLayoutSettingsView 的那几项 ──
    // ⭐⭐⭐⭐⭐ **默认两端对齐（柴阅 justified=true）** ⭐⭐⭐⭐⭐
    @AppStorage("reader.paraAlign") private var paraAlign: String = "justify"
    // ⭐⭐⭐⭐⭐ **默认 14（柴阅 0.7×字号）** ⭐⭐⭐⭐⭐
    @AppStorage("reader.paraSpacing") private var paraSpacing: Double = 14
    // ⭐⭐⭐⭐⭐ **行距档位**（柴阅的 spacing 是 0/1/2 三档，不是绝对值）⭐⭐⭐⭐⭐
    @AppStorage("reader.spacingLevel") private var spacingLevel: Int = 1
    /// 一次性迁移标记：老版本存的是绝对行距 ⇒ 首次进来换算成档位
    @AppStorage("reader.spacingLevelMigrated") private var spacingLevelMigrated: Bool = false
    @AppStorage("reader.showBaseline") private var showBaseline: Bool = false
    @AppStorage("reader.baselineScope") private var baselineScope: String = "full"
    @AppStorage("reader.verticalJustify") private var verticalJustify: Bool = false
    @AppStorage("reader.tapAnywhere") private var tapAnywhereTurnsPage: Bool = true
    @AppStorage("reader.swipeUpExit") private var swipeUpExit: Bool = false
    /// 液态玻璃浓度（滑块用；App 根把它注入 environment）
    @AppStorage(GlassTintStore.key) private var glassTintPercent: Double = 45
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
    /// 液态玻璃浓度（用户可调，App 根注入）—— 0 最透，0.45 最实
    @Environment(\.glassTint) private var glassTint

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
    /// ⭐⭐⭐ **章号归属开关已经没用了**（2026-11-25）
    ///   原来它是为了「原生分页接管时丢掉栖阅 WebView 的章号回声」——
    ///   而那套 WebView 阅读器**已经删掉** ⇒ 再没有第二个写者 ⇒ 这个开关恒为 true。
    ///   ⇒ 保留 session.pagingOwnsIndex 作文档，但不再在滚动模式下把它翻成 false。

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
                let fresh = try await sources.service.toc(source: src, tocUrl: bk.tocUrl, bookUrl: bk.bookUrl, book: bk)
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

    /// ⭐⭐⭐ **把「行距档位」写回绝对值**（lineSpacing / paraSpacing）
    ///   ⇒ 行距跟着字号缩放（柴阅行为）⇒ 改字号时行距不会还是老值。
    private func applySpacingLevel(_ level: Int, fontSize: Double) {
        let lv = ReaderSpacingLevel(rawValue: level) ?? .normal
        lineSpacing = lv.lineSpacing(fontSize: fontSize)
        paraSpacing = lv.paraSpacing(fontSize: fontSize)
    }

    /// 排版参数（柴阅的排版契约）
    private var layoutConfig: ReaderLayoutConfig {
        ReaderLayoutConfig(
            fontSize: CGFloat(fontSize),
            lineSpacing: CGFloat(lineSpacing),
            paragraphSpacing: CGFloat(paraSpacing),
            // ⭐⭐⭐ 柴阅的边距：左右 22；上下只留 4（**页眉页脚各占一条带**）⭐⭐⭐
            horizontalMargin: 22,
            topMargin: 4,
            bottomMargin: 4,
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
        // ⚠️ 同样拆成短 let —— 一次拼太长编译器会 type-check 超时（CI 报过）。
        let a = "\(fontSize)|\(lineSpacing)|\(paraSpacing)|\(themeKey)"
        let b = "\(followSystemAppearance)|\(darkScheme == .dark)|\(fontKey)|\(paraAlign)"
        let c = "\(verticalJustify)|\(showBaseline)|\(baselineScope)|\(baselineColorHex)"
        return a + b + c
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
        // ② Swift 滚动模式：`layoutConfig` 是 computed property ⇒ body 重算就传新 config ✅
        //
        // ⚠️ 栖阅那套 WebView 阅读器**已经拆掉** ⇒ 不再有「把 settings 下发给 host」这条路 ⭐⭐⭐
    }

    /// 把 SwiftUI 侧的配置和正文推进 pager。
    /// 幂等 —— 只有「章变了 / 正文变了 / 排版参数变了」才真的重排。
    private func syncPager(size: CGSize) {
        // 尺寸没量到就什么都别做：拿 .zero 去算页宽会算出 80×80 的迷你页
        guard size.width > 1, size.height > 1 else { return }
        pagerViewport = size
        let c = layoutConfig
        let sig = "\(c.fontSize)|\(c.lineSpacing)|\(c.paragraphSpacing)|\(c.horizontalMargin)|\(c.topMargin)|\(c.verticalJustify)|\(c.baselineScope.raw)|\(themeKey)|\(darkScheme == .dark)"
        let pager = pageCtl.pager
        pager.config = c
        // ⭐⭐⭐⭐⭐ **页眉要书名 + 皮肤要跟着配色走**（柴阅同款）⭐⭐⭐⭐⭐
        pager.bookTitle = book.name
        pager.skin = theme.skin
        // ⭐⭐⭐⭐⭐ **分页画布改成透明**（2026-11-25）⭐⭐⭐⭐⭐
        //   ⇒ 以前刷成 `theme.bg`（**一整块纯色**）⇒ **会把混色背景整个盖住** ⭐⭐⭐
        //   ⇒ 改透明 ⇒ 玻璃页浮在「混色背景」上 ⇒ 与栖阅一致（页面是浮层、底是混色）⭐⭐⭐
        //   ⇒ 滚动模式本来就是 `.clear`（`box.bodyView.backgroundColor = .clear`）⇒ 两边一致 ✅
        pager.background = UIColor.clear
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
                // ⭐⭐⭐⭐⭐ **混色阅读背景**（照栖阅 `ColorMixedBackground` 搬，2026-11-25）⭐⭐⭐⭐⭐
                //   ⇒ 底色渐变 + 三团辉光 + 一道高光 ⇒ 不再是「一块纯色」⭐⭐⭐
                //   ⇒ 辉光配色跟外壳同族（青/紫/粉）⇒ 整套 App 一套美学 ⭐⭐⭐
                ReaderSkinBackground(theme: theme)
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
            // ⚠️ 翻页模式（滚动 / 仿真 / 滑动 / 平移 / 无动画）切换后要**立刻**生效，
            //    不能要重进正文。`useNativePaging` 变了 → 渲染分支换了，
            //    但 pager 里已经排好的页还是旧模式的 → 必须重新 setMode + 重排。
            .onChange(of: pageTurnMode) { _, _ in
                syncPager(size: pagerViewport)
            }
            // ⚠️ 打开「大小」面板时把顶栏/底栏藏掉：
            //    ① 底栏那个「目录 / 大小 / 自检」控制块不该跟面板叠在一起；
            //    ② 底栏常驻会把面板**顶在上方**（看着"靠上"），
            //       藏掉之后面板自然就落到屏幕底了（用户：「往下挪挪」）。
            //    关闭面板时恢复。
            .onChange(of: showSettings) { _, on in
                withAnimation(.easeInOut(duration: 0.22)) { showChrome = !on }
            }
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
                            // ⚠️ 要 **toggle**：点中间在「显示顶栏底栏」和「隐藏它们」之间切。
                            //    原来写的是 `showChrome = true` —— 已经显示时点了没反应，
                            //    底栏永远消不掉（真机反馈「没有点中间隐藏这些手势」）。
                            withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() }
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

        }
        .background(theme.bg)
        // ⭐⭐⭐⭐⭐ **隐藏系统导航栏**（2026-11-25 照柴阅）⭐⭐⭐⭐⭐
        //   ⇒ 柴阅的阅读页是**全屏 + 自带 chrome**（顶栏胶囊 + 异形底栏）⭐⭐⭐
        //   ⇒ 留着系统导航栏 ⇒ 上面多一条重复的标题栏 ⇒ 观感对不上 ⭐⭐⭐
        //   ⇒ 返回键由我们的顶栏胶囊提供（dismiss()）⭐⭐⭐
        .toolbar(.hidden, for: .navigationBar)
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
            // ⭐⭐⭐ **一次性迁移**：老版本存的是绝对行距 ⇒ 换算成柴阅的「档位」
            if !spacingLevelMigrated {
                spacingLevelMigrated = true
                let lv = ReaderSpacingLevel.nearest(lineSpacing: lineSpacing, fontSize: fontSize)
                spacingLevel = lv.rawValue
                applySpacingLevel(lv.rawValue, fontSize: fontSize)
            }
            await session.start()
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
        // ⭐⭐⭐⭐⭐ **柴阅的「外观」面板 = sheet**（不是栖阅那种底部 overlay 大卡）⭐⭐⭐⭐⭐
        .sheet(isPresented: $showSettings) {
            ReaderStylePanel(
                fontSize: $fontSize,
                spacingLevel: $spacingLevel,
                fontKey: $fontKey,
                themeKey: $themeKey,
                pageTurnMode: $pageTurnMode,
                followSystem: $followSystemAppearance,
                onFontSizeChanged: { newSize in
                    // ⭐⭐ 字号变了 ⇒ 行距/段距按新字号重算（柴阅的 spacing 是**档位**不是绝对值）
                    applySpacingLevel(spacingLevel, fontSize: newSize)
                },
                onSpacingChanged: { lv in
                    applySpacingLevel(lv, fontSize: fontSize)
                },
                onThemeChanged: { _ in }
            )
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
    // MARK: - 顶栏（⭐⭐⭐ 照**柴阅** `ReaderChrome.topBar` 重写，2026-11-25）

    /// ⭐⭐⭐⭐⭐ **柴阅的顶栏 = 一整条玻璃胶囊**（不是系统导航栏 + 几个圆钮）⭐⭐⭐⭐⭐
    ///   · 高 56 · 圆角 28（= 胶囊）· 左右各留 10
    ///   · 左：返回（44×44 命中区）· 中：**书名居中 + 衬线体** · 右：书签/更多（我们用封面）
    private var topBar: some View {
        HStack(spacing: 2) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ⭐⭐⭐ **书名居中 + 衬线体**（柴阅 `.serif(16)`）⭐⭐⭐
            VStack(spacing: 1) {
                Text(book.name)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                // ⭐⭐⭐ **第二行放「章节名 + 页码」**（柴阅把翻页信息放在页眉）
                //   ⇒ 源名不放这儿了（详情页/书架上都有，翻页时更需要知道「在哪一章」）⭐⭐⭐
                Text(pageTurn
                     ? "\(session.current?.title ?? "") · 第\(session.index + 1)章 · \(pageInfo.page)/\(max(pageInfo.total, 1))页"
                     : "\(session.current?.title ?? "") · 第\(session.index + 1)/\(max(session.flat.count, 1))章")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            // 右侧：封面（柴阅这里是书签 + 更多；轻阅没有书签功能，保留封面）
            if !book.coverUrl.isEmpty, let coverURL = URL(string: book.coverUrl) {
                AsyncImage(url: coverURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay(Circle().stroke(Terminal.edge, lineWidth: 1))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        // ⭐⭐⭐ 整条胶囊玻璃（系统玻璃自带高光 ⇒ 不要再叠描边）⭐⭐⭐
        .liquidGlass(cornerRadius: 28, strength: 1.15)
        .padding(.horizontal, 10)
        .safeAreaPadding(.top, 8)
    }

    // MARK: - 底栏（⭐⭐⭐ 照**柴阅** `ReaderChrome.bottomPanel` 重写，2026-11-25）

    /// ⭐⭐⭐⭐⭐ **柴阅的底栏 = 异形玻璃面板**（上窄 32 / 下宽 45）⭐⭐⭐⭐⭐
    ///   · 第一行：[‹][章节滑杆][›]（52 高）
    ///   · 第二行：4 个工具（目录 / 大小 / 日夜 / 自检）——柴阅是(目录/朗读/日夜/外观)⭐⭐⭐
    ///   · 工具**依次浮现**（柴阅的 stagger 动画）⭐⭐⭐
    private var bottomBar: some View {
        VStack(spacing: 0) {
            // ① 第一行：上一章 / 章节滑杆 / 下一章
            HStack(spacing: 4) {
                Button { session.step(-1) } label: {
                    Image(systemName: "backward.fill").font(.system(size: 17))
                }
                .disabled(session.index <= 0)
                Slider(
                    value: Binding(
                        get: { Double(session.index) },
                        set: { session.jump(to: Int($0.rounded())) }),
                    in: 0...Double(max(session.flat.count - 1, 1)), step: 1)
                Button { session.step(1) } label: {
                    Image(systemName: "forward.fill").font(.system(size: 17))
                }
                .disabled(session.index >= session.flat.count - 1)
            }
            .frame(height: 52)
            .foregroundStyle(Theme.ink)

            // ② 第二行：4 个工具（柴阅同款）
            HStack(spacing: 0) {
                barItem("目录", "list.bullet") { showCatalog = true }
                // ⭐⭐⭐ 柴阅的「外观」用**衬线体文字 "Aa"**（系统图标在中文环境会变「格式」）⭐⭐⭐
                barItem("外观", textIcon: "Aa") { showSettings = true }
                // ⭐⭐⭐ 柴阅的「日间/夜间」是一键切换 ⇒ 轻阅有 16 套配色 ⇒ 在夜间/纸白之间切 ⭐⭐⭐
                barItem(theme.isDarkTheme ? "日间" : "夜间",
                        theme.isDarkTheme ? "sun.max" : "moon") { toggleDayNight() }
                // 真机排版自检 —— 沙盒验不了 CoreText，只能让 App 自己吐状态。
                barItem("自检", "stethoscope") { showPageDiag = true }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
        // ⭐⭐⭐ **异形玻璃**（上窄下宽）——柴阅底栏的形状 ⭐⭐⭐
        .liquidGlassUneven(top: 32, bottom: 45, strength: 1.15)
        .padding(.horizontal, 10)
        .safeAreaPadding(.bottom, 8)
    }

    /// ⭐⭐⭐ **一键日/夜切换**（柴阅底栏有这一颗）⭐⭐⭐
    private func toggleDayNight() {
        let cur = ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
        themeKey = ReaderTheme.isDark(cur) ? ReaderTheme.paper.key : ReaderTheme.dark.key
    }

    /// 一个工具按钮（`textIcon` 优先 ⇒ 柴阅的「Aa」那种文字图标）
    private func barItem(_ title: String, _ icon: String? = nil,
                         textIcon: String? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let textIcon {
                        // ⭐ 柴阅用衬线体文字画 "Aa"（系统 `textformat` 在中文环境会变「格式」）⭐
                        Text(textIcon)
                            .font(.system(size: 19, weight: .regular, design: .serif))
                    } else {
                        Image(systemName: icon ?? "circle").font(.system(size: 20, weight: .regular))
                    }
                }
                .frame(height: 24)
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - 字体

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

    /// 面板里显示的名字（柴阅的翻页方式行用）
    static func name(for raw: String) -> String {
        all.first(where: { $0.raw == raw })?.name ?? "滑动"
    }

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
