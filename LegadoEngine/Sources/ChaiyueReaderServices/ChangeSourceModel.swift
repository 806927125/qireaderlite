import Foundation
import Observation
import ChaiyueModels
import ChaiyueEngine

/// 换源候选：其他书源中书名一致、作者相符的搜索结果。`book.respondTime` 为该书源的搜索耗时（毫秒）
public struct SourceCandidate: Identifiable, Hashable, Sendable {
    public var book: SearchBook
    public var isCurrent: Bool
    public var id: String { book.origin + "\n" + book.bookUrl }
}

/// 换源搜索：用书名在启用的书源中并发搜索，保留书名一致、作者相符的结果（任一方作者为空时不比较作者）。
/// 当前来源排在最前，其余按书源顺序；同一书源的同一本书只保留一条
@MainActor
@Observable
public final class ChangeSourceModel {
    public private(set) var book: Book
    public private(set) var candidates: [SourceCandidate] = []
    public private(set) var isSearching = false
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var failures: [SearchFailure] = []
    /// 已完整搜索过一轮（复用了已完成的搜索结果也算），`start()` 不再重复搜索
    public private(set) var hasSearched = false
    /// 关闭后作者不一致的结果也保留
    public var checksAuthor = true {
        didSet { if checksAuthor != oldValue { rebuild() } }
    }
    public var concurrency = 8
    public var timeout: Duration = .seconds(30)

    @ObservationIgnored private let environment: SourceEnvironment
    @ObservationIgnored private let sources: [BookSource]
    @ObservationIgnored private var sourceOrder: [String: Int] = [:]
    /// 书名一致的全部结果，切换作者校验时重新过滤
    @ObservationIgnored private var matched: [SearchBook] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    /// 参与搜索的书源数（有搜索规则的）
    var sourceCount: Int { sources.count }

    public init(book: Book, sources: [BookSource], environment: SourceEnvironment) {
        self.book = book
        self.environment = environment
        self.sources = sources.filter { !($0.searchUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        for (index, source) in self.sources.enumerated() where sourceOrder[source.bookSourceUrl] == nil {
            sourceOrder[source.bookSourceUrl] = index
        }
    }

    public func start() {
        guard !isSearching, !hasSearched else { return }
        run()
    }

    /// 清空结果重新搜索
    public func refresh() {
        cancel()
        matched = []
        candidates = []
        failures = []
        hasSearched = false
        run()
    }

    public func cancel() {
        runID += 1
        task?.cancel()
        task = nil
        isSearching = false
    }

    /// 换源后更新当前来源标记
    public func setCurrent(_ book: Book) {
        self.book = book
        rebuild()
    }

    /// 复用搜索页的结果；`complete` 表示那次搜索已覆盖全部书源
    public func seed(_ results: [SearchBook], complete: Bool) {
        add(results)
        if complete, !isSearching { hasSearched = true }
    }

    private func run() {
        runID += 1
        let id = runID
        let list = sources
        let keyword = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        completed = 0
        total = list.count
        isSearching = !list.isEmpty && !keyword.isEmpty
        guard isSearching else {
            hasSearched = true
            return
        }
        let env = environment
        let timeout = timeout
        let limit = max(1, concurrency)
        task = Task { [weak self] in
            await withTaskGroup(of: (BookSource, Result<[SearchBook], Error>, Int).self) { group in
                var iterator = list.makeIterator()
                func addNext() {
                    guard let source = iterator.next() else { return }
                    group.addTask {
                        let start = ContinuousClock.now
                        let result = await SearchModel.searchOne(source, keyword: keyword, page: 1, env: env, timeout: timeout)
                        let elapsed = ContinuousClock.now - start
                        let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                        return (source, result, millis)
                    }
                }
                for _ in 0..<limit { addNext() }
                while let (source, result, millis) = await group.next() {
                    guard let self, self.runID == id, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.handle(source, result, millis: millis)
                    addNext()
                }
            }
            guard let self, self.runID == id else { return }
            self.isSearching = false
            self.hasSearched = true
        }
    }

    private func handle(_ source: BookSource, _ result: Result<[SearchBook], Error>, millis: Int) {
        completed += 1
        switch result {
        case .success(let books):
            add(books.map { book in
                var book = book
                book.respondTime = millis
                return book
            })
        case .failure(let error):
            failures.append(SearchFailure(sourceUrl: source.bookSourceUrl, sourceName: source.bookSourceName,
                                          message: error.localizedDescription))
        }
    }

    private func add(_ books: [SearchBook]) {
        let name = Self.nameKey(book.name)
        var changed = false
        for result in books where Self.nameKey(result.name) == name {
            guard !matched.contains(where: { $0.origin == result.origin && $0.bookUrl == result.bookUrl }) else { continue }
            matched.append(result)
            changed = true
        }
        if changed { rebuild() }
    }

    private func rebuild() {
        let author = book.author
        let checksAuthor = checksAuthor
        let current = (book.origin, book.bookUrl)
        candidates = matched
            .filter { !checksAuthor || Self.authorMatches(author, $0.author) }
            .map { SourceCandidate(book: $0, isCurrent: $0.origin == current.0 && $0.bookUrl == current.1) }
            .enumerated()
            .sorted { a, b in
                if a.element.isCurrent != b.element.isCurrent { return a.element.isCurrent }
                let oa = sourceOrder[a.element.book.origin] ?? Int.max
                let ob = sourceOrder[b.element.book.origin] ?? Int.max
                return oa != ob ? oa < ob : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - 匹配

    nonisolated static func nameKey(_ name: String) -> String {
        ChapterMatcher.fullToHalf(name).filter { !$0.isWhitespace }.lowercased()
    }

    nonisolated static func authorKey(_ author: String) -> String {
        ChapterMatcher.fullToHalf(author)
            .replacingOccurrences(of: #"^\s*作\s*者[:：\s]+|\s+著\s*$"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }
            .lowercased()
    }

    /// 任一方作者为空时视为相符；否则一方包含另一方
    nonisolated static func authorMatches(_ target: String, _ candidate: String) -> Bool {
        let a = authorKey(target), b = authorKey(candidate)
        return a.isEmpty || b.isEmpty || a.contains(b) || b.contains(a)
    }
}
