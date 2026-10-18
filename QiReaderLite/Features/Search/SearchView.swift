import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore

    @State private var keyword = ""
    @State private var sourceId: String?
    @State private var results: [Book] = []
    @State private var busy = false
    @State private var searched = false
    @State private var statusText = ""

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit(of: .search) { Task { await run() } }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
                TextField("书名或作者", text: $keyword)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !keyword.isEmpty {
                    Button { keyword = ""; results = []; searched = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.sub.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            SourcePicker(selection: $sourceId, allowAll: true)

            Button {
                Task { await run() }
            } label: {
                if busy { ProgressView().scaleEffect(0.7).frame(width: 34) }
                else { Text("搜").font(.headline).frame(width: 34) }
            }
            .disabled(busy || keyword.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    @ViewBuilder
    private var content: some View {
        if busy && results.isEmpty {
            Spacer().overlay(ProgressView("搜索中…"))
        } else if !statusText.isEmpty && results.isEmpty {
            ErrorHint(message: statusText)
        } else if !searched {
            EmptyHint(icon: "magnifyingglass", title: "搜点什么",
                      subtitle: "单个书源搜得快；选「全部书源」会并发搜所有启用的源并去重")
        } else if results.isEmpty {
            EmptyHint(icon: "questionmark.folder", title: "没搜到书",
                      subtitle: "换个关键词，或者换个书源试试")
        } else {
            List(BookDedup.unique(results)) { b in
                NavigationLink {
                    BookDetailView(book: b)
                } label: {
                    BookRow(book: b)
                }
                // BookRow 是玻璃卡片，List 默认行背景会压住它
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        busy = true
        statusText = ""
        let targets = sourceId.flatMap { id in sources.source(id: id).map { [$0] } } ?? sources.enabled
        guard !targets.isEmpty else {
            busy = false; searched = true
            statusText = "没有启用的书源，先去「书源」页导入一个"
            return
        }
        // 多源同时搜，单个源失败不影响其它源的结果。
        // 注意：引擎跑在单个 WKWebView 里，HTTP 本身是串行的，别指望真的并发。
        var collected: [Book] = []
        var firstError: String?
        await withTaskGroup(of: Result<[Book], Error>.self) { group in
            for s in targets {
                group.addTask {
                    // Result{...} 的初始化器收的是**同步**闭包，里面不能 await。
                    // 所以先 await 拿到值，再包成 Result。
                    do {
                        let list = try await SourceService.shared.search(source: s, keyword: kw, page: 1)
                        return .success(list)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await r in group {
                switch r {
                case .success(let list): collected.append(contentsOf: list)
                case .failure(let e): if firstError == nil { firstError = e.localizedDescription }
                }
            }
        }
        // 以当前书源列表顺序排列，结果稳定不跳
        // 不能用 Dictionary(uniqueKeysWithValues:) —— 遇到重复 key 会直接崩
        var order: [String: Int] = [:]
        for (i, t) in targets.enumerated() where order[t.bookSourceUrl] == nil {
            order[t.bookSourceUrl] = i
        }
        results = BookDedup.merge(collected).sorted {
            (order[$0.origin] ?? 999) < (order[$1.origin] ?? 999)
        }
        searched = true
        busy = false
        if results.isEmpty {
            statusText = firstError ?? "所有书源都没搜到结果"
        } else {
            statusText = ""
            Toast.show("\(results.count) 条结果")
        }
    }
}
