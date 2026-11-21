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
    ///
    /// ⚠️⚠️⚠️ **这是 Legado 的「站方变量」**（`source.getVariable()` / `source.setVariable(str)`）⭐⭐⭐
    ///   ⇒ 它是**一整串**（站方自己 `JSON.parse` 它拿 NH_D 之类）⇒ **不是 map** ⭐⭐⭐
    public var variable: String?
    /// ⭐⭐⭐⭐⭐ **书源变量**（`source.get(k)` / `source.put(k, v)`）—— **每个 k 一个独立项** ⭐⭐⭐
    ///
    /// ⚠️⚠️⚠️ **为什么必须与 `variable` 分开**（2026-11-19 移植 Chaiyue/柴阅 的 `SourceState` 实证）：
    ///   · Legado / 栖阅 / 柴阅：**站方变量**（一整串）与**书源变量**（每个 k 一格）是**两套** ⭐⭐⭐
    ///     · 柴阅：`sourceVariable_<key>`（整串） vs `v_<key>_<k>`（每 k 一格）⭐⭐⭐
    ///   · 之前把 `source.get(k)` 实现成「从 `variable` 这一格 JSON 里取某一项」⇒ **语义错位** ⭐⭐⭐
    ///     ⇒ 站方 `source.put('nhAuthed', h)` 写进去的项，会和站方变量的项**混在一起** ⭐⭐⭐
    ///     ⇒ 而宿主灌进 `variable` 的是**站方变量的整串** ⇒ `source.get("nhAuthed")` **读不到** ⭐⭐⭐
    ///     ⇒ 站方 `nhAuth()` 恒 false ⇒ **exploreUrl 主动交白卷** ⇒ **0 个分类** ⭐⭐⭐
    ///   ⇒ 现在：**书源变量独立一格** ⇒ 与 Legado/柴阅语义一致 ⇒ `get`/`put` 自洽且能持久 ⭐⭐⭐
    public var sourceVars: [String: String] = [:]
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
        // ⭐⭐⭐ **书源变量**（每 k 一项）—— 键名带前缀，避免和书源 JSON 字段撞名 ⭐⭐⭐
        if let m = try? c.decodeIfPresent([String: String].self, forKey: AnyCodingKey("__sourceVars")) {
            sourceVars = m
        }
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
        if !sourceVars.isEmpty {
            try c.encode(sourceVars, forKey: AnyCodingKey("__sourceVars"))
        }
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
    /// ⭐⭐⭐ **书源变量的某一项**（`source.get(k)`）—— **独立一格**，不与站方变量混 ⭐⭐⭐
    public func getVariable(key: String) -> String { sourceVars[key] ?? "" }
    public mutating func putVariable(key: String, value: String) {
        if value.isEmpty { sourceVars.removeValue(forKey: key) }
        else { sourceVars[key] = value }
    }
}