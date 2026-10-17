import SwiftUI

struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @State private var search = ""
    @State private var showAdd = false

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

    var body: some View {
        Group {
            if library.items.isEmpty {
                EmptyHint(icon: "books.vertical", title: "书架还是空的",
                          subtitle: "去「搜索」找本书，加进来就能离线读了")
            } else if shown.isEmpty {
                EmptyHint(icon: "magnifyingglass", title: "没有匹配的书")
            } else {
                List {
                    ForEach(uniqueItems) { item in
                        NavigationLink {
                            BookDetailView(book: item.book)
                        } label: {
                            BookRow(book: item.book, showSource: false)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                library.remove(item.book.id)
                            } label: { Label("移除", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("书架")
        .searchable(text: $search, prompt: "搜书架里的书")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SearchView() } label: { Image(systemName: "plus") }
            }
        }
    }
}
