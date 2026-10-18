import SwiftUI
import WebKit

/// 正文阅读器（栖阅阅读界面 + 我们的引擎）
///
/// 界面部分（reader.html/css/js + reader-scroll-core.js）是从栖阅的 IPA 里原样搬过来的，
/// 它跟原生之间只通过 8 类消息通信，那一半桥在 ReaderHost 里实现了。
/// 正文/章节还是走我们的规则引擎去取，取完用 upsertChapter 回填给界面。
struct ReaderWebView: View {
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let book: Book
    let chapters: [Chapter]
    let start: Chapter

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 8
    @AppStorage("reader.theme") private var themeKey: String = "paper"

    @StateObject private var host = ReaderHost()
    @State private var index: Int = 0
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showChrome = true
    @State private var errorText = ""
    @State private var bootstrapped = false
    @State private var hostReady = false

    private var flat: [Chapter] { chapters.filter { !$0.isVolume } }
    private var current: Chapter? {
        flat.indices.contains(index) ? flat[index] : flat.first
    }
    private var theme: ReaderTheme {
        ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
    }

    var body: some View {
        ZStack(alignment: .top) {
            ReaderWebContainer(host: host)
                .ignoresSafeArea(edges: .bottom)

            if showChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if !errorText.isEmpty {
                VStack { Spacer() }
                    .overlay(alignment: .bottom) {
                        Text(errorText).font(.caption).foregroundStyle(.orange)
                            .padding(8).background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 64)
                    }
            }
        }
        .background(theme.bg)
        .task { await bootstrap() }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(chapters: chapters, start: current) { ch in
                showCatalog = false
                if let i = flat.firstIndex(where: { $0.url == ch.url }) {
                    jump(to: i)
                }
            }
        }
        .sheet(isPresented: $showSettings) { ReaderSettingsSheet() }
    }

    // MARK: - 顶栏 / 底栏

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button { showCatalog = true } label: { Image(systemName: "list.bullet") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    private var bottomBar: some View {
        HStack {
            Button { jump(to: index - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(index <= 0)
            Spacer()
            Text("\(index + 1) / \(max(flat.count, 1))").font(.caption).foregroundStyle(Theme.sub)
            Spacer()
            Button { jump(to: index + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= flat.count - 1)
            Button { showSettings = true } label: { Image(systemName: "textformat.size") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    private func jump(to i: Int) {
        guard flat.indices.contains(i) else { return }
        index = i
        host.apply(chapters: flat, at: i, progress: nil)
        Task { await load(index: i) }
    }

    // MARK: - 接线

    private func bootstrap() async {
        if bootstrapped { return }
        bootstrapped = true
        let list = flat
        let startIdx = list.firstIndex(where: { $0.url == start.url }) ?? 0
        index = max(0, startIdx)

        host.onRequestChapter = { [weak self] i in
            await self?.load(index: i)
        }
        host.onProgress = { [weak self] i, ratio in
            guard let self else { return }
            self.index = i
            let ch = self.flat.indices.contains(i) ? self.flat[i] : nil
            self.library.saveProgress(bookID: self.book.id,
                                      chapterIndex: i,
                                      ratio: ratio,
                                      chapterTitle: ch?.title ?? "")
        }
        host.onVisibleChapter = { [weak self] i in
            guard let self, self.flat.indices.contains(i) else { return }
            self.index = i
        }
        host.onTap = { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.18)) { self.showChrome.toggle() }
        }
        host.onDebugLog = { [weak self] ev, payload in
            guard let self, self.errorText.isEmpty else { return }
            if ev.contains("error") || ev.contains("fail") {
                self.errorText = String(describing: payload["error"] ?? ev)
            }
        }

        host.onReady = { [weak self] in self?.hostReady = true }
        // 等界面 ready 再喂初始数据
        for _ in 0..<60 where !hostReady { try? await Task.sleep(nanoseconds: 100_000_000) }
        host.setSettings(settingsPayload())
        host.apply(chapters: list, at: index,
                   progress: library.progress(bookID: book.id))
        await load(index: index)
    }

    private var settingsPayload: [String: Any] {
        let ink = theme.ink
        let bg = theme.bg
        return [
            "fontFamily": "-apple-system, 'PingFang SC', sans-serif",
            "fontSize": fontSize,
            "fontWeight": 400,
            "letterSpacing": 0.5,
            "lineSpacing": lineSpacing,
            "paragraphSpacing": 14,
            "textIndent": 0,
            "textColorHex": hex(ink),
            "backgroundColorHex": hex(bg),
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

    private func load(index i: Int) async {
        guard flat.indices.contains(i), let s = sources.source(id: book.origin) else { return }
        let ch = flat[i]
        do {
            let dto = try await SourceService.shared.content(source: s, chapter: ch)
            host.update(index: i, text: dto.content, title: dto.title.isEmpty ? ch.title : dto.title)
            errorText = ""
        } catch {
            host.fail(index: i, message: error.localizedDescription)
            errorText = error.localizedDescription
        }
    }
}

/// WKWebView 的 SwiftUI 容器
struct ReaderWebContainer: UIViewRepresentable {
    @ObservedObject var host: ReaderHost

    func makeUIView(context: Context) -> WKWebView { host.webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
