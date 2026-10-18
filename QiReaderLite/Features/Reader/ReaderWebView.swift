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

    private var theme: ReaderTheme {
        ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
    }

    var body: some View {
        ZStack(alignment: .top) {
            ReaderWebContainer(host: session.host)
                .ignoresSafeArea(edges: .bottom)

            if showChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .background(theme.bg)
        .task {
            guard !started else { return }
            started = true
            session.onTap = { withAnimation(.easeInOut(duration: 0.18)) { showChrome.toggle() } }
            session.attach(sources: sources, library: library)
            await session.start(settings: settingsPayload())
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

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(session.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button { showCatalog = true } label: { Image(systemName: "list.bullet") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    private var bottomBar: some View {
        HStack {
            Button { session.jump(to: session.index - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(session.index <= 0)
            Spacer()
            Text("\(session.index + 1) / \(max(session.flat.count, 1))")
                .font(.caption).foregroundStyle(Theme.sub)
            Spacer()
            Button { session.jump(to: session.index + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(session.index >= session.flat.count - 1)
            Button { showSettings = true } label: { Image(systemName: "textformat.size") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("字号") { Slider(value: $fontSize, in: 14...28, step: 1) { Text("\(Int(fontSize))") } }
                Section("行距") { Slider(value: $lineSpacing, in: 2...20, step: 1) { Text("\(Int(lineSpacing))") } }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showSettings = false
                        session.host.setSettings(settingsPayload())
                    }
                }
            }
        }
    }

    private func settingsPayload() -> [String: Any] {
        [
            "fontFamily": "-apple-system, 'PingFang SC', sans-serif",
            "fontSize": fontSize,
            "fontWeight": 400,
            "letterSpacing": 0.5,
            "lineSpacing": lineSpacing,
            "paragraphSpacing": 14,
            "textIndent": 0,
            "textColorHex": hex(theme.ink),
            "backgroundColorHex": hex(theme.bg),
            "hasBackgroundImage": false,
            "fullScreen": false,
            "leftMargin": 18,
            "rightMargin": 18,
            "textAlign": "left",
            "highlightStyles": [:],
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

/// WKWebView 的 SwiftUI 容器
struct ReaderWebContainer: UIViewRepresentable {
    @ObservedObject var host: ReaderHost

    func makeUIView(context: Context) -> WKWebView { host.web }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
