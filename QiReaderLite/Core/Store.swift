import Foundation
import SwiftUI


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
        // ⭐⭐⭐ 源变了 ⇒ **源字典缓存要清**（否则引擎会拿到旧的源）
        SourceDictCache.invalidate()
        persist()
    }

    /// ⭐⭐⭐⭐⭐ **导入书源：新增 / 更新 / 未变，三种结果分开算**（2026-11-23 真机反馈）
    ///
    /// ⚠️⚠️ **用户原话**：「同个要看**有没有变化**，**有变化就是要更新书源**，
    ///   现在是**有书源的情况下导不进去**」⭐⭐⭐
    ///
    /// ⭐⭐⭐ **旧实现为什么让用户以为「导不进去」**：
    ///   旧版只返回**「新增条数」** ⇒ 已有同 URL 书源时返回 **0**
    ///   ⇒ Toast 显示「**导入 0 个书源**」⇒ **但源其实已经被替换了** ⇒ **用户以为没生效** ⭐⭐⭐
    ///
    /// ⭐⭐⭐ **现在的语义**：
    ///   - **新增**：这个 `bookSourceUrl` 之前没有
    ///   - **更新**：之前有 ⇒ **内容有变化**（拿「上次导入存档的原始 JSON」比）⇒ ⇒ 覆盖
    ///   - **未变**：之前有 ⇒ **内容一样** ⇒ ⇒ **不动它**（保留用户在 App 里的改动）⭐⭐⭐
    ///
    /// ⚠️⚠️ **「有没有变化」的基准 = 上次导入时的原始 JSON 存档**（`SourceRawArchive`）⭐⭐⭐
    ///   ⇒ ⇒ **导入流程必须「先比后存」** ⇒ 所以调用方要用
    ///     `BookSourceParser.parse(data, archive: false)` ⇒ 别在解析时就覆盖存档 ⭐⭐⭐
    ///
    /// - Parameters:
    ///   - list: 解析出来的源
    ///   - raws: 按 `bookSourceUrl` 索引的**原始 JSON**（比较基准 + 更新后的存档内容）
    @discardableResult
    func importSources(_ list: [BookSource], raws: [String: [String: Any]] = [:]) -> SourceImportDiff.Stats {
        // ⭐⭐⭐ **用「导入时的原始 JSON 存档」把模型缺的字段补上**
        //   （`loginUi` 是 build153 才加的 ⇒ 老版本存下来的源缺它 ⇒ 登录界面整没了）
        let list = list.map { SourceRawArchive.patch($0) }
        // ⭐⭐⭐⭐⭐ **判定逻辑放在 `SourceImportDiff`（纯 Foundation）** ⭐⭐⭐
        //   ⇒ `Store.swift` import SwiftUI ⇒ **沙盒编不到** ⇒ 逻辑放这儿**门禁才验得到** ⭐⭐⭐
        let incoming: [(source: BookSource, raw: [String: Any]?)] = list.map {
            (source: $0, raw: raws[$0.bookSourceUrl])
        }
        let plan = SourceImportDiff.plan(existing: sources, incoming: incoming) { url in
            SourceRawArchive.raw(for: url)
        }
        // ⭐⭐⭐ **应用决策**：新增 + 更新 ⇒ 覆盖；未变 ⇒ **不动** ⭐⭐⭐
        var index = Dictionary(sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, last in last })
        for s in plan.added + plan.updated { index[s.bookSourceUrl] = s }
        // ⭐⭐⭐ **「先比后存」** ⇒ 判定完之后才更新存档 ⇒ ⇒ 下次导入才判得出「未变」⭐⭐⭐
        for s in list {
            if let newRaw = raws[s.bookSourceUrl] {
                SourceRawArchive.save(newRaw, for: s.bookSourceUrl)
            }
        }
        sources = index.values.sorted { $0.name < $1.name }
        // ⭐⭐⭐ 源变了 ⇒ 缓存要清
        SourceDictCache.invalidate()
        persist()
        return plan.stats
    }

    func remove(ids: Set<String>) {
        sources.removeAll { ids.contains($0.bookSourceUrl) }
        SourceDictCache.invalidate()
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
        // ⭐⭐⭐ **用「原始 JSON 存档」把缺的字段补上**（2026-10-24 真机：「登录界面没了」）
        //   老版本存下来的源缺 `loginUi` / `jsLib` / `loginUrl` ⇒ 登录面板空、站方 JS 跑不起来
        //   ⇒ 存档是**导入时留的原始 JSON**（权威）⇒ 补得回来，**不用重新导入** ⭐
        sources = sources.map { SourceRawArchive.patch($0) }
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
