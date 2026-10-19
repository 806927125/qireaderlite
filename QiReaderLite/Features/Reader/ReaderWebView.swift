import SwiftUI
import WebKit

/// 正文阅读器：栖阅的阅读界面 + 我们自己的规则引擎。
///
/// 界面那四个文件（reader.html/css/js + reader-scroll-core.js）是从栖阅 IPA 里
/// 原样搬过来的，它跟原生之间只通过 8 类消息通信，那一半桥在 ReaderHost 里。
struct ReaderWebView: View {
    @Environment(\.dismiss) private var dismiss

    let book: Book
    let chapters: [Chapter]
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
    @State private var showChrome = false
    /// 子页：显示设置 / 间距设置
    @State private var showDisplaySettings = false
    @State private var showLayoutSettings = false
    @State private var showMoreSettings = false
    /// 面板内容实测高度，用来给 partial detent
    @State private var sheetHeight: CGFloat = 620
    @State private var started = false

    /// ReaderSession 是 @MainActor 类，init 也得在主线程（Swift 5 模式强检查）
    @MainActor init(book: Book, chapters: [Chapter], start: Chapter) {
        self.book = book
        self.chapters = chapters
        self.start = start
        // store 在 .task 里从 EnvironmentObject 挂进来
        _session = StateObject(wrappedValue: ReaderSession(book: book, chapters: chapters, start: start))
    }

    @Environment(\.colorScheme) private var darkScheme

