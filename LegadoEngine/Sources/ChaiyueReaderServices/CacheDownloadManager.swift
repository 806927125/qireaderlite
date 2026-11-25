import Foundation
import Observation
import ChaiyueModels

public enum CacheTaskState: Hashable, Sendable {
    /// 排队中（含获取目录）
    case waiting
    case downloading
    case paused
    /// 已处理完，失败的章节数见 `failedCount`
    case finished
    /// 目录获取失败或书源缺失
    case failed(String)
}

/// 一本书的缓存任务。章节数都不含卷标题
public struct CacheTask: Identifiable, Hashable, Sendable {
    public let bookUrl: String
    public var bookName: String
    public var state: CacheTaskState = .waiting
    /// 要缓存的章节数，目录获取前为 0
    public var chapterCount = 0
    /// 已缓存的章节数（含任务开始前已有的）
    public var cachedCount = 0
    /// 重试后仍失败的章节数
    public var failedCount = 0

    public var id: String { bookUrl }

    public var fractionCompleted: Double {
        chapterCount == 0 ? (state == .finished ? 1 : 0) : Double(cachedCount) / Double(chapterCount)
    }
}

/// 全本缓存下载：多本书按加入顺序排队，全局限制同时进行的请求数（获取目录也占一个名额），按队列顺序分配给各本书。
/// 已缓存的章节跳过，单章失败自动重试 `maxRetries` 次。暂停只停止派发新章节，进行中的请求会完成并计入进度
@MainActor
@Observable
public final class CacheDownloadManager {
    public private(set) var tasks: [CacheTask] = []
    public var concurrency = 4 {
        didSet { pump() }
    }
    public static let maxRetries = 2

    @ObservationIgnored private let store: ChapterStore
    @ObservationIgnored private let makeService: (Book) -> BookContentService
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var nextGeneration = 0

    private final class Job {
        let generation: Int
        let book: Book
        let service: BookContentService
        /// 请求缓存的章节序号，nil 为全本
        var requested: Set<Int>?
        var chapters: [BookChapter]?
        var loading = false
        /// 已计入任务的章节序号
        var included: Set<Int> = []
        var pending: [Int] = []
        var running: Set<Int> = []
        var attempts: [Int: Int] = [:]
        var failed: [Int: String] = [:]
        /// 进行中的请求，键为章节序号，获取目录为 -1
        var workers: [Int: Task<Void, Never>] = [:]

        init(generation: Int, book: Book, service: BookContentService, requested: Set<Int>?) {
            self.generation = generation
            self.book = book
            self.service = service
            self.requested = requested
        }
    }

    public init(store: ChapterStore, makeService: @escaping (Book) -> BookContentService) {
        self.store = store
        self.makeService = makeService
    }

    public var isActive: Bool {
        tasks.contains { $0.state == .waiting || $0.state == .downloading }
    }

    /// 进行中的请求数（含已移除任务尚未结束的请求）
    var runningRequests: Int { inFlight }

    public func task(for bookUrl: String) -> CacheTask? {
        tasks.first { $0.bookUrl == bookUrl }
    }

    // MARK: - 队列操作

    /// 缓存指定范围的章节（nil 为全本）。同一本书再次加入时合并范围并继续；本地 TXT 无需缓存，返回 false
    @discardableResult
    public func enqueue(_ book: Book, range: Range<Int>? = nil) -> Bool {
        if let job = jobs[book.bookUrl] {
            let indexes = range.map(Set.init)
            job.requested = job.requested.flatMap { current in indexes.map { current.union($0) } }
            if let chapters = job.chapters {
                include(indexes ?? Set(chapters.indices), in: job)
            }
            update(book.bookUrl) { task in
                if task.state != .downloading { task.state = .waiting }
            }
            pump()
            return true
        }
        let service = makeService(book)
        if book.isLocal, service.localBooks?.isEpub(book) != true { return false }
        nextGeneration += 1
        jobs[book.bookUrl] = Job(generation: nextGeneration, book: book, service: service, requested: range.map(Set.init))
        tasks.removeAll { $0.bookUrl == book.bookUrl }
        tasks.append(CacheTask(bookUrl: book.bookUrl, bookName: book.name))
        pump()
        return true
    }

    public func pause(_ bookUrl: String) {
        update(bookUrl) { task in
            if task.state == .waiting || task.state == .downloading { task.state = .paused }
        }
        pump()
    }

    public func resume(_ bookUrl: String) {
        update(bookUrl) { task in
            if task.state == .paused { task.state = .waiting }
        }
        pump()
    }

    public func pauseAll() {
        for task in tasks { pause(task.bookUrl) }
    }

    public func resumeAll() {
        for task in tasks { resume(task.bookUrl) }
    }

