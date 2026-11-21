import Foundation
import SwiftSoup

/// JSoup 默认语法与 `@CSS:` 规则（对应 Legado AnalyzeByJSoup）
struct AnalyzeByJSoup {
    let element: Element

    init(_ content: Any) {
        if let el = content as? Element {
            element = el
            return
        }
        let text = RuleValue.text(of: content)
        element = Self.parse(text)
    }

    static func parse(_ html: String) -> Element {
        if html.trimmedWhitespace.startsWith("<?xml", ignoreCase: true),
           let doc = try? SwiftSoup.parse(html, "", Parser.xmlParser()) {
            return doc
        }
        return (try? SwiftSoup.parse(html)) ?? Document("")
    }

    private struct CssRule {
        var isCss = false
        var rule: String

        init(_ raw: String) {
            if raw.startsWith("@CSS:", ignoreCase: true) {
                isCss = true
                rule = String(raw.dropFirst(5)).trimmedControl
            } else {
                rule = raw
            }
        }
    }

    // MARK: - 元素列表

    func getElements(_ rule: String) -> [Element] {
        Self.getElements(element, rule)
    }

    static func getElements(_ temp: Element, _ rule: String) -> [Element] {
        guard !rule.isEmpty else { return [] }
        let source = CssRule(rule)
        let split = RuleSplitter.split(source.rule, separators: ["&&", "||", "%%"])
        var lists: [[Element]] = []
        if source.isCss {
            for part in split.parts {
                let es = (try? temp.select(part).array()) ?? []
                lists.append(es)
                if !es.isEmpty, split.separator == "||" { break }
            }
        } else {
            for part in split.parts {
                let segments = RuleSplitter.split(RuleSplitter.trimLeading(part), separators: ["@"]).parts
                var els: [Element]
                if segments.count > 1 {
                    els = [temp]
                    for seg in segments {
                        var next: [Element] = []
                        for el in els { next.append(contentsOf: getElements(el, seg)) }
                        els = next
                    }
                } else {
                    els = ElementsSingle.select(temp, part)
                }
                lists.append(els)
                if !els.isEmpty, split.separator == "||" { break }
            }
        }
        return combine(lists, separator: split.separator)
    }

    static func combine<T>(_ lists: [[T]], separator: String) -> [T] {
        guard let first = lists.first else { return [] }
        if separator == "%%" {
            var out: [T] = []
            for i in first.indices {
                for list in lists where i < list.count { out.append(list[i]) }
            }
            return out
        }
        return lists.flatMap { $0 }
    }

    // MARK: - 字符串

    func getString(_ rule: String) -> String? {
        guard !rule.isEmpty else { return nil }
        let list = getStringList(rule)
        if list.isEmpty { return nil }
        return list.count == 1 ? list[0] : list.joined(separator: "\n")
    }

    /// 只取第一个结果（用于 URL）
    func getString0(_ rule: String) -> String {
        getStringList(rule).first ?? ""
    }

    func getStringList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        let source = CssRule(rule)
        if source.rule.isEmpty {
            return [element.data()]
        }
        let split = RuleSplitter.split(source.rule, separators: ["&&", "||", "%%"])
        var results: [[String]] = []
        for part in split.parts {
            let temp: [String]?
            if source.isCss {
                if let at = part.lastIndex(of: "@") {
                    let css = String(part[..<at])
                    let last = String(part[part.index(after: at)...])
                    temp = Self.resultLast((try? element.select(css).array()) ?? [], last)
                } else {
                    temp = Self.resultLast((try? element.select(part).array()) ?? [], "text")
                }
            } else {
                temp = resultList(part)
            }
            if let temp, !temp.isEmpty {
                results.append(temp)
                if split.separator == "||" { break }
            }
        }
        return Self.combine(results, separator: split.separator)
    }

    private func resultList(_ rule: String) -> [String]? {
        guard !rule.isEmpty else { return nil }
        let rules = RuleSplitter.split(RuleSplitter.trimLeading(rule), separators: ["@"]).parts
        var elements: [Element] = [element]
        for r in rules.dropLast() {
            var next: [Element] = []
            for el in elements { next.append(contentsOf: ElementsSingle.select(el, r)) }
            elements = next
        }
        if elements.isEmpty { return nil }
        return Self.resultLast(elements, rules.last ?? "")
    }

    static func resultLast(_ elements: [Element], _ lastRule: String) -> [String] {
        var out: [String] = []
        switch lastRule {
        case "text":
            for el in elements {
                if let t = try? el.text(), !t.isEmpty { out.append(t) }
            }
        case "textNodes":
            for el in elements {
                let lines = el.textNodes()
                    .map { $0.text().trimmedControl }
                    .filter { !$0.isEmpty }
                if !lines.isEmpty { out.append(lines.joined(separator: "\n")) }
            }
        case "ownText":
            for el in elements {
                let t = el.ownText()
                if !t.isEmpty { out.append(t) }
            }
        case "html":
            for el in elements {
                _ = try? el.select("script").remove()
                _ = try? el.select("style").remove()
            }
            let html = elements.compactMap { try? $0.outerHtml() }.joined(separator: "\n")
            if !html.isEmpty { out.append(html) }
        case "all":
            out.append(elements.compactMap { try? $0.outerHtml() }.joined(separator: "\n"))
        default:
            for el in elements {
                guard let v = try? el.attr(lastRule), !v.isBlank, !out.contains(v) else { continue }
                out.append(v)
            }
        }
        return out
    }
}

