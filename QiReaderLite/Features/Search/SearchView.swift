import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore

    /// ⭐⭐⭐⭐⭐ **同时最多搜几个源**（2026-10-26 jetsam 6.8GB 实证）
    ///
    /// ⚠️ 原来 = **所有启用的源一起搜**（用户有 125 个源）⇒ 125 个并发 op
    ///   ⇒ 每个 op 建一个**会话 = 一个 JSC context** ⇒ 峰值内存冲到 GB 级 ⇒ jetsam 杀 App ⭐⭐⭐
    /// ⇒ 现在 4 个 ⇒ 峰值降一个数量级（引擎侧会话也封顶 ≤4 ⇒ 不会累积）⭐⭐⭐
    static let maxConcurrentSearches = 4

    @State private var keyword = ""
    @State private var sourceId: String?
    @State private var results: [Book] = []
    @State private var busy = false
    @State private var searched = false
    @State private var statusText = ""
    /// 点书籍卡片进详情。用 Button + navigationDestination(item:) 而不是 NavigationLink，
    /// 因为 List 行里的 NavigationLink 会被 SwiftUI 自动加上行尾的 ">" 箭头，
    /// 栖阅的书籍卡片没有箭头，iOS 26/27 上外面套 HStack 也压不住。
    @State private var pickedBook: Book?

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit(of: .search) { Task { await run() } }
        .navigationDestination(item: $pickedBook) { b in
            BookDetailView(book: b)
        }
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
                Button { pickedBook = b } label: { BookRow(book: b) }
                    .buttonStyle(.plain)
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
        //
        // ⭐⭐⭐⭐⭐ **同时最多搜 N 个源**（2026-10-26 jetsam 6.8GB 实证）
        //
        // ⚠️⚠️⚠️ **原来这里是「所有源一起搜」（125 个并发 op！）**：
        //   ⇒ 每个 op 会给**那个源建一个会话 = 一个 JSC context**（引擎侧复用）
        //   ⇒ 125 个并发 ⇒ **125 个 JSC context 同时活着** ⇒ 每个都带站方 JS 的全局
        //   ⇒ 峰值内存直接冲到 GB 级 ⇒ **jetsam 杀 App**（老引擎的 JS 在别的进程里 ⇒ 没事）⭐⭐⭐
        // ⇒ 现在：**滑动窗口** ⇒ 同时最多 4 个 ⇒ 其余排队
        //   ⇒ 峰值内存降一个数量级；会话数也被引擎侧封顶（≤4）⇒ 不会累积 ⭐⭐⭐
        //   ⇒ ⚠️ 代价：全源搜索变慢（串行度提高）⇒ 但**不闪退**才是第一位的 ⭐⭐⭐
        var collected: [Book] = []
        var firstError: String?
        let limit = max(1, min(Self.maxConcurrentSearches, targets.count))
        await withTaskGroup(of: Result<[Book], Error>.self) { group in
            var next = 0
            func addTask(_ s: BookSource) {
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
            // 先塞满窗口
            while next < limit {
                addTask(targets[next]); next += 1
            }
            // 每完成一个 ⇒ 补一个（⇒ 并发数恒定 ≤ limit）
            for await r in group {
                switch r {
                case .success(let list): collected.append(contentsOf: list)
                case .failure(let e): if firstError == nil { firstError = e.localizedDescription }
                }
                if next < targets.count {
                    addTask(targets[next]); next += 1
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
