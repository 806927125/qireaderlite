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
                // ⚠️ 有问题就**一直**显示，不管目录解析出多少章。
                //    原来只在 chapters.isEmpty 时显示，目录有内容但详情解析失败时反而看不见。
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // ⚠️ 原来只在 1~2 章时显示诊断按钮，**0 章反而不显示** ——
                //    而 0 章恰恰是最需要诊断的情况（toc() 成功返回但一条没解析出来，
                //    不抛错，页面上什么都看不出来）。
                if chapters.count <= 2 || !statusText.isEmpty {
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
            CatalogSheet(chapters: chapters, start: readerChapter,
                         subtitle: book.origin.isEmpty ? nil : book.origin) { ch in
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
        //
        // ⚠️ 原来是 `if let fresh = try? await …`，**失败被完全吞掉**：
        //    页面上看着"书名作者简介都有"，其实全是**列表页那份数据**，
        //    bookInfo 压根没跑成。tocUrl 因此是空的 → 目录去抓书籍页
        //    → 0 章。而 statusText 紧接着被清空，**屏幕上一点提示都没有**。
        //    这种"静默地错"最难查，必须把错误说出来。
        var problems: [String] = []
        do {
            let fresh = try await SourceService.shared.bookInfo(
                source: s, bookUrl: book.cleanBookUrl, fallback: book)
            book = book.merged(with: fresh)
            if inShelf { library.add(book) }
            if book.tocUrl.isEmpty {
                problems.append("详情没算出 tocUrl（ruleBookInfo.tocUrl 返回空），目录只能退回书籍页")
            }
        } catch {
            problems.append("详情解析失败：\(error.localizedDescription)")
        }

        // 2) 目录
        let tocURL = book.tocUrl.isEmpty ? book.cleanBookUrl : book.tocUrl
        do {
            let list = try await SourceService.shared.toc(
                source: s, tocUrl: tocURL, bookUrl: book.cleanBookUrl)
            chapters = list
            if list.isEmpty {
                problems.append("目录接口通了但一条章节都没解析出来（chapterList 规则没命中）")
            }
            if let last = library.item(for: book.id)?.lastChapterIndex,
               last > 0, last < list.count {
                readerChapter = nil   // 只是预热，不自动跳
            }
        } catch {
            problems.append("目录加载失败：\(error.localizedDescription)")
        }
        statusText = problems.joined(separator: "\n")
    }
}

