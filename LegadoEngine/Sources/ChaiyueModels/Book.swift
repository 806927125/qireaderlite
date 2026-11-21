import Foundation

/// 书籍。字段与 Legado 书架导出格式兼容。
public struct Book: Hashable, Sendable, Identifiable {
    /// 本地书籍的 origin 标记
    public static let localOrigin = "loc_book"

    public var bookUrl: String
    public var tocUrl: String = ""
    /// 书源地址（bookSourceUrl）；本地书为 `Book.localOrigin`
    public var origin: String = Book.localOrigin
    public var originName: String = ""
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var customTag: String?
    public var coverUrl: String?
    public var customCoverUrl: String?
    public var intro: String?
    public var customIntro: String?
    public var charset: String?
    public var type: Int = BookSourceType.text.rawValue
    /// 分组位掩码
    public var group: Int64 = 0
    public var latestChapterTitle: String?
    public var latestChapterTime: Int64 = 0
    public var lastCheckTime: Int64 = 0
    public var lastCheckCount: Int = 0
    public var totalChapterNum: Int = 0
    public var durChapterTitle: String?
    public var durChapterIndex: Int = 0
    /// 当前章节内的字符偏移
    public var durChapterPos: Int = 0
    /// 当前章节的正文长度（与 durChapterPos 同一计量），书架据此算章内进度；Legado 无此字段
    public var durChapterLength: Int = 0
    public var durChapterTime: Int64 = 0
    public var wordCount: String?
    public var canUpdate: Bool = true
    public var order: Int = 0
    public var originOrder: Int = 0
    /// 书源脚本通过 `book.putVariable` 写入的变量
    public var variableMap: [String: String] = [:]
    public var readConfig: BookReadConfig?
    public var syncTime: Int64 = 0
    public var extras: [String: JSONValue] = [:]

    // 以下为解析过程中的临时数据，不参与持久化
    /// 详情页源码（目录地址与详情页相同时复用）
    public var infoHtml: String?
    /// 目录页源码
    public var tocHtml: String?
    public var downloadUrls: [String]?

    public var id: String { bookUrl }

    public init(bookUrl: String, origin: String = Book.localOrigin, name: String = "", author: String = "") {
        self.bookUrl = bookUrl
        self.origin = origin
        self.name = name
        self.author = author
    }

    public var isLocal: Bool { origin == Book.localOrigin }

    public var displayCover: String? { customCoverUrl.nilIfEmpty ?? coverUrl.nilIfEmpty }

    public var displayIntro: String? { customIntro.nilIfEmpty ?? intro.nilIfEmpty }

    public var variable: String? {
        get { VariableCoding.encode(variableMap) }
        set { variableMap = VariableCoding.decode(newValue) }
    }

    /// 与 Legado 一致：`custom` 变量用于书源说明中提示用户填写的自定义内容
    public var customVariable: String {
        get { variableMap["custom"] ?? "" }
        set { variableMap["custom"] = newValue }
    }
}

/// 单本书的阅读配置
public struct BookReadConfig: Codable, Hashable, Sendable {
    public var reverseToc: Bool?
    public var pageAnim: Int?
    public var reSegment: Bool?
    public var imageStyle: String?
    public var useReplaceRule: Bool?
    public var delTag: Int64?
    public var ttsEngine: String?
    public var splitLongChapter: Bool?

    public init() {}
}

