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
    /// 顶栏分类胶囊点开的「分类筛选」页
    @State private var showCategoryPicker = false
    /// 点书籍卡片进详情。走 navigationDestination(item:) 而不是 NavigationLink，
    /// 因为后者在 List 行里会自动多出一个行尾箭头。
    @State private var pickedBook: Book?

    /// 从发现页点进来时书源是定死的，没定死才回退到「第一个启用的」
    private let pinnedSourceId: String?

    init(source: BookSource? = nil) {
        pinnedSourceId = source?.bookSourceUrl
    }

    private var current: BookSource? {
        if let pid = pinnedSourceId, let s = sources.source(id: pid) { return s }
        guard let id = sourceId, let s = sources.source(id: id) else { return sources.enabled.first }
        return s.enabled ? s : sources.enabled.first
    }

    var body: some View {
        ZStack {
            PageBackdrop()

            VStack(spacing: 0) {
                picker
                list
            }
        }
        .navigationTitle(current?.bookSourceName ?? "发现")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 分类胶囊放导航栏，跟返回键平齐一行。
                // 之前它跟内容区里的书源名挤在一起，看起来是错位的。
                Button { showCategoryPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(selected?.title ?? "选分类")
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .liquidGlass(cornerRadius: 999)
                }
                .buttonStyle(.plain)
                .disabled(kinds.isEmpty)
            }
        }
        .task { await loadKinds() }
        // 分类筛选是 push 进来的页面，不是 sheet 弹窗。
        // sheet 自带顶部区域 + 我自己画的「× 关闭」胶囊打架，下半屏还全是空白。
        .navigationDestination(item: $pickedBook) { b in
            BookDetailView(book: b)
        }
        .navigationDestination(isPresented: $showCategoryPicker) {
            CategoryPickerView(
                kinds: kinds,
                current: selected,
                onPick: { k in
                    selected = k
                    books = []
                    page = 1
                    reachedEnd = false
                    // 先关页面再加载：onPick 跑在 push 出来的页面里，
                    // showCategoryPicker 置 false 才会 pop 回榜单页。
                    showCategoryPicker = false
                    Task { await loadBooks() }
                }
            )
            .navigationTitle("分类筛选")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("发现页诊断", isPresented: Binding(
            get: { diagText != nil }, set: { if !$0 { diagText = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(diagText ?? "")
        }
        .onChange(of: sourceId) { _, _ in
            guard pinnedSourceId == nil else { return }
            selected = nil
            books = []
            Task { await loadKinds() }
        }
    }

    /// 榜单页内容区**没有任何头部**：书源名在导航栏标题上，
    /// 分类胶囊在导航栏右侧，返回键也在导航栏。
    /// 之前这里还有一行「色块图标 + 书源名」，跟导航栏标题重复了。
    @ViewBuilder
    private var picker: some View {
        if pinnedSourceId == nil {
            HStack(spacing: 10) {
                SourcePicker(selection: $sourceId)
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
                    // 用 Button + navigationDestination(item:) 而不是 NavigationLink：
                    // List 行里的 NavigationLink 会被 SwiftUI 自动加上
                    // disclosure indicator（">"），iOS 26/27 上外面套 HStack 也不管用。
                    // 栖阅的书籍卡片右侧没有箭头，只能彻底不用 NavigationLink。
                    Button { pickedBook = b } label: { BookRow(book: b) }
                        .buttonStyle(.plain)
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
                    // 同上：Button + navigationDestination(item:)，不用 NavigationLink，
                    // 否则 List 会自动加行尾的 ">" 箭头。
                    Button { pickedBook = b } label: { BookRow(book: b) }
                        .buttonStyle(.plain)
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
        if sourceId == nil { sourceId = pinnedSourceId ?? s.bookSourceUrl }
        busy = true
        do {
            // ⚠️ 先记住用户上次选的分类。`.task` 在页面重新出现时（从详情页返回）会重跑，
            //    之前这里无条件 `selected = kinds.first` → 每返回一次就跳回「全部小说」。
            let prevUrl = selected?.url
            kinds = try await SourceService.shared.exploreKinds(source: s)
            if kinds.isEmpty {
                statusText = "这个书源没解析出分类"
                selected = nil
            } else {
                // 上次选的还在 → 保住；没了才退回第一个
                selected = kinds.first { $0.url == prevUrl } ?? selected ?? kinds.first
            }
            if selected != nil {
                await loadBooks()
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
