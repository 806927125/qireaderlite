import Foundation
import Kanna
import SwiftSoup

/// 规则解析入口（对应 Legado AnalyzeRule）。单线程使用。
final class AnalyzeRule {
    unowned let session: RuleSession
    /// 变量持有者：书籍/搜索结果/RuleData
    var ruleData: VariableHolder?
    var chapter: ChapterRef?
    private(set) var content: Any?
    private(set) var baseUrl: String?
    private(set) var redirectUrl: String?
    var nextChapterUrl: String?
    private(set) var isJSON = false
    /// AllInOne 正则列表之后，字段规则也按正则模式解析
    private(set) var isRegex = false

    private var contentToken = 0
    private var jsoupCache: (Int, AnalyzeByJSoup)?
    private var jsonCache: (Int, AnalyzeByJSONPath)?
    private var xpathCache: (Int, AnalyzeByXPath)?
    private var ruleCache: [String: [SourceRule]] = [:]

    init(session: RuleSession, ruleData: VariableHolder? = nil) {
        self.session = session
        self.ruleData = ruleData
    }

    var book: BookRef? { ruleData as? BookRef }

    @discardableResult
    func setContent(_ content: Any?, baseUrl: String? = nil) throws -> AnalyzeRule {
        guard let content else { throw RuleError.message("内容不可空（Content cannot be null）") }
        self.content = content
        isJSON = RuleValue.isJSON(content)
        if let baseUrl { setBaseUrl(baseUrl) }
        contentToken += 1
        return self
    }

    @discardableResult
    func setBaseUrl(_ url: String?) -> AnalyzeRule {
        if let url { baseUrl = url }
        return self
    }

    @discardableResult
    func setRedirectUrl(_ url: String?) -> AnalyzeRule {
        if let url, !url.isEmpty { redirectUrl = url }
        return self
    }

    // MARK: - 解析器缓存

    private func jsoup(_ value: Any, isContent: Bool) -> AnalyzeByJSoup {
        if isContent, let (token, cached) = jsoupCache, token == contentToken { return cached }
        let analyzer = AnalyzeByJSoup(value)
        if isContent { jsoupCache = (contentToken, analyzer) }
        return analyzer
    }

    private func jsonPath(_ value: Any, isContent: Bool) -> AnalyzeByJSONPath {
        if isContent, let (token, cached) = jsonCache, token == contentToken { return cached }
        let analyzer = AnalyzeByJSONPath(value)
        if isContent { jsonCache = (contentToken, analyzer) }
        return analyzer
    }

    private func xpath(_ value: Any, isContent: Bool) -> AnalyzeByXPath {
        if isContent, let (token, cached) = xpathCache, token == contentToken { return cached }
        let analyzer = AnalyzeByXPath(value)
        if isContent { xpathCache = (contentToken, analyzer) }
        return analyzer
    }

    // MARK: - 规则拆分

    /// 按 `<js>`/`@js:` 拆分规则
    func splitSourceRule(_ ruleStr: String?, allInOne: Bool = false) -> [SourceRule] {
        guard let ruleStr, !ruleStr.isEmpty else { return [] }
        var mode: RuleMode = .defaultMode
        var start = 0
        if allInOne, ruleStr.hasPrefix(":") {
            mode = .regex
            isRegex = true
            start = 1
        } else if isRegex {
            mode = .regex
        }
        var list: [SourceRule] = []
        let ns = ruleStr as NSString
        if let re = try? RegexCache.shared.regex(SourceRule.jsPattern) {
            for m in re.matches(in: ruleStr, range: ruleStr.fullRange) {
                if m.range.location > start {
                    let tmp = ns.substring(with: NSRange(location: start, length: m.range.location - start)).trimmedControl
                    if !tmp.isEmpty { list.append(SourceRule(tmp, mode: mode, isJSON: isJSON)) }
                }
                let js = ruleStr.group(m, 2) ?? ruleStr.group(m, 1) ?? ""
                list.append(SourceRule(js, mode: .js, isJSON: isJSON))
                start = m.range.location + m.range.length
            }
        }
        if ns.length > start {
            let tmp = ns.substring(from: start).trimmedControl
            if !tmp.isEmpty { list.append(SourceRule(tmp, mode: mode, isJSON: isJSON)) }
        }
        return list
    }

    // MARK: - 字符串列表

    func getStringList(_ rule: String?, content mContent: Any? = nil, isUrl: Bool = false) throws -> [String]? {
        guard let rule, !rule.isEmpty else { return nil }
        return try getStringList(splitSourceRule(rule), content: mContent, isUrl: isUrl)
    }