/// 单段规则：`class.x`、`tag.a.0`、`id.x`、`text.x`、`children`、CSS 以及各种索引写法
enum ElementsSingle {
    private enum Index {
        case single(Int)
        case range(Int?, Int?, Int)
    }

    private struct Parsed {
        var split: Character = " "
        var beforeRule = ""
        var indexDefault: [Int] = []
        var indexes: [Index] = []
    }

    static func select(_ temp: Element, _ rule: String) -> [Element] {
        let p = parseIndex(rule)
        var elements: [Element]
        if p.beforeRule.isEmpty {
            elements = temp.children().array()
        } else {
            let parts = p.beforeRule.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "children": elements = temp.children().array()
            case "class": elements = (try? temp.getElementsByClass(arg).array()) ?? []
            case "tag": elements = (try? temp.getElementsByTag(arg).array()) ?? []
            case "id": elements = ((try? temp.getAllElements().array()) ?? []).filter { $0.id() == arg }
            case "text": elements = (try? temp.getElementsContainingOwnText(arg).array()) ?? []
            default: elements = (try? temp.select(p.beforeRule).array()) ?? []
            }
        }
        let len = elements.count
        // 索引集合（保持顺序、去重、去越界）
        var indexSet: [Int] = []
        func add(_ i: Int) {
            if !indexSet.contains(i) { indexSet.append(i) }
        }
        if p.indexes.isEmpty {
            for it in p.indexDefault.reversed() {
                if it >= 0, it < len { add(it) } else if it < 0, len >= -it { add(it + len) }
            }
        } else {
            for index in p.indexes.reversed() {
                switch index {
                case .single(let it):
                    if it >= 0, it < len { add(it) } else if it < 0, len >= -it { add(it + len) }
                case .range(let startX, let endX, let stepX):
                    var start = startX ?? 0
                    if start < 0 { start += len }
                    var end = endX ?? (len - 1)
                    if end < 0 { end += len }
                    if (start < 0 && end < 0) || (start >= len && end >= len) { continue }
                    if start >= len { start = len - 1 } else if start < 0 { start = 0 }
                    if end >= len { end = len - 1 } else if end < 0 { end = 0 }
                    if start == end || stepX >= len {
                        add(start)
                        continue
                    }
                    let step = stepX > 0 ? stepX : (-stepX < len ? stepX + len : 1)
                    if end > start {
                        for i in stride(from: start, through: end, by: step) { add(i) }
                    } else {
                        for i in stride(from: start, through: end, by: -step) { add(i) }
                    }
                }
            }
        }
        switch p.split {
        case "!":
            let excluded = Set(indexSet)
            return elements.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        case ".":
            return indexSet.map { elements[$0] }
        default:
            return elements
        }
    }

    /// 逆向解析索引（移植自 Legado findIndexSet）
    private static func parseIndex(_ rule: String) -> Parsed {
        let rus = Array(rule.trimmedControl)
        var p = Parsed()
        guard !rus.isEmpty else { return p }
        var len = rus.count
        var l = ""
        var curMinus = false
        var curList: [Int?] = []
        if rus.last == "]" {
            len -= 1
            while len - 1 >= 0 {
                len -= 1
                var rl = rus[len]
                if rl == " " { continue }
                if rl.isASCII, rl.isNumber {
                    l = String(rl) + l
                } else if rl == "-" {
                    curMinus = true
                } else {
                    let curInt: Int? = l.isEmpty ? nil : (curMinus ? -(Int(l) ?? 0) : (Int(l) ?? 0))
                    if rl == ":" {
                        curList.append(curInt)
                    } else {
                        if curList.isEmpty {
                            guard let curInt else { break }
                            p.indexes.append(.single(curInt))
                        } else {
                            let step = curList.count == 2 ? (curList.first! ?? 1) : 1
                            p.indexes.append(.range(curInt, curList.last!, step))
                            curList.removeAll()
                        }
                        if rl == "!" {
                            p.split = "!"
                            repeat {
                                len -= 1
                                rl = len >= 0 ? rus[len] : " "
                            } while len > 0 && rl == " "
                        }
                        if rl == "[" {
                            p.beforeRule = String(rus[0..<max(len, 0)])
                            if p.split != "!" { p.split = "." }
                            return p
                        }
                        if rl != "," { break }
                    }
                    l = ""
                    curMinus = false
                }
            }
        } else {
            while len - 1 >= 0 {
                len -= 1
                let rl = rus[len]
                if rl == " " { continue }
                if rl.isASCII, rl.isNumber {
                    l = String(rl) + l
                } else if rl == "-" {
                    curMinus = true
                } else {
                    if rl == "!" || rl == "." || rl == ":" {
                        guard let v = Int(l) else { break }
                        p.indexDefault.append(curMinus ? -v : v)
                        if rl != ":" {
                            p.split = rl
                            p.beforeRule = String(rus[0..<len])
                            return p
                        }
                    } else {
                        break
                    }
                    l = ""
                    curMinus = false
                }
            }
        }
        return Parsed(split: " ", beforeRule: String(rus), indexDefault: [], indexes: [])
    }
}
