import Foundation

/// 规则拆分（对应 Legado RuleAnalyzer）。
/// 在 `[]`、`()` 之外按分隔符拆分；第一个出现的分隔符决定整条规则的组合类型。
enum RuleSplitter {
    struct Result {
        var parts: [String]
        /// 实际使用的分隔符；未拆分时为空
        var separator: String
    }

    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let singleQuote = UInt16(UInt8(ascii: "'"))
    private static let doubleQuote = UInt16(UInt8(ascii: "\""))
    private static let lBracket = UInt16(UInt8(ascii: "["))
    private static let rBracket = UInt16(UInt8(ascii: "]"))
    private static let lParen = UInt16(UInt8(ascii: "("))
    private static let rParen = UInt16(UInt8(ascii: ")"))
    private static let lBrace = UInt16(UInt8(ascii: "{"))
    private static let rBrace = UInt16(UInt8(ascii: "}"))

    /// - Parameter code: JSON 规则使用代码平衡（引号内的括号不计）
    static func split(_ rule: String, separators: [String], code: Bool = false) -> Result {
        let chars = Array(rule.utf16)
        let seps = separators.map { Array($0.utf16) }
        var parts: [String] = []
        var chosen: [UInt16]?
        var segmentStart = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == lBracket || c == lParen {
                let close = c == lBracket ? rBracket : rParen
                if let end = code ? balancedCode(chars, from: i, open: c, close: close) : balancedRule(chars, from: i, open: c, close: close) {
                    i = end
                    continue
                }
                // 不平衡时按普通字符处理
                i += 1
                continue
            }
            var matched: [UInt16]?
            if let chosen {
                if matches(chars, at: i, chosen) { matched = chosen }
            } else {
                matched = seps.first { matches(chars, at: i, $0) }
            }
            if let sep = matched {
                chosen = sep
                parts.append(string(chars, segmentStart, i))
                i += sep.count
                segmentStart = i
                continue
            }
            i += 1
        }
        parts.append(string(chars, segmentStart, chars.count))
        let separator = chosen.map { String(decoding: $0, as: UTF16.self) } ?? ""
        return Result(parts: parts, separator: separator)
    }

    /// JSoup 默认语法按 `@` 拆分前，去掉前导的 `@` 与空白（RuleAnalyzer.trim）
    static func trimLeading(_ rule: String) -> String {
        var scalars = Substring(rule)
        while let first = scalars.unicodeScalars.first, first == "@" || first.value < 0x21 {
            scalars = scalars.dropFirst()
        }
        return String(scalars)
    }

    private static func matches(_ chars: [UInt16], at i: Int, _ sep: [UInt16]) -> Bool {
        guard i + sep.count <= chars.count else { return false }
        for k in 0..<sep.count where chars[i + k] != sep[k] {
            return false
        }
        return true
    }

    private static func string(_ chars: [UInt16], _ from: Int, _ to: Int) -> String {
        guard from < to else { return "" }
        return String(decoding: chars[from..<to], as: UTF16.self)
    }

    /// 规则平衡：引号内不计，反斜杠转义下一个字符。返回闭合符之后的位置。
    static func balancedRule(_ chars: [UInt16], from start: Int, open: UInt16, close: UInt16) -> Int? {
        var pos = start
        var depth = 0
        var inSingle = false
        var inDouble = false
        repeat {
            guard pos < chars.count else { break }
            let c = chars[pos]
            pos += 1
            if c == singleQuote, !inDouble {
                inSingle.toggle()
            } else if c == doubleQuote, !inSingle {
                inDouble.toggle()
            }
            if inSingle || inDouble { continue }
            if c == backslash {
                pos += 1
                continue
            }
            if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
            }
        } while depth > 0
        return depth > 0 ? nil : pos
    }

    /// 代码平衡：同时跟踪 `[]` 与指定括号，处理引号与转义
    static func balancedCode(_ chars: [UInt16], from start: Int, open: UInt16, close: UInt16) -> Int? {
        var pos = start
        var depth = 0
        var otherDepth = 0
        var inSingle = false
        var inDouble = false
        repeat {
            guard pos < chars.count else { break }
            let c = chars[pos]
            pos += 1
            if c != backslash {
                if c == singleQuote, !inDouble {
                    inSingle.toggle()
                } else if c == doubleQuote, !inSingle {
                    inDouble.toggle()
                }
                if inSingle || inDouble { continue }
                if c == lBracket {
                    depth += 1
                } else if c == rBracket {
                    depth -= 1
                } else if depth == 0 {
                    if c == open {
                        otherDepth += 1
                    } else if c == close {
                        otherDepth -= 1
                    }
                }
            } else {
                pos += 1
            }
        } while depth > 0 || otherDepth > 0
        return (depth > 0 || otherDepth > 0) ? nil : pos
    }

    /// 替换以 `inner` 开头、花括号平衡的内嵌规则，例如 `{$.a}`。
    /// 没有任何成功替换时返回空串（与 Legado 一致，调用方据此回退到整条规则）。
    static func innerRule(_ text: String, inner: String, startStep: Int = 1, endStep: Int = 1, transform: (String) -> String?) -> String {
        let chars = Array(text.utf16)
        let innerChars = Array(inner.utf16)
        var out = ""
        var startX = 0
        var pos = 0
        var replaced = false
        while let found = indexOf(chars, innerChars, from: pos) {
            pos = found
            if let end = balancedCode(chars, from: pos, open: lBrace, close: rBrace) {
                let content = string(chars, found + startStep, end - endStep)
                if let value = transform(content), !value.isEmpty {
                    out += string(chars, startX, found) + value
                    startX = end
                    pos = end
                    replaced = true
                    continue
                }
            }
            pos += innerChars.count
        }
        guard replaced else { return "" }
        return out + string(chars, startX, chars.count)
    }

    /// 按起止标记替换（用于 URL 中的 `{{ }}`）。没有匹配时原样返回。
    static func innerRule(_ text: String, startStr: String, endStr: String, transform: (String) -> String?) -> String {
        let chars = Array(text.utf16)
        let s = Array(startStr.utf16)
        let e = Array(endStr.utf16)
        var out = ""
        var startX = 0
        var pos = 0
        var replaced = false
        while let found = indexOf(chars, s, from: pos) {
            let contentStart = found + s.count
            guard let end = indexOf(chars, e, from: contentStart) else { break }
            let value = transform(string(chars, contentStart, end)) ?? ""
            out += string(chars, startX, found) + value
            pos = end + e.count
            startX = pos
            replaced = true
        }
        guard replaced else { return text }
        return out + string(chars, startX, chars.count)
    }

    private static func indexOf(_ chars: [UInt16], _ needle: [UInt16], from: Int) -> Int? {
        guard !needle.isEmpty, from <= chars.count - needle.count else { return nil }
        var i = from
        while i <= chars.count - needle.count {
            if matches(chars, at: i, needle) { return i }
            i += 1
        }
        return nil
    }
}
