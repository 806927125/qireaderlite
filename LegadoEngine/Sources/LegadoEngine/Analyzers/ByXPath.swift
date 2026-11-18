import Foundation
import Kanna

/// XPath 解析后端（Kanna/libxml2）。
public final class ByXPath {
    private var doc: Searchable?
    private var node: XMLElement?

    public init(_ content: Any) {
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("<?xml") || (t.hasPrefix("<") && !t.lowercased().contains("<html")) {
                doc = try? Kanna.XML(xml: s, encoding: .utf8)
            }
            if doc == nil { doc = try? Kanna.HTML(html: s, encoding: .utf8) }
        } else if let el = content as? XMLElement {
            node = el
        } else if let d = content as? Searchable {
            doc = d
        }
    }

    public func getElements(_ rule: String) -> [XMLElement] {
        let r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return [] }
        let target: XPathObject?
        if let node { target = node.xpath(r) } else { target = doc?.xpath(r) }
        guard let result = target else { return [] }
        var out: [XMLElement] = []
        for i in 0..<result.count {
            out.append(result[i])
        }
        return out
    }

    static func string(of el: XMLElement) -> String {
        // text() 节点取内容，元素节点取文本
        if el.tagName == nil || el.tagName?.isEmpty == true { return el.content ?? "" }
        return el.text ?? el.content ?? ""
    }

    public func getStringList(_ rule: String) -> [String] {
        getElements(rule).map { Self.string(of: $0) }
    }

    public func getString(_ rule: String) -> String? {
        let list = getStringList(rule)
        let joined = list.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}