import Foundation
import ChaiyueModels
import ChaiyueEngine

/// 功能层入口：界面层创建并持有一个实例。
/// `dataDirectory` 存书源、书架、替换规则、目录规则、搜索历史、引擎状态（Cookie、登录信息、设备标识）、本地书文件
/// 与备份同步记录，`cacheDirectory` 存章节正文与图片
@MainActor
public final class LibraryServices {
    public let environment: SourceEnvironment
    public let sources: SourceRepository
    public let shelf: BookshelfRepository
    public let replaceRules: ReplaceRuleRepository
    public let txtTocRules: TxtTocRuleRepository
    public let searchHistory: SearchHistoryStore
    /// 未加入书架时的阅读进度
    public let readingRecords: ReadingRecordStore
    public let chapterStore: ChapterStore
    public let localBooks: LocalBookStore
    public let images: ImageCache
    /// 在线朗读源
    public let httpTTS: HttpTTSRepository
    public let search: SearchModel
    /// 在线朗读的合成与预取
    public private(set) lazy var speech = SpeechAudioLoader(environment: environment)
    public private(set) lazy var shelfUpdater = ShelfUpdater(shelf: shelf) { [unowned self] in contentService(for: $0) }
    /// 全本缓存下载队列
    public private(set) lazy var downloads = CacheDownloadManager(store: chapterStore) { [unowned self] in contentService(for: $0) }
    /// 备份与恢复（本地 zip、WebDAV）。App 层可注册自己的类别，如设置、外观主题
    public private(set) lazy var backup = makeBackupService(directory: dataDirectory.appendingPathComponent("Sync", isDirectory: true))

    /// 简繁转换（阅读设置），对之后创建的阅读会话生效
    public var chineseConversion: ChineseConversion = .none
    /// 阅读时向后预缓存的章数
    public var preloadCount = 3
    /// 读过的书是否自动加入书架。关闭时进度仍写入阅读记录，下次打开从上次位置继续
    public var autoAddToShelf = true
    /// 需要界面处理的书源事件：`searchBook`（跳到搜索）、`open`（打开网页或登录页）。
    /// `refreshExplore` 会先在内部分发给对应书源的发现页，再转给这里
    public var onSourceEvent: ((SourceEvent) -> Void)?

    private let dataDirectory: URL
    private let keyValueStore: FileKeyValueStore
    private var exploreSessions: [String: ExploreSession] = [:]
    private var exploreLists: [String: ExploreBookList] = [:]
    /// 最近打开的换源列表（按书名、作者、分组），重新打开时直接展示已有结果
    private var changeSourceModels: [(key: String, model: ChangeSourceModel)] = []
    private static let changeSourceCacheLimit = 8

    public init(dataDirectory: URL, cacheDirectory: URL, http: HTTPTransport = URLSessionTransport()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.dataDirectory = dataDirectory
        keyValueStore = FileKeyValueStore(fileURL: dataDirectory.appendingPathComponent("engine.json"))
        environment = SourceEnvironment(http: http, store: keyValueStore)
        sources = SourceRepository(fileURL: dataDirectory.appendingPathComponent("sources.json"))
        shelf = BookshelfRepository(fileURL: dataDirectory.appendingPathComponent("bookshelf.json"))
        replaceRules = ReplaceRuleRepository(fileURL: dataDirectory.appendingPathComponent("replaceRules.json"))
        txtTocRules = TxtTocRuleRepository(fileURL: dataDirectory.appendingPathComponent("txtTocRules.json"))
        searchHistory = SearchHistoryStore(fileURL: dataDirectory.appendingPathComponent("searchHistory.json"))
        readingRecords = ReadingRecordStore(fileURL: dataDirectory.appendingPathComponent("readingRecords.json"))
        chapterStore = ChapterStore(root: cacheDirectory.appendingPathComponent("Chapters", isDirectory: true))
        localBooks = LocalBookStore(root: dataDirectory.appendingPathComponent("LocalBooks", isDirectory: true))
        images = ImageCache(directory: cacheDirectory.appendingPathComponent("Images", isDirectory: true), environment: environment)
        httpTTS = HttpTTSRepository(fileURL: dataDirectory.appendingPathComponent("httpTTS.json"))
        search = SearchModel(environment: environment)
        environment.setEventHandler { [weak self] event in
            Task { @MainActor in self?.dispatch(event) }
        }
        environment.setLoginChangeHandler { [weak self] key in
            Task { @MainActor in self?.loginDidChange(key) }
        }
    }

    /// 进入后台或退出前调用，立即写盘
    public func flush() {
        sources.flush()
        shelf.flush()
        replaceRules.flush()
        txtTocRules.flush()
        searchHistory.flush()
        readingRecords.flush()
        httpTTS.flush()
        keyValueStore.flush()
    }