    /// 用原生分页（CoreText 排版 + 翻页动画）还是 webview 上下滚动。
    /// 只有「上下滚动」这一种走 webview —— 栖阅也是这么分的：
    /// 它的 WebViewVerticalScrollViewController 管滚动，ReaderPaginator 管分页。
    private var useNativePaging: Bool {
        pageTurnMode != "scroll"
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
    @ViewBuilder
    private var chapterStatusOverlay: some View {
        if session.loadingChapter {
            ProgressView().controlSize(.large).scaleEffect(1.4)
        } else if !session.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text("这一章加载失败")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(session.errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .lineLimit(6)
                HStack(spacing: 10) {
                    Button("重试") {
                        Task { await session.load(index: session.index) }
                    }
                    .buttonStyle(.borderedProminent)
                    if session.index > 0 {
                        Button("回上一章") { session.step(-1) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 28)
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
        ZStack(alignment: .top) {
            ZStack {
                theme.bg.ignoresSafeArea()
                GlassBackdrop()
                if useNativePaging {
                    // 原生分页（栖阅那套 CoreText 排版 + 翻页动画）
                    PagedReaderView(
                        text: session.chapterText,
                        title: session.chapterTitle,
                        chapterKey: session.index,
                        config: layoutConfig,
                        mode: pageTurnMode,
                        onPageChange: { p, total in
                            pageInfo = (p, total)
                            saveProgress(ratio: total > 1 ? Double(p - 1) / Double(total) : 0)
                        },
                        onEdge: { dir in session.step(dir) },
                        onMenu: { withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() } },
                        tapAnywhereTurnsPage: tapAnywhereTurnsPage
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay {
                        // ⚠️ 这层以前完全没有 → 换章失败时正文静默停在上一章第一页，
                        //    看着就像「翻页坏了」。加载中/失败必须让人看见。
                        chapterStatusOverlay
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
        }
        .background(theme.bg)
        .task {
            guard !started else { return }
            started = true
            session.onTap = { withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() } }
            // 翻页模式：左边上一章 / 中间出菜单 / 右边下一章
            session.onTapZone = { x in
                // 原生分页模式下正文不在 webview 里，翻页由 PagedReaderView 管
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
            CatalogSheet(chapters: chapters, start: session.current) { ch in
                showCatalog = false
                if let i = session.flat.firstIndex(where: { $0.url == ch.url }) {
                    session.jump(to: i)
                }
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    // MARK: - 顶栏 / 底栏

    /// 顶栏：圆形返回 / 中间书名+来源 / 右侧圆形封面（照栖阅截图）
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
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
                .frame(width: 34, height: 34)
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
    private var settingsSheet: some View {
        settingsContent
            .background(Color.clear)
            .modifier(FitSheetHeight(contentHeight: sheetHeight))
    }

    /// 面板内容
    private var settingsContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                displayCard
                pageTurnCard
                featureGrid
            }
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
                // +56 是导航栏（标题 + 完成按钮）
                let target = min(max(h + 56, 320), 900)
                if abs(target - sheetHeight) > 1 { sheetHeight = target }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showSettings = false
                        session.host.setSettings(settingsPayload(coverDataURL: nil))
                    }
                }
            }
            .navigationDestination(isPresented: $showDisplaySettings) {
                displaySettingsPage
                    // 推入的页面默认带一层不透明背景，会把 sheet 的玻璃盖掉
                    .modifier(ClearNavigationBackground())
            }
            .navigationDestination(isPresented: $showLayoutSettings) {
                layoutSettingsPage
                    // 推入的页面默认带一层不透明背景，会把 sheet 的玻璃盖掉
                    .modifier(ClearNavigationBackground())
            }
            .navigationDestination(isPresented: $showMoreSettings) {
                moreSettingsPage
                    // 推入的页面默认带一层不透明背景，会把 sheet 的玻璃盖掉
                    .modifier(ClearNavigationBackground())
            }
        }
    }

    /// ① 字号 + 配色 + 跟随系统：一张大卡片
    private var displayCard: some View {
        VStack(spacing: 0) {
            sizeRow
            hairLine
            paletteGrid
            followSystemRow
        }
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.34),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.bottom, 10)
    }

    private var hairLine: some View {
        Divider().opacity(0.35).padding(.vertical, 2)
    }

    // MARK: - ① 字号行（小方块 + 滑块 + 大方块 + 字体下拉，全在一行）

    private var sizeRow: some View {
        HStack(spacing: 10) {
            sizeKnob("小", pointSize: 13)
            Slider(value: $fontSize, in: 14...30, step: 1)
            sizeKnob("大", pointSize: 17)
            fontMenu
        }
        .padding(.vertical, 12)
    }

    /// 小 / 大：灰底圆角方块
    private func sizeKnob(_ text: String, pointSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(width: 36, height: 32)
            .background(Color.gray.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 字体下拉（胶囊）
    private var fontMenu: some View {
        Menu {
            ForEach(ReaderFont.all) { f in
                Button(f.name) { fontKey = f.raw }
            }
        } label: {
            HStack(spacing: 4) {
                Text(ReaderFont.name(for: fontKey))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.subheadline)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.gray.opacity(0.18), in: Capsule())
        }
    }

    // MARK: - ③ 配色格子

    private var paletteGrid: some View {
        VStack(spacing: 8) {
            paletteRow(ReaderTheme.light, icon: "sun.max.fill")
            paletteRow(ReaderTheme.darkRow, icon: "moon.fill")
        }
        .padding(.vertical, 12)
    }

    private func paletteRow(_ list: [ReaderTheme], icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.sub)
                .frame(width: 18)
            ForEach(list) { t in
                Button { themeKey = t.key } label: {
                    Text("文")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(t.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(t.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(themeKey == t.key ? Theme.accent : .white.opacity(0.55),
                                              lineWidth: themeKey == t.key ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - ④ 跟随系统深浅色

    private var followSystemRow: some View {
        settingRow(title: "跟随系统深浅色", icon: "circle.lefthalf.filled") {
            Toggle("", isOn: $followSystemAppearance).labelsHidden().tint(Theme.accent)
        }
    }

    // MARK: - ⑥ 翻页方式（灰底圆角卡片）

    private var pageTurnCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Theme.sub)
                .frame(width: 18)
            ForEach(PageTurnMode.all) { m in
                ChipButton(title: m.name,
                           selected: pageTurnMode == m.raw,
                           fontSize: 13,
                           cornerRadius: 15,
                           fillsWidth: true) {
                    pageTurnMode = m.raw
                    pageTurn = m.raw != "scroll"
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.34),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.bottom, 10)
    }

    // MARK: - ⑦ 功能磁贴（4 + 5）

    private var featureGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { showDisplaySettings = true } label: {
                    featureTileLabel(name: "大小", subtitle: "显示设置",
                                     icon: "", ready: true)
                }
                .buttonStyle(.plain)
                featureTile(FeatureTile(name: "间距设置", icon: "text.alignleft", ready: true)) {
                    showLayoutSettings = true
                }
                featureTile(FeatureTile(name: "朗读设置", icon: "speaker.wave.2", ready: false)) {}
                featureTile(FeatureTile(name: "高亮设置", icon: "highlighter", ready: false)) {}
            }
            HStack(spacing: 8) {
                featureTile(FeatureTile(name: "气泡设置", icon: "bubble.left.and.bubble.right", ready: false)) {}
                featureTile(FeatureTile(name: "格式", icon: "text.alignleft", ready: false)) {}
                featureTile(FeatureTile(name: "标题样式", icon: "doc.text", ready: false)) {}
                featureTile(FeatureTile(name: "页眉页脚", icon: "book", ready: false)) {}
                featureTile(FeatureTile(name: "更多设置", icon: "ellipsis.circle", ready: true)) {
                    showMoreSettings = true
                }
            }
        }
    }

    /// 一个磁贴（图标 + 粗体标题 + 副标题）
    private func featureTileLabel(name: String, subtitle: String?, icon: String, ready: Bool) -> some View {
        VStack(spacing: 6) {
            if !icon.isEmpty {
                Image(systemName: icon).font(.system(size: 19))
            }
            Text(name).font(.subheadline.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.caption2)
            }
        }
        .foregroundStyle(ready ? Theme.ink : Theme.sub.opacity(0.45))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(ready ? 0.34 : 0.16),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 没接的**只摆位不点**：灰掉、点不动。
    /// 给用户一个点下去只会挨骂的按钮，比没有更糟。
    private func featureTile(_ t: FeatureTile, action: @escaping () -> Void) -> some View {
        Button {
            guard t.ready else { return }
            action()
        } label: {
            featureTileLabel(name: t.name, subtitle: t.subtitle, icon: t.icon, ready: t.ready)
        }
        .buttonStyle(.plain)
        .disabled(!t.ready)
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
struct FeatureTile: Identifiable {
    let name: String
    let icon: String
    let ready: Bool
    var subtitle: String? = nil
    var raw: String { name }
    var id: String { name }
}

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
    var fontSize: CGFloat = 12
    var cornerRadius: CGFloat = 12
    var fillsWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize))
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selected ? Theme.accent : Color.white.opacity(0.5))
                )
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: fillsWidth ? 32 : nil)
        }
        .buttonStyle(.plain)
    }
}


