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
    @State private var edgeToast: String?
    @State private var pageInfo: (page: Int, total: Int) = (1, 1)

    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var session: ReaderSession
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showChrome = false
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

    private var theme: ReaderTheme {
        let t = ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
        // 开了"跟随系统深浅色"但没手动选色板时，跟系统走
        if followSystemAppearance && themeKey == "auto" {
            return darkScheme ? .dChar : .paper
        }
        return t
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                theme.bg.ignoresSafeArea()
                GlassBackdrop()
                ReaderWebContainer(
                    host: session.host,
                    pageTurn: pageTurn,
                    onSwipe: { delta in session.step(delta) }
                )
                    .ignoresSafeArea(edges: .bottom)
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
                // 分页模式下翻页由 JS 模块自己做（章内翻页优先，翻到边才换章），
                // 这里不再抢，避免跟它打架
                if pageTurn && session.host.paginateReady { return }
                guard pageTurn else { showChrome = true; return }
                if x < 0.32 {
                    session.step(-1)
                } else if x > 0.68 {
                    session.step(1)
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() }
                }
            }
            // ── 分页模式 ──
            session.host.onPaginateReady = {
                applyPageTurn()
            }
            session.host.onPaginatePage = { p, c in pageInfo = (p, c) }
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
                Button { session.step(-1); repaginate() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                }
                .disabled(session.index <= 0)
                Button { session.step(1); repaginate() } label: {
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

    /// 把当前的翻页开关 / 翻页方式同步给分页模块
    private func applyPageTurn() {
        let idx = session.flat.firstIndex(where: { $0.url == session.current?.url }) ?? session.index
        session.host.setPageTurn(pageTurn, chapterIndex: idx, mode: pageTurnMode)
        if pageTurn { session.host.setPageTurnMode(pageTurnMode) }
    }

    /// 章节跳了之后重新分页（分页只对当前章生效）
    private func repaginate() {
        guard pageTurn, session.host.paginateReady else { return }
        let idx = session.flat.firstIndex(where: { $0.url == session.current?.url }) ?? session.index
        session.host.refreshPageTurn(chapterIndex: idx)
        pageInfo = (1, 1)
    }

    /// 阅读设置 —— 照栖阅那一版布局：
    ///   字号滑杆 + 字体  →  配色格子（浅色一排 / 深色一排）→ 跟随系统深浅色
    ///   →  翻页方式那一排  →  功能宫格
    /// 没接上的功能**只摆位不点**（灰掉），留着当以后的接口。
    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    sizeAndFontRow
                    Divider().opacity(0.35)
                    paletteGrid
                    followSystemRow
                    Divider().opacity(0.35)
                    pageTurnRow
                    Divider().opacity(0.35)
                    featureTiles
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showSettings = false
                        session.host.setSettings(settingsPayload(coverDataURL: nil))
                        applyPageTurn()
                    }
                }
            }
        }
        .presentationDetents([.height(560)])
    }

    // MARK: 字号 + 字体

    private var sizeAndFontRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("小").font(.footnote).foregroundStyle(Theme.sub)
                Slider(value: $fontSize, in: 14...30, step: 1)
                Text("大").font(.footnote).foregroundStyle(Theme.sub)
            }
            HStack {
                Spacer()
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
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white.opacity(0.5), in: Capsule())
                }
            }
        }
    }

    // MARK: 配色格子（浅色一排 / 深色一排）

    private var paletteGrid: some View {
        VStack(spacing: 8) {
            paletteRow(ReaderTheme.light, icon: "sun.max.fill")
            paletteRow(ReaderTheme.darkRow, icon: "moon.fill")
        }
    }

    private func paletteRow(_ list: [ReaderTheme], icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.sub)
                .frame(width: 16)
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

    private var followSystemRow: some View {
        HStack {
            Label("跟随系统深浅色", systemImage: "circle.lefthalf.filled")
                .font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            Toggle("", isOn: $followSystemAppearance).labelsHidden()
                .tint(Theme.accent)
        }
    }

    // MARK: 翻页方式

    private var pageTurnRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(Theme.sub)
                .frame(width: 16)
            ForEach(PageTurnMode.all) { m in
                Button {
                    pageTurnMode = m.raw
                    pageTurn = m.raw != "scroll"
                    applyPageTurn()
                } label: {
                    Text(m.name)
                        .font(.system(size: 13))
                        .foregroundStyle(pageTurnMode == m.raw ? .white : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(pageTurnMode == m.raw ? Theme.accent : Color.white.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 功能宫格

    /// 没接上的**只摆位不点**：灰掉、点不动，等真接了再开。
    /// 给用户一个点下去只会挨骂的按钮，比没有更糟。
    private var featureTiles: some View {
        let rows: [[FeatureTile]] = [
            [.init(name: "大小", icon: "textformat.size", ready: true),
             .init(name: "间距", icon: "text.line.spacing", ready: true),
             .init(name: "朗读", icon: "speaker.wave.2", ready: false),
             .init(name: "高亮", icon: "highlighter", ready: false)],
            [.init(name: "气泡", icon: "bubble.left.and.bubble.right", ready: false),
             .init(name: "格式", icon: "text.alignleft", ready: false),
             .init(name: "标题样式", icon: "textformat", ready: false),
             .init(name: "页眉页脚", icon: "rectangle.split.2x1", ready: false)],
            [.init(name: "更多设置", icon: "ellipsis.circle", ready: false)]
        ]
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, tile in
                        featureTile(tile)
                    }
                    // 一行不满 4 个时补空位，网格才对得齐。
                    // ⚠️ ForEach(0..<0) 在 SwiftUI 里会崩，必须挡掉。
                    if row.count < 4 {
                        ForEach(0..<(4 - row.count), id: \.offset) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func featureTile(_ t: FeatureTile) -> some View {
        Button {
            guard t.ready else { return }
            if t.name == "间距" {
                lineSpacing = lineSpacing >= 16 ? 6 : lineSpacing + 4
                session.host.setSettings(settingsPayload(coverDataURL: nil))
                return
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: t.icon).font(.system(size: 17))
                Text(t.name).font(.caption2)
                if t.raw == "spacing" {
                    Text("当前 \(Int(lineSpacing))").font(.system(size: 9)).opacity(0.7)
                }
            }
            .foregroundStyle(t.ready ? Theme.ink : Theme.sub.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!t.ready)
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
            "isDarkMode": followSystemAppearance && darkScheme,
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
