import Foundation

// MARK: - 书籍

struct Book: Codable, Identifiable, Hashable {
    /// 全局唯一：`来源URL::书籍URL`
    /// ⚠️ 列表渲染靠它做 ForEach 的 id，重复会直接让 SwiftUI 抛异常闪退。
    /// 只用 origin+bookUrl 不够：规则没抽到 bookUrl 时整页书的 id 全一样。
    var id: String { "\(origin)??\(bookUrl)??\(name)??\(author)" }

    var origin: String          // 来自哪个书源（bookSourceUrl）
    var bookUrl: String
    var name: String
    var author: String = ""
    var intro: String = ""
    var kind: String = ""
    var lastChapter: String = ""
    var coverUrl: String = ""
    var wordCount: String = ""
    var tocUrl: String = ""
    var sourceName: String = ""

    /// 搜索结果还没跑过详情页时为 true，点进书架后补齐
    var detailLoaded: Bool = false

    var cleanCover: String { Self.normalizeURL(coverUrl) }
    var cleanBookUrl: String { Self.normalizeURL(bookUrl) }

    /// 详情接口失败时，用列表页已经拿到的字段兜底，绝不让整本书变空白页
    func merged(with info: Book) -> Book {
        var b = self
        func pick(_ a: String, _ c: String) -> String {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? c : t
        }
        b.name     = pick(info.name, name)
        b.author   = pick(info.author, author)
        b.intro    = pick(info.intro, intro)
        b.kind     = pick(info.kind, kind)
        b.lastChapter = pick(info.lastChapter, lastChapter)
        b.coverUrl = pick(info.coverUrl, coverUrl)
        b.wordCount = pick(info.wordCount, wordCount)
        b.tocUrl   = pick(info.tocUrl, tocUrl)
        b.detailLoaded = true
        return b
    }

    static func normalizeURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s) else { return "" }
        return u.absoluteString
    }
}

// MARK: - 章节

struct Chapter: Codable, Identifiable, Hashable {
    var id: String { "\(url)??\(index)" }

    var url: String
    var title: String
    var index: Int
    var isVolume: Bool = false
    var isVip: Bool = false
    var isPay: Bool = false
    var updateTime: String = ""
    /// 阅读器里显示的小字，Legado 用 tag，栖阅也用它
    var tag: String = ""
    /// 正文缓存（离线阅读用）
    var content: String? = nil
}

struct BookCatalog: Codable, Hashable {
    var bookId: String
    var chapters: [Chapter] = []
    /// 目录翻页到第几页（有些站目录要串行抓多页）
    var pagesFetched: Int = 0

    var plain: [Chapter] { chapters.filter { !$0.isVolume } }
}

// MARK: - 书架条目

struct LibraryItem: Codable, Identifiable, Hashable {
    var id: String { book.id }

    var book: Book
    var addedAt: Date = Date()
    var lastReadAt: Date? = nil
    /// 上次读到第几章（全局下标，不是卷序号）
    var lastChapterIndex: Int = 0
    var readChapters: [String: Int] = [:]   // chapter.url -> 读完的行位置，用于滚动续读
    var finished: Bool = false
}

// MARK: - 搜索/发现结果

struct BookLite: Codable, Identifiable, Hashable {
    var id: String { book.id }

    var book: Book
    /// 列表页给的 bookUrl 有时是相对地址，JS 侧已补全
    var fromSearch: Bool = true
}
