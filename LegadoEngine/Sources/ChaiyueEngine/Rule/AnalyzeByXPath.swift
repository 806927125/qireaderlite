import Foundation
import Kanna

/// XPath 规则（对应 Legado AnalyzeByXPath）。基于 libxml2（XPath 1.0），
/// 并兼容 JsoupXpath 的 `allText()`、`html()`、`outerHtml()` 等后缀函数。
struct AnalyzeByXPath {
    private let node: Kanna.XMLElement?
    private let document: Kanna.XMLDocument?

    init(_ content: Any) {
        if let el = content as? Kanna.XMLElement {
            node = el
            document = nil
            return
        }
        var html = RuleValue.text(of: content)
        if html.hasSuffix("</td>") { html = "<tr>\(html)</tr>" }
        if html.hasSuffix("</tr>") || html.hasSuffix("</tbody>") { html = "<table>\(html)</table>" }
        node = nil
        if html.trimmedWhitespace.startsWith("<?xml", ignoreCase: true) {
            document = try? Kanna.XML(xml: html, encoding: .utf8)
        } else {
            document = try? Kanna.HTML(html: html, encoding: .utf8)
        }
    }

    private enum Suffix {
        case none, allText, text, html, outerHtml
    }

    /// 拆出 JsoupXpath 特有的末尾函数
    private static func splitSuffix(_ xpath: String) -> (String, Suffix) {
        let table: [(String, Suffix)] = [
            ("/allText()", .allText), ("/text()", .text), ("/html()", .html), ("/outerHtml()", .outerHtml),
        ]
        for (suffix, kind) in table where xpath.hasSuffix(suffix) {
            return (String(xpath.dropLast(suffix.count)), kind)
        }
        return (xpath, .none)
    }

    private func query(_ rawXPath: String) -> [Kanna.XMLElement] {
        var xpath = rawXPath.trimmedWhitespace
        if let node {
            // 元素上下文中，绝对路径按相对路径处理（与 JsoupXpath 一致）
            if xpath.hasPrefix("//") {
                xpath = "." + xpath
            } else if xpath.hasPrefix("/") {
                xpath = "." + xpath
            }
            return Array(node.xpath(xpath))
        }
        guard let document else { return [] }
        return Array(document.xpath(xpath))
    }

    func getElements(_ rule: String) -> [Kanna.XMLElement] {
        guard !rule.isEmpty else { return [] }
        let split = RuleSplitter.split(rule, separators: ["&&", "||", "%%"])
        var lists: [[Kanna.XMLElement]] = []
        for part in split.parts {
            let es = query(part)
            if !es.isEmpty {
                lists.append(es)
                if split.separator == "||" { break }
            }
        }
        return AnalyzeByJSoup.combine(lists, separator: split.separator)
    }

    func getStringList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        let split = RuleSplitter.split(rule, separators: ["&&", "||", "%%"])
        var results: [[String]] = []
        for part in split.parts {
            let temp = strings(part)
            if !temp.isEmpty {
                results.append(temp)
                if split.separator == "||" { break }
            }
        }
        return AnalyzeByJSoup.combine(results, separator: split.separator)
    }

    func getString(_ rule: String) -> String? {
        let list = getStringList(rule)
        return list.isEmpty ? nil : list.joined(separator: "\n")
    }

    private func strings(_ rule: String) -> [String] {
        let (xpath, suffix) = Self.splitSuffix(rule.trimmedWhitespace)
        let nodes = query(xpath)
        switch suffix {
        case .none:
            return nodes.compactMap { n in
                // 属性节点、文本节点返回内容；元素节点返回文本
                let v = n.text ?? ""
                return v.isEmpty ? nil : v
            }
        case .text:
            return nodes.compactMap { n in
                let own = n.xpath("./text()").compactMap(\.text).joined()
                return own.isBlank ? nil : own
            }
        case .allText:
            return nodes.compactMap { n in
                let t = (n.text ?? "").trimmedWhitespace
                return t.isEmpty ? nil : t
            }
        case .html:
            return nodes.compactMap { $0.innerHTML }
        case .outerHtml:
            return nodes.compactMap { $0.toHTML }
        }
    }
}
