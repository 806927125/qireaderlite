import Foundation

/// 正则解析后端。regex[0] 为模式，其余为分组模板（"$1" 等）；缺省模板 "$0"。
public enum ByRegex {
    static func regex(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    static func expand(_ template: String, match: NSTextCheckingResult, in text: String) -> String {
        let ns = text as NSString
        var out = template
        // $n / ${n}
        let pat = try! NSRegularExpression(pattern: "\\$\\{?(\\d+)\\}?")
        let ms = pat.matches(in: template, range: NSRange(location: 0, length: template.utf16.count))
        for m in ms.reversed() {
            let g = Int((template as NSString).substring(with: m.range(at: 1))) ?? 0
            var rep = ""
            if g < match.numberOfRanges, match.range(at: g).location != NSNotFound {
                rep = ns.substring(with: match.range(at: g))
            }
            out = (out as NSString).replacingCharacters(in: m.range, with: rep)
        }
        return out
    }

    /// 所有匹配，每个匹配按模板展开为一组字符串。
    public static func getElements(_ text: String, _ regex: [String], _ index: Int) -> [[String]] {
        guard let pattern = regex.first, let re = try? Self.regex(pattern) else { return [] }
        let templates = regex.count > 1 ? Array(regex.dropFirst()) : ["$0"]
        let ns = text as NSString
        let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [[String]] = []
        for m in ms { out.append(templates.map { expand($0, match: m, in: text) }) }
        if index != 0, !out.isEmpty {
            let i = index > 0 ? index - 1 : out.count + index
            if i >= 0 && i < out.count { return [out[i]] }
            return []
        }
        return out
    }

    /// 第 index 个匹配（1 起；负数从末尾；0 取第一个）。
    public static func getElement(_ text: String, _ regex: [String], _ index: Int) -> [String]? {
        let all = getElements(text, regex, 0)
        guard !all.isEmpty else { return nil }
        let i = index > 0 ? index - 1 : (index < 0 ? all.count + index : 0)
        guard i >= 0 && i < all.count else { return nil }
        return all[i]
    }

    public static func replace(_ text: String, pattern: String, replacement: String, firstOnly: Bool) -> String {
        guard let re = try? regex(pattern) else { return text }
        let ns = text as NSString
        let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return text }
        var out = text
        for m in (firstOnly ? [ms[0]] : ms).reversed() {
            let rep = expand(replacement, match: m, in: text)
            out = (out as NSString).replacingCharacters(in: m.range, with: rep)
        }
        return out
    }
}