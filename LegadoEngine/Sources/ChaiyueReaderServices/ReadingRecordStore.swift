import Foundation
import Observation
import ChaiyueModels

/// 不在书架上的阅读进度。再次打开同一本书时从这里恢复章节位置
@MainActor
@Observable
public final class ReadingRecordStore {
    public private(set) var books: [Book]
    public var limit = 100
    @ObservationIgnored private let store: JSONFileStore<[Book]>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { [] }
        books = store.current
    }

    public func book(_ bookUrl: String) -> Book? {
        books.first { $0.bookUrl == bookUrl }
    }

    /// 记下当前进度，最近读的排在前面
    public func save(_ book: Book) {
        var book = book
        book.infoHtml = nil
        book.tocHtml = nil
        if book.durChapterTime == 0 { book.durChapterTime = BookshelfRepository.now() }
        books.removeAll { $0.bookUrl == book.bookUrl }
        books.insert(book, at: 0)
        if books.count > limit { books.removeLast(books.count - limit) }
        persist()
    }

    /// 用已保存的进度覆盖传入书籍的章节位置，书名、封面等仍用传入的这份
    public func restored(_ book: Book) -> Book {
        guard let saved = self.book(book.bookUrl) else { return book }
        var book = book
        book.durChapterIndex = saved.durChapterIndex
        book.durChapterPos = saved.durChapterPos
        book.durChapterTitle = saved.durChapterTitle ?? book.durChapterTitle
        book.durChapterLength = saved.durChapterLength
        book.durChapterTime = saved.durChapterTime
        if saved.totalChapterNum > book.totalChapterNum { book.totalChapterNum = saved.totalChapterNum }
        return book
    }

    public func flush() {
        store.flush()
    }

    private func persist() {
        let books = books
        store.update { $0 = books }
    }
}
