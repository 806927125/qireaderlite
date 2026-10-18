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
                if !statusText.isEmpty && chapters.isEmpty { Text(statusText).font(.footnote).foregroundStyle(.orange) }
                // ⚠️ 原来只在 1~2 章时显示诊断按钮，**0 章反而不显示** ——
                //    而 0 章恰恰是最需要诊断的情况（toc() 成功返回但一条没解析出来，
                //    不抛错，statusText 也是空的，页面上什么都看不出来）。
                if chapters.count <= 2 {
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
            PageBackdrop()
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
    private var meta: some View {
        HStack(spacing: 0) {
            metaCell("folder.fill", "分组", "未分组", Theme.tagBlue)
            Divider().frame(height: 34)
            metaCell("doc.text.fill", "类型", book.kind.isEmpty ? "文本" : book.kind, Theme.tagPurple)
            Divider().frame(height: 34)
            metaCell("bell.fill", "更新",
                     chapters.filter { !$0.isVolume }.count > 0
                        ? "\(chapters.filter { !$0.isVolume }.count) 章"
                        : "未加载",
                     Theme.tagOrange)
        }
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 16)
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
            Text(book.intro.isEmpty ? "（这本书没有简介）" : book.intro)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineSpacing(5)
                .lineLimit(showAllIntro ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)

            if !book.intro.isEmpty && book.intro.count > 110 {
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
