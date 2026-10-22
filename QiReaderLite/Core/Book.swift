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
    /// ⭐⭐⭐ **列表项的【原始字段】**（2026-10-22 真机）
    ///   站方 jsLib 生成 `data:;base64,<载荷>` 时要读 **book.book_id** 之类
    ///   ⇒ 宿主原先只送 name/author/… ⇒ 站方拿不到 ⇒ 载荷缺 book_id
    ///      ⇒ 详情/目录请求全是 book_id=undefined ⇒ 服务器回「illegal base64」⇒ 整本书崩 ⭐
    var raw: [String: String] = [:]

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
        guard !s.isEmpty else { return "" }
        // ⚠️⚠️ **data: / blob: / 自定义 scheme 必须原样返回**（2026-10-21 真机栽在这）
        //   聚合源（🍅大灰狼）的书籍 URL 是 `data:;base64,<载荷>,{"type":"qingtian"}`，
        //   而 `URL(string:).absoluteString` 会把那个 `{"type":…}` **百分号编码**成
        //   `%7B%22type%22%3A%22qingtian%22%7D` ⇒ 引擎的 `,{` 后缀剥离**失效**
        //   ⇒ 载荷被污染 → 站方 `JSON.parse(java.hexDecodeToString(result))` 炸
        //   → 「JSON Parse error: Unable to parse JSON string」→ 详情页整条规则静默失效。
        //
        //   ⚠️ 沙盒测不到：我的活体测试传的是**原始** bookUrl，
        //      而 App 传的是 `cleanBookUrl`（规范化后的）—— 两边走的不是同一条路！
        //   ⇒ 引擎侧还有一道防御（dataUrlContent 也能剥百分号编码的后缀）。
        let lower = s.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("blob:") || lower.hasPrefix("qireaderlite:") {
            return s
        }
        guard let u = URL(string: s) else { return s }
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