    // MARK: - 在线朗读

    /// 朗读源的合成与登录接口（不经过缓存）
    public func ttsEngine(for tts: HttpTTS) -> HttpTTSEngine {
        HttpTTSEngine(tts: tts, environment: environment, retryCount: speech.retryCount)
    }

    /// 合成一句，经过 `speech` 的缓存与预取
    public func synthesize(engine tts: HttpTTS, text: String, rate speed: Int = HttpTTS.defaultSpeakSpeed) async throws -> TTSAudio {
        try await speech.audio(tts, text: text, speed: speed)
    }

    /// 从 JSON 文本、网址或一键导入链接导入朗读源；内容不是朗读源时抛出 `ImportError.unsupported`
    @discardableResult
    public func importHttpTTS(text: String) async throws -> ImportSummary {
        let payload = try await ImportService.classify(text: text)
        guard case .httpTTS(let items) = payload else { throw ImportError.unsupported(payload.kindName + "（这里只能导入朗读源）") }
        return httpTTS.importEngines(items)
    }

    // MARK: - 书籍

    public func source(for book: Book) -> BookSource? {
        sources.source(for: book.origin)
    }

    public func webBook(for source: BookSource) -> WebBook {
        WebBook(source: source, environment: environment)
    }

    /// 通知书籍所属书源发生了事件（书源开启 eventListener 时执行 callBackJs）。后台执行，不等待结果；本地书不触发
    public func callBack(_ event: SourceCallBackEvent, book: Book, chapter: BookChapter? = nil) {
        guard !book.isLocal, let source = source(for: book), source.eventListener else { return }
        let webBook = webBook(for: source)
        Task { await webBook.callBack(event: event, book: book, chapter: chapter) }
    }

    public func contentService(for book: Book) -> BookContentService {
        BookContentService(source: book.isLocal ? nil : source(for: book), environment: environment, store: chapterStore,
                           localBooks: localBooks, images: images)
    }

    /// 正文处理器：全部已启用的替换规则（是否对本书生效由书的阅读设置决定）+ 简繁转换
    public func processor() -> ContentProcessor {
        ContentProcessor(rules: replaceRules.enabledRules, conversion: chineseConversion)
    }

    /// 详情页：联网获取书籍详情；书在书架中时同时更新书架信息
    public func loadBookInfo(_ book: Book) async throws -> Book {
        let info = try await contentService(for: book).bookInfo(book)
        if shelf.contains(info.bookUrl) {
            shelf.mergeMetadata(from: info)
        }
        return info
    }

    public func readerSession(for book: Book) -> ReaderSession {
        let session = ReaderSession(book: bookForReading(book), shelf: shelf, service: contentService(for: book), processor: processor(),
                                    preloadCount: preloadCount)
        session.readingRecords = readingRecords
        session.autoAddToShelf = { [weak self] in self?.autoAddToShelf ?? true }
        session.onAddedToShelf = { [weak self] book in self?.callBack(.addBookShelf, book: book) }
        return session
    }

    public func mediaSession(for book: Book) -> MediaSession {
        let session = MediaSession(book: bookForReading(book), shelf: shelf, service: contentService(for: book), processor: processor())
        session.readingRecords = readingRecords
        session.autoAddToShelf = { [weak self] in self?.autoAddToShelf ?? true }
        session.onAddedToShelf = { [weak self] book in self?.callBack(.addBookShelf, book: book) }
        return session
    }

    /// 书架上的书用书架进度；否则用阅读记录里的章节位置
    private func bookForReading(_ book: Book) -> Book {
        if let stored = shelf.book(book.bookUrl) { return stored }
        return readingRecords.restored(book)
    }

    /// 书籍封面或正文插图，使用书籍所属书源的请求头与解密脚本；本地书的封面与插图从书籍文件读取
    public func imageData(_ url: String, for book: Book? = nil) async throws -> Data {
        if LocalBookStore.handles(url) {
            let store = localBooks
            return try await Task.detached(priority: .userInitiated) { try store.resourceData(url) }.value
        }
        return try await images.data(for: url, source: book.flatMap(source(for:)))
    }

    /// 从书架删除，同时清除章节缓存与缓存任务；本地书连同书籍文件一起删除
    public func removeBooks(_ bookUrls: Set<String>) {
        var removed: [Book] = []
        for bookUrl in bookUrls {
            downloads.remove(bookUrl)
            if let book = shelf.book(bookUrl) {
                if book.isLocal { localBooks.remove(book) } else { removed.append(book) }
            }
            chapterStore.clear(bookUrl: bookUrl)
        }
        shelf.remove(bookUrls)
        for book in removed { callBack(.delBookShelf, book: book) }
    }

    // MARK: - 本地书

