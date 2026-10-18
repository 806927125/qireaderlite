import SwiftUI

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

    var body: some View {
        ZStack {
            PageBackdrop()

            ScrollView {
                VStack(spacing: 12) {
                    BigTitle("书库",
                              subtitle: library.items.isEmpty ? nil
                                : "\(library.items.count) 本 · 在读 \(library.items.filter { $0.lastChapterIndex > 0 && !$0.finished }.count) 本")
                        .padding(.top, 4)

                    if uniqueItems.isEmpty {
                        EmptyHint(icon: "books.vertical",
                                  title: search.isEmpty ? "书库还是空的" : "没有匹配的书",
                                  subtitle: search.isEmpty ? "去「搜索」找本书，加进来就能离线读了" : "")
                            .padding(.top, 60)
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
                // 搜索从底栏挪上来（底栏第四格给了设置），
                // 这里跟栖阅一样：右上角一组胶囊按钮
                GlassCapsule {
                    NavigationLink { SearchView() } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)

                    NavigationLink { SearchView() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
