import SwiftUI

/// 正文阅读器：纯原生渲染，WKWebView 一个像素都不沾。
/// 支持连续加载下一章（站方章节内翻页会自动续接）。
struct ReaderView: View {
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let book: Book
    let chapters: [Chapter]
    let start: Chapter

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 8
    @AppStorage("reader.theme") private var themeKey: String = "paper"

    @State private var index: Int = 0
    @State private var text: String = ""
    @State private var title: String = ""
    @State private var busy = false
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var errorText = ""

    private var current: Chapter? {
        let list = chapters.filter { !$0.isVolume }
        guard !list.isEmpty else { return start }
        return list[min(max(index, 0), list.count - 1)]
    }
    private var flat: [Chapter] { chapters.filter { !$0.isVolume } }
    /// 显式写 first(where:)，用尾随闭包会被解析歧义
    private var theme: ReaderTheme {
        ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(title.isEmpty ? (current?.title ?? "") : title)
                            .font(.system(size: fontSize + 4, weight: .bold))
                            .foregroundStyle(theme.ink)
                            .id("top")
                        if busy && text.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            Text(text.isEmpty ? "（本章没有内容）" : text)
                                .font(.system(size: fontSize))
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(theme.ink)
                                .textSelection(.enabled)
                        }
                        if !errorText.isEmpty {
                            Text(errorText).font(.footnote).foregroundStyle(.orange)
                        }
                        navBar
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .background(theme.bg)
                .onAppear { proxy.scrollTo("top", anchor: .top) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showCatalog = true } label: {
                    VStack(spacing: 1) {
                        Text(current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(index + 1) / \(flat.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showCatalog = true } label: { Label("目录", systemImage: "list.bullet") }
                    Button { showSettings = true } label: { Label("阅读设置", systemImage: "textformat.size") }
                    Divider()
                    Button { syncProgress(); dismiss() } label: { Label("退出", systemImage: "xmark") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(chapters: chapters, start: current,
                         bookTitle: book.name.isEmpty ? nil : book.name,
                         sourceLabel: sources.source(id: book.origin)?.name) { ch in
                showCatalog = false
                if let i = flat.firstIndex(where: { $0.url == ch.url }) { index = i }
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .task { start0() }
        .onDisappear { syncProgress() }
    }

    private var navBar: some View {
        HStack(spacing: 12) {
            Button { index = max(index - 1, 0) } label: { Label("上一章", systemImage: "chevron.left") }
                .disabled(index <= 0)
            Spacer()
            Button { index = min(index + 1, flat.count - 1) } label: {
                Label("下一章", systemImage: "chevron.right")
            }
            .disabled(index >= flat.count - 1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.top, 12)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    Slider(value: $fontSize, in: 14...28, step: 1) { Text("\(Int(fontSize))") }
                }
                Section("行距") {
                    Slider(value: $lineSpacing, in: 2...20, step: 1) { Text("\(Int(lineSpacing))") }
                }
                Section("背景") {
                    Picker("主题", selection: $themeKey) {
                        ForEach(ReaderTheme.all) { t in Text(t.name).tag(t.key) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } }
            }
        }
    }

    // MARK: 加载

    private func start0() {
        guard let i = flat.firstIndex(where: { $0.url == start.url }) else { index = 0; return }
        index = i
        Task { await load() }
    }

    private func load() async {
        guard let ch = current, let s = sources.source(id: book.origin) else {
            errorText = "找不到书源"; return
        }
        // 缓存命中就不联网
        if let cached = ContentCache.shared.get(ch.url), !cached.isEmpty {
            text = cached
            title = ch.title
            return
        }
        busy = true
        errorText = ""
        do {
            var dto = try await SourceService.shared.content(source: s, chapter: ch, book: book)
            // 站方章节内分页：一直追到没有 nextUrl 为止
            var guardCount = 0
            while !dto.nextUrl.isEmpty && guardCount < 8 {
                var nextCh = ch
                nextCh.url = dto.nextUrl
                let more = try await SourceService.shared.content(source: s, chapter: nextCh, book: book)
                if more.content.isEmpty { break }
                dto.content += "\n\n" + more.content
                dto.nextUrl = more.nextUrl
                guardCount += 1
            }
            text = dto.content
            title = dto.title.isEmpty ? ch.title : dto.title
            ContentCache.shared.put(ch.url, dto.content)
            syncProgress()
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
    }

    private func syncProgress() {
        guard let ch = current else { return }
        library.update(book.id) {
            $0.lastReadAt = Date()
            $0.lastChapterIndex = index
            $0.readChapters[ch.url] = text.count
        }
    }
}

struct ReaderTheme: Identifiable {
    let key: String
    let name: String
    let bg: Color
    let ink: Color
    /// ⭐⭐⭐⭐⭐ **皮肤**（柴阅的四套：宣纸/晴窗/星夜/烛灯）⭐⭐⭐⭐⭐
    ///   ⇒ 皮肤决定**版式与装饰**（字体 / 章节号装饰 / 进度装饰），配色决定**颜色** ⇒ 两层分开 ⭐⭐⭐
    var skin: ReaderSkin = .xuan
    var id: String { key }

    // 必须定义成静态成员：`all.first(where:) ?? .paper` 里的 .paper
    // 要能从 ReaderTheme 上解析到，只在 all 数组里写 .init 是不够的。
    static let paper = ReaderTheme(key: "paper", name: "纸白",
                                   bg: Color(red: 0.949, green: 0.941, blue: 0.914),
                                   ink: Color(red: 0.16, green: 0.15, blue: 0.13, skin: .xuan)
    static let green = ReaderTheme(key: "green", name: "护眼",
                                   bg: Color(red: 0.847, green: 0.906, blue: 0.816),
                                   ink: Color(red: 0.13, green: 0.18, blue: 0.12, skin: .xuan)
    static let gray = ReaderTheme(key: "gray", name: "米灰",
                                  bg: Color(red: 0.90, green: 0.90, blue: 0.90),
                                  ink: Color(red: 0.18, green: 0.18, blue: 0.18, skin: .qing)
    static let dark = ReaderTheme(key: "dark", name: "夜间",
                                  bg: Color(red: 0.10, green: 0.10, blue: 0.11),
                                  ink: Color(red: 0.82, green: 0.82, blue: 0.84, skin: .xing)

    // 浅色一排（对应设置面板第一行「文」格子）
    static let paper2 = ReaderTheme(key: "paper2", name: "米黄",
                                    bg: Color(red: 0.976, green: 0.961, blue: 0.925),
                                    ink: Color(red: 0.20, green: 0.18, blue: 0.14, skin: .xuan)
    static let wheat = ReaderTheme(key: "wheat", name: "麦黄",
                                   bg: Color(red: 0.949, green: 0.906, blue: 0.796),
                                   ink: Color(red: 0.22, green: 0.18, blue: 0.12, skin: .zhu)
    static let rose = ReaderTheme(key: "rose", name: "藕粉",
                                  bg: Color(red: 0.965, green: 0.914, blue: 0.918),
                                  ink: Color(red: 0.24, green: 0.16, blue: 0.17, skin: .zhu)
    static let sky = ReaderTheme(key: "sky", name: "天青",
                                 bg: Color(red: 0.898, green: 0.933, blue: 0.949),
                                 ink: Color(red: 0.14, green: 0.18, blue: 0.24, skin: .qing)
    static let blue = ReaderTheme(key: "blue", name: "湖蓝",
                                  bg: Color(red: 0.855, green: 0.906, blue: 0.941),
                                  ink: Color(red: 0.12, green: 0.17, blue: 0.24, skin: .qing)
    static let teal = ReaderTheme(key: "teal", name: "青碧",
                                  bg: Color(red: 0.855, green: 0.929, blue: 0.902),
                                  ink: Color(red: 0.12, green: 0.20, blue: 0.18, skin: .qing)
    static let green2 = ReaderTheme(key: "green2", name: "豆绿",
                                    bg: Color(red: 0.898, green: 0.933, blue: 0.859),
                                    ink: Color(red: 0.15, green: 0.21, blue: 0.13, skin: .xuan)

    // 深色一排（对应第二行「文」格子）
    static let dChar = ReaderTheme(key: "dChar", name: "炭黑",
                                   bg: Color(red: 0.13, green: 0.13, blue: 0.14),
                                   ink: Color(red: 0.80, green: 0.80, blue: 0.82, skin: .xing)
    static let dOlive = ReaderTheme(key: "dOlive", name: "橄榄",
                                    bg: Color(red: 0.16, green: 0.17, blue: 0.14),
                                    ink: Color(red: 0.78, green: 0.80, blue: 0.72, skin: .xing)
    static let dNavy = ReaderTheme(key: "dNavy", name: "藏青",
                                   bg: Color(red: 0.12, green: 0.14, blue: 0.20),
                                   ink: Color(red: 0.76, green: 0.80, blue: 0.88, skin: .xing)
    static let dPurple = ReaderTheme(key: "dPurple", name: "紫檀",
                                     bg: Color(red: 0.17, green: 0.13, blue: 0.19),
                                     ink: Color(red: 0.82, green: 0.78, blue: 0.86, skin: .xing)
    static let dBrown = ReaderTheme(key: "dBrown", name: "深棕",
                                    bg: Color(red: 0.19, green: 0.16, blue: 0.13),
                                    ink: Color(red: 0.84, green: 0.80, blue: 0.74, skin: .xing)
    static let dGreen = ReaderTheme(key: "dGreen", name: "墨绿",
                                    bg: Color(red: 0.12, green: 0.17, blue: 0.15),
                                    ink: Color(red: 0.76, green: 0.84, blue: 0.80, skin: .xing)
    static let dBlue = ReaderTheme(key: "dBlue", name: "深蓝",
                                   bg: Color(red: 0.12, green: 0.16, blue: 0.22),
                                   ink: Color(red: 0.78, green: 0.84, blue: 0.90, skin: .xing)

    /// 浅色一排
    static let light: [ReaderTheme] = [.paper, .paper2, .wheat, .rose, .sky, .blue, .green2, .gray]
    /// 深色一排
    static let darkRow: [ReaderTheme] = [.dChar, .dOlive, .dNavy, .dPurple, .dBrown, .dGreen, .dBlue, .dark]

    static let all: [ReaderTheme] = light + darkRow
    // ⚠️ 必须写 contains(where:)：`contains(t)` 在这里会被当成
    //    contains(where:) 的柯里化简写，Swift 5.9 编译不过
    //    （"missing argument label 'where:'"）。
    static func isDark(_ t: ReaderTheme) -> Bool { darkRow.contains(where: { $0.key == t.key }) }

    // ⭐⭐⭐⭐⭐ **深色适配**：控件/面板的底色必须**随主题反**（2026-11-25 真机）⭐⭐⭐⭐⭐
    //
    //   以前面板那层白纱是**写死的白色**（`Color.white.opacity(max(glassTint, 0.12))`）⭐⭐⭐
    //   ⇒ 浅色纸底上没问题 ⇒ **夜间底上就是一块乳白板**（白纱 + 玻璃 ⇒ 灰糊）⭐⭐⭐
    //   ⇒ 正解：**深色底用黑纱、浅色底才用白纱** ⇒ 两种底都通透可读 ⭐⭐⭐⭐⭐
    /// ⭐⭐⭐ **实例侧的深色判定**（名字叫 `isDarkTheme`，避免和静态的 `ReaderTheme.isDark(_:)` 同名）⭐⭐⭐
    var isDarkTheme: Bool { ReaderTheme.isDark(self) }

    /// ⭐⭐⭐ 面板的「压底纱」（栖阅的 dimming layer）
    ///   · 浅色底 ⇒ 白纱（压住后面的正文字）
    ///   · 深色底 ⇒ **黑纱**（白纱会把玻璃变成乳白板）
    func panelVeil(white: Double) -> Color {
        isDarkTheme ? Color.black.opacity(0.34) : Color.white.opacity(max(white, 0.12))
    }

    /// ⭐⭐⭐ 控件（旋钮/小按钮）的底色
    var controlFill: Color {
        isDarkTheme ? Color.white.opacity(0.12) : Color.black.opacity(0.05)
    }

    // ⭐⭐⭐⭐⭐ **阅读页 chrome 的配色**（照栖阅 `appThemeTint` 的思路：**跟着阅读主题走**）⭐⭐⭐⭐⭐
    //
    //   以前这些全是**写死的浅色版**（`Color(white: 0x22/0xff)` / `Color.black.opacity(0.05)` …）⭐⭐⭐
    //   ⇒ 浅色纸底上没问题 ⇒ **夜间底上：深灰字 + 黑色控件底 ⇒ 全部看不见** ⭐⭐⭐⭐⭐
    //   ⇒ 正解：每项都给**深/浅两档**，由 `isDark` 选 ⭐⭐⭐

    /// 面板里的正文色
    var chromeInk: Color { isDarkTheme ? Color.white.opacity(0.90) : Color(white: 0x22 / 0xff) }
    /// 面板里的次级文字
    var chromeSubInk: Color { isDarkTheme ? Color.white.opacity(0.62) : Color(white: 0x55 / 0xff) }
    /// 面板里的发丝线
    var hairLineColor: Color { isDarkTheme ? Color.white.opacity(0.16) : Color.black.opacity(0.07) }
    /// 面板内层（子分组）的底
    var panelInnerFill: Color { isDarkTheme ? Color.black.opacity(0.26) : Color.white.opacity(0.55) }
    /// 选中项的高亮色（跟 App 主色同族）
    var chromeAccent: Color { Terminal.cyan }
}
