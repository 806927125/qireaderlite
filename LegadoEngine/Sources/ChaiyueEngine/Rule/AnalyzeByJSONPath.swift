import Foundation
import Sextant

/// JSONPath 规则（对应 Legado AnalyzeByJSonPath，语义与 Jayway JsonPath 一致）
struct AnalyzeByJSONPath {
    let root: Any

    init(_ content: Any) {
        if let s = content as? String {
            root = Self.parseJSON(s) ?? s
        } else if content is [Any] || content is [String: Any] {
            root = content
        } else {
            let text = RuleValue.text(of: content)
            root = Self.parseJSON(text) ?? text
        }
    }

    static func parseJSON(_ text: String) -> Any? {
        guard let data = text.trimmedWhitespace.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 按 Jayway 语义读取：确定路径返回单值，不确定路径返回列表
    func read(_ rawPath: String) -> Any? {
        var path = rawPath.trimmedWhitespace
        if !path.hasPrefix("$"), !path.hasPrefix("@") {
            path = "$." + path
        }
        if path.hasPrefix("@") { path = "$" + path.dropFirst() }
        let anyRoot: JsonAny = root
        guard let values = anyRoot.query(values: path) else {
            return Self.isDefinite(path) ? nil : []
        }
        let cleaned = values.map { $0 ?? NSNull() }
        if Self.isDefinite(path) {
            guard let first = cleaned.first, !(first is NSNull) else { return nil }
            return first
        }
        return cleaned
    }

    /// Jayway 的确定路径：不含深度扫描、通配符、过滤器、多索引、切片、多属性
    static func isDefinite(_ path: String) -> Bool {
        var depth = 0
        var quote: Character?
        let chars = Array(path)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\" { i += 2; continue }
                if c == q { quote = nil }
                i += 1
                continue
            }
            switch c {
            case "'", "\"": quote = c
            case "[": depth += 1
            case "]": depth -= 1
            case "*": return false
            case "?": if depth > 0 { return false }
            case ":", ",": if depth > 0 { return false }
            case ".": if i + 1 < chars.count, chars[i + 1] == "." { return false }
            default: break
            }
            i += 1
        }
        return true
    }

    func getString(_ rule: String) -> String? {
        guard !rule.isEmpty else { return nil }
        let split = RuleSplitter.split(rule, separators: ["&&", "||"], code: true)
        if split.parts.count == 1 {
            let inner = RuleSplitter.innerRule(rule, inner: "{$.") { getString($0) }
            if !inner.isEmpty { return inner }
            guard let value = read(rule) else { return "" }
            if let list = value as? [Any] {
                return list.map { LenientJSON.stringify($0) }.joined(separator: "\n")
            }
            return LenientJSON.stringify(value)
        }
        var texts: [String] = []
        for part in split.parts {
            if let t = getString(part), !t.isEmpty {
                texts.append(t)
                if split.separator == "||" { break }
            }
        }
        return texts.joined(separator: "\n")
    }

    func getStringList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        let split = RuleSplitter.split(rule, separators: ["&&", "||", "%%"], code: true)
        if split.parts.count == 1 {
            let inner = RuleSplitter.innerRule(rule, inner: "{$.") { getString($0) }
            if !inner.isEmpty { return [inner] }
            guard let value = read(rule) else { return [] }
            if let list = value as? [Any] {
                return list.map { LenientJSON.stringify($0) }
            }
            return [LenientJSON.stringify(value)]
        }
        var results: [[String]] = []
        for part in split.parts {
            let temp = getStringList(part)
            if !temp.isEmpty {
                results.append(temp)
                if split.separator == "||" { break }
            }
        }
        return AnalyzeByJSoup.combine(results, separator: split.separator)
    }

    func getObject(_ rule: String) -> Any? {
        read(rule)
    }

    func getList(_ rule: String) -> [Any] {
        guard !rule.isEmpty else { return [] }
        let split = RuleSplitter.split(rule, separators: ["&&", "||", "%%"], code: true)
        if split.parts.count == 1 {
            return read(split.parts[0]) as? [Any] ?? []
        }
        var results: [[Any]] = []
        for part in split.parts {
            let temp = getList(part)
            if !temp.isEmpty {
                results.append(temp)
                if split.separator == "||" { break }
            }
        }
        return AnalyzeByJSoup.combine(results, separator: split.separator)
    }
}
