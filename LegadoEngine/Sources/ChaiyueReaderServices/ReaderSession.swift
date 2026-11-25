import Foundation
import Observation
import ChaiyueModels

/// 一本书的阅读会话：目录、当前位置、章节加载与预缓存、进度和书签。
/// 只产出处理后的章节文本，排版（分页或竖向滚动）由界面层用 ReaderKit 完成
@MainActor
@Observable
public final class ReaderSession {
    public enum TocState: Hashable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var book: Book
    public private(set) var chapters: [BookChapter] = []
    public private(set) var tocState: TocState = .idle
    public private(set) var position: ReadingPosition
    public private(set) var chapterStates: [Int: ChapterLoadState] = [:]
    /// 向后预缓存的章数（当前章之后），只下载到磁盘
    public var preloadCount: Int
    /// 内存中保留处理结果的范围：当前章前后各几章
    public var retainRadius = 2
    /// 一章插图同时下载的张数与总等待时间，超时未到的图片按占位显示
    public var imageConcurrency = 4
    public var imageTimeout: Duration = .seconds(30)

    /// 阅读过程中自动加入书架后通知一次（用于书源的加入书架事件）
    @ObservationIgnored public var onAddedToShelf: ((Book) -> Void)?
    /// 未加入书架时把进度写到这里，下次打开接着读
    @ObservationIgnored public var readingRecords: ReadingRecordStore?
    /// 为 false 时只保存阅读记录，不放进书架
    @ObservationIgnored public var autoAddToShelf: () -> Bool = { true }
    @ObservationIgnored private let shelf: BookshelfRepository
    @ObservationIgnored private let service: BookContentService
    @ObservationIgnored private var processor: ContentProcessor
    @ObservationIgnored private var loadTasks: [Int: Task<ChapterLoadState, Never>] = [:]
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// 已加载章节的插图：章节索引 → 图片段落中的原始地址 → 数据
    @ObservationIgnored private var chapterImages: [Int: [String: Data]] = [:]
    @ObservationIgnored private var imageTasks: [Int: Task<Void, Never>] = [:]
    /// 目录或处理规则变化后递增，丢弃过期的加载结果
    @ObservationIgnored private var generation = 0

    public init(book: Book, shelf: BookshelfRepository, service: BookContentService, processor: ContentProcessor,
                preloadCount: Int = 3) {
        let book = shelf.book(book.bookUrl) ?? book
        self.book = book
        self.shelf = shelf
        self.service = service
        self.processor = processor
        self.preloadCount = preloadCount
        position = ReadingPosition(chapterIndex: max(0, book.durChapterIndex), offset: max(0, book.durChapterPos))
    }

    public var isOnShelf: Bool { shelf.contains(book.bookUrl) }

    public var currentChapter: BookChapter? {
        chapters.indices.contains(position.chapterIndex) ? chapters[position.chapterIndex] : nil
    }

    public func text(of index: Int) -> ChapterText? {
        if case .loaded(let text) = chapterStates[index] { return text }
        return nil
    }

    /// 已就绪的插图数据（`src` 为图片段落中的原始地址），只查内存，供排版时同步调用；没有时返回 nil
    public func imageData(for src: String) -> Data? {
        if let data = chapterImages[position.chapterIndex]?[src] { return data }
        return chapterImages.values.lazy.compactMap { $0[src] }.first
    }

    /// 执行正文里的点按脚本（段评气泡、带 click/js 的图片），在书源环境里带上本书与该章
    public func runContentAction(_ script: String, chapter index: Int) async throws {
        try await service.runContentAction(script, book: book, chapter: chapters.indices.contains(index) ? chapters[index] : nil)
    }

    // MARK: - 目录

    /// 打开：加载目录（缓存优先），校正进度，加载当前章与相邻章
    public func open() async {
        await loadToc(refresh: false)
    }