/// sheet 的高度**贴合内容**，并且**用系统级的液态玻璃**。
///
/// ── iOS 26：系统 sheet 本来就是液态玻璃 ──
/// Apple 的规则（WWDC25 session 323）：
///   · **partial-height**（.medium / .height / fitted）的 sheet **默认就是玻璃**；
///   · **.large 全屏 detent 是不透明的**；
///   · 自定义 `presentationBackground(_:)` 会**覆盖掉系统的玻璃** —— 要去掉。
/// 所以 iOS 26 这条分支**什么都不设背景**，让系统材质自己出来。
///
/// ── iOS 17~25：没有系统玻璃，自己糊一层材质 ──
/// `.ultraThinMaterial` 是最接近玻璃的退路。
///
/// ── iOS 26：partial-height sheet 才有系统液态玻璃 ──
/// Apple 的原话（WWDC25 session 323）：
///   "we need to specify presentation detents in the sheet content and
///    **include at least one partial height option**, such as medium or
///    a custom height detent."
/// 而且 ".large 全屏 detent 的背景会变成不透明"。
///
/// 踩过的坑：只给 `presentationSizing(.fitted)`、**不给 detent** —— sheet 走默认
/// 全屏，就是不透明的，玻璃出不来，面板还撑满整屏。**detent 必须是 partial**。
///
/// `.height(n)` 是 partial ✓ → 系统玻璃 ✓
///
/// ⚠️ 别用 `presentationBackground` 覆盖 iOS 26 的背景，那样系统玻璃就没了。
/// iOS 17~25 没有系统玻璃，才自己糊 `.ultraThinMaterial` 兜底。
private struct FitSheetHeight: ViewModifier {
    let contentHeight: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // partial detent → 系统液态玻璃；不设 presentationBackground
            content.presentationDetents([.height(contentHeight)])
        } else if #available(iOS 18.0, *) {
            content
                .presentationDetents([.height(contentHeight)])
                .presentationBackground(.ultraThinMaterial)
        } else {
            content
                .presentationDetents([.height(contentHeight)])
                .presentationBackground(.ultraThinMaterial)
        }
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
/// ⚠️ `containerBackground(_:for: .navigation)` 里的 `.navigation` 是 **iOS 18+** 的，
///    iOS 17 上写死会报 "'navigation' is only available in iOS 18.0 or newer"。
///    iOS 17 退而求其次用 `.background(Color.clear)`。
private struct ClearNavigationBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.containerBackground(.clear, for: .navigation)
        } else {
            content.background(Color.clear)
        }
    }
}
