import Foundation

// MARK: - 规则字段

/// Legado 书源里的一个规则字段。
///
/// 站方书源写法非常松：一个字段可能是字符串、字符串数组、整数，甚至 null；
/// 还可能写成 `"规则A && 规则B"`（前者失败才用后者）或 `"规则A || 规则B"`（任一命中即可）。
/// 这里**原样保留**，拆分与回退逻辑全部交给 JS 侧的 `rule-analyzer.js` 处理，
/// Swift 只负责无损地把它送进沙盒、结果取回来。
enum RuleValue: Codable, Hashable {
    case none
    case text(String)
    case list([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .none; return }
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let a = try? c.decode([String].self) { self = .list(a); return }
        if let n = try? c.decode(Int.self) { self = .text(String(n)); return }
        if let b = try? c.decode(Bool.self) { self = .text(String(b)); return }
        // 实在认不出来的对象，序列化成 JSON 文本交给 JS 侧碰运气
        if let obj = try? c.decode(AnyCodable.self) {
            self = .text(String(data: (try? JSONEncoder().encode(obj)) ?? Data(), encoding: .utf8) ?? "")
            return
        }
        self = .none
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .none: try c.encodeNil()
        case .text(let s): try c.encode(s)
        case .list(let a): try c.encode(a)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .list(let a): return a.isEmpty
        }
    }

    /// 送进沙盒的原始文本（数组取第一项）
    var raw: String? {
        switch self {
        case .none: return nil
        case .text(let s): return s
        case .list(let a): return a.first
        }
    }

    /// 规则的所有候选分支（数组展开；字符串原样）
    var lines: [String] {
        switch self {
        case .none: return []
        case .text(let s): return [s]
        case .list(let a): return a
        }
    }
}

/// 用于容忍书源里出现的任意 JSON 值（对象/数组），避免解析直接炸掉。
struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let d = try? c.decode([String: AnyCodable].self) { value = d.mapValues(\.value) }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch v {
        case let x as Bool: try c.encode(x)
        case let x as Int: try c.encode(x)
        case let x as String: try c.encode(x)
        case let x as [Any]: try c.encode(x.map { AnyCodable(value: $0) })
        case let x as [String: Any]: try c.encode(x.mapValues { AnyCodable(value: $0) })
        default: try c.encodeNil()
        }
    }
    let value: Any
    init(value: Any) { self.value = value }
    var v: Any { value }
}

// MARK: - 规则组

/// 列表页规则。`ruleSearch` / `ruleExplore` 共用同一套字段定义。
struct ListRule: Codable, Hashable {
    var bookList: RuleValue = .none
    var name: RuleValue = .none
    var author: RuleValue = .none
    var intro: RuleValue = .none
    var kind: RuleValue = .none
    var lastChapter: RuleValue = .none
    var coverUrl: RuleValue = .none
    var bookUrl: RuleValue = .none
    var wordCount: RuleValue = .none
    var searchUrl: RuleValue = .none
    var exploreUrl: RuleValue = .none
    var selector: RuleValue = .none

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func g(_ k: K, _ d: RuleValue) -> RuleValue { (try? c.decodeIfPresent(RuleValue.self, forKey: k)) ?? d }
        bookList     = g(.bookList, .none);  name       = g(.name, .none)
        author       = g(.author, .none);    intro      = g(.intro, .none)
        kind         = g(.kind, .none);      lastChapter = g(.lastChapter, .none)
        coverUrl     = g(.coverUrl, .none);  bookUrl    = g(.bookUrl, .none)
        wordCount    = g(.wordCount, .none); searchUrl  = g(.searchUrl, .none)
        exploreUrl   = g(.exploreUrl, .none); selector  = g(.selector, .none)
    }
    private enum K: String, CodingKey {
        case bookList, name, author, intro, kind, lastChapter
        case coverUrl, bookUrl, wordCount, searchUrl, exploreUrl, selector
    }
}

struct BookInfoRule: Codable, Hashable {
    var name: RuleValue = .none
    var author: RuleValue = .none
    var intro: RuleValue = .none
    var kind: RuleValue = .none
    var lastChapter: RuleValue = .none
    var coverUrl: RuleValue = .none
    var tocUrl: RuleValue = .none
    var wordCount: RuleValue = .none
    var canReName: RuleValue = .none

