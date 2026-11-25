import Foundation
import Observation
import ChaiyueModels

/// 交给系统播放器的直链。本地有声书按章节标记分章时，只播文件中 `start`..`end` 秒这一段（`end` 为空时播到文件结束）
public struct MediaPlayback: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public var start: Double = 0
    public var end: Double?
}

/// 关联值为正文里书源给出的说明（如登录或次数提示），没有时为空
public enum MediaError: LocalizedError, Sendable, Equatable {
    case noLink(String)
    case noImages(String)

    public var errorDescription: String? {
        switch self {
        case .noLink(let message): message.isEmpty ? "本章没有可播放的地址" : message
        case .noImages(let message): message.isEmpty ? "本章没有图片" : message
        }
    }

    static func note(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

/// 听书、漫画、短剧的会话：目录、当前章与章内位置、正文取链、进度保存。
/// 章内位置的计量由界面决定：听书与短剧为毫秒，漫画为图片序号；`length` 同一计量，书架据此算章内进度
@MainActor
@Observable
public final class MediaSession {
    public private(set) var book: Book
    public private(set) var chapters: [BookChapter] = []
    public private(set) var tocState: ReaderSession.TocState = .idle
    public private(set) var index: Int
    public private(set) var position: Int

    /// 播放过程中自动加入书架后通知一次
    @ObservationIgnored public var onAddedToShelf: ((Book) -> Void)?
    /// 未加入书架时把进度写到这里，下次打开接着看
    @ObservationIgnored public var readingRecords: ReadingRecordStore?
    /// 为 false 时只保存阅读记录，不放进书架
    @ObservationIgnored public var autoAddToShelf: () -> Bool = { true }
    @ObservationIgnored public let service: BookContentService
    @ObservationIgnored private let shelf: BookshelfRepository
    @ObservationIgnored private let processor: ContentProcessor

    public init(book: Book, shelf: BookshelfRepository, service: BookContentService, processor: ContentProcessor) {
        let book = shelf.book(book.bookUrl) ?? book
        self.book = book
        self.shelf = shelf
        self.service = service
        self.processor = processor
        index = max(0, book.durChapterIndex)
        position = max(0, book.durChapterPos)
    }

    public var kind: BookMediaKind { book.mediaKind(sourceType: service.source?.bookSourceType) }
    public var isOnShelf: Bool { shelf.contains(book.bookUrl) }

    public var currentChapter: BookChapter? {
        chapters.indices.contains(index) ? chapters[index] : nil
    }

    // MARK: - 目录

    public func open() async {
        await loadToc(refresh: false)
    }

    public func refreshToc() async {
        await loadToc(refresh: true)
    }

    private func loadToc(refresh: Bool) async {
        tocState = .loading
        let oldTitle = currentChapter?.title ?? book.durChapterTitle
        let oldCount = chapters.isEmpty ? book.totalChapterNum : chapters.count
        do {
            let result = try await service.chapters(for: book, refresh: refresh)
            if isOnShelf {
                var fresh = result.book
                if fresh.totalChapterNum != result.chapters.count { fresh.totalChapterNum = result.chapters.count }
                shelf.mergeMetadata(from: fresh)
                book = shelf.book(book.bookUrl) ?? result.book
            } else {
                book = result.book
            }
            chapters = result.chapters
            var target = index
            if !chapters.indices.contains(target) || (oldTitle != nil && chapters[target].title != oldTitle) {
                target = ChapterMatcher.index(oldIndex: target, oldTitle: oldTitle, newChapters: chapters, oldCount: oldCount)
            }
            target = min(max(0, target), chapters.count - 1)
            if target != index {
                let same = oldTitle != nil && chapters[target].title == oldTitle
                index = target
                if !same { position = 0 }
            }
            tocState = .ready
            save(length: nil)
            remember()
        } catch {
            tocState = .failed(error.localizedDescription)
        }
    }

    // MARK: - 正文

    /// 原始正文；听书与短剧不缓存，每次联网取最新直链
    public func content(at index: Int, refresh: Bool = false) async throws -> String {
        guard chapters.indices.contains(index) else { throw MediaError.noLink("") }
        let next = chapters.indices.contains(index + 1) ? chapters[index + 1] : nil
        return try await service.content(for: book, chapter: chapters[index], nextChapter: next, refresh: refresh)
    }

    /// 听书、短剧：本章直链与请求头
    public func playback(at index: Int) async throws -> MediaPlayback {
        if book.isLocal, let local = service.localBooks {
            guard chapters.indices.contains(index) else { throw MediaError.noLink("") }
            return try local.mediaPlayback(for: book, chapter: chapters[index])
        }
        let raw = try await content(at: index)
        guard let link = MediaContent.link(in: raw) else { throw MediaError.noLink(MediaError.note(raw)) }
        let request = try await service.playbackRequest(link, book: book, chapter: chapters[index])
        guard let url = URL(string: request.url) ?? URL(string: request.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
            throw MediaError.noLink("")
        }
        return MediaPlayback(url: url, headers: request.headers)
    }

    /// 漫画：本章图片地址（原样，按出现顺序去重）
    public func images(at index: Int, refresh: Bool = false) async throws -> [String] {
        if book.isLocal, let local = service.localBooks {
            guard chapters.indices.contains(index) else { throw MediaError.noImages("") }
            let book = book, chapter = chapters[index]
            return try await offload { try local.mediaImages(for: book, chapter: chapter) }
        }
        let raw = try await content(at: index, refresh: refresh)
        let paragraphs = processor.paragraphs(content: raw, chapterTitle: chapters[index].title, book: book, useReplace: false)
        let sources = ChapterText(index: index, title: chapters[index].title, paragraphs: paragraphs).imageSources
        guard !sources.isEmpty else { throw MediaError.noImages(MediaError.note(raw)) }
        return sources
    }

    public func imageData(_ src: String, chapter index: Int) async throws -> Data {
        guard chapters.indices.contains(index) else { throw MediaError.noImages("") }
        return try await service.imageData(src, book: book, chapter: chapters[index])
    }

    public func cachedImageData(_ src: String, chapter index: Int) -> Data? {
        guard chapters.indices.contains(index) else { return nil }
        return service.cachedImageData(src, book: book, chapter: chapters[index])
    }

    // MARK: - 进度

    /// 换章或章内位置变化后调用；`length` 为本章总长（毫秒或图片数），未知时传 nil
    public func update(index newIndex: Int, position newPosition: Int, length: Int? = nil) {
        guard chapters.indices.contains(newIndex) else { return }
        index = newIndex
        position = max(0, newPosition)
        save(length: length)
    }

    /// `replacing` 为书架上要被覆盖的同一本书（其它来源）
    public func addToShelf(replacing: String? = nil) {
        guard !isOnShelf else { return }
        var book = book
        book.durChapterIndex = index
        book.durChapterPos = position
        book.durChapterTitle = currentChapter?.title
        book.totalChapterNum = max(book.totalChapterNum, chapters.count)
        if let replacing { shelf.replace(replacing, with: book) } else { shelf.add(book) }
        self.book = shelf.book(book.bookUrl) ?? book
    }

    private func save(length: Int?) {
        book.durChapterIndex = index
        book.durChapterPos = position
        book.durChapterTitle = currentChapter?.title ?? book.durChapterTitle
        if let length { book.durChapterLength = length }
        if !isOnShelf {
            if index > 0 || position > 0 { remember() }
            return
        }
        shelf.saveProgress(bookUrl: book.bookUrl, chapterIndex: index, chapterPos: position,
                           chapterTitle: currentChapter?.title, chapterLength: length)
    }

    /// 听过、看过但不在书架上的书记下进度。自动加入书架打开、且没有同名同作者的其它来源时，再放进书架
    private func remember() {
        guard !isOnShelf else { return }
        guard index > 0 || position > 0 || tocState == .ready else { return }
        book.durChapterIndex = index
        book.durChapterPos = position
        book.durChapterTitle = currentChapter?.title ?? book.durChapterTitle
        book.totalChapterNum = max(book.totalChapterNum, chapters.count)
        readingRecords?.save(book)
        guard autoAddToShelf(), shelf.sameBook(as: book) == nil else { return }
        shelf.add(book)
        book = shelf.book(book.bookUrl) ?? book
        onAddedToShelf?(book)
    }
}

/// 媒体正文解析
public enum MediaContent {
    /// 正文中的直链：整段就是地址（可带 Legado 的 `,{选项}`）时原样返回，否则取第一个 http(s) 地址
    public static func link(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^https?://\S+(,\s*\{[\s\S]*\})?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return text
        }
        if let src = InlineImage.source(of: text), src.lowercased().hasPrefix("http") { return src }
        guard let range = text.range(of: #"https?://[^\s"'<>]+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(text[range])
    }
}
