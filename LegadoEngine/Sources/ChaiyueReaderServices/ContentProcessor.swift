import Foundation
import ChaiyueModels

/// 简繁转换方式（取值与 Legado `chineseConverterType` 一致）
public enum ChineseConversion: Int, Codable, Sendable, CaseIterable {
    case none = 0
    case toSimplified = 1
    case toTraditional = 2

    public var title: String {
        switch self {
        case .none: "不转换"
        case .toSimplified: "繁转简"
        case .toTraditional: "简转繁"
        }
    }

    public func apply(_ text: String) -> String {
        switch self {
        case .none: text
        case .toSimplified: text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        case .toTraditional: text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        }
    }
}

/// 正文处理：去重复标题 → 简繁转换 → 替换净化 → 拆分段落（流程与 Legado ContentProcessor 一致）
public struct ContentProcessor: Sendable {
    public var rules: [ReplaceRule]
    public var conversion: ChineseConversion

    public init(rules: [ReplaceRule] = [], conversion: ChineseConversion = .none) {
        self.rules = rules
        self.conversion = conversion
    }

    /// 显示用章节标题：应用标题范围的替换规则与简繁转换
    public func displayTitle(_ title: String, book: Book, useReplace: Bool = true) -> String {
        var result = title
        if useReplace {
            for rule in applicableRules(book: book) where rule.scopeTitle {
                result = Self.replace(result, rule: rule)
            }
        }
        return conversion.apply(result)
    }

    /// 处理后的段落（不含标题、不含缩进）。图片保持 `<img …>` 原样且单独成段，夹在文字中间的图片会被拆开
    public func paragraphs(content: String, chapterTitle: String, book: Book, useReplace: Bool = true) -> [String] {
        process(content: content, chapterTitle: chapterTitle, book: book, useReplace: useReplace).paragraphs
    }

    /// 段落及其附带内容：段末的段评标记从文字里拿掉另记；文字中间 `style` 为 TEXT 的小图留在段内，
    /// 文字里用 `InlineImage.inlineMark` 占一个字，其余图片单独成段
    public func process(content: String, chapterTitle: String, book: Book, useReplace: Bool = true) -> ProcessedContent {
        var text = Self.removeSameTitle(content, title: chapterTitle, bookName: book.name)
        text = conversion.apply(text)
        if useReplace {
            let contentRules = applicableRules(book: book).filter(\.scopeContent)
            if !contentRules.isEmpty {
                text = text.components(separatedBy: "\n").map(Self.trimParagraph).joined(separator: "\n")
                for rule in contentRules {
                    text = Self.replace(text, rule: rule)
                }
            }
        }
        var result = ProcessedContent()
        for line in text.components(separatedBy: "\n") {
            Self.appendLine(line, to: &result)
        }
        return result
    }

    private static func appendLine(_ line: String, to result: inout ProcessedContent) {
        let (stripped, comment) = ParagraphComment.extract(from: line)
        let pieces = InlineImage.split(stripped)
        let hasText = pieces.contains { !InlineImage.isImage($0) && !trimParagraph($0).isEmpty }
        var pending = ""
        var inline: [String] = []
        var lastText: Int?
        func flush() {
            let paragraph = trimParagraph(pending)
            defer {
                pending = ""
                inline = []
            }
            guard !paragraph.isEmpty, paragraph != InlineImage.inlineMark || !inline.isEmpty else { return }
            var extras = ParagraphExtras()
            if !inline.isEmpty {
                let ns = paragraph as NSString
                var sources = inline.makeIterator()
                var location = 0
                while location < ns.length {
                    let found = ns.range(of: InlineImage.inlineMark, range: NSRange(location: location, length: ns.length - location))
                    guard found.location != NSNotFound, let src = sources.next() else { break }
                    extras.inlineImages[found.location] = src
                    location = NSMaxRange(found)
                }
            }
            lastText = result.paragraphs.count
            if !extras.isEmpty { result.extras[result.paragraphs.count] = extras }
            result.paragraphs.append(paragraph)
        }
        for piece in pieces {
            guard InlineImage.isImage(piece) else {
                pending += piece
                continue
            }
            if hasText, let src = InlineImage.source(of: piece), InlineImageSource(src).style == .text {
                pending += InlineImage.inlineMark
                inline.append(src)
                continue
            }
            flush()
            let image = trimParagraph(piece)
            if !image.isEmpty { result.paragraphs.append(image) }
        }
        flush()
        if let comment, let index = lastText {
            result.extras[index, default: ParagraphExtras()].comment = comment
        }
    }

    func applicableRules(book: Book) -> [ReplaceRule] {
        rules.filter { $0.isEnabled && !$0.pattern.isEmpty && $0.applies(toBookName: book.name, origin: book.origin) }
    }

    /// 去掉首尾空白与全角空格（Kotlin `trim { it.code <= 0x20 || it == '　' }`）
    static func trimParagraph(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}").union(.whitespacesAndNewlines).union(.controlCharacters))
    }

    /// 正文开头与章节标题重复时去掉：`^(\s|\p{P}|书名)*标题(\s)*`
    static func removeSameTitle(_ content: String, title: String, bookName: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return content }
        let titlePattern = NSRegularExpression.escapedPattern(for: trimmedTitle)
            .replacingOccurrences(of: "\\s+", with: "\\\\s*", options: .regularExpression)
        let namePattern = NSRegularExpression.escapedPattern(for: bookName)
        let pattern = "^(\\s|\\p{P}|\(namePattern))*\(titlePattern)(\\s)*"
        guard let regex = RegexCache.shared.regex(pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range, in: content)
        else { return content }
        return String(content[range.upperBound...])
    }

    static func replace(_ text: String, rule: ReplaceRule) -> String {
        if rule.isRegex {
            guard let regex = RegexCache.shared.regex(rule.pattern) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.replacement)
        }
        return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)
    }
}

/// 处理后的正文：段落（稳定文本）与段落附带内容（段落索引 → 行内小图、段评）
public struct ProcessedContent: Hashable, Sendable {
    public var paragraphs: [String] = []
    public var extras: [Int: ParagraphExtras] = [:]

    public init(paragraphs: [String] = [], extras: [Int: ParagraphExtras] = [:]) {
        self.paragraphs = paragraphs
        self.extras = extras
    }
}

/// 编译后的正则缓存
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]
    private var failed = Set<String>()

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        if failed.contains(pattern) { return nil }
        // 与 Java Pattern 默认行为一致：不开启多行模式，需要时由规则自带 (?m)
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            failed.insert(pattern)
            return nil
        }
        if cache.count > 256 { cache.removeAll() }
        cache[pattern] = regex
        return regex
    }
}