    /// Legado 的 `ruleBookInfo.init`：在详情页结果上跑一次，
    /// **把输出当成后面所有字段规则的基准**。JSON 接口源几乎全靠它
    /// （`init: "$.data"` 把 `{code,msg,data:{…}}` 缩成 `{…}`）。
    ///
    /// ⚠️ Swift **不允许**存储属性取名 `init` —— 那是初始化器保留字，
    ///    编译器直接报错。所以属性叫 `initRule`，但对外的 JSON 键
    ///    必须仍是 `init`：`SourceService.call` 是
    ///    `AppEncoder.encode(source)` **重新编码**后才发给 JS 引擎的，
    ///    键名对不上引擎就永远看不到这条规则（实测「免费追书」书源
    ///    详情页所有字段全空）。解码走 K，编码走 CodingKeys，两边都是 `init`。
    var initRule: RuleValue = .none

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func g(_ k: K, _ d: RuleValue) -> RuleValue { (try? c.decodeIfPresent(RuleValue.self, forKey: k)) ?? d }
        name = g(.name, .none);       author     = g(.author, .none)
        intro = g(.intro, .none);     kind       = g(.kind, .none)
        lastChapter = g(.lastChapter, .none); coverUrl = g(.coverUrl, .none)
        tocUrl = g(.tocUrl, .none);   wordCount  = g(.wordCount, .none)
        canReName = g(.canReName, .none)
        initRule = g(.initRule, .none)
    }
    private enum K: String, CodingKey {
        case name, author, intro, kind, lastChapter, coverUrl, tocUrl, wordCount, canReName
        case initRule = "init"
    }
    /// 合成 `encode(to:)` 用的键名；Swift 会优先找 CodingKeys。
    enum CodingKeys: String, CodingKey {
        case name, author, intro, kind, lastChapter, coverUrl, tocUrl, wordCount, canReName
        case initRule = "init"
    }
}

struct TocRule: Codable, Hashable {
    var chapterList: RuleValue = .none
    var chapterName: RuleValue = .none
    var chapterUrl: RuleValue = .none
    var chapterContent: RuleValue = .none
    var formatJs: RuleValue = .none
    var isVolume: RuleValue = .none
    var isVip: RuleValue = .none
    var isPay: RuleValue = .none
    var nextTocUrl: RuleValue = .none
    var prefetchTocUrl: RuleValue = .none
    var updateTime: RuleValue = .none

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func g(_ k: K, _ d: RuleValue) -> RuleValue { (try? c.decodeIfPresent(RuleValue.self, forKey: k)) ?? d }
        chapterList   = g(.chapterList, .none);   chapterName   = g(.chapterName, .none)
        chapterUrl    = g(.chapterUrl, .none);    chapterContent = g(.chapterContent, .none)
        formatJs      = g(.formatJs, .none);      isVolume      = g(.isVolume, .none)
        isVip         = g(.isVip, .none);         isPay         = g(.isPay, .none)
        nextTocUrl    = g(.nextTocUrl, .none);    prefetchTocUrl = g(.prefetchTocUrl, .none)
        updateTime    = g(.updateTime, .none)
    }
    private enum K: String, CodingKey {
        case chapterList, chapterName, chapterUrl, chapterContent, formatJs
        case isVolume, isVip, isPay, nextTocUrl, prefetchTocUrl, updateTime
    }
}

struct ContentRule: Codable, Hashable {
    var content: RuleValue = .none
    var title: RuleValue = .none
    var nextContentUrl: RuleValue = .none
    var webJs: RuleValue = .none
    var sourceRegex: RuleValue = .none
    var replaceRegex: RuleValue = .none
    var imageStyle: RuleValue = .none
    var imageDecode: RuleValue = .none

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func g(_ k: K, _ d: RuleValue) -> RuleValue { (try? c.decodeIfPresent(RuleValue.self, forKey: k)) ?? d }
        content     = g(.content, .none);   title         = g(.title, .none)
        nextContentUrl = g(.nextContentUrl, .none)
        webJs       = g(.webJs, .none);     sourceRegex   = g(.sourceRegex, .none)
        replaceRegex = g(.replaceRegex, .none)
        imageStyle  = g(.imageStyle, .none); imageDecode  = g(.imageDecode, .none)
    }
    private enum K: String, CodingKey {
        case content, title, nextContentUrl, webJs, sourceRegex, replaceRegex, imageStyle, imageDecode
    }
}

