import Foundation
import SwiftSoup

/// 规则解析核心（语义对齐 Legado AnalyzeRule）。
public final class AnalyzeRule {
    public var content: Any?
    public var book: Book?
    public var chapter: BookChapter?
    public var source: BookSource?
    public var key: String?
    public var page: Int?
    public var baseUrl: String?
    public var nextChapterUrl: String?
    public var redirectUrl: String?
    public let variables: RuleVariables
    public var writesToSource: Bool = false

    private var bridge: JSBridge?
    private var isJSON = false
    private var cachedDefault: ByDefault?
    private var cachedXPath: ByXPath?
    private var cachedJSON: ByJSONPath?

    // 原二进制提取的精确常量
    static let evalPattern = try! NSRegularExpression(pattern: "@get:\\{[^}]+?\\}|\\{\\{[\\w\\W]*?\\}\\}")
    static let putPattern = try! NSRegularExpression(pattern: "@put:(\\{[^}]+?\\})")
    static let jsPattern = try! NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", options: [.caseInsensitive])

    public enum Mode { case defaultMode, jsoup, jsonPath, xPath, regex }
    public struct SourceRule {
        public var rule: String
        public var mode: Mode
        public var replaceRegex: [String] = []
        public var replacement: String = ""
        public var replaceFirst: Bool = false
    }

    public init(book: Book? = nil, source: BookSource? = nil, variables: RuleVariables? = nil) {
        self.book = book
        self.source = source
        self.variables = variables ?? RuleVariables()
        if let v = source?.variable, !v.isEmpty { self.variables.putVariable(v) }
    }