extension Book: Codable {
    private static let knownKeys: Set<String> = [
        "bookUrl", "tocUrl", "origin", "originName", "name", "author", "kind", "customTag", "coverUrl",
        "customCoverUrl", "intro", "customIntro", "charset", "type", "group", "latestChapterTitle",
        "latestChapterTime", "lastCheckTime", "lastCheckCount", "totalChapterNum", "durChapterTitle",
        "durChapterIndex", "durChapterPos", "durChapterLength", "durChapterTime", "wordCount", "canUpdate", "order",
        "originOrder", "variable", "readConfig", "syncTime",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(bookUrl: c.string("bookUrl") ?? "")
        tocUrl = c.string("tocUrl") ?? ""
        origin = c.string("origin") ?? Book.localOrigin
        originName = c.string("originName") ?? ""
        name = c.string("name") ?? ""
        author = c.string("author") ?? ""
        kind = c.string("kind")
        customTag = c.string("customTag")
        coverUrl = c.string("coverUrl")
        customCoverUrl = c.string("customCoverUrl")
        intro = c.string("intro")
        customIntro = c.string("customIntro")
        charset = c.string("charset")
        type = c.int("type") ?? 0
        group = c.int64("group") ?? 0
        latestChapterTitle = c.string("latestChapterTitle")
        latestChapterTime = c.int64("latestChapterTime") ?? 0
        lastCheckTime = c.int64("lastCheckTime") ?? 0
        lastCheckCount = c.int("lastCheckCount") ?? 0
        totalChapterNum = c.int("totalChapterNum") ?? 0
        durChapterTitle = c.string("durChapterTitle")
        durChapterIndex = c.int("durChapterIndex") ?? 0
        durChapterPos = c.int("durChapterPos") ?? 0
        durChapterLength = c.int("durChapterLength") ?? 0
        durChapterTime = c.int64("durChapterTime") ?? 0
        wordCount = c.string("wordCount")
        canUpdate = c.bool("canUpdate") ?? true
        order = c.int("order") ?? 0
        originOrder = c.int("originOrder") ?? 0
        variable = c.string("variable")
        readConfig = c.object(BookReadConfig.self, "readConfig")
        syncTime = c.int64("syncTime") ?? 0
        extras = c.unknownFields(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeExtras(extras)
        try c.encode(bookUrl, "bookUrl")
        try c.encode(tocUrl, "tocUrl")
        try c.encode(origin, "origin")
        try c.encode(originName, "originName")
        try c.encode(name, "name")
        try c.encode(author, "author")
        try c.encodeIfPresent(kind, "kind")
        try c.encodeIfPresent(customTag, "customTag")
        try c.encodeIfPresent(coverUrl, "coverUrl")
        try c.encodeIfPresent(customCoverUrl, "customCoverUrl")
        try c.encodeIfPresent(intro, "intro")
        try c.encodeIfPresent(customIntro, "customIntro")
        try c.encodeIfPresent(charset, "charset")
        try c.encode(type, "type")
        try c.encode(group, "group")
        try c.encodeIfPresent(latestChapterTitle, "latestChapterTitle")
        try c.encode(latestChapterTime, "latestChapterTime")
        try c.encode(lastCheckTime, "lastCheckTime")
        try c.encode(lastCheckCount, "lastCheckCount")
        try c.encode(totalChapterNum, "totalChapterNum")
        try c.encodeIfPresent(durChapterTitle, "durChapterTitle")
        try c.encode(durChapterIndex, "durChapterIndex")
        try c.encode(durChapterPos, "durChapterPos")
        if durChapterLength > 0 { try c.encode(durChapterLength, "durChapterLength") }
        try c.encode(durChapterTime, "durChapterTime")
        try c.encodeIfPresent(wordCount, "wordCount")
        try c.encode(canUpdate, "canUpdate")
        try c.encode(order, "order")
        try c.encode(originOrder, "originOrder")
        try c.encodeIfPresent(variable, "variable")
        try c.encodeIfPresent(readConfig, "readConfig")
        try c.encode(syncTime, "syncTime")
    }
}

/// 搜索/发现结果
public struct SearchBook: Hashable, Sendable, Identifiable {
    public var bookUrl: String
    /// 书源地址
    public var origin: String
    public var originName: String = ""
    public var type: Int = BookSourceType.text.rawValue
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var coverUrl: String?
    public var intro: String?
    public var wordCount: String?
    public var latestChapterTitle: String?
    public var tocUrl: String = ""
    public var time: Int64 = 0
    public var variableMap: [String: String] = [:]
    public var originOrder: Int = 0
    public var respondTime: Int = -1
    /// 搜索结果合并时记录的所有来源
    public var origins: [String] = []
    /// 列表即详情时缓存的详情页源码
    public var infoHtml: String?
    public var tocHtml: String?

    public var id: String { "\(origin)\u{1}\(bookUrl)" }

    public init(bookUrl: String, origin: String) {
        self.bookUrl = bookUrl
        self.origin = origin
    }

    public var variable: String? {
        get { VariableCoding.encode(variableMap) }
        set { variableMap = VariableCoding.decode(newValue) }
    }