// MARK: - 书源

struct BookSource: Codable, Identifiable, Hashable {
    var id: String { bookSourceUrl }
    var bookSourceUrl: String = ""
    var bookSourceName: String = ""
    var bookSourceGroup: String = ""
    var bookSourceComment: String = ""
    var bookSourceType: Int = 0
    var enabled: Bool = true
    var enabledExplore: Bool = true
    var enabledCookieJar: Bool = true
    var header: String? = nil
    var jsLib: String? = nil
    var loginUrl: String? = nil
    /// 登录界面（Legado 的 loginUi，JSON 串）。
    /// ⚠️ 以前**没这个字段** → 导入时被整个丢掉 →
    ///    站方 JS 里 `source.loginUi` 拿不到（checkEnv 靠它判环境）。
    var loginUi: String? = nil
    var bookUrlPattern: String? = nil
    var lastUpdateTime: Double = 0
    /// ⚠️ Legado 里 searchUrl / exploreUrl 是**顶层字段**，
    /// 不在 ruleSearch / ruleExplore 里面（实测 9060 个源：顶层 7339 条，
    /// ruleSearch 里 0 条）。漏了这两个，搜索和发现会整个静默失效。
    var searchUrl: String? = nil
    var exploreUrl: String? = nil

    var ruleSearch: ListRule = ListRule()
    var ruleExplore: ListRule = ListRule()
    var ruleBookInfo: BookInfoRule = BookInfoRule()
    var ruleToc: TocRule = TocRule()
    var ruleContent: ContentRule = ContentRule()

    /// 必须自己写，不能用编译器合成的。
    /// 合成的 init(from:) **不使用属性默认值** —— 少任何一个键就 keyNotFound 整个解码失败。
    /// 而真实书源经常缺 enabledCookieJar / bookSourceType / jsLib 之类的字段。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func g<T: Decodable>(_ k: K, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        bookSourceUrl  = g(.bookSourceUrl, "")
        bookSourceName = g(.bookSourceName, "")
        bookSourceGroup = g(.bookSourceGroup, "")
        bookSourceComment = g(.bookSourceComment, "")
        // 站方有人写 "bookSourceType": "0"（字符串），Int 收不住，兜一层
        bookSourceType = (try? c.decodeIfPresent(Int.self, forKey: .bookSourceType))
            ?? (try? c.decodeIfPresent(String.self, forKey: .bookSourceType)).flatMap { Int($0) }
            ?? 0
        enabled = g(.enabled, true)
        enabledExplore = g(.enabledExplore, true)
        enabledCookieJar = g(.enabledCookieJar, true)
        header = (try? c.decodeIfPresent(String.self, forKey: .header)) ?? nil
        jsLib = (try? c.decodeIfPresent(String.self, forKey: .jsLib)) ?? nil
        loginUrl = (try? c.decodeIfPresent(String.self, forKey: .loginUrl)) ?? nil
        loginUi = (try? c.decodeIfPresent(String.self, forKey: .loginUi)) ?? nil
        bookUrlPattern = (try? c.decodeIfPresent(String.self, forKey: .bookUrlPattern)) ?? nil
        lastUpdateTime = g(.lastUpdateTime, 0)
        searchUrl  = (try? c.decodeIfPresent(String.self, forKey: .searchUrl)) ?? nil
        exploreUrl = (try? c.decodeIfPresent(String.self, forKey: .exploreUrl)) ?? nil

