import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var sources: SourceStore

    @State private var sourceId: String?
    @State private var kinds: [SourceService.KindDTO] = []
    @State private var selected: SourceService.KindDTO?
    @State private var books: [Book] = []
    @State private var busy = false
    @State private var statusText = ""
    @State private var diagText: String?
    @State private var diagBusy = false
    /// 上拉加载更多：页码 / 加载中 / 是否到底 / 触发器 id（改 id 让 .task 重跑）
    @State private var page = 1
    @State private var loadingMore = false
    @State private var reachedEnd = false
    @State private var loadMoreID = 0

    private var current: BookSource? {
        guard let id = sourceId, let s = sources.source(id: id) else { return sources.enabled.first
        }
        return s.enabled ? s : sources.enabled.first
    }

    var body: some View {
        ZStack {
            PageBackdrop()

            VStack(spacing: 0) {
                picker
                kindBar
                list
            }
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadKinds() }
        .alert("发现页诊断", isPresented: Binding(
            get: { diagText != nil }, set: { if !$0 { diagText = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(diagText ?? "")
        }
        .onChange(of: sourceId) { _, _ in
            selected = nil
            books = []
            Task { await loadKinds() }
        }
    }

    /// 栖阅截图 1 那个顶栏：圆形按钮 + 书源名（带色块图标）+ 右侧分组胶囊
    private var picker: some View {
        HStack(spacing: 10) {
            SourceBadge(source: current ?? BookSource(bookSourceUrl: "", bookSourceName: "书源"), size: 34)

            Text(current?.name ?? "没有可用书源")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)

            Spacer()

            GlassCapsule {
                SourcePicker(selection: $sourceId)
                    .labelsHidden()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var kindBar: some View {
        if !kinds.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, k in
                        let on = selected?.url == k.url
                        Button {
                            selected = k
                            books = []
                            page = 1
                            reachedEnd = false
                            Task { await loadBooks() }
                        } label: {
                            Text(k.title)
                                .font(.system(size: 14, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .foregroundStyle(on ? .white : Theme.ink)
                                .background(
                                    Capsule().fill(on ? Theme.accent : Color.white.opacity(0.55))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if let s = current, s.exploreUrl.isNil {
            EmptyHint(icon: "safari", title: "这个书源没有发现页", subtitle: "去「搜索」页直接搜书名")
        } else if busy && books.isEmpty {
            Spacer().overlay(ProgressView("加载中…"))
        } else if !statusText.isEmpty && books.isEmpty {
            ErrorHint(message: statusText)
        } else if books.isEmpty {
            VStack(spacing: 14) {
                EmptyHint(icon: "rectangle.stack", title: "选个分类看看")
                if let s = current, let k = selected {
                    Button {
                        diagBusy = true
                        Task {
                            diagText = (try? await SourceService.shared.explain(source: s, kindUrl: k.url))
                                ?? "诊断跑失败了"
                            diagBusy = false
                        }
                    } label: {
                        Text(diagBusy ? "诊断中…" : "为什么只有这几本？点我诊断")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        } else if books.count <= 1 {
            VStack(spacing: 14) {
                List(BookDedup.unique(books)) { b in
                    NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) }
                }
                .listStyle(.plain)
                .disabled(true)
                .opacity(0.75)
                if let s = current, let k = selected {
                    Button {
                        diagBusy = true
                        Task {
                            diagText = (try? await SourceService.shared.explain(source: s, kindUrl: k.url))
                                ?? "诊断跑失败了"
                            diagBusy = false
                        }
                    } label: {
                        Text(diagBusy ? "诊断中…" : "只出 \(books.count) 本？点我诊断")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        } else {
            List {
                ForEach(BookDedup.unique(books)) { b in
                    NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) }
                        // BookRow 自己是玻璃卡片，List 的默认行背景会把它压住
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                }
                // 列表底部这一行就是「上拉加载」的触发器：
                // 它出现在屏幕里就自动加载下一页，加完把 id 一改，.task 就会再跑一次；
                // 页面不满屏时会连着翻，直到填满或者站方没数据了。
                if !reachedEnd {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .task(id: loadMoreID) { await loadMore() }
                } else {
                    Text("没有更多了")
                        .font(.caption)
                        .foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .refreshable { await loadBooks() }
        }
    }

    private func loadKinds() async {
        guard let s = current else {
            kinds = []; statusText = "没有启用且带发现页的书源"; return
        }
        if sourceId == nil { sourceId = s.bookSourceUrl }
        busy = true
        do {
            kinds = try await SourceService.shared.exploreKinds(source: s)
            if let first = kinds.first {
                selected = first
                await loadBooks()
            } else {
                statusText = "这个书源没解析出分类"
            }
        } catch {
            statusText = error.localizedDescription
            kinds = []
        }
        busy = false
    }

    /// 重新从头加载（切分类、下拉刷新都走这里）
    private func loadBooks() async {
        guard let s = current, let k = selected else { return }
        busy = true
        statusText = ""
        page = 1
        reachedEnd = false
        do {
            let first = try await SourceService.shared.explore(source: s, kindUrl: k.url, page: 1)
            books = first
            // 一页都没东西就别显示"没有更多了"，直接算到底，交给诊断按钮
            reachedEnd = first.isEmpty
            loadMoreID += 1
        } catch {
            statusText = error.localizedDescription
            books = []
            reachedEnd = true
        }
        busy = false
    }

    /// 上拉加载下一页，追加到已有列表后面
    private func loadMore() async {
        guard !loadingMore, !reachedEnd, !busy else { return }
        guard let s = current, let k = selected else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try await SourceService.shared.explore(source: s, kindUrl: k.url, page: page + 1)
            let before = Set(books.map(\.bookUrl))
            let merged = books + more
            let addedNew = Set(merged.map(\.bookUrl)).subtracting(before).count
            if more.isEmpty || addedNew == 0 || page >= 60 {
                // 三种情况都算到底：
                //   more 为空        —— 站方真没下一页了
                //   addedNew == 0    —— 站方 {{page}} 没生效，一直返回同一页（不挡住就是死循环）
                //   page >= 60       —— 兜底，别无限翻
                reachedEnd = true
            } else {
                page += 1
                books = merged
                loadMoreID += 1
            }
        } catch {
            // 翻页失败就停在这儿，别无限重试（站方 403/超时很常见）
            reachedEnd = true
        }
    }
}
