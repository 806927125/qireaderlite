import SwiftUI

// =============================================================================
// ⭐⭐⭐⭐⭐ **「星澜终端」首页**（2026-11-24，按 HTML 原型 `v-terminal` 重做）⭐⭐⭐⭐⭐
//
// ⚠️ **为什么把「书架」改成「终端首页」**：
//   原型是一套「终端」信息架构：当前在读 + 继续阅读 + 三个快捷入口 + 最近阅读轨道 ⭐⭐⭐
//   ⇒ 而轻阅原来的「书架」只有一张列表 ⇒ ⇒ 把书���变成终端首页，**列表照旧留在下面** ⭐⭐⭐
//   ⇒ ⇒ **不删任何功能**：搜索/编辑/加书工具栏、完整书库列表、右键菜单全保留 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **进度环的诚实原则** ⭐⭐⭐⭐⭐
//   原型那圈 62% 是**装饰**（虚构的书）⇒ 我们不能照抄一个假百分比 ⭐⭐⭐
//   ⇒ 书架里**没有总章数**（`Book` 不带章节总数，要联网抓目录才有）⭐⭐⭐
//   ⇒ 所以：**只有「已读完」才画满环**；在读就写「第 N 章」；没开始就写「还没开始」⭐⭐⭐
//   ⇒ 宁可环空着，也不给用户一个假的进度 ⭐⭐⭐
// =============================================================================

struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @State private var search = ""
    @State private var showAdd = false
    @State private var editing = false

    private var shown: [LibraryItem] {
        let list = search.isEmpty
            ? library.items
            : library.items.filter {
                $0.book.name.localizedCaseInsensitiveContains(search)
                    || $0.book.author.localizedCaseInsensitiveContains(search)
              }
        return list.sorted {
            ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt)
        }
    }

    /// ForEach 的 id 撞了会直接闪退，渲染前先去重
    private var uniqueItems: [LibraryItem] {
        var seen = Set<String>()
        return shown.filter { seen.insert($0.id).inserted }
    }

    // MARK: - 终端首页要用的数据

    /// ⭐⭐⭐ **当前在读的那本**（最近读过、且没读完）⭐⭐⭐
    private var currentItem: LibraryItem? {
        let sorted = library.items.sorted {
            ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt)
        }
        return sorted.first { !$0.finished && $0.lastChapterIndex > 0 } ?? sorted.first
    }

    /// ⭐⭐⭐ **最近阅读轨道**（最近读过的前 12 本）⭐⭐⭐
    private var recentItems: [LibraryItem] {
        var seen = Set<String>()
        return library.items
            .sorted { ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt) }
            .filter { seen.insert($0.id).inserted }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            PageBackdrop()

            ScrollView {
                VStack(spacing: 14) {
                    // ── ① 品牌顶栏（原型 `.topbar`）────────────────────────────
                    TerminalTitle(
                        kicker: "READING TERMINAL",
                        title: "星澜终端",
                        trailing: AnyView(
                            NavigationLink { SourcesView() } label: {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Terminal.ink)
                                    .frame(width: 38, height: 38)
                                    .background(Terminal.glass2, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .stroke(Terminal.edge, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        )
                    )
                    .padding(.top, 6)

                    // ── ② 驾驶舱（原型 `.cabin`）──────────────────────────────
                    cabin

                    // ── ③ 三个快捷气泡（原型 `.quick`）────────────────────────
                    quickBar

                    // ── ④ 最近阅读轨道（原型 `.rail`）──────────────────────────
                    if !recentItems.isEmpty {
                        HStack {
                            Text("最近阅读")
                                .font(.system(size: 17, weight: .bold, design: .serif))
                                .foregroundStyle(Terminal.ink)
                            Spacer()
                            Text("全部 ›")
                                .font(.system(size: 12))
                                .foregroundStyle(Terminal.dim)
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 6)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recentItems) { item in
                                    NavigationLink {
                                        BookDetailView(book: item.book)
                                    } label: {
                                        RecentSpine(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                        }
                    }

                    // ── ⑤ 完整书库（原有功能全保留）────────────────────────────
                    HStack {
                        Text("我的藏书")
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(Terminal.ink)
                        Spacer()
                        Text("\(library.items.count) 本")
                            .font(.system(size: 12))
                            .foregroundStyle(Terminal.dim)
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 6)

                    if uniqueItems.isEmpty {
                        EmptyHint(icon: "books.vertical",
                                  title: search.isEmpty ? "书库还是空的" : "没有匹配的书",
                                  subtitle: search.isEmpty ? "去「搜索」找本书，加进来就能离线读了" : "")
                            .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(uniqueItems) { item in
                                NavigationLink {
                                    BookDetailView(book: item.book)
                                } label: {
                                    ShelfCard(item: item)
                                }
                                .buttonStyle(.plain)
                                // List 换成 ScrollView 后没有 swipeActions，
                                // 长按菜单是唯一入口 —— 空出来就是"能看不能删"，不可接受
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.remove(item.book.id)
                                    } label: { Label("移出书库", systemImage: "trash") }
                                    Button {
                                        let want = !item.finished
                                        library.update(item.book.id) { $0.finished = want }
                                    } label: {
                                        Label(item.finished ? "标记为在读" : "标记已读完",
                                              systemImage: item.finished ? "book" : "checkmark.circle")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .searchable(text: $search, prompt: "搜书库里的书")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation { editing.toggle() }
                } label: {
                    Text(editing ? "完成" : "编辑")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        // 同 GlassCapsule：走真玻璃，别叠半透明白
                        .liquidGlass(cornerRadius: 999, strength: 1.1)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 搜索已经回到底栏了，这里只留「加书」——之前塞了两个
                // 长得一模一样、都通往搜索页的按钮，纯属重复。
                NavigationLink { SearchView() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .liquidGlass(cornerRadius: 999)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - ② 驾驶舱

    @ViewBuilder
    private var cabin: some View {
        if let item = currentItem {
            NavigationLink {
                BookDetailView(book: item.book)
            } label: {
                VStack(spacing: 12) {
                    // 进度环 + 封面（原型 `.cabin .ring`）
                    ProgressRing(progress: item.finished ? 1 : 0, size: 128) {
                        AnyView(
                            CoverImage(url: item.book.cleanCover, width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Terminal.edge, lineWidth: 1)
                                )
                        )
                    }

                    // 书名（衬线大字）
                    Text(item.book.name)
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(Terminal.ink)
                        .lineLimit(1)

                    // 作者 · 进度说明
                    Text(cabinSubtitle(item))
                        .font(.system(size: 12))
                        .foregroundStyle(Terminal.dim)
                        .lineLimit(1)

                    // 进度条（**只在「已读完」时满**；在读时不给假百分比）⭐⭐⭐
                    if item.finished {
                        // ⚠️ **宽度必须用 GeometryReader 给** ⇒ 否则 overlay 里的 Capsule
                        //   会按「父视图整个宽度」铺满 ⇒ 永远是 100%（假进度）⭐⭐⭐
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Terminal.track)
                                Capsule().fill(Terminal.gradient)
                                    .frame(width: geo.size.width, height: 6)
                            }
                        }
                        .frame(height: 6)
                        .frame(maxWidth: 220)
                    }

                    // 「继续阅读」按钮（原型 `.cgo`）
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 12))
                        Text(item.finished ? "再读一遍" : "继续阅读")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Terminal.bg)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .terminalGradientButton()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .padding(.horizontal, 18)
                .terminalCard()
            }
            .buttonStyle(.plain)
        } else {
            // 空态也给一张玻璃卡（别让首页空荡荡）
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30))
                    .foregroundStyle(Terminal.cyan)
                Text("还没有在读的书")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(Terminal.ink)
                Text("去「搜索」找一本，加进来就能读")
                    .font(.system(size: 12))
                    .foregroundStyle(Terminal.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .terminalCard()
        }
    }

    /// ⭐⭐⭐ **驾驶舱副标题**（有据可依的进度文案，不编百分比）⭐⭐⭐
    private func cabinSubtitle(_ item: LibraryItem) -> String {
        let author = item.book.author.isEmpty ? "未知作者" : item.book.author
        if item.finished { return "\(author) · 已读完" }
        if item.lastChapterIndex > 0 {
            let chapter = item.book.lastChapter.isEmpty ? "" : " · \(item.book.lastChapter)"
            return "\(author) · 在读第 \(item.lastChapterIndex + 1) 章\(chapter)"
        }
        return "\(author) · 还没开始"
    }

    // MARK: - ③ 快捷气泡

    private var quickBar: some View {
        HStack(spacing: 12) {
            NavigationLink { SourcesView() } label: {
                QuickBubble(icon: "dot.radiowaves.left.and.right",
                            title: "书源频道",
                            sub: "\(sources.enabled.count) 个")
            }
            .buttonStyle(.plain)

            NavigationLink { SearchView() } label: {
                QuickBubble(icon: "magnifyingglass",
                            title: "找书",
                            sub: "搜索书源")
            }
            .buttonStyle(.plain)

            NavigationLink { SettingsView() } label: {
                QuickBubble(icon: "person.crop.circle",
                            title: "我的",
                            sub: "数据中心")
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 快捷气泡（原型 `.quick .qb`）

struct QuickBubble: View {
    let icon: String
    let title: String
    let sub: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Terminal.cyan)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Terminal.ink)
                .padding(.top, 8)
            Text(sub)
                .font(.system(size: 11))
                .foregroundStyle(Terminal.dim)
                .padding(.top, 3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .terminalCard(cornerRadius: 18)
        .contentShape(Rectangle())
    }
}

// MARK: - 最近阅读书脊（原型 `.rail .doc`）

struct RecentSpine: View {
    let item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(url: item.book.cleanCover, width: 110, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Terminal.edge, lineWidth: 1)
                )
                .overlay(alignment: .leading) {
                    // 书脊（原型 `.spine::before` 那条竖线）
                    Rectangle()
                        .fill(Terminal.spine)
                        .frame(width: 5)
                }
            Text(item.book.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Terminal.ink)
                .lineLimit(1)
                .padding(.top, 9)
            Text(item.book.author.isEmpty ? "—" : item.book.author)
                .font(.system(size: 11))
                .foregroundStyle(Terminal.dim)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(width: 110)
        .contentShape(Rectangle())
    }
}
