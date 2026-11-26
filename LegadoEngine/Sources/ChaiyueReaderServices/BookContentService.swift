import Foundation
import ChaiyueModels
import ChaiyueEngine

public enum BookServiceError: LocalizedError, Sendable, Equatable {
    case sourceMissing(String)
    case emptyToc
    case localBooksUnavailable
    case localBookCannotChangeSource

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let name): "找不到书源「\(name)」，请换源或重新导入书源"
        case .emptyToc: "目录为空"
        case .localBooksUnavailable: "无法读取本地书籍"
        case .localBookCannotChangeSource: "本地书不支持换源"
        }
    }
}

/// 单本书的目录与正文获取：缓存优先，缺失时联网获取并写入缓存。
/// 本地书从书籍文件读取：TXT 直接按偏移读，EPUB 按章解析后写入章节缓存
public final class BookContentService: Sendable {
    public let source: BookSource?
    public let environment: SourceEnvironment
    public let store: ChapterStore
    public let localBooks: LocalBookStore?
    public let images: ImageCache?

    public init(source: BookSource?, environment: SourceEnvironment, store: ChapterStore, localBooks: LocalBookStore? = nil,
                images: ImageCache? = nil) {
        self.source = source
        self.environment = environment
        self.store = store
        self.localBooks = localBooks
        self.images = images
    }

    private func localStore() throws -> LocalBookStore {
        guard let localBooks else { throw BookServiceError.localBooksUnavailable }
        return localBooks
    }

    private func webBook(for book: Book) throws -> WebBook {
        guard let source else { throw BookServiceError.sourceMissing(book.originName.isEmpty ? book.origin : book.originName) }
        return WebBook(source: source, environment: environment)
    }

    /// 刷新详情（封面、简介、最新章节、目录地址）
    public func bookInfo(_ book: Book) async throws -> Book {
        try await webBook(for: book).getBookInfo(book)
    }

    /// 目录。`refresh` 为 false 时优先使用缓存；返回的书籍带有更新后的统计字段
    public func chapters(for book: Book, refresh: Bool = false) async throws -> (book: Book, chapters: [BookChapter]) {
        if book.isLocal {
            let chapters = try localStore().chapters(for: book)
            guard !chapters.isEmpty else { throw BookServiceError.emptyToc }
            return (book, chapters)
        }
        if !refresh, let cached = store.loadChapters(bookUrl: book.bookUrl), !cached.isEmpty {
            var book = book
            if let type = store.bookType(bookUrl: book.bookUrl) { book.type = type }
            return (book, cached)
        }
        let web = try webBook(for: book)
        var book = book
        if book.tocUrl.isEmpty {
            book = try await web.getBookInfo(book)
        }
        let result = try await web.getChapterList(book)
        guard !result.chapters.isEmpty else { throw BookServiceError.emptyToc }
        // 已取消的请求（如书已删除）不再写缓存
        if !Task.isCancelled {
            store.saveChapters(result.chapters, bookUrl: book.bookUrl)
            store.saveBookType(result.book.type, bookUrl: book.bookUrl)
        }
        return result
    }

    /// 听书与短剧的直链多带签名、会过期，正文不走缓存
    private func cachesContent(_ book: Book) -> Bool {
        let kind = book.mediaKind(sourceType: source?.bookSourceType)
        return kind != .audio && kind != .video
    }

    /// 音频、视频直链交给系统播放器：解析地址选项并带上书源请求头与 Cookie
    public func playbackRequest(_ link: String, book: Book, chapter: BookChapter) async throws -> (url: String, headers: [String: String]) {
        let base = URLUtils.absoluteURL(base: book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl, relative: chapter.url)
        return try await webBook(for: book).playbackRequest(link, baseUrl: base)
    }

    /// 原始正文（未经替换净化），缓存优先
    public func content(for book: Book, chapter: BookChapter, nextChapter: BookChapter?, refresh: Bool = false) async throws -> String {
        if book.isLocal {
            let local = try localStore()
            guard local.isEpub(book) else { return try local.content(for: book, chapter: chapter) }
            if !refresh, let cached = store.content(bookUrl: book.bookUrl, chapter: chapter) {
                return cached
            }
            let content = try local.content(for: book, chapter: chapter)
            if !content.isEmpty, !Task.isCancelled {
                store.saveContent(content, bookUrl: book.bookUrl, chapter: chapter)
            }
            return content
        }
        let caches = cachesContent(book)
        if !refresh, caches, let cached = store.content(bookUrl: book.bookUrl, chapter: chapter) {
            return cached
        }
        if chapter.isVolume, chapter.url.isEmpty || chapter.url.hasPrefix(chapter.title) {
            return ""
        }
        let (content, _) = try await webBook(for: book).getContent(book, chapter: chapter, nextChapterUrl: nextChapter?.url)
        if caches, !content.isEmpty, !Task.isCancelled {
            store.saveContent(content, bookUrl: book.bookUrl, chapter: chapter)
        }
        return content
    }

    // MARK: - 正文插图

    /// 插图的完整地址：相对地址按章节地址补全，本地书资源地址原样保留；
    /// `,{选项}` 里只给界面用的 style、click、js 去掉，其余（请求头等）保留
    func imageURL(_ src: String, book: Book, chapter: BookChapter) -> String {
        if book.isLocal || LocalBookStore.handles(src) { return src }
        let request = InlineImageSource(src).requestURL
        let base = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        return URLUtils.absoluteURL(base: URLUtils.absoluteURL(base: base, relative: chapter.url), relative: request)
    }

    /// 正文里的点按脚本，见 `WebBook.runContentAction`
    public func runContentAction(_ script: String, book: Book, chapter: BookChapter?) async throws {
        try await webBook(for: book).runContentAction(script, book: book, chapter: chapter)
    }

    /// 只读本机已有的插图（磁盘缓存、本地书文件），不联网
    public func cachedImageData(_ src: String, book: Book, chapter: BookChapter) -> Data? {
        let url = imageURL(src, book: book, chapter: chapter)
        if LocalBookStore.handles(url) { return try? localBooks?.resourceData(url) }
        return images?.cachedData(for: url, source: source, isContent: true)
    }

    /// 插图数据：网络书用书源的请求头、Cookie 与 imageDecode 下载并缓存，本地书从书籍文件读取
    public func imageData(_ src: String, book: Book, chapter: BookChapter) async throws -> Data {
        let url = imageURL(src, book: book, chapter: chapter)
        if LocalBookStore.handles(url) {
            let local = try localStore()
            return try await offload { try local.resourceData(url) }
        }
        guard let images else { throw URLError(.resourceUnavailable) }
        return try await images.data(for: url, source: source, isContent: true)
    }

    /// 后台预缓存后续章节（已缓存的跳过），出错不影响阅读
    public func prefetch(book: Book, chapters: [BookChapter], from index: Int, count: Int) async {
        let canPrefetch = book.isLocal ? localBooks?.isEpub(book) == true : source != nil
        guard count > 0, canPrefetch, cachesContent(book) else { return }
        let end = min(chapters.count, index + count)
        guard index < end else { return }
        for i in index..<end {
            if Task.isCancelled { return }
            let chapter = chapters[i]
            if chapter.isVolume || store.hasContent(bookUrl: book.bookUrl, chapter: chapter) { continue }
            let next = i + 1 < chapters.count ? chapters[i + 1] : nil
            _ = try? await content(for: book, chapter: chapter, nextChapter: next)
        }
    }
}
