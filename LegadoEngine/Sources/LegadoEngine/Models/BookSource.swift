import Foundation

/// Legado 3.0 compatible book source. JSON schema matches gedoor/legado BookSource.
public struct BookSource: Codable, Hashable, Identifiable {
    public var bookSourceUrl: String = ""
    public var bookSourceName: String = ""
    public var bookSourceGroup: String?
    /// 0 = text novel, 1 = audio, 2 = image/manga, 3 = video/file
    public var bookSourceType: Int = 0
    public var bookUrlPattern: String?
    public var customOrder: Int = 0
    public var enabled: Bool = true
    public var enabledExplore: Bool = true
    public var jsLib: String?
    public var enabledCookieJar: Bool = true
    public var concurrentRate: String?
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var bookSourceComment: String?
    public var lastUpdateTime: Int64 = 0
    public var respondTime: Int = 180_000
    public var weight: Int = 0
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var searchUrl: String?
    public var ruleExplore: ExploreRule?
    public var ruleSearch: SearchRule?
    public var ruleBookInfo: BookInfoRule?
    public var ruleToc: TocRule?
    public var ruleContent: ContentRule?
    public var coverDecodeJs: String?
    public var variableComment: String?
    /// persisted source-level custom variables (JSON object string)
    public var variable: String?
    public var eventListener: String?

    public var id: String { bookSourceUrl }

    public init() {}
    public init(bookSourceUrl: String, bookSourceName: String) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
    }

    public func getSourceKey() -> String { bookSourceUrl }
    public var isHttpSource: Bool { bookSourceType == 0 && !bookSourceUrl.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        func s(_ k: String) -> String? { c.lenientString(AnyCodingKey(k)) }
        func i(_ k: String) -> Int? { c.lenientInt(AnyCodingKey(k)) }
        func b(_ k: String) -> Bool? { c.lenientBool(AnyCodingKey(k)) }
        bookSourceUrl = s("bookSourceUrl") ?? ""
        bookSourceName = s("bookSourceName") ?? ""
        bookSourceGroup = s("bookSourceGroup")
        bookSourceType = i("bookSourceType") ?? 0
        bookUrlPattern = s("bookUrlPattern")
        customOrder = i("customOrder") ?? 0
        enabled = b("enabled") ?? true
        enabledExplore = b("enabledExplore") ?? true
        jsLib = s("jsLib")
        enabledCookieJar = b("enabledCookieJar") ?? true
        concurrentRate = s("concurrentRate")
        header = s("header")
        loginUrl = s("loginUrl")
        loginUi = s("loginUi")
        loginCheckJs = s("loginCheckJs")
        bookSourceComment = s("bookSourceComment")
        lastUpdateTime = c.lenientInt64(AnyCodingKey("lastUpdateTime")) ?? 0
        respondTime = i("respondTime") ?? 180_000
        weight = i("weight") ?? 0
        exploreUrl = s("exploreUrl")
        exploreScreen = s("exploreScreen")
        searchUrl = s("searchUrl")
        ruleExplore = try? c.decodeIfPresent(ExploreRule.self, forKey: AnyCodingKey("ruleExplore"))
        ruleSearch = try? c.decodeIfPresent(SearchRule.self, forKey: AnyCodingKey("ruleSearch"))
        ruleBookInfo = try? c.decodeIfPresent(BookInfoRule.self, forKey: AnyCodingKey("ruleBookInfo"))
        ruleToc = try? c.decodeIfPresent(TocRule.self, forKey: AnyCodingKey("ruleToc"))
        ruleContent = try? c.decodeIfPresent(ContentRule.self, forKey: AnyCodingKey("ruleContent"))
        coverDecodeJs = s("coverDecodeJs")
        variableComment = s("variableComment")
        variable = s("variable")
        eventListener = s("eventListener")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        func e(_ v: String?, _ k: String) throws { if let v, !v.isEmpty { try c.encode(v, forKey: AnyCodingKey(k)) } }
        try c.encode(bookSourceUrl, forKey: AnyCodingKey("bookSourceUrl"))
        try c.encode(bookSourceName, forKey: AnyCodingKey("bookSourceName"))
        try e(bookSourceGroup, "bookSourceGroup")
        try c.encode(bookSourceType, forKey: AnyCodingKey("bookSourceType"))
        try e(bookUrlPattern, "bookUrlPattern")
        try c.encode(customOrder, forKey: AnyCodingKey("customOrder"))
        try c.encode(enabled, forKey: AnyCodingKey("enabled"))
        try c.encode(enabledExplore, forKey: AnyCodingKey("enabledExplore"))
        try e(jsLib, "jsLib")
        try c.encode(enabledCookieJar, forKey: AnyCodingKey("enabledCookieJar"))
        try e(concurrentRate, "concurrentRate")
        try e(header, "header")
        try e(loginUrl, "loginUrl")
        try e(loginUi, "loginUi")
        try e(loginCheckJs, "loginCheckJs")
        try e(bookSourceComment, "bookSourceComment")
        try c.encode(lastUpdateTime, forKey: AnyCodingKey("lastUpdateTime"))
        try c.encode(respondTime, forKey: AnyCodingKey("respondTime"))
        try c.encode(weight, forKey: AnyCodingKey("weight"))
        try e(exploreUrl, "exploreUrl")
        try e(exploreScreen, "exploreScreen")
        try e(searchUrl, "searchUrl")
        try c.encodeIfPresent(ruleExplore, forKey: AnyCodingKey("ruleExplore"))
        try c.encodeIfPresent(ruleSearch, forKey: AnyCodingKey("ruleSearch"))
        try c.encodeIfPresent(ruleBookInfo, forKey: AnyCodingKey("ruleBookInfo"))
        try c.encodeIfPresent(ruleToc, forKey: AnyCodingKey("ruleToc"))
        try c.encodeIfPresent(ruleContent, forKey: AnyCodingKey("ruleContent"))
        try e(coverDecodeJs, "coverDecodeJs")
        try e(variableComment, "variableComment")
        try e(variable, "variable")
        try e(eventListener, "eventListener")
    }

    /// Parse a single source or an array of sources from JSON data.
    public static func parse(_ data: Data) throws -> [BookSource] {
        let dec = JSONDecoder()
        if let arr = try? dec.decode([BookSource].self, from: data) { return arr }
        if let one = try? dec.decode(BookSource.self, from: data) { return [one] }
        throw LegadoError("无法解析书源 JSON")
    }

    // MARK: source-level variable persistence (in-memory; host app may persist `variable`)

    public func getVariable() -> String { variable ?? "" }
    public mutating func setVariable(_ v: String) { variable = v }
    public func getVariable(key: String) -> String {
        guard let data = (variable ?? "").data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return obj[key].map { "\($0)" } ?? ""
    }
    public mutating func putVariable(key: String, value: String) {
        var obj: [String: Any] = [:]
        if let data = (variable ?? "").data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = o }
        obj[key] = value
        if let d = try? JSONSerialization.data(withJSONObject: obj) { variable = String(data: d, encoding: .utf8) }
    }
}