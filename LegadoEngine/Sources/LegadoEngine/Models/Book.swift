import Foundation

public final class Book: Codable, Hashable, Identifiable {
    public var bookUrl: String = ""
    public var tocUrl: String = ""
    public var origin: String = ""
    public var originName: String = ""
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var coverUrl: String?
    public var intro: String?
    public var wordCount: String?
    public var latestChapterTitle: String?
    public var latestChapterTime: Int64 = 0
    public var totalChapterNum: Int = 0
    public var durChapterTitle: String?
    public var durChapterIndex: Int = 0
    public var durChapterPos: Int = 0
    public var durChapterTime: Int64 = 0
    public var lastCheckCount: Int = 0
    public var canUpdate: Bool = true
    public var order: Int = 0
    public var group: Int = 0
    public var variable: String?
    public var infoHtml: String?
    public var tocHtml: String?

    public var id: String { bookUrl }
    public init() {}
    public init(bookUrl: String, origin: String) { self.bookUrl = bookUrl; self.origin = origin }

    public static func == (l: Book, r: Book) -> Bool { l.bookUrl == r.bookUrl && l.origin == r.origin }
    public func hash(into hasher: inout Hasher) { hasher.combine(bookUrl); hasher.combine(origin) }

    public func getVariable() -> String { variable ?? "" }
    public func setVariable(_ v: String) { variable = v }
    public func getVariable(key: String) -> String {
        guard let d = (variable ?? "").data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return o[key].map { "\($0)" } ?? ""
    }
    public func putVariable(key: String, value: String) {
        var o: [String: Any] = [:]
        if let d = (variable ?? "").data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = j }
        o[key] = value
        if let d = try? JSONSerialization.data(withJSONObject: o) { variable = String(data: d, encoding: .utf8) }
    }
    /// origin fingerprint used when the source key is a login-scoped URL
    public var originFingerprint: String { origin }
}

public final class BookChapter: Codable, Hashable, Identifiable {
    public var url: String = ""
    public var baseUrl: String = ""
    public var title: String = ""
    public var index: Int = 0
    public var tag: String?
    public var isVolume: Bool = false
    public var isVip: Bool = false
    public var isPay: Bool = false
    public var updateTime: String?
    public var variable: String?

    public var id: String { "\(index)|\(url)" }
    public init() {}
    public init(index: Int, title: String, url: String, baseUrl: String = "") {
        self.index = index; self.title = title; self.url = url; self.baseUrl = baseUrl
    }
    public static func == (l: BookChapter, r: BookChapter) -> Bool { l.url == r.url && l.index == r.index }
    public func hash(into hasher: inout Hasher) { hasher.combine(url); hasher.combine(index) }

    public func getVariable() -> String { variable ?? "" }
    public func setVariable(_ v: String) { variable = v }
}

/// A search/explore result row before it becomes a Book.
public struct SearchBook: Hashable {
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var wordCount: String?
    public var lastChapter: String?
    public var intro: String?
    public var coverUrl: String?
    public var bookUrl: String = ""
    public var updateTime: String?
    public var origin: String = ""
    public var originName: String = ""
    public var variable: String?
    public init() {}

    public func toBook() -> Book {
        let b = Book(bookUrl: bookUrl, origin: origin)
        b.originName = originName
        b.name = name; b.author = author
        b.kind = kind; b.wordCount = wordCount
        b.intro = intro; b.coverUrl = coverUrl
        b.latestChapterTitle = lastChapter
        b.variable = variable
        return b
    }
}

/// One explore category parsed from `exploreUrl`.
public struct ExploreKind: Hashable {
    public var title: String
    public var url: String
    public init(title: String, url: String) { self.title = title; self.url = url }
}