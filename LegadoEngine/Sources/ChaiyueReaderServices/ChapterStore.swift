import Foundation
import ChaiyueModels

/// 目录与正文的磁盘缓存：每本书一个目录（bookUrl 的 MD5），目录存 `chapters.json`，
/// 正文按 Legado 的命名习惯存为 `{index:05d}-{md5(title) 前 16 位}.txt`
public final class ChapterStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func directory(for bookUrl: String) -> URL {
        root.appendingPathComponent(Hashing.md5(bookUrl), isDirectory: true)
    }

    public static func fileName(for chapter: BookChapter) -> String {
        String(format: "%05d-", chapter.index) + Hashing.md5(chapter.title).prefix(16) + ".txt"
    }

    // MARK: - 目录

    public func loadChapters(bookUrl: String) -> [BookChapter]? {
        let url = directory(for: bookUrl).appendingPathComponent("chapters.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([BookChapter].self, from: data)
    }

    public func saveChapters(_ chapters: [BookChapter], bookUrl: String) {
        let dir = directory(for: bookUrl)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(chapters) else { return }
        try? data.write(to: dir.appendingPathComponent("chapters.json"), options: .atomic)
    }

    /// 目录脚本写入的 `book.type`（听书、漫画、短剧），随目录缓存，目录走缓存时据此还原
    public func bookType(bookUrl: String) -> Int? {
        let url = directory(for: bookUrl).appendingPathComponent("type")
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0) }
    }

    public func saveBookType(_ type: Int, bookUrl: String) {
        let dir = directory(for: bookUrl)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(type).write(to: dir.appendingPathComponent("type"), atomically: true, encoding: .utf8)
    }

    // MARK: - 正文

    public func content(bookUrl: String, chapter: BookChapter) -> String? {
        let url = directory(for: bookUrl).appendingPathComponent(Self.fileName(for: chapter))
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func saveContent(_ content: String, bookUrl: String, chapter: BookChapter) {
        let dir = directory(for: bookUrl)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: dir.appendingPathComponent(Self.fileName(for: chapter)), options: .atomic)
    }

    public func removeContent(bookUrl: String, chapter: BookChapter) {
        try? FileManager.default.removeItem(at: directory(for: bookUrl).appendingPathComponent(Self.fileName(for: chapter)))
    }

    public func hasContent(bookUrl: String, chapter: BookChapter) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: bookUrl).appendingPathComponent(Self.fileName(for: chapter)).path)
    }

    /// 已缓存的正文文件名集合，配合 `fileName(for:)` 判断章节是否已缓存
    public func cachedFileNames(bookUrl: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(for: bookUrl).path)) ?? []
        return Set(names.filter { $0.hasSuffix(".txt") })
    }

    // MARK: - 清理

    public func clear(bookUrl: String) {
        try? FileManager.default.removeItem(at: directory(for: bookUrl))
    }

    public func clearAll() {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }

    public func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
