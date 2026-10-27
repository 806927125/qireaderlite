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
                filterBar
                list
            }
        }
        .navigationTitle(current?.bookSourceName ?? "发现")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    // 分类胶囊放导航栏，跟返回键平齐一行。
                    // 之前它跟内容区里的书源名挤在一起，看起来是错位的。
                    // ⚠️ **筛选不在顶栏**（2026-10-22 用户反馈「栖阅是弄一行胶囊的」）
                    //   ⇒ 筛选胶囊行放在**内容区顶部**（跟栖阅一样）
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
        .task {
            // ⭐⭐⭐ **先挑一条最快的线路**（2026-10-24 真机「唯独大灰狼卡死」）
            //   大灰狼 8 条线路 ⇒ 站方挨个试 ⇒ 死线路每条等超时 ⇒ 每个 op 十几秒
            //   ⇒ 先挑一条通的写进 `server` ⇒ 之后每个 op 只打那一条 ⇒ 秒回 ⭐
            if let s = current { await SourceService.shared.ensureFastLine(source: s) }
            await loadKinds()
        }
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
            kindsLoaded = false          // 换了书源 ⇒ 分类要重来
            Task { await loadKinds(force: true) }
        }
    }

    /// ⭐⭐ **发现页筛选栏**（栖阅同款：内容区顶部**一行横向滚动的胶囊**）
    ///
    /// 2026-10-22 用户反馈：「栖阅的筛选键，是在发现页上面弄一行胶囊的呀」
    /// 栖阅那行是：`5006` / `模式 小说` / `频道 男频` / `平台 番茄` / `字数 不限` ……
    /// ⇒ 每个筛选项一个胶囊，显示「标题 + 当前值」⇒ 点一下直接出选项（Menu）
    ///
    /// ⚠️ 这些是站方 exploreUrl 返回的 `type:"select"` 项
    ///    （**没有 url 字段** ⇒ 以前混在分类列表里、点不动 ⇒ 用户看到「平台」没有 api）
    @ViewBuilder
    private var filterBar: some View {
        if !filters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filters) { f in
                        filterChip(f)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    /// 一个筛选项的胶囊（点开就是该筛选项的全部选项）
    private func filterChip(_ f: SourceService.FilterDTO) -> some View {
        // ⚠️ 别写成 `if let cur = ...currentValue(...)` ——
        //    `currentValue` 返回的是**非可选 String** ⇒ 那样编不过
        let cur = SourceService.FilterDTO.currentValue(f, sourceUrl: currentSourceUrl)
        return Menu {
            if f.chars.isEmpty {
                Text("（这个筛选项没有可选项）")
            } else {
                ForEach(f.chars, id: \.self) { c in
                    Button {
                        applyFilter(f, c)
                    } label: {
                        Text(c)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(f.title)
                    .font(.system(size: 12))
                Text(cur.isEmpty ? "请选择" : cur)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            // ⭐ **液态玻璃**（2026-10-22 用户要求「筛选键接入液态玻璃」）
            //   ⚠️ `glassCapsule()` 内部已经走系统 `.glassEffect(.capsule)`（或手搓 999 圆角）
            //   ⇒ **别再叠 `.background` / `.glassEffectShape`** ⇒ 玻璃套玻璃 = 一坨灰糊
            .glassCapsule()
        }
    }

    /// 选中一个筛选项 ⇒ **写源级变量** ⇒ 重新跑站方 exploreUrl
    ///
    /// ⚠️⚠️ 两条路（2026-10-22）：
    ///   ① `paramKey` 有值（🍅大灰狼：`show(infoMap['平台'],'find_source')`）
    ///      ⇒ 轻阅自己写这个源级变量
    ///   ② `paramKey` 为空但**有 action**（🍒NovelHub：action 自己写变量 + 刷新）
    ///      ⇒ **执行站方 action**（栖阅同款）—— 宿主自己写不了那个变量 ⭐
    ///
    /// ⚠️⚠️ 写变量**必须合并站方默认表**（`mergeVars`）—— 只写一项会把源改坏：
    ///   站方 `getArguments` **只在变量串为空时才给默认表** ⇒ 只写一项 ⇒
    ///   `server / tab / sources / source_type / proxy` 全变 undefined ❗
    private func applyFilter(_ f: SourceService.FilterDTO, _ value: String) {
        // ⚠️ 先记下「用户选了什么」—— paramKey 为空的筛选项（站方自己管变量）
        //   读不到源级变量 ⇒ 胶囊会一直显示站方的 default ⇒ 用户以为没生效
        SourceVariables.setFilterChoice(value, for: currentSourceUrl, title: f.title)
        if f.paramKey.isEmpty {
            // ── ② 站方自己管变量 ⇒ 执行它的 action ──
            guard !f.action.isEmpty, let s = current else { return }
            Task {
                _ = try? await SourceService.shared.applySourceFilter(
                    source: s, action: f.action, title: f.title, value: value)
                // 站方写完变量 ⇒ 分类/筛选栏都要重跑
                //（胶囊上的当前值来自站方重跑后给的 default）
                kindsLoaded = false
                selected = nil
                books = []
                await loadKinds(force: true)
            }
            return
        }
        // ── ① 轻阅自己写源级变量 ──
        let key = f.paramKey
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
            // ⭐⭐ 发现页筛选在 Legado 里是**站方变量**（`source.setVariable(JSON…)`）⇒ 两处都写 ⭐
            //   ⭐⭐⭐ 走 `setHostMap` ⇒ **凭据形态的源不许被塞 map**（✿UAA：那一格放的是 token）⭐⭐⭐
            SourceVariables.setHostMap(str, for: currentSourceUrl)
        }
        // 站方的 exploreUrl 要重跑才看得到新平台（discoverySource 是在里面读的）
        kindsLoaded = false
        selected = nil
        books = []
        Task { await loadKinds(force: true) }
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
            // ⭐⭐⭐ **说清在等什么**（2026-10-24 真机「app 死机」）
            //   聚合源的发现页要**跑站方 JS + 自己 ajax 站方服务器** ⇒ 可能几十秒
            //   ⇒ 以前只转一个圈 ⇒ 用户以为 App 死了（真机就是被 watchdog 杀的）
            //   ⇒ 现在：**明说在等站方服务器**，并给出「最多等多久」
            Spacer().overlay(
                VStack(spacing: 10) {
                    ProgressView()
                    Text("在等书源服务器…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.sub)
                    Text("聚合源要自己跑站方脚本再问服务器，慢的话可能要几十秒\n（不会超过 60 秒；超时会自动报错并可换线路）")
                        .font(.caption2)
                        .foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            )
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
                // 列表底部这一行 = **「上拉加载」的触发器 + 看得见的「加载更多」按钮**
                //
                // ⚠️⚠️ **翻页成功时不要再自增 `loadMoreID`**（2026-10-22 真机「发现页没有翻页功能」）：
                //   原来 `loadMore()` 成功后 `loadMoreID += 1` ⇒ `.task(id:)` 立刻重跑
                //   ⇒ **一路连翻到站方没数据为止**（番茄 355 个分类、每页 30 本 ⇒ 一次拉几十页，手机发烫）
                //   ⇒ 现在：**只有「换分类 / 重新加载」才动 loadMoreID**
                //      ⇒ 滚动到底 ⇒ 翻**一页** ⇒ 内容变多把这一行推走 ⇒ 再滚到底 ⇒ 再翻一页 ✅
                //   ⇒ 再配一个**显式按钮**（用户说「没有翻页功能」⇒ 看不到按钮就以为没有）
                if !reachedEnd {
                    HStack(spacing: 10) {
                        Spacer()
                        if loadingMore {
                            ProgressView()
                        } else {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                Label("加载更多", systemImage: "arrow.down.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    // ⚠️ 挂 id（换分类时 loadMoreID 变 ⇒ task 重跑 ⇒ 翻新分类的第一页）
                    //   但 **loadMore() 成功后不再自增** ⇒ 不会自动连翻 ✅
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
                try await SourceService.shared.exploreKinds(source: s, force: force)
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
            // ⭐⭐ **优先选「带 `{{page}}`」的分类**（2026-10-22 真机「发现页没有翻页功能」）
            //   🍅大灰狼的分类列表**第一个是「大灰狼个人中心」**（站方塞进来的个人书架入口），
            //   它的 url = `get_book_shelf` —— **没有 `{{page}}`** ⇒ 每次都返回同一页
            //   ⇒ `addedNew == 0` ⇒ 判定「没有更多了」⇒ **看起来像没有翻页功能** ❗
            //   ⇒ 真正能翻页的分类（`get_discover` / `discovedata`）都带 `{{page}}` ⇒ 优先选它们 ✅
            let pageable = withURL.filter { $0.url.contains("{{page}}") }
            selected = kinds.first { $0.url == prevUrl && !$0.url.isEmpty }
                ?? (pageable.isEmpty
                    ? (withURL.isEmpty ? kinds.first : withURL.first)
                    : pageable.first)
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
                // ⚠️ **不要** `loadMoreID += 1`（那会让 `.task(id:)` 立刻重跑 ⇒ 自动连翻到死）
                //   ⇒ 无 id 的 `.task` 只在这一行**出现**时跑 ⇒ 滚到底才翻一页 ✅
            }
        } catch {
            // 翻页失败就停在这儿，别无限重试（站方 403/超时很常见）
            reachedEnd = true
        }
    }
}