    @discardableResult
    public func setContent(_ content: Any?, baseUrl: String? = nil) -> AnalyzeRule {
        self.content = content
        if let baseUrl { self.baseUrl = baseUrl }
        cachedDefault = nil; cachedXPath = nil; cachedJSON = nil
        isJSON = false
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            isJSON = t.hasPrefix("{") || t.hasPrefix("[")
        } else if content is [String: Any] || content is [Any] {
            isJSON = true
        }
        return self
    }

    // MARK: - 公开求值

    public func getString(_ rule: String?, isUrl: Bool = false, unescape: Bool = true) throws -> String {
        guard let rule, !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let splitter = RuleSplitter()
        let parts = splitter.splitRule(rule, "&&", "||", "%%")
        var result: String
        if parts.count <= 1 {
            result = try getStringSingle(rule, isUrl: isUrl, unescape: unescape)
        } else {
            switch splitter.elementsType {
            case "||":
                result = ""
                for p in parts {
                    let v = try getStringSingle(p, isUrl: isUrl, unescape: unescape)
                    if !v.isEmpty { result = v; break }
                }
            case "&&":
                var acc = ""
                for p in parts {
                    let v = try getStringSingle(p, isUrl: isUrl, unescape: unescape)
                    if !v.isEmpty { acc += v }
                }
                result = acc
            default: // %%
                let lists = try parts.map { try getStringListSingle($0, isUrl: isUrl) }
                result = interleave(lists).joined(separator: "\n")
            }
        }
        return result
    }

    public func getStringList(_ rule: String?, isUrl: Bool = false) throws -> [String] {
        guard let rule, !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let splitter = RuleSplitter()
        let parts = splitter.splitRule(rule, "&&", "||", "%%")
        if parts.count <= 1 { return try getStringListSingle(rule, isUrl: isUrl) }
        switch splitter.elementsType {
        case "||":
            for p in parts {
                let v = try getStringListSingle(p, isUrl: isUrl)
                if !v.isEmpty { return v }
            }
            return []
        case "&&":
            var out: [String] = []
            for p in parts { out += try getStringListSingle(p, isUrl: isUrl) }
            return out
        default:
            return interleave(try parts.map { try getStringListSingle($0, isUrl: isUrl) })
        }
    }

    public func getElement(_ rule: String) throws -> Any? {
        try getElements(rule).first
    }

    public func getElements(_ rule: String) throws -> [Any] {
        let r = processPut(rule)
        let sr = splitSourceRule(r).first ?? SourceRule(rule: r, mode: .defaultMode)
        let body = try processEval(sr.rule)
        let (mode, actual) = parseMode(body)
        switch mode {
        case .regex:
            return ByRegex.getElements(contentString(), [actual], 0).map { $0.joined(separator: "\n") }
        case .jsonPath:
            return jsonAnalyzer().getList(actual)
        case .xPath:
            return xpathAnalyzer().getElements(actual)
        default:
            if isJSRule(actual) {
                let v = try evalJSChain(actual, result: nil)
                if let arr = v as? [Any] { return arr }
                if let v { return [v] }
                return []
            }
            return defaultAnalyzer().getElements(actual)
        }
    }

    public func evalJS(_ js: String, result: Any? = nil) throws -> Any? {
        if bridge == nil {
            bridge = JSBridge(source: source, book: book, chapter: chapter, variables: variables)
        }
        var bindings: [String: Any?] = [
            "result": result, "baseUrl": baseUrl, "key": key, "page": page,
            "nextChapterUrl": nextChapterUrl, "redirectUrl": redirectUrl,
        ]
        if let src = source { bindings["source"] = src }
        return try bridge!.eval(js, bindings: bindings)
    }

    /// @get:{key}
    public func get(_ key: String) -> String { variables.get(key) }

    /// @put:{...}：值按规则求值后存入变量
    public func putRule(_ json: String) throws {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw LegadoError("@put 规则不是合法 JSON: \(json)")
        }
        for (k, v) in obj {
            let rule = "\(v)"
            let val = (try? getString(rule)) ?? ""
            variables.put(k, val)
        }
    }

    public func splitSourceRule(_ ruleStr: String, allInOne: Bool = false) -> [SourceRule] {
        var r = ruleStr
        var sr = SourceRule(rule: r, mode: .defaultMode)
        // ##正则##替换###（结尾 ### 表示只替换第一个）
        if let range = r.range(of: "##") {
            let body = String(r[..<range.lowerBound])
            var rest = String(r[range.upperBound...])
            var firstOnly = false
            if rest.hasSuffix("###") { firstOnly = true; rest.removeLast(3) }
            else if rest.hasSuffix("##") { firstOnly = true; rest.removeLast(2) }
            if let sep = rest.range(of: "##") {
                sr.replaceRegex = [String(rest[..<sep.lowerBound])]
                sr.replacement = String(rest[sep.upperBound...])
            } else {
                sr.replaceRegex = [rest]
                sr.replacement = ""
            }
            sr.replaceFirst = firstOnly
            r = body
        }
        sr.rule = r
        sr.mode = parseMode(r).0
        return [sr]
    }

    // MARK: - 内部

    func contentString() -> String {
        if let s = content as? String { return s }
        if let el = content as? Element { return (try? el.outerHtml()) ?? "" }
        if let v = content { return ByJSONPath.stringify(v) }
        return ""
    }

    private func interleave(_ lists: [[String]]) -> [String] {
        var out: [String] = []
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for l in lists where i < l.count { out.append(l[i]) }
        }
        return out
    }

    private func defaultAnalyzer() -> ByDefault {
        if let c = cachedDefault { return c }
        let c = ByDefault(content ?? "", baseUrl: baseUrl)
        cachedDefault = c
        return c
    }
    private func xpathAnalyzer() -> ByXPath {
        if let c = cachedXPath { return c }
        let c = ByXPath(content ?? "")
        cachedXPath = c
        return c
    }
    private func jsonAnalyzer() -> ByJSONPath {
        if let c = cachedJSON { return c }
        let c = ByJSONPath(content ?? "")
        cachedJSON = c
        return c
    }

    private func isJSRule(_ r: String) -> Bool {
        let t = r.trimmingCharacters(in: .whitespaces)
        return t.lowercased().hasPrefix("@js:") || t.lowercased().hasPrefix("<js>")
    }

    /// 判断模式并剥掉前缀
    private func parseMode(_ rule: String) -> (Mode, String) {
        let r = rule.trimmingCharacters(in: .whitespaces)
        let lower = r.lowercased()
        if lower.hasPrefix("@js:") || lower.hasPrefix("<js>") { return (.defaultMode, r) }
        if lower.hasPrefix("@xpath:") { return (.xPath, String(r.dropFirst(7))) }
        if r.hasPrefix("@@") { return (.xPath, String(r.dropFirst(2))) }
        if lower.hasPrefix("@json:") { return (.jsonPath, String(r.dropFirst(6))) }
        if r.hasPrefix("$.") || r.hasPrefix("$[") || r == "$" { return (.jsonPath, r) }
        if lower.hasPrefix(":regex") { return (.regex, String(r.dropFirst(6))) }
        if r.hasPrefix(":") { return (.regex, String(r.dropFirst(1))) }
        if isJSON && !r.hasPrefix("class.") && !r.hasPrefix("id.") && !r.hasPrefix("tag.") {
            return (.jsonPath, r)
        }
        return (.defaultMode, r)
    }

    /// @put 提取并执行，返回剩余规则
    private func processPut(_ rule: String) -> String {
        let ns = rule as NSString
        let ms = Self.putPattern.matches(in: rule, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return rule }
        var out = rule
        for m in ms.reversed() {
            let json = ns.substring(with: m.range(at: 1))
            try? putRule(json)
            out = (out as NSString).replacingCharacters(in: m.range, with: "")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// {{...}} 与 @get:{...} 求值替换
    private func processEval(_ rule: String) throws -> String {
        let ns = rule as NSString
        let ms = Self.evalPattern.matches(in: rule, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return rule }
        var out = rule
        for m in ms.reversed() {
            let token = ns.substring(with: m.range)
            var replacement = ""
            if token.hasPrefix("@get:") {
                let k = String(token.dropFirst(6).dropLast())
                replacement = variables.get(k)
            } else {
                let expr = String(token.dropFirst(2).dropLast())
                if let v = try evalJS(expr, result: nil) {
                    replacement = stringify(v)
                }
            }
            out = (out as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return out
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let arr = v as? [Any] { return arr.map { stringify($0) }.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }
    private func stringify(_ v: Any) -> String { Self.stringify(v) }

    /// JS 链：<js>..</js> 与 @js: 段依次求值，result 传递
    private func evalJSChain(_ rule: String, result: Any?) throws -> Any? {
        let ns = rule as NSString
        let ms = Self.jsPattern.matches(in: rule, range: NSRange(location: 0, length: ns.length))
        var current: Any? = result
        var lastEnd = 0
        for m in ms {
            if m.range.location > lastEnd {
                let pre = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pre.isEmpty { current = try analyzeText(pre, result: current) }
            }
            var js = ""
            if m.range(at: 1).location != NSNotFound { js = ns.substring(with: m.range(at: 1)) }
            else if m.range(at: 2).location != NSNotFound { js = ns.substring(with: m.range(at: 2)) }
            current = try evalJS(js, result: current)
            lastEnd = m.range.location + m.range.length
        }
        if lastEnd < ns.length {
            let post = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespacesAndNewlines)
            if !post.isEmpty { current = try analyzeText(post, result: current) }
        }
        return current
    }

    /// 普通规则段（可带前序 result 作为内容）
    private func analyzeText(_ rule: String, result: Any?) throws -> Any? {
        let saved = content
        if let result { content = result }
        defer { content = saved }
        cachedDefault = nil; cachedXPath = nil; cachedJSON = nil
        let (mode, body) = parseMode(rule)
        switch mode {
        case .regex: return ByRegex.getElement(contentString(), [body], 0)?.joined(separator: "\n")
        case .jsonPath: return jsonAnalyzer().getString(body)
        case .xPath: return xpathAnalyzer().getString(body)
        default: return defaultAnalyzer().getString(body)
        }
    }

    /// 整条规则仅由 {{...}} / @get:{...} 组成时，替换结果即最终值（不再当选择器解析）
    private func isPureEval(_ s: String) -> Bool {
        let ns = s as NSString
        let ms = Self.evalPattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return false }
        var cover = 0
        for m in ms {
            if m.range.location != cover { return false }
            cover = m.range.location + m.range.length
        }
        return cover == ns.length
    }

    private func getStringSingle(_ rule: String, isUrl: Bool, unescape: Bool) throws -> String {
        let r = processPut(rule)
        let sr = splitSourceRule(r).first ?? SourceRule(rule: r, mode: .defaultMode)
        if isPureEval(sr.rule) {
            var result = try processEval(sr.rule)
            for re in sr.replaceRegex {
                result = ByRegex.replace(result, pattern: re, replacement: sr.replacement, firstOnly: sr.replaceFirst)
            }
            if unescape { result = NetworkUtils.unescapeHTML(result) }
            if isUrl { result = NetworkUtils.absoluteURL(baseUrl, result) }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = try processEval(sr.rule)
        var result: String
        if isJSRule(body) {
            let v = try evalJSChain(body, result: nil)
            result = v.map { stringify($0) } ?? ""
        } else {
            let (mode, actual) = parseMode(body)
            switch mode {
            case .regex:
                result = ByRegex.getElement(contentString(), [actual], 0)?.joined(separator: "\n") ?? ""
            case .jsonPath:
                result = jsonAnalyzer().getString(actual) ?? ""
            case .xPath:
                result = xpathAnalyzer().getString(actual) ?? ""
            default:
                // 默认规则中内嵌 <js> 链
                let ns = body as NSString
                if Self.jsPattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) != nil {
                    let v = try evalJSChain(body, result: nil)
                    result = v.map { stringify($0) } ?? ""
                } else {
                    result = defaultAnalyzer().getString(actual) ?? ""
                }
            }
        }
        for re in sr.replaceRegex {
            result = ByRegex.replace(result, pattern: re, replacement: sr.replacement, firstOnly: sr.replaceFirst)
        }
        if unescape { result = NetworkUtils.unescapeHTML(result) }
        if isUrl { result = NetworkUtils.absoluteURL(baseUrl, result) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func getStringListSingle(_ rule: String, isUrl: Bool) throws -> [String] {
        let r = processPut(rule)
        let sr = splitSourceRule(r).first ?? SourceRule(rule: r, mode: .defaultMode)
        if isPureEval(sr.rule) {
            let v = try getStringSingle(rule, isUrl: isUrl, unescape: true)
            return v.isEmpty ? [] : [v]
        }
        let body = try processEval(sr.rule)
        var list: [String]
        if isJSRule(body) {
            let v = try evalJSChain(body, result: nil)
            if let arr = v as? [Any] { list = arr.map { stringify($0) } }
            else if let v { list = [stringify(v)] }
            else { list = [] }
        } else {
            let (mode, actual) = parseMode(body)
            switch mode {
            case .regex:
                list = ByRegex.getElements(contentString(), [actual], 0).map { $0.joined(separator: "\n") }
            case .jsonPath:
                list = jsonAnalyzer().getStringList(actual)
            case .xPath:
                list = xpathAnalyzer().getStringList(actual)
            default:
                list = defaultAnalyzer().getStringList(actual)
            }
        }
        list = list.map { s in
            var v = s
            for re in sr.replaceRegex {
                v = ByRegex.replace(v, pattern: re, replacement: sr.replacement, firstOnly: sr.replaceFirst)
            }
            v = NetworkUtils.unescapeHTML(v)
            if isUrl { v = NetworkUtils.absoluteURL(baseUrl, v) }
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return list.filter { !$0.isEmpty }
    }
}