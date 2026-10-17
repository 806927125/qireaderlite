import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var sources: SourceStore

    @State private var sourceId: String?
    @State private var kinds: [SourceService.KindDTO] = []
    @State private var selected: SourceService.KindDTO?
    @State private var books: [Book] = []
    @State private var busy = false
    @State private var statusText = ""

    private var current: BookSource? {
        guard let id = sourceId, let s = sources.source(id: id) else { return sources.enabled.first
        }
        return s.enabled ? s : sources.enabled.first
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            kindBar
            Divider()
            list
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadKinds() }
        .onChange(of: sourceId) { _, _ in
            selected = nil
            books = []
            Task { await loadKinds() }
        }
    }

    private var picker: some View {
        HStack {
            Text(current?.name ?? "没有可用书源")
                .font(.headline).foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer()
            SourcePicker(selection: $sourceId)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    @ViewBuilder
    private var kindBar: some View {
        if !kinds.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, k in
                        let on = selected?.url == k.url
                        Button {
                            selected = k
                            Task { await loadBooks() }
                        } label: {
                            Text(k.title)
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(on ? Theme.accent : Theme.sub.opacity(0.1),
                                            in: Capsule())
                                .foregroundStyle(on ? .white : Theme.ink)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .background(Theme.card)
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
            EmptyHint(icon: "rectangle.stack", title: "选个分类看看")
        } else {
            List(BookDedup.unique(books)) { b in
                NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) }
            }
            .listStyle(.plain)
            .refreshable { await loadBooks() }
        }
    }

    private func loadKinds() async {
        guard let s = current else {
            kinds = []; statusText = "没有启用且带发现页的书源"; return
        }
        if sourceId == nil { sourceId = s.bookSourceUrl }
        busy = true
        do {
            kinds = try await SourceService.shared.exploreKinds(source: s)
            if let first = kinds.first {
                selected = first
                await loadBooks()
            } else {
                statusText = "这个书源没解析出分类"
            }
        } catch {
            statusText = error.localizedDescription
            kinds = []
        }
        busy = false
    }

    private func loadBooks() async {
        guard let s = current, let k = selected else { return }
        busy = true
        statusText = ""
        do {
            books = try await SourceService.shared.explore(source: s, kindUrl: k.url, page: 1)
        } catch {
            statusText = error.localizedDescription
            books = []
        }
        busy = false
    }
}
