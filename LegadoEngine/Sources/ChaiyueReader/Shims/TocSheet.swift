#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/Sheets.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/Sheets.swift

import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

struct TocSheet: View {
    let chapters: [BookChapter]
    let current: Int
    var bookUrl: String
    var bookmarks: [Bookmark]?
    var state: ReaderSession.TocState = .ready
    var onRetry: (() -> Void)?
    let onPick: (Int) -> Void
    var onBookmark: ((Bookmark) -> Void)?
    var onDeleteBookmark: ((Bookmark) -> Void)?

    @Environment(AppModel.self) private var app
    @State private var tab = 0
    @State private var reversed = false
    @State private var cached: Set<String> = []

    private struct Section: Identifiable {
        let id: Int
        let title: String?
        let items: [BookChapter]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if bookmarks != nil {
                    SegmentedChips(items: ["目录", "书签"], selection: $tab, height: 32, font: .ui(14), itemWidth: 96, inset: 3, glass: true)
                } else {
                    Text("目录").font(.serif(22)).foregroundStyle(Tok.gFg)
                    Text("\(chapters.count)").font(.num(14)).foregroundStyle(Tok.gFg3)
                }
                Spacer()
                if tab == 0 {
                    Button {
                        withAnimation(.soft) { reversed.toggle() }
                    } label: {
                        Image(icon: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(reversed ? Tok.gAccent : Tok.gFg2)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.leading, bookmarks != nil ? 20 : 24)
            .padding(.trailing, 14)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ZStack {
                if tab == 0 {
                    chapterList.transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    bookmarkList.transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.soft, value: tab)
        }
        .task(id: chapters.count) {
            let store = app.library.chapterStore
            let url = bookUrl
            cached = await Task.detached(priority: .utility) { store.cachedFileNames(bookUrl: url) }.value
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        switch state {
        case .loading where chapters.isEmpty, .idle where chapters.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where chapters.isEmpty:
            VStack(spacing: 14) {
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Tok.gFg3)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                if let onRetry {
                    Button("重试", action: onRetry)
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Tok.gAccent)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                                ForEach(section.items, id: \.index) { chapter in
                                    chapterRow(chapter).id(chapter.index)
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                        .font(.ui(12))
                                        .tracking(1)
                                        .foregroundStyle(Tok.gFg3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 24)
                                        .padding(.top, 12)
                                        .padding(.bottom, 8)
                                        .background(.ultraThinMaterial.opacity(0.9))
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
                .onChange(of: reversed) { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private var sections: [Section] {
        var result: [Section] = []
        var title: String?
        var items: [BookChapter] = []
        var sectionID = 0
        for chapter in chapters {
            if chapter.isVolume {
                if !items.isEmpty || title != nil {
                    result.append(Section(id: sectionID, title: title, items: reversed ? items.reversed() : items))
                }
                sectionID += 1
                title = chapter.title
                items = []
            } else {
                items.append(chapter)
            }
        }
        if !items.isEmpty || title != nil {
            result.append(Section(id: sectionID, title: title, items: reversed ? items.reversed() : items))
        }
        return reversed ? result.reversed() : result
    }

    private func chapterRow(_ chapter: BookChapter) -> some View {
        let on = chapter.index == current
        return Button {
            onPick(chapter.index)
        } label: {
            HStack(spacing: 10) {
                Text("\(chapter.index + 1)")
                    .font(.num(12))
                    .foregroundStyle(on ? Tok.gAccent : Tok.gFg3)
                    .frame(width: 42, alignment: .leading)
                Text(chapter.title.withoutEmoji)
                    .font(.ui(15, on ? .semibold : .regular))
                    .foregroundStyle(on ? Tok.gAccent : Tok.gFg)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if chapter.isVip, !chapter.isPay {
                    Image(icon: "lock.fill").font(.system(size: 10)).foregroundStyle(Tok.gFg3)
                }
                if cached.contains(ChapterStore.fileName(for: chapter)) {
                    Circle().fill(Tok.gFg3).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 50)
            .overlay(alignment: .leading) {
                if on {
                    Capsule().fill(Tok.accent).frame(width: 3, height: 18).padding(.leading, 11)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle(color: Tok.gFill))
    }

    @ViewBuilder
    private var bookmarkList: some View {
        let marks = bookmarks ?? []
        if marks.isEmpty {
            Image(icon: "bookmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Tok.gFg3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(marks) { mark in
                    Button {
                        onBookmark?(mark)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mark.chapterName)
                                .font(.ui(12))
                                .foregroundStyle(Tok.gFg3)
                                .lineLimit(1)
                            Text(mark.bookText)
                                .font(.serif(15, bold: false))
                                .foregroundStyle(Tok.gFg)
                                .lineLimit(2)
                            if !mark.content.isEmpty {
                                Text(mark.content).font(.ui(13)).foregroundStyle(Tok.gFg2).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Tok.gLine)
                    .swipeActions {
                        Button("删除", icon: "trash", role: .destructive) { onDeleteBookmark?(mark) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
#endif
