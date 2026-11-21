import Foundation

/// AllInOne 正则（规则以 `:` 开头），多个正则用 `&&` 逐级缩小范围
enum AnalyzeByRegex {
    static func getElement(_ text: String, _ regs: [String], _ index: Int = 0) -> [String]? {
        guard index < regs.count, let re = try? RegexCache.shared.regex(regs[index]) else { return nil }
        let matches = re.matches(in: text, range: text.fullRange)
        guard let first = matches.first else { return nil }
        if index + 1 == regs.count {
            return groups(first, in: text)
        }
        let joined = matches.map { text.substring(with: $0.range) }.joined()
        return getElement(joined, regs, index + 1)
    }

    static func getElements(_ text: String, _ regs: [String], _ index: Int = 0) -> [[String]] {
        guard index < regs.count, let re = try? RegexCache.shared.regex(regs[index]) else { return [] }
        let matches = re.matches(in: text, range: text.fullRange)
        guard !matches.isEmpty else { return [] }
        if index + 1 == regs.count {
            return matches.map { groups($0, in: text) }
        }
        let joined = matches.map { text.substring(with: $0.range) }.joined()
        return getElements(joined, regs, index + 1)
    }

    private static func groups(_ m: NSTextCheckingResult, in text: String) -> [String] {
        (0..<m.numberOfRanges).map { text.group(m, $0) ?? "" }
    }
}
