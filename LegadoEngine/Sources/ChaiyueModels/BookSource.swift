import Foundation

/// 书源类型（与 Legado `bookSourceType` 取值一致）
public enum BookSourceType: Int, Codable, Sendable, CaseIterable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
}

/// 书源。字段名与 Legado 导出格式保持一致，未识别字段原样保留。
public struct BookSource: Hashable, Sendable, Identifiable {
    public var bookSourceUrl: String
    public var bookSourceName: String
    public var bookSourceGroup: String?
    public var bookSourceType: Int = BookSourceType.text.rawValue
    public var bookSourceComment: String?
    public var variableComment: String?
    public var bookUrlPattern: String?
    public var customOrder: Int = 0
    public var enabled: Bool = true
    public var enabledExplore: Bool = true
    public var enabledCookieJar: Bool = true
    public var eventListener: Bool = false
    public var customButton: Bool = false
    /// 并发限制："n" 表示两次请求至少间隔 n 毫秒；"n/ms" 表示 ms 毫秒内最多 n 次请求
    public var concurrentRate: String?
    /// 请求头，JSON 文本或 `@js:`/`<js>` 脚本
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var jsLib: String?
    public var lastUpdateTime: Int64 = 0
    public var respondTime: Int64 = 180_000
    public var weight: Int = 0
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var searchUrl: String?
    public var ruleExplore: ExploreRule?
    public var ruleSearch: SearchRule?
    public var ruleBookInfo: BookInfoRule?
    public var ruleToc: TocRule?
    public var ruleContent: ContentRule?
    public var ruleReview: ReviewRule?
    /// 未识别字段
    public var extras: [String: JSONValue] = [:]

    public var id: String { bookSourceUrl }

    public var type: BookSourceType {
        BookSourceType(rawValue: bookSourceType) ?? .text
    }

    public init(bookSourceUrl: String, bookSourceName: String) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
    }

    /// 分组拆分（Legado 使用逗号、分号等分隔多个分组）
    public var groups: [String] {
        guard let group = bookSourceGroup else { return [] }
        return group
            .components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var hasExplore: Bool {
        !(exploreUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasLogin: Bool {
        !(loginUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var searchRule: SearchRule { ruleSearch ?? SearchRule() }
    public var exploreRule: ExploreRule { ruleExplore ?? ExploreRule() }
    public var bookInfoRule: BookInfoRule { ruleBookInfo ?? BookInfoRule() }
    public var tocRule: TocRule { ruleToc ?? TocRule() }
    public var contentRule: ContentRule { ruleContent ?? ContentRule() }
}

extension BookSource: Codable {
    private static let knownKeys: Set<String> = [
        "bookSourceUrl", "bookSourceName", "bookSourceGroup", "bookSourceType", "bookSourceComment",
        "variableComment", "bookUrlPattern", "customOrder", "enabled", "enabledExplore",
        "enabledCookieJar", "eventListener", "customButton", "concurrentRate", "header", "loginUrl",
        "loginUi", "loginCheckJs", "coverDecodeJs", "jsLib", "lastUpdateTime", "respondTime", "weight",
        "exploreUrl", "exploreScreen", "searchUrl", "ruleExplore", "ruleSearch", "ruleBookInfo",
        "ruleToc", "ruleContent", "ruleReview",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let url = c.string("bookSourceUrl"), !url.isEmpty else {
            throw DecodingError.keyNotFound(
                AnyCodingKey("bookSourceUrl"),
                .init(codingPath: decoder.codingPath, debugDescription: "书源缺少 bookSourceUrl")
            )
        }
        self.init(bookSourceUrl: url, bookSourceName: c.string("bookSourceName") ?? "")
        bookSourceGroup = c.string("bookSourceGroup")
        bookSourceType = c.int("bookSourceType") ?? 0
        bookSourceComment = c.string("bookSourceComment")
        variableComment = c.string("variableComment")
        bookUrlPattern = c.string("bookUrlPattern")
        customOrder = c.int("customOrder") ?? 0
        enabled = c.bool("enabled") ?? true
        enabledExplore = c.bool("enabledExplore") ?? true
        enabledCookieJar = c.bool("enabledCookieJar") ?? true
        eventListener = c.bool("eventListener") ?? false
        customButton = c.bool("customButton") ?? false
        concurrentRate = c.string("concurrentRate")
        header = c.string("header")
        loginUrl = c.string("loginUrl")
        loginUi = c.string("loginUi")
        loginCheckJs = c.string("loginCheckJs")
        coverDecodeJs = c.string("coverDecodeJs")
        jsLib = c.string("jsLib")
        lastUpdateTime = c.int64("lastUpdateTime") ?? 0
        respondTime = c.int64("respondTime") ?? 180_000
        weight = c.int("weight") ?? 0
        exploreUrl = c.string("exploreUrl")
        exploreScreen = c.string("exploreScreen")
        searchUrl = c.string("searchUrl")
        ruleExplore = c.object(ExploreRule.self, "ruleExplore")
        ruleSearch = c.object(SearchRule.self, "ruleSearch")
        ruleBookInfo = c.object(BookInfoRule.self, "ruleBookInfo")
        ruleToc = c.object(TocRule.self, "ruleToc")
        ruleContent = c.object(ContentRule.self, "ruleContent")
        ruleReview = c.object(ReviewRule.self, "ruleReview")
        extras = c.unknownFields(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeExtras(extras)
        try c.encode(bookSourceUrl, "bookSourceUrl")
        try c.encode(bookSourceName, "bookSourceName")
        try c.encodeIfPresent(bookSourceGroup, "bookSourceGroup")
        try c.encode(bookSourceType, "bookSourceType")
        try c.encodeIfPresent(bookSourceComment, "bookSourceComment")
        try c.encodeIfPresent(variableComment, "variableComment")
        try c.encodeIfPresent(bookUrlPattern, "bookUrlPattern")
        try c.encode(customOrder, "customOrder")
        try c.encode(enabled, "enabled")
        try c.encode(enabledExplore, "enabledExplore")
        try c.encode(enabledCookieJar, "enabledCookieJar")
        try c.encode(eventListener, "eventListener")
        try c.encode(customButton, "customButton")
        try c.encodeIfPresent(concurrentRate, "concurrentRate")
        try c.encodeIfPresent(header, "header")
        try c.encodeIfPresent(loginUrl, "loginUrl")
        try c.encodeIfPresent(loginUi, "loginUi")
        try c.encodeIfPresent(loginCheckJs, "loginCheckJs")
        try c.encodeIfPresent(coverDecodeJs, "coverDecodeJs")
        try c.encodeIfPresent(jsLib, "jsLib")
        try c.encode(lastUpdateTime, "lastUpdateTime")
        try c.encode(respondTime, "respondTime")
        try c.encode(weight, "weight")
        try c.encodeIfPresent(exploreUrl, "exploreUrl")
        try c.encodeIfPresent(exploreScreen, "exploreScreen")
        try c.encodeIfPresent(searchUrl, "searchUrl")
        try c.encodeIfPresent(ruleExplore, "ruleExplore")
        try c.encodeIfPresent(ruleSearch, "ruleSearch")
        try c.encodeIfPresent(ruleBookInfo, "ruleBookInfo")
        try c.encodeIfPresent(ruleToc, "ruleToc")
        try c.encodeIfPresent(ruleContent, "ruleContent")
        try c.encodeIfPresent(ruleReview, "ruleReview")
    }
}
