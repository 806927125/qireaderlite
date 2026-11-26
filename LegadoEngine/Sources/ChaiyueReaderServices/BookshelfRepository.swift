import Foundation
import Observation
import ChaiyueModels

/// 书架分组（与 Legado 一致：groupId 为 2 的幂，书籍的 group 字段是位掩码）
public struct BookGroup: Codable, Hashable, Sendable, Identifiable {
    public var groupId: Int64
    public var groupName: String
    public var order: Int

    public var id: Int64 { groupId }

    public init(groupId: Int64, groupName: String, order: Int) {
        self.groupId = groupId
        self.groupName = groupName
        self.order = order
    }
}

/// 书签（字段与 Legado 一致）
public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var time: Int64
    public var bookName: String
    public var bookAuthor: String
    public var chapterIndex: Int
    public var chapterPos: Int
    public var chapterName: String
    public var bookText: String
    public var content: String

    public var id: Int64 { time }

    public init(time: Int64 = Int64(Date().timeIntervalSince1970 * 1000), bookName: String, bookAuthor: String,
                chapterIndex: Int, chapterPos: Int, chapterName: String, bookText: String, content: String = "") {
        self.time = time
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        self.chapterIndex = chapterIndex
        self.chapterPos = chapterPos
        self.chapterName = chapterName
        self.bookText = bookText
        self.content = content
    }
}

struct ShelfState: Codable, Sendable {
    var books: [Book] = []
    var groups: [BookGroup] = []
    var pinned: [String] = []
    var bookmarks: [Bookmark] = []
}

/// 书架：书籍、分组、置顶、阅读进度与书签
@MainActor
@Observable
public final class BookshelfRepository {
    public private(set) var books: [Book] = []
    public private(set) var groups: [BookGroup] = []
    public private(set) var pinned: Set<String> = []
    public private(set) var bookmarks: [Bookmark] = []
    @ObservationIgnored private let store: JSONFileStore<ShelfState>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { ShelfState() }
        let state = store.current
        books = state.books
        groups = state.groups.sorted { $0.order < $1.order }
        pinned = Set(state.pinned)
        bookmarks = state.bookmarks
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - 书籍

    public func book(_ bookUrl: String) -> Book? {
        books.first { $0.bookUrl == bookUrl }
    }

    public func contains(_ bookUrl: String) -> Bool {
        books.contains { $0.bookUrl == bookUrl }
    }

    /// 同名同作者的书（换源后判断是否已在书架）
    public func book(named name: String, author: String) -> Book? {
        books.first { $0.name == name && $0.author == author }
    }