    /// 失败的章节重新排队；目录获取失败的任务重新开始
    public func retryFailed(_ bookUrl: String) {
        guard let job = jobs[bookUrl] else { return }
        job.pending.append(contentsOf: job.failed.keys.sorted())
        job.failed.removeAll()
        job.attempts.removeAll()
        update(bookUrl) { task in
            task.failedCount = 0
            task.state = .waiting
        }
        pump()
    }

    /// 移除任务，进行中的请求结果丢弃
    public func remove(_ bookUrl: String) {
        if let job = jobs.removeValue(forKey: bookUrl) {
            job.workers.values.forEach { $0.cancel() }
        }
        tasks.removeAll { $0.bookUrl == bookUrl }
        pump()
    }

    public func removeFinished() {
        for task in tasks where task.state == .finished && task.failedCount == 0 {
            remove(task.bookUrl)
        }
    }

    // MARK: - 调度

    private func pump() {
        let limit = max(1, concurrency)
        for task in tasks where task.state == .waiting || task.state == .downloading {
            guard let job = jobs[task.bookUrl] else { continue }
            if job.chapters != nil {
                while inFlight < limit, !job.pending.isEmpty {
                    startDownload(job, index: job.pending.removeFirst())
                }
                settle(job)
            } else if !job.loading, inFlight < limit {
                loadChapters(job)
            }
        }
    }

    private func loadChapters(_ job: Job) {
        job.loading = true
        inFlight += 1
        let service = job.service
        let book = job.book
        let generation = job.generation
        job.workers[-1] = Task { [weak self] in
            let result: Result<[BookChapter], Error>
            do {
                result = .success(try await service.chapters(for: book).chapters)
            } catch {
                result = .failure(error)
            }
            self?.chaptersLoaded(book.bookUrl, generation: generation, result: result)
        }
    }

    private func chaptersLoaded(_ bookUrl: String, generation: Int, result: Result<[BookChapter], Error>) {
        inFlight -= 1
        defer { pump() }
        guard let job = jobs[bookUrl], job.generation == generation else { return }
        job.loading = false
        job.workers[-1] = nil
        switch result {
        case .success(let chapters):
            job.chapters = chapters
            include(job.requested ?? Set(chapters.indices), in: job)
            settle(job)
        case .failure(let error):
            update(bookUrl) { task in
                if task.state != .paused { task.state = .failed(error.localizedDescription) }
            }
            job.chapters = nil
        }
    }

    /// 把章节计入任务：卷标题与超出目录的序号忽略，已缓存的直接算完成
    private func include(_ indexes: Set<Int>, in job: Job) {
        guard let chapters = job.chapters else { return }
        let cachedNames = store.cachedFileNames(bookUrl: job.book.bookUrl)
        var added = 0
        var cached = 0
        for index in indexes.sorted() where chapters.indices.contains(index) && !job.included.contains(index) {
            let chapter = chapters[index]
            if chapter.isVolume { continue }
            job.included.insert(index)
            added += 1
            if cachedNames.contains(ChapterStore.fileName(for: chapter)) {
                cached += 1
            } else {
                job.pending.append(index)
            }
        }
        update(job.book.bookUrl) { task in
            task.chapterCount += added
            task.cachedCount += cached
        }
    }

    private func startDownload(_ job: Job, index: Int) {
        guard let chapters = job.chapters else { return }
        inFlight += 1
        job.running.insert(index)
        update(job.book.bookUrl) { task in
            if task.state == .waiting { task.state = .downloading }
        }
        let service = job.service
        let book = job.book
        let chapter = chapters[index]
        let next = index + 1 < chapters.count ? chapters[index + 1] : nil
        let generation = job.generation
        job.workers[index] = Task { [weak self] in
            var failure: String?
            do {
                let content = try await service.content(for: book, chapter: chapter, nextChapter: next)
                if content.isEmpty { failure = "正文为空" }
            } catch {
                failure = error.localizedDescription
            }
            self?.downloadFinished(book.bookUrl, generation: generation, index: index, failure: failure)
        }
    }

    private func downloadFinished(_ bookUrl: String, generation: Int, index: Int, failure: String?) {
        inFlight -= 1
        defer { pump() }
        guard let job = jobs[bookUrl], job.generation == generation else { return }
        job.running.remove(index)
        job.workers[index] = nil
        if let failure {
            let attempts = job.attempts[index, default: 0] + 1
            job.attempts[index] = attempts
            if attempts <= Self.maxRetries {
                job.pending.append(index)
            } else {
                job.failed[index] = failure
                update(bookUrl) { $0.failedCount += 1 }
            }
        } else {
            update(bookUrl) { $0.cachedCount += 1 }
        }
        settle(job)
    }

    private func settle(_ job: Job) {
        guard job.chapters != nil, job.pending.isEmpty, job.running.isEmpty else { return }
        update(job.book.bookUrl) { task in
            if task.state == .waiting || task.state == .downloading { task.state = .finished }
        }
    }

    private func update(_ bookUrl: String, _ body: (inout CacheTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.bookUrl == bookUrl }) else { return }
        body(&tasks[index])
    }
}
