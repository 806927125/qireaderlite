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
    @State private var showCatalog = false
    @State private var readerChapter: Chapter?

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
                if !statusText.isEmpty && chapters.isEmpty { Text(statusText).font(.footnote).foregroundStyle(.orange) }
                if !chapters.isEmpty && chapters.count <= 2 {
                    HStack(spacing: 6) {
                        Text("只解析出 \(chapters.count) 章，多半不对")
                            .font(.caption).foregroundStyle(.orange)
                        Button {
                            guard let src = source else { return }
                            tocDiagBusy = true
                            Task {
                                tocDiag = (try? await SourceService.shared.explainToc(
                                    source: src,
                                    tocUrl: book.tocUrl.isEmpty ? book.cleanBookUrl : book.tocUrl,
                                    bookUrl: book.cleanBookUrl)) ?? "诊断跑失败了"
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
            ZStack { Theme.bg; GlassBackdrop() }
            .ignoresSafeArea()
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading { ProgressView().controlSize(.large) }
        }
        .task { await loadDetail() }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(chapters: chapters, start: readerChapter) { ch in
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
            CoverImage(url: book.cleanCover, width: 96, height: 132)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.name).font(.title3.bold()).foregroundStyle(Theme.ink)
                if !book.author.isEmpty {
                    Text(book.author).font(.subheadline).foregroundStyle(Theme.sub)
                }
                if !book.sourceName.isEmpty {
                    Text(book.sourceName).font(.caption2).foregroundStyle(Theme.accent)
                }
                if !book.lastChapter.isEmpty {
                    Text(book.lastChapter).font(.caption).foregroundStyle(Theme.sub).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                readerChapter = chapters.first(where: { !$0.isVolume })
            } label: {
                Label("开始阅读", systemImage: "book")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .disabled(chapters.isEmpty)

            Button {
                showCatalog = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.headline).frame(width: 46, height: 42)
                    .background(Theme.sub.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(chapters.isEmpty)

            Button {
                // 不能写成三元：remove 返回 ()，add 返回 LibraryItem，两边类型不一致编译不过
                if inShelf {
                    library.remove(book.id)
                } else {
                    library.add(book)
                }
            } label: {
                Image(systemName: inShelf ? "checkmark.square.fill" : "square")
                    .font(.headline).frame(width: 46, height: 42)
                    .background(Theme.sub.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !book.kind.isEmpty { line("分类", book.kind) }
            if !book.wordCount.isEmpty { line("字数", book.wordCount) }
            if !chapters.isEmpty { line("章节", "\(chapters.filter { !$0.isVolume }.count) 章") }
        }
        .cardStyle()
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介").font(.headline).foregroundStyle(Theme.ink)
            Text(book.intro.isEmpty ? "（这本书没有简介）" : book.intro)
                .font(.subheadline).foregroundStyle(Theme.sub)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(Theme.sub).frame(width: 44, alignment: .leading)
            Text(v).font(.caption).foregroundStyle(Theme.ink)
            Spacer()
        }
    }

    // MARK: 加载

    private func loadDetail() async {
        guard let s = source else {
            statusText = "找不到这本书对应的书源了（可能导入时覆盖过）"
            return
        }
        loading = true
        defer { loading = false }

        // 1) 详情页
        if let fresh = try? await SourceService.shared.bookInfo(source: s, bookUrl: book.cleanBookUrl, fallback: book) {
            book = book.merged(with: fresh)
            if inShelf { library.add(book) }
        }
        statusText = ""

        // 2) 目录
        let tocURL = book.tocUrl.isEmpty ? book.cleanBookUrl : book.tocUrl
        if let list = try? await SourceService.shared.toc(source: s, tocUrl: tocURL, bookUrl: book.cleanBookUrl) {
            chapters = list
            if let last = library.item(for: book.id)?.lastChapterIndex,
               last > 0, last < list.count {
                readerChapter = nil   // 只是预热，不自动跳
            }
        } else if !chapters.isEmpty {
            statusText = "目录加载失败"
        }
    }
}

struct CatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chapters: [Chapter]
    let start: Chapter?
    let onPick: (Chapter) -> Void
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { c in
                    Button {
                        onPick(c)
                    } label: {
                        HStack {
                            if c.isVolume {
                                Text(c.title).font(.subheadline.bold()).foregroundStyle(Theme.accent)
                            } else {
                                Text(c.title).font(.subheadline).foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if c.url == start?.url { Image(systemName: "location.fill").font(.caption) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $filter, prompt: "搜章节名")
            .navigationTitle("目录 (\(chapters.filter { !$0.isVolume }.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var shown: [Chapter] {
        filter.isEmpty ? chapters : chapters.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }
}
