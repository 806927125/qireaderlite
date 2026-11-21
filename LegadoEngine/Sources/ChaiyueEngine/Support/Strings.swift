import Foundation

extension String {
    var fullRange: NSRange { NSRange(location: 0, length: utf16.count) }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }

    /// 与 Kotlin `trim { it <= ' ' }` 一致：只去掉控制字符和半角空格
    var trimmedControl: String {
        let scalars = unicodeScalars
        guard let start = scalars.firstIndex(where: { $0.value > 0x20 }) else { return "" }
        let end = scalars.lastIndex(where: { $0.value > 0x20 })!
        return String(scalars[start...end])
    }

    /// 与 Kotlin `trim()` 一致：去掉所有空白（含全角空格、不换行空格）
    var trimmedWhitespace: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool { trimmedWhitespace.isEmpty }

    var isJsonObject: Bool {
        let t = trimmedWhitespace
        return t.hasPrefix("{") && t.hasSuffix("}")
    }

    var isJsonArray: Bool {
        let t = trimmedWhitespace
        return t.hasPrefix("[") && t.hasSuffix("]")
    }

    var isJson: Bool { isJsonObject || isJsonArray }

    var isAbsUrl: Bool {
        let lower = prefix(8).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    var isDataUrl: Bool {
        guard prefix(5).lowercased() == "data:" else { return false }
        return range(of: ";base64,") != nil
    }

    func startsWith(_ prefix: String, ignoreCase: Bool) -> Bool {
        guard ignoreCase else { return hasPrefix(prefix) }
        guard count >= prefix.count else { return false }
        return self.prefix(prefix.count).lowercased() == prefix.lowercased()
    }

    /// 按分隔符拆分并去掉空白项
    func splitNotBlank(_ separator: String) -> [String] {
        components(separatedBy: separator)
            .map(\.trimmedWhitespace)
            .filter { !$0.isEmpty }
    }

    func splitNotBlank(regex pattern: String) -> [String] {
        guard let re = try? RegexCache.shared.regex(pattern) else { return splitNotBlank(pattern) }
        var parts: [String] = []
        var last = 0
        let ns = self as NSString
        for m in re.matches(in: self, range: fullRange) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.map(\.trimmedWhitespace).filter { !$0.isEmpty }
    }
}

/// Legado `String?.isTrue()`：空白或 null 返回 `nullIsTrue`，否则只要不是 false/no/not/0 都算真
func isTrueValue(_ value: String?, nullIsTrue: Bool = false) -> Bool {
    guard let value, !value.isBlank, value != "null" else { return nullIsTrue }
    let lower = value.trimmedWhitespace.lowercased()
    return !["false", "no", "not", "0"].contains(lower)
}

/// 线程安全的正则缓存。书源规则使用 Java 正则语法，ICU 与之基本兼容。
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()

    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String, options: NSRegularExpression.Options = []) throws -> NSRegularExpression {
        let key = "\(options.rawValue)\u{1}\(pattern)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let re = try NSRegularExpression(pattern: pattern, options: options)
        lock.lock()
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = re
        lock.unlock()
        return re
    }
}

extension String {
    /// Java `String.replaceAll` 语义；正则无效时按普通字符串替换
    func replacingRegex(_ pattern: String, with replacement: String) -> String {
        guard let re = try? RegexCache.shared.regex(pattern) else {
            return replacingOccurrences(of: pattern, with: replacement)
        }
        return re.stringByReplacingMatches(in: self, range: fullRange, withTemplate: JavaRegex.template(replacement))
    }

    /// Java `String.replaceFirst` 语义
    func replacingFirstRegex(_ pattern: String, with replacement: String) -> String {
        guard let re = try? RegexCache.shared.regex(pattern),
              let m = re.firstMatch(in: self, range: fullRange) else {
            return self
        }
        let replaced = re.replacementString(for: m, in: self, offset: 0, template: JavaRegex.template(replacement))
        return (self as NSString).replacingCharacters(in: m.range, with: replaced)
    }

    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        guard let re = try? RegexCache.shared.regex(pattern, options: options) else { return nil }
        return re.firstMatch(in: self, range: fullRange)
    }

    func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        firstMatch(pattern, options: options) != nil
    }

    func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
        guard index <= match.numberOfRanges - 1 else { return nil }
        let r = match.range(at: index)
        guard r.location != NSNotFound else { return nil }
        return substring(with: r)
    }
}

enum JavaRegex {
    /// Java 替换串与 ICU 模板基本一致（`$1`、`\$`），只需处理 `${name}` 之外的少量差异
    static func template(_ replacement: String) -> String {
        replacement
    }
}