    public func toBook() -> Book {
        var book = Book(bookUrl: bookUrl, origin: origin, name: name, author: author)
        book.originName = originName
        book.type = type
        book.kind = kind
        book.coverUrl = coverUrl
        book.intro = intro
        book.wordCount = wordCount
        book.latestChapterTitle = latestChapterTitle
        book.tocUrl = tocUrl
        book.originOrder = originOrder
        book.variableMap = variableMap
        book.infoHtml = infoHtml
        book.tocHtml = tocHtml
        return book
    }
}

public extension Book {
    func toSearchBook() -> SearchBook {
        var sb = SearchBook(bookUrl: bookUrl, origin: origin)
        sb.originName = originName
        sb.type = type
        sb.name = name
        sb.author = author
        sb.kind = kind
        sb.coverUrl = coverUrl
        sb.intro = intro
        sb.wordCount = wordCount
        sb.latestChapterTitle = latestChapterTitle
        sb.tocUrl = tocUrl
        sb.originOrder = originOrder
        sb.variableMap = variableMap
        sb.infoHtml = infoHtml
        sb.tocHtml = tocHtml
        return sb
    }
}

extension SearchBook: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(bookUrl: c.string("bookUrl") ?? "", origin: c.string("origin") ?? "")
        originName = c.string("originName") ?? ""
        type = c.int("type") ?? 0
        name = c.string("name") ?? ""
        author = c.string("author") ?? ""
        kind = c.string("kind")
        coverUrl = c.string("coverUrl")
        intro = c.string("intro")
        wordCount = c.string("wordCount")
        latestChapterTitle = c.string("latestChapterTitle")
        tocUrl = c.string("tocUrl") ?? ""
        time = c.int64("time") ?? 0
        variable = c.string("variable")
        originOrder = c.int("originOrder") ?? 0
        respondTime = c.int("respondTime") ?? -1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(bookUrl, "bookUrl")
        try c.encode(origin, "origin")
        try c.encode(originName, "originName")
        try c.encode(type, "type")
        try c.encode(name, "name")
        try c.encode(author, "author")
        try c.encodeIfPresent(kind, "kind")
        try c.encodeIfPresent(coverUrl, "coverUrl")
        try c.encodeIfPresent(intro, "intro")
        try c.encodeIfPresent(wordCount, "wordCount")
        try c.encodeIfPresent(latestChapterTitle, "latestChapterTitle")
        try c.encode(tocUrl, "tocUrl")
        try c.encode(time, "time")
        try c.encodeIfPresent(variable, "variable")
        try c.encode(originOrder, "originOrder")
        try c.encode(respondTime, "respondTime")
    }
}

/// 章节
public struct BookChapter: Hashable, Sendable, Identifiable {
    public var url: String = ""
    public var title: String = ""
    public var isVolume: Bool = false
    /// 用于拼接相对地址的目录页地址
    public var baseUrl: String = ""
    public var bookUrl: String = ""
    public var index: Int = 0
    public var isVip: Bool = false
    public var isPay: Bool = false
    /// 音频等资源的真实地址
    public var resourceUrl: String?
    /// 更新时间或其他附加信息
    public var tag: String?
    public var wordCount: String?
    /// 本地书籍：章节在文件中的起止位置
    public var start: Int64?
    public var end: Int64?
    /// EPUB：章节起止 fragment
    public var startFragmentId: String?
    public var endFragmentId: String?
    public var variableMap: [String: String] = [:]

    public var id: String { "\(index)\u{1}\(url)" }

    public init(url: String = "", title: String = "", bookUrl: String = "", baseUrl: String = "", index: Int = 0) {
        self.url = url
        self.title = title
        self.bookUrl = bookUrl
        self.baseUrl = baseUrl
        self.index = index
    }

    public var variable: String? {
        get { VariableCoding.encode(variableMap) }
        set { variableMap = VariableCoding.decode(newValue) }
    }
}

extension BookChapter: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(
            url: c.string("url") ?? "",
            title: c.string("title") ?? c.string("name") ?? "",
            bookUrl: c.string("bookUrl") ?? "",
            baseUrl: c.string("baseUrl") ?? "",
            index: c.int("index") ?? 0
        )
        isVolume = c.bool("isVolume") ?? false
        isVip = c.bool("isVip") ?? false
        isPay = c.bool("isPay") ?? false
        resourceUrl = c.string("resourceUrl")
        tag = c.string("tag") ?? c.string("updateTime")
        wordCount = c.string("wordCount")
        start = c.int64("start")
        end = c.int64("end")
        startFragmentId = c.string("startFragmentId")
        endFragmentId = c.string("endFragmentId")
        variable = c.string("variable")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(url, "url")
        try c.encode(title, "title")
        try c.encode(isVolume, "isVolume")
        try c.encode(baseUrl, "baseUrl")
        try c.encode(bookUrl, "bookUrl")
        try c.encode(index, "index")
        try c.encode(isVip, "isVip")
        try c.encode(isPay, "isPay")
        try c.encodeIfPresent(resourceUrl, "resourceUrl")
        try c.encodeIfPresent(tag, "tag")
        try c.encodeIfPresent(wordCount, "wordCount")
        try c.encodeIfPresent(start, "start")
        try c.encodeIfPresent(end, "end")
        try c.encodeIfPresent(startFragmentId, "startFragmentId")
        try c.encodeIfPresent(endFragmentId, "endFragmentId")
        try c.encodeIfPresent(variable, "variable")
    }
}

/// 变量表与 JSON 文本互转（Legado 中 `variable` 字段存的是 JSON 对象文本）
public enum VariableCoding {
    public static func encode(_ map: [String: String]) -> String? {
        guard !map.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String?) -> [String: String] {
        guard let text, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in obj {
            map[key] = JSONValue(foundation: value).stringValue ?? ""
        }
        return map
    }
}

public extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