    /// 书架上同名同作者、但来源不同的书（加入书架时提示覆盖）
    public func sameBook(as book: Book) -> Book? {
        guard !contains(book.bookUrl) else { return nil }
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return books.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
                && $0.author.trimmingCharacters(in: .whitespacesAndNewlines) == author
        }
    }

    /// 置顶在前，其余按最近阅读倒序
    public func sortedBooks(inGroup groupId: Int64? = nil) -> [Book] {
        let filtered = groupId.map { id in
            id == 0 ? books.filter { $0.group == 0 } : books.filter { $0.group & id != 0 }
        } ?? books
        return filtered.sorted { a, b in
            let pa = pinned.contains(a.bookUrl), pb = pinned.contains(b.bookUrl)
            if pa != pb { return pa }
            if a.durChapterTime != b.durChapterTime { return a.durChapterTime > b.durChapterTime }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func add(_ book: Book) {
        var book = book
        if book.durChapterTime == 0 { book.durChapterTime = Self.now() }
        if let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            books[index] = book
        } else {
            book.order = (books.map(\.order).min() ?? 0) - 1
            books.append(book)
        }
        persist()
    }

    public func update(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) else { return }
        books[index] = book
        persist()
    }

    /// 换源：用新书替换旧书，保留分组、阅读进度与置顶
    public func replace(_ oldBookUrl: String, with newBook: Book) {
        var newBook = newBook
        if let old = book(oldBookUrl) {
            newBook.group = old.group
            newBook.durChapterTime = Self.now()
            newBook.customCoverUrl = old.customCoverUrl
            newBook.customIntro = old.customIntro
            if newBook.durChapterIndex == 0 && newBook.durChapterPos == 0 {
                newBook.durChapterIndex = old.durChapterIndex
                newBook.durChapterPos = old.durChapterPos
                newBook.durChapterTitle = old.durChapterTitle
            }
        }
        let wasPinned = pinned.remove(oldBookUrl) != nil
        books.removeAll { $0.bookUrl == oldBookUrl || $0.bookUrl == newBook.bookUrl }
        books.append(newBook)
        if wasPinned { pinned.insert(newBook.bookUrl) }
        persist()
    }

    /// 恢复备份：整体替换书籍、分组与置顶，书签不变
    public func restore(books: [Book], groups: [BookGroup], pinned: [String]) {
        var seenBooks = Set<String>()
        self.books = books.filter { seenBooks.insert($0.bookUrl).inserted }
        var seenGroups = Set<Int64>()
        self.groups = groups.filter { $0.groupId > 0 && seenGroups.insert($0.groupId).inserted }.sorted { $0.order < $1.order }
        self.pinned = Set(pinned).intersection(seenBooks)
        persist()
    }

    public func remove(_ bookUrls: Set<String>) {
        books.removeAll { bookUrls.contains($0.bookUrl) }
        pinned.subtract(bookUrls)
        persist()
    }

    /// 用联网获取的书籍信息更新书架中的同一本书：只覆盖书源提供的字段，保留阅读进度、分组与自定义封面简介。
    /// `lastCheckCount` 记录本次新增的章节数
    public func mergeMetadata(from updated: Book) {
        guard let index = books.firstIndex(where: { $0.bookUrl == updated.bookUrl }) else { return }
        var book = books[index]
        if !updated.tocUrl.isEmpty { book.tocUrl = updated.tocUrl }
        if let latest = updated.latestChapterTitle.nilIfEmpty { book.latestChapterTitle = latest }
        if updated.totalChapterNum > 0 {
            book.lastCheckCount = book.totalChapterNum > 0 ? max(0, updated.totalChapterNum - book.totalChapterNum) : 0
            book.totalChapterNum = updated.totalChapterNum
        }
        if updated.latestChapterTime > 0 { book.latestChapterTime = updated.latestChapterTime }
        book.lastCheckTime = Self.now()
        if let cover = updated.coverUrl.nilIfEmpty { book.coverUrl = cover }
        if let intro = updated.intro.nilIfEmpty { book.intro = intro }
        if let kind = updated.kind.nilIfEmpty { book.kind = kind }
        if let wordCount = updated.wordCount.nilIfEmpty { book.wordCount = wordCount }
        if updated.type != 0 { book.type = updated.type }
        book.variableMap.merge(updated.variableMap) { _, new in new }
        books[index] = book
        persist()
    }

    /// `chapterLength` 为当前章正文长度，未加载完时传 nil；换章时清零，避免沿用上一章的长度
    public func saveProgress(bookUrl: String, chapterIndex: Int, chapterPos: Int, chapterTitle: String?,
                             chapterLength: Int? = nil) {
        guard let index = books.firstIndex(where: { $0.bookUrl == bookUrl }) else { return }
        if let chapterLength {
            books[index].durChapterLength = chapterLength
        } else if books[index].durChapterIndex != chapterIndex {
            books[index].durChapterLength = 0
        }
        books[index].durChapterIndex = chapterIndex
        books[index].durChapterPos = chapterPos
        if let chapterTitle { books[index].durChapterTitle = chapterTitle }
        books[index].durChapterTime = Self.now()
        persist()
    }

    public func togglePin(_ bookUrl: String) {
        if pinned.remove(bookUrl) == nil { pinned.insert(bookUrl) }
        persist()
    }

    // MARK: - 分组

    @discardableResult
    public func addGroup(_ name: String) -> BookGroup? {
        let used = groups.reduce(Int64(0)) { $0 | $1.groupId }
        guard let bit = (0..<62).first(where: { used & (Int64(1) << $0) == 0 }) else { return nil }
        let group = BookGroup(groupId: Int64(1) << bit, groupName: name, order: (groups.map(\.order).max() ?? 0) + 1)
        groups.append(group)
        persist()
        return group
    }

    public func renameGroup(_ groupId: Int64, to name: String) {
        guard let index = groups.firstIndex(where: { $0.groupId == groupId }) else { return }
        groups[index].groupName = name
        persist()
    }

    public func deleteGroup(_ groupId: Int64) {
        groups.removeAll { $0.groupId == groupId }
        for index in books.indices {
            books[index].group &= ~groupId
        }
        persist()
    }

    /// 设置书籍分组（位掩码，0 表示未分组）
    public func setGroup(_ mask: Int64, for bookUrls: Set<String>) {
        for index in books.indices where bookUrls.contains(books[index].bookUrl) {
            books[index].group = mask
        }
        persist()
    }

    // MARK: - 书签

    public func bookmarks(for book: Book) -> [Bookmark] {
        bookmarks
            .filter { $0.bookName == book.name && $0.bookAuthor == book.author }
            .sorted { ($0.chapterIndex, $0.chapterPos) < ($1.chapterIndex, $1.chapterPos) }
    }

    public func addBookmark(_ bookmark: Bookmark) {
        bookmarks.append(bookmark)
        persist()
    }

    public func removeBookmark(_ id: Int64) {
        bookmarks.removeAll { $0.time == id }
        persist()
    }

    /// 恢复备份：整体替换书签
    public func restoreBookmarks(_ items: [Bookmark]) {
        var seen = Set<Int64>()
        bookmarks = items.filter { seen.insert($0.time).inserted }
        persist()
    }

    public func flush() {
        store.flush()
    }

    private func persist() {
        let state = ShelfState(books: books, groups: groups, pinned: Array(pinned), bookmarks: bookmarks)
        store.update { $0 = state }
    }
}
