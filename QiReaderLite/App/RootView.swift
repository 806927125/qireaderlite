import SwiftUI

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { BookshelfView() }
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            // 栖阅底栏是「书架/书签/统计/设置」，没有独立的发现——
            // 用户明确说了「统计不玩了，栖阅的书签就是发现」，
            // 所以这里第二格放发现，第三格放书源，第四格给设置。
            NavigationStack { ExploreView() }
                .tabItem { Label("发现", systemImage: "safari") }
                .tag(1)

            NavigationStack { SourcesView() }
                .tabItem { Label("书源", systemImage: "slider.horizontal.3") }
                .tag(2)

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(Theme.accent)
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
            CoverImage(url: book.cleanCover, width: 56, height: 78)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.name)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline).foregroundStyle(Theme.sub).lineLimit(1)
                }
                if !book.intro.isEmpty {
                    Text(book.intro)
                        .font(.caption).foregroundStyle(Theme.sub)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if !book.lastChapter.isEmpty {
                        Text(book.lastChapter)
                            .font(.caption2).foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    if showSource && !book.sourceName.isEmpty {
                        Text("· " + book.sourceName)
                            .font(.caption2).foregroundStyle(Theme.sub).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
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