        ruleSearch   = (try? c.decodeIfPresent(ListRule.self, forKey: .ruleSearch)) ?? ListRule()
        ruleExplore  = (try? c.decodeIfPresent(ListRule.self, forKey: .ruleExplore)) ?? ListRule()
        ruleBookInfo = (try? c.decodeIfPresent(BookInfoRule.self, forKey: .ruleBookInfo)) ?? BookInfoRule()
        ruleToc      = (try? c.decodeIfPresent(TocRule.self, forKey: .ruleToc)) ?? TocRule()
        ruleContent  = (try? c.decodeIfPresent(ContentRule.self, forKey: .ruleContent)) ?? ContentRule()
    }

    private enum K: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceComment
        case bookSourceType, enabled, enabledExplore, enabledCookieJar
        case header, jsLib, loginUrl, loginUi, bookUrlPattern, lastUpdateTime
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
        // searchUrl / exploreUrl 是顶层字段（实测都在顶层，不在 ruleSearch 里）
        case searchUrl, exploreUrl
    }

    var name: String { bookSourceName.isEmpty ? bookSourceUrl : bookSourceName }
    var sourceIconURL: String? { bookSourceUrl.isEmpty ? nil : URL(string: bookSourceUrl)?.host.map { "https://favicon.im/\($0)" } }

    /// 展示用的分组，Legado 允许用 `,` 分多层
    var groupPath: [String] {
        bookSourceGroup.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// 导入的书源文件：一个 JSON 对象、对象数组，或换行/花括号拼起来的多个。
enum BookSourceParser {
    /// 失败时把真实原因带出来 —— 「没解析出书源」这种报错等于没报。
    static func parse(_ data: Data) throws -> [BookSource] {
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceImportError.diagnose("文件是空的") }
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            throw SourceImportError.diagnose(
                "不是 JSON 开头（开头是 \"\(prefix(trimmed, 20))\"）。文件可能不是书源，或者下载坏了。")
        }

        let decoder = JSONDecoder()
        var why: [String] = []

        // 1) 整体是数组
        do { let a = try decoder.decode([BookSource].self, from: data); if !a.isEmpty { return a } }
        catch { why.append("当数组解析：" + short(error)) }

        // 2) 整体是单个对象
        do { return [try decoder.decode(BookSource.self, from: data)] }
        catch { why.append("当对象解析：" + short(error)) }

        // 3) 多对象拼接 / 逐行 JSON
        var out: [BookSource] = []
        for chunk in splitConcatenatedJSON(trimmed) {
            guard let d = chunk.data(using: .utf8) else { continue }
            if let a = try? decoder.decode([BookSource].self, from: d) { out.append(contentsOf: a) }
            else if let s = try? decoder.decode(BookSource.self, from: d) { out.append(s) }
        }
        if !out.isEmpty { return out }

        throw SourceImportError.diagnose(
            "解析失败：\n" + why.joined(separator: "\n")
            + "\n\n文件开头：\n" + prefix(trimmed, 240))
    }

    private static func short(_ e: Error) -> String {
        let m = (e as NSError).localizedDescription
        return m.count > 160 ? String(m.prefix(160)) + "…" : m
    }
    private static func prefix(_ s: String, _ n: Int) -> String {
        String(s.prefix(n))
    }

    /// 把 `{...}{...}` / 一行一个 JSON 这类文本切成若干完整 JSON 值。
    /// 走括号配对而不是正则，避免书源里嵌套的 `{` `}` 把边界切错。
    private static func splitConcatenatedJSON(_ text: String) -> [String] {
        var chunks: [String] = []
        var depth = 0, inStr = false, esc = false, start: String.Index? = nil
        for (i, ch) in text.enumerated() {
            let idx = text.index(text.startIndex, offsetBy: i)
            if esc { esc = false; continue }
            if ch == "\\" && inStr { esc = true; continue }
            if ch == "\"" { inStr.toggle(); continue }
            guard !inStr else { continue }
            if ch == "{" || ch == "[" {
                if depth == 0 { start = idx }
                depth += 1
            } else if ch == "}" || ch == "]" {
                depth -= 1
                if depth <= 0, let s = start {
                    chunks.append(String(text[s...idx]))
                    depth = 0; start = nil
                }
            }
        }
        return chunks
    }

    enum SourceImportError: LocalizedError {
        case empty, unparsable
        case diagnose(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "文件是空的"
            case .unparsable: return "没解析出书源，请确认是 Legado 书源 JSON"
            case .diagnose(let m): return m
            }
        }
    }
}