    func getStringList(_ ruleList: [SourceRule], content mContent: Any? = nil, isUrl: Bool = false) throws -> [String]? {
        var result: Any?
        let content = mContent ?? self.content
        if let content, !ruleList.isEmpty {
            result = content
            var isOriginal = mContent == nil
            for sourceRule in ruleList {
                try putRule(sourceRule.putMap)
                try sourceRule.makeUpRule(result, analyzer: self)
                guard let current = result else { break }
                if !sourceRule.rule.isEmpty {
                    if let direct = directValue(current, sourceRule) {
                        result = direct
                    } else {
                        switch sourceRule.mode {
                        case .js: result = try evalJS(sourceRule.rule, result: current)
                        case .json: result = jsonPath(current, isContent: isOriginal).getStringList(sourceRule.rule)
                        case .xpath: result = xpath(current, isContent: isOriginal).getStringList(sourceRule.rule)
                        case .defaultMode: result = jsoup(current, isContent: isOriginal).getStringList(sourceRule.rule)
                        case .regex: result = sourceRule.rule
                        }
                    }
                }
                isOriginal = false
                if !sourceRule.replaceRegex.isEmpty {
                    if let list = result as? [Any] {
                        result = list.map { replaceRegex(RuleValue.text(of: $0), sourceRule) }
                    } else {
                        result = replaceRegex(RuleValue.text(of: result), sourceRule)
                    }
                }
            }
        }
        guard let result else { return nil }
        var list: [String]
        switch result {
        case let s as String:
            list = s.components(separatedBy: "\n")
        case let strings as [String]:
            list = strings
        case let arr as [Any]:
            list = arr.map { RuleValue.jsString($0) ?? "" }
        default:
            list = [RuleValue.text(of: result)]
        }
        if isUrl {
            var urls: [String] = []
            for item in list {
                let abs = URLUtils.absoluteURL(base: redirectUrl, relative: item)
                if !abs.isEmpty, !urls.contains(abs) { urls.append(abs) }
            }
            return urls
        }
        return list
    }

    // MARK: - 字符串

    func getString(_ rule: String?, content mContent: Any? = nil, isUrl: Bool = false, unescape: Bool = true) throws -> String {
        guard let rule, !rule.isEmpty else {
            return isUrl ? (baseUrl ?? "") : ""
        }
        return try getString(splitSourceRule(rule), content: mContent, isUrl: isUrl, unescape: unescape)
    }

    func getString(_ ruleList: [SourceRule], content mContent: Any? = nil, isUrl: Bool = false, unescape: Bool = true) throws -> String {
        var result: Any?
        let content = mContent ?? self.content
        if let content, !ruleList.isEmpty {
            result = content
            var isOriginal = mContent == nil
            for sourceRule in ruleList {
                try putRule(sourceRule.putMap)
                try sourceRule.makeUpRule(result, analyzer: self)
                guard let current = result else { break }
                if !sourceRule.rule.isBlank || sourceRule.replaceRegex.isEmpty {
                    if let direct = directValue(current, sourceRule) {
                        result = direct
                    } else {
                        switch sourceRule.mode {
                        case .js: result = try evalJS(sourceRule.rule, result: current)
                        case .json: result = jsonPath(current, isContent: isOriginal).getString(sourceRule.rule)
                        case .xpath: result = xpath(current, isContent: isOriginal).getString(sourceRule.rule)
                        case .defaultMode:
                            let analyzer = jsoup(current, isContent: isOriginal)
                            result = isUrl ? analyzer.getString0(sourceRule.rule) : analyzer.getString(sourceRule.rule)
                        case .regex: result = sourceRule.rule
                        }
                    }
                }
                isOriginal = false
                if result != nil, !sourceRule.replaceRegex.isEmpty {
                    result = replaceRegex(RuleValue.jsString(result) ?? "", sourceRule)
                }
            }
        }
        var str = RuleValue.jsString(result) ?? ""
        if unescape, str.contains("&") {
            str = HTMLEntities.unescape(str)
        }
        if isUrl {
            return str.isBlank ? (baseUrl ?? "") : URLUtils.absoluteURL(base: redirectUrl, relative: str)
        }
        return str
    }

    /// JS 返回的对象作为内容时，非 JSONPath 规则按属性名直接取值（与 Rhino NativeObject 行为一致）
    private func directValue(_ current: Any, _ rule: SourceRule) -> Any? {
        guard rule.mode != .js, rule.mode != .regex,
              let dict = current as? [String: Any],
              let value = dict[rule.rule] else { return nil }
        if value is NSNull { return "" }
        return value
    }

    // MARK: - 元素

    func getElement(_ rule: String?) throws -> Any? {
        guard let rule, !rule.isEmpty else { return nil }
        var result: Any?
        let ruleList = splitSourceRule(rule, allInOne: true)
        if let content, !ruleList.isEmpty {
            result = content
            var isOriginal = true
            for sourceRule in ruleList {
                try putRule(sourceRule.putMap)
                try sourceRule.makeUpRule(result, analyzer: self)
                guard let current = result else { break }
                switch sourceRule.mode {
                case .regex: result = AnalyzeByRegex.getElement(RuleValue.text(of: current), sourceRule.rule.splitNotBlank("&&"))
                case .js: result = try evalJS(sourceRule.rule, result: current)
                case .json: result = jsonPath(current, isContent: isOriginal).getObject(sourceRule.rule)
                case .xpath: result = xpath(current, isContent: isOriginal).getElements(sourceRule.rule)
                case .defaultMode: result = jsoup(current, isContent: isOriginal).getElements(sourceRule.rule)
                }
                isOriginal = false
                if !sourceRule.replaceRegex.isEmpty {
                    result = replaceRegex(RuleValue.text(of: result), sourceRule)
                }
            }
        }
        return result
    }