    /// 导入 TXT 或 EPUB 并加入书架。`name`、`author` 为空时从文件名或 EPUB 元数据解析
    @discardableResult
    public func importLocalBook(at url: URL, name: String? = nil, author: String? = nil,
                                tocMode: TxtTocMode = .auto) async throws -> Book {
        let store = localBooks
        let rules = txtTocRules.enabledRules
        let result = try await Task.detached(priority: .userInitiated) {
            try store.importBook(from: url, name: name, author: author, tocMode: tocMode, rules: rules)
        }.value
        shelf.add(result.book)
        return shelf.book(result.book.bookUrl) ?? result.book
    }

    /// TXT 重新分章（换目录规则、按长度分章或换编码），按章节名找回阅读进度
    @discardableResult
    public func resplitLocalBook(_ book: Book, tocMode: TxtTocMode, charset: String? = nil) async throws -> Book {
        let current = shelf.book(book.bookUrl) ?? book
        let store = localBooks
        let rules = txtTocRules.enabledRules
        let oldChapters = (try? store.chapters(for: current)) ?? []
        let result = try await Task.detached(priority: .userInitiated) {
            try store.resplit(current, tocMode: tocMode, charset: charset, rules: rules)
        }.value
        var updated = result.book
        let oldIndex = current.durChapterIndex
        let oldTitle = oldChapters.indices.contains(oldIndex) ? oldChapters[oldIndex].title : current.durChapterTitle
        let index = min(max(0, ChapterMatcher.index(oldIndex: oldIndex, oldTitle: oldTitle, newChapters: result.chapters,
                                                     oldCount: oldChapters.count)), result.chapters.count - 1)
        updated.durChapterIndex = index
        updated.durChapterPos = result.chapters[index].title == oldTitle ? current.durChapterPos : 0
        updated.durChapterTitle = result.chapters[index].title
        chapterStore.clear(bookUrl: book.bookUrl)
        if shelf.contains(book.bookUrl) {
            shelf.update(updated)
        }
        return updated
    }

    /// 检查书架更新（默认全部书籍）
    @discardableResult
    public func refreshShelf(_ books: [Book]? = nil) async -> ShelfRefreshReport {
        await shelfUpdater.refresh(books ?? shelf.books)
    }

    // MARK: - 搜索与发现

    /// 用全部启用的书源（或指定分组）搜索，并记入搜索历史
    public func startSearch(_ keyword: String, group: String? = nil) {
        searchHistory.record(keyword)
        search.search(keyword, sources: enabledSources(group: group))
    }

    private func enabledSources(group: String?) -> [BookSource] {
        sources.enabledSources.filter { source in
            guard let group, !group.isEmpty else { return true }
            return (source.bookSourceGroup ?? "").split(whereSeparator: { ",;，；".contains($0) })
                .contains { $0.trimmingCharacters(in: .whitespaces) == group }
        }
    }

    // MARK: - 换源

    /// 换源列表。同一本书再次打开时复用已有结果；搜索页刚搜过这本书时直接带入那次的结果
    public func changeSourceModel(for book: Book, group: String? = nil) -> ChangeSourceModel {
        let key = [book.name, book.author, group ?? ""].joined(separator: "\u{1}")
        if let index = changeSourceModels.firstIndex(where: { $0.key == key }) {
            let entry = changeSourceModels.remove(at: index)
            changeSourceModels.append(entry)
            entry.model.setCurrent(book)
            return entry.model
        }
        let model = ChangeSourceModel(book: book, sources: enabledSources(group: group), environment: environment)
        if group.nilIfEmpty == nil,
           search.keyword == book.name.trimmingCharacters(in: .whitespacesAndNewlines), !search.results.isEmpty {
            model.seed(search.results.flatMap(\.items), complete: !search.isSearching && search.total == model.sourceCount)
        }
        changeSourceModels.append((key, model))
        if changeSourceModels.count > Self.changeSourceCacheLimit {
            changeSourceModels.removeFirst().model.cancel()
        }
        return model
    }

