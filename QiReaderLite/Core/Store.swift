import Foundation
import SwiftUI

// MARK: - 磁盘路径

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var sourcesFile: URL { documents.appendingPathComponent("book_sources.json") }
    /// 从 Info.plist 读版本号，自检面板用
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var libraryFile: URL { documents.appendingPathComponent("library.json") }
    static var cacheDir: URL {
        let d = documents.appendingPathComponent("content_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - 书源仓库

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var sources: [BookSource] = []

    private let queue = DispatchQueue(label: "qr.sources.io", qos: .utility)

    init() { load() }

    var enabled: [BookSource] { sources.filter { $0.enabled } }

    /// 目录面板「刷新目录」要真发一次请求，所以这里挂一个 service。
    /// 放 store 上是图省事（调用方拿得到 EnvironmentObject 就行），
    /// 纯读路径（列源 / 搜索）不需要它。
    /// ⚠️ SourceService 是单例（`private init()`），不能直接 `SourceService()`，
    ///    编译器报 'initializer is inaccessible due to private protection level'。
    var service: SourceService { .shared }

    func source(id: String) -> BookSource? { sources.first { $0.bookSourceUrl == id } }

    func replaceAll(_ list: [BookSource]) {
        sources = list.sorted { $0.name < $1.name }
        persist()
    }

    /// 按 bookSourceUrl 覆盖式导入，重复的更新、不重复的追加，返回新增条数
    @discardableResult
    func importSources(_ list: [BookSource]) -> Int {
        var index = Dictionary(sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, last in last })
        var added = 0
        for s in list where !s.bookSourceUrl.isEmpty {
            if index[s.bookSourceUrl] == nil { added += 1 }
            index[s.bookSourceUrl] = s
        }
        sources = index.values.sorted { $0.name < $1.name }
        persist()
        return added
    }

    func remove(ids: Set<String>) {
        sources.removeAll { ids.contains($0.bookSourceUrl) }
        persist()
    }

    func setEnabled(_ on: Bool, for id: String) {
        guard let i = sources.firstIndex(where: { $0.bookSourceUrl == id }) else { return }
        sources[i].enabled = on
        persist()
    }

    private func load() {
        guard let d = try? Data(contentsOf: AppPaths.sourcesFile) else { return }
        sources = (try? AppDecoder.decode([BookSource].self, from: d)) ?? []
        sources.sort { $0.name < $1.name }
    }

    private func persist() {
        let snapshot = sources
        queue.async {
            guard let d = try? AppEncoder.encode(snapshot) else { return }
            try? d.write(to: AppPaths.sourcesFile, options: .atomic)
        }
    }
}

// MARK: - 书架

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    private let queue = DispatchQueue(label: "qr.library.io", qos: .utility)

    init() { load() }

    func item(for bookId: String) -> LibraryItem? { items.first { $0.book.id == bookId } }

    /// 存阅读进度（章索引 + 章内比例）。WebView 阅读界面每次滚动都会调。
    func saveProgress(bookID: String, chapterIndex: Int, ratio: Double,
                      chapterTitle: String) {
        guard items.contains(where: { $0.book.id == bookID }) else { return }
        update(bookID) { item in
            item.lastChapterIndex = max(item.lastChapterIndex, chapterIndex)
            item.lastReadAt = Date()
            if !chapterTitle.isEmpty, item.book.lastChapter.isEmpty {
                item.book.lastChapter = chapterTitle
            }
        }
    }

    /// 取上次读到的位置，给阅读界面 setInitial 用
    func progress(bookID: String) -> (chapterIndex: Int, scrollRatio: Double)? {
        guard let it = items.first(where: { $0.book.id == bookID }),
              it.lastReadAt != nil || it.lastChapterIndex > 0 else { return nil }
        return (it.lastChapterIndex, 0)
    }
    func contains(_ book: Book) -> Bool { items.contains { $0.book.id == book.id } }

    @discardableResult
    func add(_ book: Book) -> LibraryItem {
        if let exist = items.first(where: { $0.book.id == book.id }) {
            update(exist.id) { $0.book = $0.book.merged(with: book) }
            return items.first { $0.book.id == book.id }!
        }
        let it = LibraryItem(book: book)
        items.insert(it, at: 0)
        persist()
        return it
    }

    func remove(_ bookId: String) {
        items.removeAll { $0.book.id == bookId }
        ContentCache.shared.remove(bookId)
        persist()
    }

    func update(_ bookId: String, _ mutate: (inout LibraryItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.book.id == bookId }) else { return }
        mutate(&items[i])
        persist()
    }

    private func load() {
        guard let d = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        items = (try? AppDecoder.decode([LibraryItem].self, from: d)) ?? []
    }

    private func persist() {
        let snapshot = items
        queue.async {
            guard let d = try? AppEncoder.encode(snapshot) else { return }
            try? d.write(to: AppPaths.libraryFile, options: .atomic)
        }
    }
}

// MARK: - 正文缓存

/// 章正文按 URL 分片存磁盘，内存只留索引。
/// Legado 正文动辄几百 KB，攒在内存里几十本就能把 App 干退。
final class ContentCache {
    static let shared = ContentCache()

    private let dir = AppPaths.cacheDir
    private var index: [String: String] = [:]   // 绝对URL -> 文件路径
    private let io = DispatchQueue(label: "qr.cache.io", qos: .utility)
    private let lock = NSLock()

    private func key(_ url: String) -> String {
        let h = abs(url.hashValue)
        return "\(h).txt"
    }

    func get(_ url: String) -> String? {
        lock.lock(); let p = index[url]; lock.unlock()
        guard let p else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8)
    }

    func put(_ url: String, _ text: String) {
        io.async { [dir] in
            let p = dir.appendingPathComponent(self.key(url))
            guard let d = text.data(using: .utf8) else { return }
            try? d.write(to: p, options: .atomic)
            self.lock.lock(); self.index[url] = p.path; self.lock.unlock()
        }
    }

    func remove(_ bookId: String) {
        io.async { [dir] in
            let prefix = String(bookId.prefix(24))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for f in files {
                // 缓存文件名是 hash，删书时靠 BookCatalog 记录的 URL 清理，见 removeURLs
                if f.hasPrefix(prefix) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            }
        }
    }

    func removeURLs(_ urls: [String]) {
        lock.lock()
        let paths = urls.compactMap { index[$0] }
        urls.forEach { index[$0] = nil }
        lock.unlock()
        io.async {
            for p in paths { try? FileManager.default.removeItem(atPath: p) }
        }
    }
}

// MARK: - 小工具

extension Optional where Wrapped == String {
    /// 空串也当「没有」。规则字段经常是 "" 而不是 null。
    var isNil: Bool {
        guard let v = self else { return true }
        return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 编解码

enum AppEncoder {
    static let shared: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static func encode<T: Encodable>(_ v: T) throws -> Data { try shared.encode(v) }
}

enum AppDecoder {
    static let shared: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static func decode<T: Decodable>(_ t: T.Type, from data: Data) throws -> T { try shared.decode(t, from: data) }
}
