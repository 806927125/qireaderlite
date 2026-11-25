import Foundation
import ChaiyueModels

/// 一次书架更新检查的结果
public struct ShelfRefreshReport: Sendable, Equatable {
    public var checked = 0
    /// 有新章节的书（bookUrl）
    public var updated: [String] = []
    /// 刷新失败的书：bookUrl → 错误信息
    public var failed: [String: String] = [:]

    public init() {}
}

/// 书架更新检查：并发刷新目录，合并书籍信息并统计新章节。本地书和关闭了更新的书跳过
@MainActor
public final class ShelfUpdater {
    private let shelf: BookshelfRepository
    private let makeService: (Book) -> BookContentService
    public var concurrency = 4
    public private(set) var isRefreshing = false

    public init(shelf: BookshelfRepository, makeService: @escaping (Book) -> BookContentService) {
        self.shelf = shelf
        self.makeService = makeService
    }

    @discardableResult
    public func refresh(_ books: [Book]) async -> ShelfRefreshReport {
        var report = ShelfRefreshReport()
        guard !isRefreshing else { return report }
        isRefreshing = true
        defer { isRefreshing = false }

        let jobs = books.filter { !$0.isLocal && $0.canUpdate }.map { ($0, makeService($0)) }
        var pending = jobs.makeIterator()
        let width = max(1, concurrency)
        await withTaskGroup(of: (Book, Result<Book, Error>).self) { group in
            func addNext() -> Bool {
                guard let (book, service) = pending.next() else { return false }
                group.addTask {
                    do {
                        return (book, .success(try await service.chapters(for: book, refresh: true).book))
                    } catch {
                        return (book, .failure(error))
                    }
                }
                return true
            }
            for _ in 0..<width {
                if !addNext() { break }
            }
            while let (old, result) = await group.next() {
                report.checked += 1
                switch result {
                case .success(let fresh):
                    shelf.mergeMetadata(from: fresh)
                    if old.totalChapterNum > 0, fresh.totalChapterNum > old.totalChapterNum {
                        report.updated.append(old.bookUrl)
                    }
                case .failure(let error):
                    report.failed[old.bookUrl] = error.localizedDescription
                }
                _ = addNext()
            }
        }
        return report
    }
}