    /// 换成另一个书源的同一本书：获取新书源的详情与目录，按章节名找回进度，保留分组、置顶、自定义封面与简介、阅读设置。
    /// 书在书架中时替换书架记录，旧来源的章节缓存一并清除。阅读中换源时用返回的新书重新创建 `ReaderSession`
    @discardableResult
    public func changeSource(of oldBook: Book, to candidate: SearchBook) async throws -> (book: Book, chapters: [BookChapter]) {
        guard !oldBook.isLocal else { throw BookServiceError.localBookCannotChangeSource }
        guard let source = sources.source(for: candidate.origin) else {
            throw BookServiceError.sourceMissing(candidate.originName.isEmpty ? candidate.origin : candidate.originName)
        }
        let oldChapters = chapterStore.loadChapters(bookUrl: oldBook.bookUrl) ?? []
        let service = BookContentService(source: source, environment: environment, store: chapterStore)
        let (fetched, chapters) = try await service.chapters(for: candidate.toBook(), refresh: true)
        let current = shelf.book(oldBook.bookUrl) ?? oldBook
        var newBook = Self.migrate(current, to: fetched, chapters: chapters, oldChapters: oldChapters)
        downloads.remove(oldBook.bookUrl)
        if newBook.bookUrl == oldBook.bookUrl {
            chapterStore.clear(bookUrl: newBook.bookUrl)
            chapterStore.saveChapters(chapters, bookUrl: newBook.bookUrl)
        } else {
            chapterStore.clear(bookUrl: oldBook.bookUrl)
        }
        if shelf.contains(oldBook.bookUrl) {
            shelf.replace(oldBook.bookUrl, with: newBook)
            newBook = shelf.book(newBook.bookUrl) ?? newBook
        }
        for entry in changeSourceModels where entry.model.book.bookUrl == oldBook.bookUrl {
            entry.model.setCurrent(newBook)
        }
        return (newBook, chapters)
    }

    /// 把旧书的阅读进度与用户设置迁移到新来源的书（Legado Book.migrateTo）
    static func migrate(_ old: Book, to new: Book, chapters: [BookChapter], oldChapters: [BookChapter]) -> Book {
        var book = new
        if !chapters.isEmpty {
            let oldTitle = old.durChapterTitle.nilIfEmpty
                ?? (oldChapters.indices.contains(old.durChapterIndex) ? oldChapters[old.durChapterIndex].title : nil)
            let index = ChapterMatcher.index(oldIndex: old.durChapterIndex, oldTitle: oldTitle, newChapters: chapters,
                                             oldCount: old.totalChapterNum)
            book.durChapterIndex = min(max(0, index), chapters.count - 1)
            book.durChapterTitle = chapters[book.durChapterIndex].title
            book.totalChapterNum = chapters.count
            book.latestChapterTitle = chapters.last?.title ?? book.latestChapterTitle
        }
        book.durChapterPos = old.durChapterPos
        book.durChapterTime = old.durChapterTime
        book.group = old.group
        book.order = old.order
        book.customCoverUrl = old.customCoverUrl
        book.customIntro = old.customIntro
        book.customTag = old.customTag
        book.canUpdate = old.canUpdate
        book.readConfig = old.readConfig
        book.lastCheckCount = 0
        return book
    }

    /// 同一书源共用一个发现页会话。离开页面后再进来沿用已加载的分类，不重新请求；
    /// 书源脚本调用 `java.refreshExplore()` 或登录状态变化时才重新加载
    public func exploreSession(for source: BookSource) -> ExploreSession {
        if let session = exploreSessions[source.bookSourceUrl], session.source == source {
            return session
        }
        let session = ExploreSession(source: source, environment: environment)
        exploreSessions[source.bookSourceUrl] = session
        return session
    }

    /// 同一分类的书单也保留。已经加载过的页直接复用，避免每次进入发现页都从第一页重新请求
    public func exploreList(source: BookSource, url: String) -> ExploreBookList {
        let key = source.bookSourceUrl + "\u{1}" + url
        if let list = exploreLists[key] { return list }
        let list = ExploreBookList(source: source, url: url, environment: environment)
        exploreLists[key] = list
        return list
    }

    // MARK: - 导入

    /// 写入已识别的导入内容，返回合并统计
    @discardableResult
    public func apply(_ payload: ImportPayload) -> ImportSummary? {
        switch payload {
        case .bookSources(let items): sources.importSources(items)
        case .replaceRules(let items): replaceRules.importRules(items)
        case .httpTTS(let items): httpTTS.importEngines(items)
        }
    }

    // MARK: - 书源事件

    private func dispatch(_ event: SourceEvent) {
        if case .refreshExplore(let key) = event, let session = exploreSessions[key] {
            dropExploreLists(for: key)
            Task { await session.reload() }
        }
        onSourceEvent?(event)
    }

    /// 任一入口登录或退出后：丢掉按旧登录态缓存的书单，已打开的发现页重新生成分类，再通知界面
    private func loginDidChange(_ key: String) {
        dropExploreLists(for: key)
        if let session = exploreSessions[key] {
            Task { await session.reload() }
        }
        NotificationCenter.default.post(name: .sourceLoginChanged, object: key)
    }

    private func dropExploreLists(for sourceUrl: String) {
        let prefix = sourceUrl + "\u{1}"
        exploreLists = exploreLists.filter { !$0.key.hasPrefix(prefix) }
    }
}

public extension Notification.Name {
    /// 书源登录状态变化，`object` 为书源地址（`bookSourceUrl`）
    static let sourceLoginChanged = Notification.Name("chaiyue.sourceLoginChanged")
}