    /// 刷新目录，按章节名找回当前章（目录增删章节后索引会变）
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
                // 目录走缓存时返回的书不带章节数，书架进度按它计算
                var fresh = result.book
                if fresh.totalChapterNum != result.chapters.count { fresh.totalChapterNum = result.chapters.count }
                shelf.mergeMetadata(from: fresh)
                book = shelf.book(book.bookUrl) ?? result.book
            } else {
                book = result.book
            }
            chapters = result.chapters
            var index = position.chapterIndex
            if !chapters.indices.contains(index) || (oldTitle != nil && chapters[index].title != oldTitle) {
                index = ChapterMatcher.index(oldIndex: index, oldTitle: oldTitle, newChapters: chapters, oldCount: oldCount)
            }
            index = min(max(0, index), chapters.count - 1)
            if index != position.chapterIndex {
                let sameChapter = oldTitle != nil && chapters[index].title == oldTitle
                position = ReadingPosition(chapterIndex: index, offset: sameChapter ? position.offset : 0)
            }
            resetLoadedChapters()
            tocState = .ready
            saveProgress()
            // 目录脚本标出听书、漫画、短剧时由界面转交对应的播放页，不再加载正文
            guard book.mediaKind(sourceType: service.source?.bookSourceType) == .text else { return }
            activate()
        } catch {
            tocState = .failed(error.localizedDescription)
        }
    }

    // MARK: - 位置

    /// 翻页或滚动后调用：更新位置并记下进度。开关打开时，不在书架上的书会自动加入；换章时加载相邻章并预缓存
    public func updatePosition(_ newPosition: ReadingPosition) {
        guard chapters.indices.contains(newPosition.chapterIndex) else { return }
        let chapterChanged = newPosition.chapterIndex != position.chapterIndex
        position = ReadingPosition(chapterIndex: newPosition.chapterIndex, offset: max(0, newPosition.offset))
        saveProgress()
        if chapterChanged { activate() }
    }

    public func jump(toChapter index: Int) {
        updatePosition(ReadingPosition(chapterIndex: index))
    }

    @discardableResult
    public func moveToNextChapter() -> Bool {
        guard chapters.indices.contains(position.chapterIndex + 1) else { return false }
        jump(toChapter: position.chapterIndex + 1)
        return true
    }

    /// 回到上一章；`toEnd` 为 true 时定位到章末（往回翻页进入上一章）。
    /// 上一章尚未加载时偏移记为 `Int.max`，排版后换算会落到最后一页
    @discardableResult
    public func moveToPreviousChapter(toEnd: Bool = false) -> Bool {
        let index = position.chapterIndex - 1
        guard chapters.indices.contains(index) else { return false }
        updatePosition(ReadingPosition(chapterIndex: index, offset: toEnd ? (text(of: index)?.length ?? .max) : 0))
        return true
    }

    // MARK: - 章节加载

    /// 确保某章开始加载（界面翻到相邻章时调用）。加载失败的章不会自动重试，需调用 `load(_:refresh:)`
    public func ensureLoaded(_ index: Int) {
        guard chapters.indices.contains(index), chapterStates[index] == nil, loadTasks[index] == nil else { return }
        _ = startLoad(index, refresh: false)
    }

    /// 加载并等待结果；`refresh` 为 true 时忽略缓存重新下载（刷新本章）
    @discardableResult
    public func load(_ index: Int, refresh: Bool = false) async -> ChapterLoadState? {
        guard chapters.indices.contains(index) else { return nil }
        if !refresh {
            if let task = loadTasks[index] { return await task.value }
            if case .loaded = chapterStates[index] { return chapterStates[index] }
        }
        return await startLoad(index, refresh: refresh).value
    }

    /// 刷新全本：删除已缓存的正文（保留目录），重新加载当前章附近
    public func refreshAllContent() {
        for chapter in chapters {
            service.store.removeContent(bookUrl: book.bookUrl, chapter: chapter)
        }
        resetLoadedChapters()
        activate()
    }

    /// 替换规则、简繁转换或本书的净化开关变化后重新处理（正文来自缓存，不会重新下载）
    public func updateProcessor(_ processor: ContentProcessor) {
        self.processor = processor
        resetLoadedChapters()
        activate()
    }

    /// 本书的阅读设置（是否启用替换净化等），保存到书架并重新处理正文
    public func updateReadConfig(_ body: (inout BookReadConfig) -> Void) {
        var config = book.readConfig ?? BookReadConfig()
        body(&config)
        book.readConfig = config
        if isOnShelf, var stored = shelf.book(book.bookUrl) {
            stored.readConfig = config
            shelf.update(stored)
        }
        resetLoadedChapters()
        activate()
    }

    private func activate() {
        let index = position.chapterIndex
        ensureLoaded(index)
        ensureLoaded(index + 1)
        ensureLoaded(index - 1)
        for key in Array(chapterStates.keys) where abs(key - index) > retainRadius {
            loadTasks.removeValue(forKey: key)?.cancel()
            imageTasks.removeValue(forKey: key)?.cancel()
            chapterStates[key] = nil
            chapterImages[key] = nil
        }
        schedulePrefetch(after: index + 1)
    }

    private func resetLoadedChapters() {
        generation += 1
        for task in loadTasks.values { task.cancel() }
        for task in imageTasks.values { task.cancel() }
        loadTasks = [:]
        imageTasks = [:]
        chapterStates = [:]
        chapterImages = [:]
    }

    private struct Fetched: Sendable {
        var state: ChapterLoadState
        /// 本机已有的插图
        var images: [String: Data] = [:]
        /// 需要下载的插图
        var missing: [String] = []
    }

    private func startLoad(_ index: Int, refresh: Bool) -> Task<ChapterLoadState, Never> {
        loadTasks.removeValue(forKey: index)?.cancel()
        imageTasks.removeValue(forKey: index)?.cancel()
        chapterStates[index] = .loading
        let current = generation
        let book = book
        let chapter = chapters[index]
        let next = chapters.indices.contains(index + 1) ? chapters[index + 1] : nil
        let service = service
        let processor = processor
        let task = Task { [weak self] () -> ChapterLoadState in
            let fetched = await Self.fetch(index: index, book: book, chapter: chapter, next: next, refresh: refresh,
                                           service: service, processor: processor)
            guard let self, !Task.isCancelled, generation == current else { return fetched.state }
            chapterImages[index] = fetched.images
            chapterStates[index] = fetched.state
            loadTasks[index] = nil
            if case .loaded(let text) = fetched.state, !fetched.missing.isEmpty {
                loadImages(fetched.missing, for: text, book: book, chapter: chapter)
            }
            return fetched.state
        }
        loadTasks[index] = task
        return task
    }

    nonisolated private static func fetch(index: Int, book: Book, chapter: BookChapter, next: BookChapter?, refresh: Bool,
                                          service: BookContentService, processor: ContentProcessor) async -> Fetched {
        do {
            let raw = try await service.content(for: book, chapter: chapter, nextChapter: next, refresh: refresh)
            let useReplace = book.readConfig?.useReplaceRule ?? true
            let title = processor.displayTitle(chapter.title, book: book, useReplace: useReplace)
            let processed = processor.process(content: raw, chapterTitle: chapter.title, book: book, useReplace: useReplace)
            var fetched = Fetched(state: .loading)
            let text = ChapterText(index: index, title: title, paragraphs: processed.paragraphs, extras: processed.extras,
                                   isVolume: chapter.isVolume)
            for src in text.imageSources {
                if let data = service.cachedImageData(src, book: book, chapter: chapter) {
                    fetched.images[src] = data
                } else {
                    fetched.missing.append(src)
                }
            }
            fetched.state = .loaded(fetched.missing.isEmpty ? text : ChapterText(
                index: index, title: title, paragraphs: text.paragraphs, extras: text.extras, isVolume: chapter.isVolume,
                imagesLoaded: false))
            return fetched
        } catch {
            return Fetched(state: .failed(error.localizedDescription))
        }
    }

    /// 文字已发布后下载本章插图，全部结束（成功、失败或超时）后发布 `imagesLoaded` 为 true 的新文本，界面据此重排
    private func loadImages(_ sources: [String], for text: ChapterText, book: Book, chapter: BookChapter) {
        let index = text.index
        let current = generation
        let service = service
        let concurrency = max(1, imageConcurrency)
        let deadline = ContinuousClock.now + imageTimeout
        imageTasks[index] = Task { [weak self] in
            let loaded = await Self.downloadImages(sources, service: service, book: book, chapter: chapter,
                                                   concurrency: concurrency, deadline: deadline)
            guard let self, !Task.isCancelled, generation == current, chapterStates[index] == .loaded(text) else { return }
            chapterImages[index, default: [:]].merge(loaded) { $1 }
            chapterStates[index] = .loaded(text.withImagesLoaded())
            imageTasks[index] = nil
        }
    }

    nonisolated private static func downloadImages(_ sources: [String], service: BookContentService, book: Book,
                                                   chapter: BookChapter, concurrency: Int,
                                                   deadline: ContinuousClock.Instant) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            // 每张图按剩余时间限时，不等待超时请求真正结束，整体不超过截止时间
            func add(_ src: String) {
                group.addTask {
                    let remaining = deadline - .now
                    guard remaining > .zero else { return (src, nil) }
                    let data = try? await withTimeout(remaining) { try await service.imageData(src, book: book, chapter: chapter) }
                    return (src, data)
                }
            }
            var pending = sources.makeIterator()
            for _ in 0..<concurrency {
                guard let src = pending.next() else { break }
                add(src)
            }
            var results: [String: Data] = [:]
            while let (src, data) = await group.next() {
                if let data, !data.isEmpty { results[src] = data }
                if let next = pending.next() { add(next) }
            }
            return results
        }
    }

    private func schedulePrefetch(after index: Int) {
        prefetchTask?.cancel()
        let count = preloadCount - 1
        guard count > 0 else { return }
        let service = service
        let book = book
        let chapters = chapters
        prefetchTask = Task.detached(priority: .utility) {
            await service.prefetch(book: book, chapters: chapters, from: index + 1, count: count)
        }
    }

    // MARK: - 书架与书签

    /// 加入书架，带上当前进度。`replacing` 为书架上要被覆盖的同一本书（其它来源）
    public func addToShelf(replacing: String? = nil) {
        guard !isOnShelf else { return }
        var book = book
        book.durChapterIndex = position.chapterIndex
        book.durChapterPos = position.offset
        book.durChapterTitle = currentChapter?.title
        book.totalChapterNum = max(book.totalChapterNum, chapters.count)
        if let replacing { shelf.replace(replacing, with: book) } else { shelf.add(book) }
        self.book = shelf.book(book.bookUrl) ?? book
    }

    @discardableResult
    public func addBookmark(at position: ReadingPosition? = nil, note: String = "") -> Bookmark? {
        let position = position ?? self.position
        guard chapters.indices.contains(position.chapterIndex) else { return nil }
        let excerpt = text(of: position.chapterIndex)?.excerpt(from: position.offset) ?? ""
        let bookmark = Bookmark(bookName: book.name, bookAuthor: book.author, chapterIndex: position.chapterIndex,
                                chapterPos: position.offset, chapterName: chapters[position.chapterIndex].title,
                                bookText: excerpt, content: note)
        shelf.addBookmark(bookmark)
        return bookmark
    }

    /// 退出阅读：停止加载与预缓存，并记下读过的进度
    public func close() {
        prefetchTask?.cancel()
        prefetchTask = nil
        remember()
        resetLoadedChapters()
    }

    private func saveProgress() {
        let length = text(of: position.chapterIndex)?.length
        book.durChapterIndex = position.chapterIndex
        book.durChapterPos = position.offset
        book.durChapterTitle = currentChapter?.title ?? book.durChapterTitle
        if let length { book.durChapterLength = length }
        if !isOnShelf {
            // 翻过页或滑过正文才记，只打开就退出的先不记
            if position.chapterIndex > 0 || position.offset > 0 { remember() }
            return
        }
        shelf.saveProgress(bookUrl: book.bookUrl, chapterIndex: position.chapterIndex, chapterPos: position.offset,
                           chapterTitle: currentChapter?.title, chapterLength: length)
    }

    /// 读过但不在书架上的书记下进度。自动加入书架打开、且没有同名同作者的其它来源时，再放进书架
    private func remember() {
        guard !isOnShelf else { return }
        let read = position.chapterIndex > 0 || position.offset > 0 || text(of: position.chapterIndex) != nil
        guard read else { return }
        book.durChapterIndex = position.chapterIndex
        book.durChapterPos = position.offset
        book.durChapterTitle = currentChapter?.title ?? book.durChapterTitle
        book.totalChapterNum = max(book.totalChapterNum, chapters.count)
        readingRecords?.save(book)
        guard autoAddToShelf(), shelf.sameBook(as: book) == nil else { return }
        shelf.add(book)
        book = shelf.book(book.bookUrl) ?? book
        onAddedToShelf?(book)
    }
}
