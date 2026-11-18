import Foundation
import SwiftSoup

/// 默认规则后端（SwiftSoup），语法对齐 Legado：class.xxx.0@tag.a@href / id.x / tag.a / text / html / 索引。
public final class ByDefault {
    private var doc: Document?
    private var elements: [Element] = []
    private var json: ByJSONPath?
    private var baseUrl: String?

    public init(_ content: Any, baseUrl: String? = nil) {
        self.baseUrl = baseUrl
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") || t.hasPrefix("[") {
                json = ByJSONPath(s)
            } else {
                doc = try? SwiftSoup.parse(s, baseUrl ?? "")
            }
        } else if let el = content as? Element {
            elements = [el]
        } else if let els = content as? [Element] {
            elements = els
        } else if let d = content as? Document {
            doc = d
        }
    }

    // MARK: 公开接口

    public func getElements(_ rule: String) -> [Element] {
        if json != nil { return [] } // JSON 内容不走选择器
        let sections = RuleSplitter().splitRule(rule, "@")
        var current: [Element] = elements
        if current.isEmpty, let doc { current = [doc.body() ?? doc] }
        for (si, section) in sections.enumerated() {
            let tokens = mergePrefixes(splitDots(section))
            var next: [Element] = []
            var extracted = false
            for (ti, token) in tokens.enumerated() {
                let t = token.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let idx = parseIndex(t) {
                    current = select(current, idx)
                    continue
                }
                if si == 0 && current.count == 1 && current[0] === (doc?.body() ?? doc) {
                    // 首段从文档选择
                    next = selectFromDoc(t)
                    current = next
                    next = []
                    continue
                }
                switch t {
                case "children":
                    next = current.flatMap { $0.children().array() }
                case "text", "html", "outerHtml", "all", "textNodes", "ownText":
                    extracted = true
                default:
                    if t.hasPrefix("class.") {
                        let name = String(t.dropFirst(6))
                        next = current.flatMap { (try? $0.getElementsByClass(name).array()) ?? [] }
                    } else if t.hasPrefix("id.") {
                        let name = String(t.dropFirst(3))
                        next = current.compactMap { try? $0.getElementById(name) }
                    } else if t.hasPrefix("tag.") {
                        let name = String(t.dropFirst(4))
                        next = current.flatMap { (try? $0.getElementsByTag(name).array()) ?? [] }
                    } else if ti == tokens.count - 1 {
                        extracted = true // 末位视为属性名
                    } else {
                        // 裸名称按 class 处理（Legado 兼容）
                        next = current.flatMap { (try? $0.getElementsByClass(t).array()) ?? [] }
                    }
                }
                if extracted { break }
                if !next.isEmpty || ti < tokens.count - 1 {
                    if !next.isEmpty { current = next; next = [] }
                }
            }
            if extracted { break }
            if !next.isEmpty { current = next }
        }
        return current
    }

    public func getStringList(_ rule: String) -> [String] {
        if let json { return json.getStringList(rule) }
        let sections = RuleSplitter().splitRule(rule, "@")
        let last = sections.last ?? rule
        let extract = last.trimmingCharacters(in: .whitespaces)
        let els: [Element]
        if isExtractor(extract) || (!extract.contains(".") && !extract.hasPrefix("class.") && !extract.hasPrefix("id.") && !extract.hasPrefix("tag.") && sections.count > 1) {
            els = getElements(sections.dropLast().joined(separator: "@"))
            return els.compactMap { extractValue($0, extract) }.filter { !$0.isEmpty }
        }
        els = getElements(rule)
        return els.compactMap { extractValue($0, "text") }.filter { !$0.isEmpty }
    }

    public func getString(_ rule: String) -> String? {
        if let json { return json.getString(rule) }
        let list = getStringList(rule)
        if list.isEmpty { return nil }
        return list.joined(separator: "\n")
    }

    public static func getElements(_ element: Element, _ rule: String) -> [Element] {
        ByDefault(element).getElements(rule)
    }

    // MARK: 内部

    private func isExtractor(_ t: String) -> Bool {
        ["text", "html", "outerHtml", "all", "textNodes", "ownText", "href", "src", "content", "value", "alt", "title", "data-src", "data-original"].contains(t)
    }

    private func extractValue(_ el: Element, _ token: String) -> String? {
        switch token {
        case "text": return (try? el.text()) ?? ""
        case "html": return (try? el.html()) ?? ""
        case "outerHtml", "all": return (try? el.outerHtml()) ?? ""
        case "ownText": return el.ownText()
        case "textNodes":
            let nodes = el.textNodes()
            return nodes.map { $0.text() }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        case "href", "src":
            if let abs = try? el.absUrl(token), !abs.isEmpty { return abs }
            let v = (try? el.attr(token)) ?? ""
            return NetworkUtils.absoluteURL(baseUrl, v)
        default:
            return (try? el.attr(token)) ?? ""
        }
    }

    private func selectFromDoc(_ t: String) -> [Element] {
        guard let doc else { return [] }
        if t.hasPrefix("class.") { return (try? doc.getElementsByClass(String(t.dropFirst(6))).array()) ?? [] }
        if t.hasPrefix("id.") { if let e = try? doc.getElementById(String(t.dropFirst(3))) { return [e] }; return [] }
        if t.hasPrefix("tag.") { return (try? doc.getElementsByTag(String(t.dropFirst(4))).array()) ?? [] }
        if t == "children" { return doc.children().array() }
        if isExtractor(t) { return [doc.body() ?? doc] }
        return (try? doc.getElementsByClass(t).array()) ?? []
    }

    /// 索引语法：0 / -1 / [0:3] / [1,3] / !0 / !0:2
    private func parseIndex(_ t: String) -> [Int]? {
        var s = t
        var exclude = false
        if s.hasPrefix("!") { exclude = true; s.removeFirst() }
        var picked: [Int]? = nil
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let body = String(s.dropFirst().dropLast())
            if body.contains(":") {
                let ps = body.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                picked = sliceIndices(ps.count > 0 ? ps[0] : nil, ps.count > 1 ? ps[1] : nil)
            } else if body.contains(",") {
                picked = body.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else if let n = Int(body) { picked = [n] }
        } else if let n = Int(s) { picked = [n] }
        guard let p = picked else { return nil }
        if exclude { picked = nil; return p.isEmpty ? [] : p.map { -$0 - 100000 } } // 标记排除
        return p
    }

    private func sliceIndices(_ s: Int?, _ e: Int?) -> [Int] {
        let end = min(e ?? 10000, 10000)
        let start = max(0, s ?? 0)
        return start < end ? Array(start..<end) : []
    }

    private func select(_ els: [Element], _ indices: [Int]) -> [Element] {
        let count = els.count
        var excludeSet = Set<Int>()
        var include: [Int] = []
        for i in indices {
            if i <= -100000 { excludeSet.insert(-i - 100000) } else { include.append(i) }
        }
        if !excludeSet.isEmpty {
            var out: [Element] = []
            for (i, el) in els.enumerated() {
                let neg = i - count
                if !excludeSet.contains(i) && !excludeSet.contains(neg) { out.append(el) }
            }
            return out
        }
        var out: [Element] = []
        for i in include {
            let idx = i < 0 ? count + i : i
            if idx >= 0 && idx < count { out.append(els[idx]) }
        }
        return out
    }

    /// 按 '.' 切分但跳过 [...] 内的点
    private func splitDots(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", depth = 0
        for c in s {
            if c == "[" { depth += 1; cur.append(c) }
            else if c == "]" { depth -= 1; cur.append(c) }
            else if c == "." && depth == 0 { parts.append(cur); cur = "" }
            else { cur.append(c) }
        }
        parts.append(cur)
        return parts
    }

    /// class / id / tag 是前缀标记，与后一个 token 合并（class.item → "class.item"）
    private func mergePrefixes(_ parts: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < parts.count {
            let p = parts[i].trimmingCharacters(in: .whitespaces)
            if (p == "class" || p == "id" || p == "tag") && i + 1 < parts.count {
                out.append(p + "." + parts[i + 1])
                i += 2
            } else {
                out.append(parts[i])
                i += 1
            }
        }
        return out
    }
}