/// 目录面板 —— 照栖阅 `ReaderChapterListView.swift` 重做。
///
/// 从栖阅二进制里挖到的结构（strings）：
/// ```
/// /ReaderChapterListView.swift          目录视图本体
/// ChapterCacheService(Protocol)         章节缓存服务 → 已缓存章打云图标
/// _sortAscending / sortAscending        正倒序切换
/// VolumeButtonPageTurn*                 卷分组（isVolume）
/// ReaderSearchView / chapterListEmpty   目录内搜索 / 空态
/// ```
///
/// 视觉照栖阅截图：partial sheet + **系统玻璃**（iOS 26 的 `.glassEffect()`
/// 由 `LiquidGlass` 统一处理，iOS 17~25 走手搓四层），顶部一行
/// 「胶囊按钮组 + 书名/副标题 + 关闭圆钮」，底部一个玻璃胶囊搜索框。
///
/// ⚠️ sheet 背景**不能**自己设 `presentationBackground` —— 那会把系统玻璃盖掉，
///    栖阅那种「透出后面正文」的效果就没了（设置面板已经踩过一次）。
struct CatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chapters: [Chapter]
    let start: Chapter?
    /// 顶部那一行的副标题（栖阅显示的是书源名 + 版本）
    var subtitle: String? = nil
    /// 已预载到内存的章号集合。栖阅那边是 `ChapterCacheService` 的磁盘缓存，
    /// 轻阅还没做磁盘缓存，所以只标「内存里已有」——不假装成离线可读。
    var preloaded: Set<Int> = []
    /// 磁盘缓存还没实现 → 按钮置灰，不做假动作。
    var cacheEnabled: Bool = false
    let onPick: (Chapter) -> Void

    @State private var filter = ""
    @State private var sortAscending = true
    /// 当前停在哪个 detent（`.medium` 对应 0.62，`.large` 是拖满屏）
    @State private var detent: PresentationDetent = .fraction(0.62)

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            searchBar
        }
        // partial sheet + 系统玻璃：不设 presentationBackground，
        // 让 iOS 26 的 glass 自己透出后面的正文。
        //
        // ⚠️ detent 列表要**保留 .large** —— 栖阅那边按住顶部横线上滑是会变大的，
        //    不是定死的。变的触发方式由 iOS 默认行为决定：
        //    **只有按住 grabber 上滑**才在 detent 之间切，拖列表内容是滚列表。
        //
        // ⚠️ 但**绝对不能开** `.presentationBackgroundInteraction(
        //        .enabled(upThrough: .fraction(0.62)))`。
        //    那个修饰符的语义就是「sheet 的背景区域也接管手势」——
        //    开了以后**随便在空白处一拖**整个 sheet 就跟着变形，
        //    用户看到的正是「目录拉一下直接变大窗口」。
        //    这就是前两轮改来改去没改对的那一个。
        .presentationDetents([.fraction(0.62), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
    }

    // MARK: 顶部行

    private var header: some View {
        HStack(spacing: 10) {
            // 左：胶囊按钮组（正倒序 + 缓存）
            HStack(spacing: 0) {
                iconInCapsule(systemName: sortAscending ? "arrow.up" : "arrow.down") {
                    withAnimation(.snappy(duration: 0.2)) {
                        sortAscending.toggle()
                    }
                }
                Rectangle().fill(Theme.ink.opacity(0.16))
                    .frame(width: 1, height: 18)
                iconInCapsule(systemName: "arrow.down.circle", enabled: cacheEnabled) {
                    // 磁盘缓存还没做 —— 置灰就是置灰，不弹「即将支持」糊弄
                }
            }
            .glassCapsule()
            .glassEffectShape(.capsule)

            // 中：书名 + 副标题
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：关闭
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .accessibilityLabel("关闭目录")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var titleText: String {
        let n = chapters.filter { !$0.isVolume }.count
        return "目录 (\(n.formatted()))"
    }

    private func iconInCapsule(systemName: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Image(systemName: systemName)
                .font(.footnote.weight(.semibold))
                // ⚠️ 未实现的功能置灰：半透明 + 弱化色，
                //    一眼能看出点不动，而不是点了给个假反馈。
                .foregroundStyle(enabled ? Theme.ink : Theme.ink.opacity(0.28))
                .frame(width: 42, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ordered) { c in
                        row(c)
                        if c.id != ordered.last?.id {
                            Rectangle().fill(Theme.ink.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 16)
                        }
                    }
                    if ordered.isEmpty {
                        Text("没有匹配的章节")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
            }
            .onAppear {
                // 打开就停在当前章（栖阅也是这么做的）
                if let cur = start {
                    DispatchQueue.main.async {
                        proxy.scrollTo(cur.id, anchor: .center)
                    }
                }
            }
            // 排序/搜索变了要把「当前章高亮」重新滚进视野
            .onChange(of: sortAscending) { _, _ in resyncCurrent(proxy) }
            .onChange(of: filter) { _, _ in resyncCurrent(proxy) }
        }
    }

    private func resyncCurrent(_ proxy: ScrollViewProxy) {
        guard let cur = start else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(cur.id, anchor: .center)
        }
    }

    private func row(_ c: Chapter) -> some View {
        let isCurrent = c.url == start?.url
        return Button {
            onPick(c)
        } label: {
            HStack(spacing: 10) {
                // 已预载标记（栖阅是云图标 = 磁盘缓存，这里是内存预载）
                if preloaded.contains(c.index) && !isCurrent {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(Theme.ink.opacity(0.35))
                }
                Text(c.title)
                    .font(c.isVolume ? .subheadline.weight(.bold) : .body)
                    .foregroundStyle(isCurrent ? Theme.accent : (c.isVolume ? Theme.accent : Theme.ink))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // 当前章：浅色圆角底 + 蓝色文字（栖阅截图就是这样，不是整行填充）
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCurrent ? Theme.accent.opacity(0.12) : .clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(c.id)
    }

    // MARK: 底部搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.55))
            TextField("搜索章节名", text: $filter)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassCapsule()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: 数据

    private var ordered: [Chapter] {
        let base = filter.isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        return sortAscending ? base : base.reversed()
    }
}
