import SwiftUI

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            // ⭐⭐⭐⭐⭐ **「终端」首页**（2026-11-24 星澜终端换肤）⭐⭐⭐⭐⭐
            //   ⇒ 原型第一屏是「终端」（当前在读 + 继续阅读 + 快捷入口 + 最近阅读）⭐⭐⭐
            //   ⇒ 原来的「书架」列表**完整保留在终端首页下方** ⇒ 不丢任何功能 ⭐⭐⭐
            NavigationStack { BookshelfView() }
                .tabItem { Label("终端", systemImage: "dot.radiowaves.left.and.right") }
                .tag(0)

            // 栖阅是「书源列表 → 点进去才是某个书源的榜单」两级，
            // 所以发现这一格是 DiscoverView（列书源），不是直接甩榜单列表。
            // ⭐⭐⭐ **发现页的「筛选键」原样保留**（filterBar / filterChip 逻辑一字未动）⭐⭐⭐
            NavigationStack { DiscoverView() }
                .tabItem { Label("发现", systemImage: "safari") }
                .tag(1)

            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(2)

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(Theme.accent)
        // ⭐⭐⭐⭐⭐ **导航栏：深色玻璃**（星澜终端）⭐⭐⭐⭐⭐
        //   ⇒ `.toolbarColorScheme(.dark)` ⇒ 标题/按钮自动变浅色（深底上才看得见）⭐⭐⭐
        //   ⇒ `.ultraThinMaterial` ⇒ 毛玻璃底 ⇒ 底下��深空背景隐约透出来 ⭐⭐⭐
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // ⭐⭐⭐ **标签栏同样走毛玻璃 + 深色**（底下就是深空背景）⭐⭐⭐
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
    }
}

// MARK: - 书源选择器

/// 搜索/发现页共用：列出启用中的书源
struct SourcePicker: View {
    @EnvironmentObject private var store: SourceStore
    @Binding var selection: String?
    var allowAll = false

    var body: some View {
        Menu {
            if allowAll {
                Button("全部书源") { selection = nil }
            }
            ForEach(store.enabled) { s in
                Button {
                    selection = s.bookSourceUrl
                } label: {
                    if selection == s.bookSourceUrl {
                        Label(s.name, systemImage: "checkmark")
                    } else {
                        Text(s.name)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }
}

// MARK: - 书籍行

struct BookRow: View {
    let book: Book
    var showSource = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: book.cleanCover, width: 76, height: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if !book.kind.isEmpty {
                        PillTag(text: book.kind, color: Theme.tagPurple)
                    }
                    if !book.wordCount.isEmpty {
                        PillTag(text: book.wordCount, color: Theme.tagPink)
                    }
                    if showSource && !book.sourceName.isEmpty {
                        PillTag(text: book.sourceName, color: Theme.tagBlue)
                    }
                }
                if !book.intro.isEmpty {
                    Text(book.intro)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub.opacity(0.85))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
        .contentShape(Rectangle())
    }
}

/// 多个书源同时搜时，同一本书的重复结果合并掉
enum BookDedup {
    /// 按 id 去重：List/ForEach 撞 id 会直接闪退，必须在渲染前挡掉
    static func unique(_ books: [Book]) -> [Book] {
        var seen = Set<String>()
        return books.filter { seen.insert($0.id).inserted }
    }

    static func merge(_ books: [Book]) -> [Book] {
        var seen = Set<String>()
        var out: [Book] = []
        for b in books {
            let key = b.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(b)
        }
        return out
    }
}