    func getElements(_ rule: String?) throws -> [Any] {
        guard let rule, !rule.isEmpty else { return [] }
        var result: Any?
        let ruleList = splitSourceRule(rule, allInOne: true)
        if let content, !ruleList.isEmpty {
            result = content
            var isOriginal = true
            for sourceRule in ruleList {
                try putRule(sourceRule.putMap)
                try sourceRule.makeUpRule(result, analyzer: self)
                guard let current = result else { break }
                switch sourceRule.mode {
                case .regex: result = AnalyzeByRegex.getElements(RuleValue.text(of: current), sourceRule.rule.splitNotBlank("&&"))
                case .js: result = try evalJS(sourceRule.rule, result: current)
                case .json: result = jsonPath(current, isContent: isOriginal).getList(sourceRule.rule)
                case .xpath: result = xpath(current, isContent: isOriginal).getElements(sourceRule.rule)
                case .defaultMode: result = jsoup(current, isContent: isOriginal).getElements(sourceRule.rule)
                }
                isOriginal = false
                if !sourceRule.replaceRegex.isEmpty {
                    if let list = result as? [Any] {
                        result = list.map { replaceRegex(RuleValue.text(of: $0), sourceRule) }
                    } else {
                        result = replaceRegex(RuleValue.text(of: result), sourceRule)
                    }
                }
            }
        }
        switch result {
        case let list as [Any]: return list
        case let s as String where s.isJsonArray:
            return LenientJSON.array(s) ?? []
        default: return []
        }
    }

    // MARK: - 替换与变量

    func replaceRegex(_ text: String, _ rule: SourceRule) -> String {
        guard !rule.replaceRegex.isEmpty else { return text }
        if rule.replaceFirst {
            guard let re = try? RegexCache.shared.regex(rule.replaceRegex) else { return rule.replacement }
            guard let m = re.firstMatch(in: text, range: text.fullRange) else { return "" }
            return text.substring(with: m.range).replacingFirstRegex(rule.replaceRegex, with: rule.replacement)
        }
        return text.replacingRegex(rule.replaceRegex, with: rule.replacement)
    }

    private func putRule(_ map: [String: String]) throws {
        for (key, value) in map {
            put(key, try getString(value))
        }
    }

    @discardableResult
    func put(_ key: String, _ value: String) -> String {
        if let chapter {
            chapter.putVariable(key, value)
        } else if let ruleData {
            ruleData.putVariable(key, value)
        } else {
            session.sourcePut(key, value)
        }
        return value
    }

    func get(_ key: String) -> String {
        switch key {
        case "bookName":
            if let book { return book.book.name }
        case "title":
            if let chapter { return chapter.chapter.title }
        default:
            break
        }
        if let v = chapter?.getVariable(key), !v.isEmpty { return v }
        if let v = ruleData?.getVariable(key), !v.isEmpty { return v }
        let v = session.sourceGet(key)
        return v
    }

    // MARK: - JS

    func evalJS(_ script: String, result: Any?) throws -> Any? {
        var bindings = JSBindings(host: self)
        bindings.result = result
        bindings.baseUrl = baseUrl
        bindings.src = content
        bindings.book = book
        bindings.chapter = chapter
        bindings.title = chapter?.chapter.title
        bindings.nextChapterUrl = nextChapterUrl
        return try session.evalJS(script, bindings: bindings)
    }
}

extension AnalyzeRule: JSAnalyzerHost {
    var hostRuleData: VariableHolder? { ruleData }
    var hostChapter: ChapterRef? { chapter }

    func jsGetString(_ rule: String, content: Any?, isUrl: Bool) throws -> String {
        try getString(rule, content: content, isUrl: isUrl)
    }

    func jsGetStringList(_ rule: String, content: Any?, isUrl: Bool) throws -> [String] {
        try getStringList(rule, content: content, isUrl: isUrl) ?? []
    }

    func jsGetElements(_ rule: String) throws -> [Any] {
        try getElements(rule)
    }

    func jsGetElement(_ rule: String) throws -> Any? {
        try getElement(rule)
    }

    func jsSetContent(_ content: Any?, baseUrl: String?) throws {
        _ = try setContent(content, baseUrl: baseUrl)
    }

    func jsPut(_ key: String, _ value: String) -> String { put(key, value) }
    func jsGet(_ key: String) -> String { get(key) }
}

public enum RuleError: Error, CustomStringConvertible, LocalizedError {
    case message(String)
    case js(String)
    case network(String)
    case cancelled

    public var description: String {
        switch self {
        case .message(let m): return m
        case .js(let m): return "JS 错误：\(m)"
        case .network(let m): return "网络错误：\(m)"
        case .cancelled: return "已取消"
        }
    }

    public var errorDescription: String? { description }
}
