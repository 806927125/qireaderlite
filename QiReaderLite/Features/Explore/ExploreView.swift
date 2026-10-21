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
    /// 顶栏「筛选」点开的「发现页筛选栏」页（站方 exploreUrl 的 `type:"select"` 契约）
    @State private var showFilterPicker = false
    /// 站方的发现页筛选栏（平台 / 模式 / 频道 / 字数 / 状态 / 排序…）
    @State private var filters: [SourceService.FilterDTO] = []
    /// 已经加载过分类（从详情页返回时**不要**重新加载）
    @State private var kindsLoaded = false
    /// 点书籍卡片进详情。走 navigationDestination(item:) 而不是 NavigationLink，
    /// 因为后者在 List 行里会自动多出一个行尾箭头。
    @State private var pickedBook: Book?

    /// 从发现页点进来时书源是定死的，没定死才回退到「第一个启用的」
    private let pinnedSourceId: String?

    init(source: BookSource? = nil) {
        pinnedSourceId = source?.bookSourceUrl
    }

    /// 当前书源的 URL（闭包里要用 ⇒ 不能用局部变量）
    private var currentSourceUrl: String { current?.bookSourceUrl ?? "" }

    /// 筛选栏里「平台」这一项的**当前值**（显示在顶栏按钮上）
    ///
    /// ⚠️ 别写成 `if let cur = ...currentValue(...)` ——
    ///    `currentValue` 返回的是**非可选 String** ⇒ 那样编不过
    ///    （2026-10-22 CI 报错：initializer for conditional binding must have Optional type）
    private var currentPlatformText: String {
        guard let pf = filters.first(where: { $0.paramKey == "find_source" }) else { return "" }
        return SourceService.FilterDTO.currentValue(pf, sourceUrl: currentSourceUrl)
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
                HStack(spacing: 8) {
                    // ⭐ **筛选按钮**（2026-10-21 补：站方的发现页筛选栏契约）
                    //   站方 exploreUrl 会返回「平台 / 模式 / 频道 / 字数 / 状态 / 排序」这些
                    //   `type:"select"` 项（**没有 url 字段**）⇒ 以前混在分类里、点不动
                    //   ⇒ 用户看到的「平台」那几项**没有 api**（2026-10-21 用户原话）
                    //   ⇒ 现在单独渲染成筛选栏 ⇒ **42 个平台终于能切**
                    if !filters.isEmpty {
                        Button { showFilterPicker = true } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "line.3.horizontal.decrease")
                                    .font(.system(size: 11, weight: .semibold))
                                // 有筛选项时显示**当前平台**（一眼知道自己在哪）
                                if !currentPlatformText.isEmpty {
                                    Text(currentPlatformText)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .liquidGlass(cornerRadius: 999)
                        }
                        .buttonStyle(.plain)
                    }
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
        }
        .task { await loadKinds() }
        // 分类筛选是 push 进来的页面，不是 sheet 弹窗。
        // sheet 自带顶部区域 + 我自己画的「× 关闭」胶囊打架，下半屏还全是空白。
        .navigationDestination(item: $pickedBook) { b in
            BookDetailView(book: b)
        }
        .navigationDestination(isPresented: $showFilterPicker) {
            ExploreFilterView(
                filters: filters,
                current: SourceService.FilterDTO.currentValues(
                    filters: filters, sourceUrl: currentSourceUrl),
                onPick: { key, value in
                    // ⭐ 写源级变量（**必须合并站方默认表**，不能只写一项 ——
                    //    站方 getArguments 只在变量串为空时才给默认表 ⇒ 只写一项会把源改坏）
                    let merged = SourceVariables.mergeVars(
                        userJSON: SourceVariables.vars(for: currentSourceUrl),
                        defaults: SourceVariables.defaultVars(for: currentSourceUrl))
                    var obj: [String: Any] = [:]
                    if let d = merged.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        obj = o
                    }
                    obj[key] = value
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let str = String(data: data, encoding: .utf8) {
                        SourceVariables.setVars(str, for: currentSourceUrl)
                    }
                    showFilterPicker = false
                    kindsLoaded = false
                    selected = nil
                    books = []
                    // 站方的 exploreUrl 要重跑才看得到新平台（discoverySource 是在里面读的）
                    Task { await loadKinds(force: true) }
                }
            )
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
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
            kindsLoaded = false          // 换了书源 ⇒ 分类要重来
            Task { await loadKinds(force: true) }
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

    private func loadKinds(force: Bool = false) async {
        guard let s = current else {
            kinds = []; statusText = "没有启用且带发现页的书源"; return
        }
        if sourceId == nil { sourceId = pinnedSourceId ?? s.bookSourceUrl }
        // ⚠️⚠️ **从详情页返回时不要重新加载**（2026-10-21 用户反馈「详情页返回发现，发现页会重新加载」）：
        //   `.task` 在页面重新出现时会重跑 ⇒ exploreKinds 要跑站方 exploreUrl JS
        //   （里面还有 ajax + 8 条线路兜底）⇒ **十几秒白等 + 整屏转圈**。
        //   ⇒ 已经加载过就直接返回（书源换了才 force 重来）。
        if !force, kindsLoaded, !kinds.isEmpty { return }
        busy = true
        do {
            // ⚠️ 先记住用户上次选的分类。`.task` 在页面重新出现时（从详情页返回）会重跑，
            //    之前这里无条件 `selected = kinds.first` → 每返回一次就跳回「全部小说」。
            let prevUrl = selected?.url
            // ⚠️ 加超时（2026-10-21 用户报「一直提示分组正在加载中」）：
            //    exploreKinds 要跑站方的 exploreUrl JS（里面还有 ajax + 8 条线路兜底）
            //    ⇒ op 层超时 360 秒 → 页面就永远转圈 ❗
            //    20 秒没出来就报错，让用户看到原因（多半是线路不通）。
            let res = try await Self.withTimeout(seconds: 20) {
                try await SourceService.shared.exploreKinds(source: s)
            }
            kinds = res.kinds
            filters = res.filters
            kindsLoaded = true
            if kinds.isEmpty {
                statusText = "这个书源没解析出分类"
                selected = nil
            } else {
                // 上次选的还在 → 保住；没了才退回第一个
                // ⚠️ 默认**不要**选中「登录番茄」那种**没有 url 的纯动作项**：
            //    站方把 `java.startBrowser(...)` 直接写在 url 模板里
            //    （`"url": '{java.startBrowser("https://fanqienovel.com/","番茄登录");}'`）
            //    ⇒ 轻阅解析后 url 为**空串** ⇒ 拿它去请求 ⇒「URL 非法」
            //    ⇒ **整个发现页打不开**（2026-10-21 真机实测）
            //    ⇒ 它仍然显示在列表里（用户可以点它去登录），但**默认选中第一个有 url 的**。
            let withURL = kinds.filter { !$0.url.isEmpty }
            selected = kinds.first { $0.url == prevUrl && !$0.url.isEmpty }
                ?? (withURL.isEmpty ? kinds.first : withURL.first)
            }
            if selected != nil {
                await loadBooks()
            }
            // ⚠️ **自动选线**（2026-10-21 用户原话「检测当前服务器只是看快不快的，没有别的用处」）
            //    ⇒ 那就 App 自己测自己切：测速站方所有线路 → 最快的写进书源变量 ✅
            //    （一次启动里每个源只测一次；当前线路够快就不折腾）
            // ⚠️ **detached**：完全不占主线程（主线程被阻塞会被 watchdog 杀 ⇒ 闪退）
            //    失败一律静默（选线只是优化，不值得为它崩）✅
            Task.detached {
                _ = await SourceService.shared.autoPickFastestLine(source: s)
            }
        } catch {
            statusText = error.localizedDescription
            kinds = []
        }
        busy = false
    }

    /// 重新从头加载（切分类、下拉刷新都走这里）
    /// 给 async 操作加 UI 级超时（超时组里，谁先回来用谁）
    private static func withTimeout<T>(seconds: Double,
                                       _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ExploreTimeout()
            }
            guard let first = try await group.next() else { throw ExploreTimeout() }
            group.cancelAll()
            return first
        }
    }

    struct ExploreTimeout: LocalizedError {
        var errorDescription: String? {
            "加载分类超过 20 秒（多半是线路不通：这个源的服务器有几条线路会逐条兜底）"
        }
    }

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
