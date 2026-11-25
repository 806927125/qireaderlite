import Foundation

/// 阅读主题样式表：CSS 的一个子集，解析后映射到原生排版参数。
///
/// 选择器：`body`/`p`（正文）、`.chap-no`（章序号行）、`.chap-title`（章名）、`.header`、`.footer`、`.page`（纸面），
/// `p.名字` 或 `.名字`（脚本 `paragraphClass` 给段落分的类）、`:root`（只放 `--变量`）。
/// 支持 `@media (prefers-color-scheme: dark|light)` 分深浅两套，`var(--名字, 备用值)` 引用变量。
/// 不认识的选择器、属性或取值不会报错中断，只记进 `diagnostics`
public struct ReaderStyleSheet: Sendable, Hashable {
    public struct Declaration: Sendable, Hashable {
        public let name: String
        public let value: String
        public let line: Int
    }

    public struct Rule: Sendable, Hashable {
        public let selectors: [String]
        public let declarations: [Declaration]
        /// nil 表示深浅都生效
        public let dark: Bool?
    }

    public let rules: [Rule]
    public private(set) var diagnostics: [ReaderStyleDiagnostic]

    public init(css: String) {
        var parser = CSSParser(css)
        let parsed = parser.parse()
        rules = parsed
        diagnostics = parser.diagnostics
        // 用两种外观各解析一遍，收集取值层面的问题（同一行只报一次）
        var seen = Set(diagnostics)
        for dark in [false, true] {
            for item in Self.resolve(rules: parsed, dark: dark).1 where seen.insert(item).inserted {
                diagnostics.append(item)
            }
        }
        diagnostics.sort { ($0.line, $0.message) < ($1.line, $1.message) }
    }

    public func resolve(dark: Bool) -> ReaderPageStyle {
        Self.resolve(rules: rules, dark: dark).0
    }

    private static func resolve(rules: [Rule], dark: Bool) -> (ReaderPageStyle, [ReaderStyleDiagnostic]) {
        let active = rules.filter { $0.dark == nil || $0.dark == dark }
        var variables: [String: String] = [:]
        for rule in active {
            for item in rule.declarations where item.name.hasPrefix("--") { variables[item.name] = item.value }
        }
        var style = ReaderPageStyle()
        var problems: [ReaderStyleDiagnostic] = []
        for rule in active {
            for selector in rule.selectors {
                for item in rule.declarations {
                    let value = substitute(item.value, variables: variables)
                    if let message = apply(item.name, value, to: selector, in: &style) {
                        problems.append(ReaderStyleDiagnostic(line: item.line, message: message))
                    }
                }
            }
        }
        return (style, problems)
    }

    private static func substitute(_ value: String, variables: [String: String], depth: Int = 0) -> String {
        guard depth < 8, let range = value.range(of: "var(") else { return value }
        var level = 1
        var index = range.upperBound
        while index < value.endIndex, level > 0 {
            if value[index] == "(" { level += 1 }
            if value[index] == ")" { level -= 1 }
            if level > 0 { index = value.index(after: index) }
        }
        guard index < value.endIndex else { return value }
        let inner = String(value[range.upperBound..<index])
        let parts = inner.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let replacement = parts.first.flatMap { variables[$0] } ?? (parts.count > 1 ? parts[1] : "")
        let next = value.replacingCharacters(in: range.lowerBound...index, with: replacement)
        return substitute(next, variables: variables, depth: depth + 1)
    }

    /// 返回问题描述；成功或可以忽略时为 nil
    private static func apply(_ name: String, _ value: String, to selector: String, in style: inout ReaderPageStyle) -> String? {
        if name.hasPrefix("--") {
            if selector == ".page", name == "--grain" {
                guard let number = Double(value) else { return "--grain 需要 0–1 的数字" }
                style.page.grain = min(max(number, 0), 1)
            }
            return nil
        }
        switch selector {
        case ":root":
            return "「\(name)」：:root 里只能放 --变量"
        case ".page":
            return applyPage(name, value, to: &style.page)
        case "body", "p":
            return applyText(name, value, to: &style.body, allowLineHeight: true)
        case ".chap-no":
            return applyText(name, value, to: &style.chapterNumber, allowLineHeight: false)
        case ".chap-title":
            return applyText(name, value, to: &style.chapterTitle, allowLineHeight: false)
        case ".header":
            return applyText(name, value, to: &style.header, allowLineHeight: false)
        case ".footer":
            return applyText(name, value, to: &style.footer, allowLineHeight: false)
        default:
            var key = selector
            if key.hasPrefix("p.") { key.removeFirst(2) } else if key.hasPrefix(".") { key.removeFirst() } else {
                return "不支持的选择器「\(selector)」"
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                return "不支持的选择器「\(selector)」"
            }
            var text = style.classes[key] ?? ReaderTextStyle()
            let problem = applyText(name, value, to: &text, allowLineHeight: false)
            style.classes[key] = text
            return problem
        }
    }

    private static func applyPage(_ name: String, _ value: String, to page: inout ReaderPageBox) -> String? {
        switch name {
        case "background-color":
            guard let color = ReaderColor(css: value) else { return "无法识别的颜色「\(value)」" }
            page.background = color
        case "background":
            var matched = false
            for token in tokens(value) {
                if let color = ReaderColor(css: token) {
                    page.background = color
                    matched = true
                } else if let url = urlName(token) {
                    page.backgroundImage = url
                    matched = true
                } else if let size = ReaderPageBox.ImageFit(rawValue: token) {
                    page.backgroundFit = size
                    matched = true
                }
            }
            if !matched { return "无法识别的背景「\(value)」" }
        case "background-image":
            if value == "none" {
                page.backgroundImage = nil
            } else {
                guard let url = urlName(value) else { return "背景图要写成 url(文件名)" }
                page.backgroundImage = url
            }
        case "background-size":
            guard let fit = ReaderPageBox.ImageFit(rawValue: value) else { return "background-size 只支持 cover / contain" }
            page.backgroundFit = fit
        case "background-repeat":
            if value == "repeat" { page.backgroundFit = .repeat } else if value != "no-repeat" {
                return "background-repeat 只支持 repeat / no-repeat"
            }
        case "padding":
            let parts = tokens(value).map { ReaderLength(css: $0)?.points(fontSize: 19) }
            guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return "无法识别的 padding「\(value)」" }
            let p = parts.compactMap { $0 }
            let top = p[0], right = p.count > 1 ? p[1] : p[0], bottom = p.count > 2 ? p[2] : p[0]
            let left = p.count > 3 ? p[3] : right
            page.paddingTop = top
            page.paddingRight = right
            page.paddingBottom = bottom
            page.paddingLeft = left
        case "padding-top", "padding-right", "padding-bottom", "padding-left":
            guard let length = ReaderLength(css: value) else { return "无法识别的长度「\(value)」" }
            let points = length.points(fontSize: 19)
            switch name {
            case "padding-top": page.paddingTop = points
            case "padding-right": page.paddingRight = points
            case "padding-bottom": page.paddingBottom = points
            default: page.paddingLeft = points
            }
        default:
            return "纸面（.page）不支持属性「\(name)」"
        }
        return nil
    }

    private static func applyText(_ name: String, _ value: String, to text: inout ReaderTextStyle, allowLineHeight: Bool) -> String? {
        switch name {
        case "font-family":
            text.fontFamily = families(value)
        case "font-size":
            guard let length = ReaderLength(css: value), length.isAbsoluteOrEm else { return "无法识别的字号「\(value)」" }
            text.fontSize = length
        case "font-weight":
            guard let weight = fontWeight(value) else { return "无法识别的字重「\(value)」" }
            text.fontWeight = weight
        case "font-style":
            text.italic = value == "italic" || value == "oblique"
        case "font":
            return applyFontShorthand(value, to: &text, allowLineHeight: allowLineHeight)
        case "color":
            guard let color = ReaderColor(css: value) else { return "无法识别的颜色「\(value)」" }
            text.color = color
        case "opacity":
            guard let number = Double(value) else { return "opacity 需要 0–1 的数字" }
            text.opacity = min(max(number, 0), 1)
        case "letter-spacing":
            if value == "normal" {
                text.letterSpacing = .px(0)
            } else {
                guard let length = ReaderLength(css: value) else { return "无法识别的字距「\(value)」" }
                text.letterSpacing = length
            }
        case "line-height":
            guard allowLineHeight else { return "line-height 只对正文（body / p）生效" }
            guard let length = ReaderLength(css: value) else { return "无法识别的行高「\(value)」" }
            text.lineHeight = length
        case "text-align":
            guard let align = ReaderTextAlign(rawValue: value == "start" ? "left" : value == "end" ? "right" : value) else {
                return "text-align 只支持 left / right / center / justify"
            }
            text.textAlign = align
        case "text-indent":
            guard let length = ReaderLength(css: value) else { return "无法识别的缩进「\(value)」" }
            text.textIndent = length
        case "margin":
            let parts = tokens(value).map(ReaderLength.init(css:))
            guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return "无法识别的 margin「\(value)」" }
            let p = parts.compactMap { $0 }
            text.marginTop = p[0]
            text.marginBottom = p.count > 2 ? p[2] : p[0]
        case "margin-top", "margin-bottom":
            guard let length = ReaderLength(css: value) else { return "无法识别的长度「\(value)」" }
            if name == "margin-top" { text.marginTop = length } else { text.marginBottom = length }
        case "margin-left", "margin-right":
            return "左右边距请写在 .page 的 padding 上"
        case "display":
            text.hidden = value == "none"
        case "visibility":
            text.hidden = value == "hidden"
        case "text-transform", "text-decoration", "text-shadow", "word-spacing", "white-space":
            return "暂不支持属性「\(name)」"
        default:
            return "不支持的属性「\(name)」"
        }
        return nil
    }

    private static func applyFontShorthand(_ value: String, to text: inout ReaderTextStyle, allowLineHeight: Bool) -> String? {
        var parts = tokens(value)
        guard let sizeIndex = parts.firstIndex(where: { token in
            ReaderLength(css: token.split(separator: "/").first.map(String.init) ?? token)?.isAbsoluteOrEm == true
        }) else { return "font 简写里找不到字号" }
        for token in parts[..<sizeIndex].map({ $0.lowercased() }) {
            if token == "italic" || token == "oblique" { text.italic = true } else if let weight = fontWeight(token) {
                text.fontWeight = weight
            }
        }
        let sizeToken = parts[sizeIndex].lowercased()
        let pieces = sizeToken.split(separator: "/").map(String.init)
        text.fontSize = ReaderLength(css: pieces[0])
        if pieces.count > 1 {
            guard allowLineHeight else { return "line-height 只对正文（body / p）生效" }
            text.lineHeight = ReaderLength(css: pieces[1])
        }
        parts.removeSubrange(...sizeIndex)
        if !parts.isEmpty { text.fontFamily = families(parts.joined(separator: " ")) }
        return nil
    }

    private static func fontWeight(_ value: String) -> Int? {
        switch value {
        case "normal": 400
        case "bold": 700
        case "lighter": 300
        case "bolder": 800
        default: Int(value).flatMap { (100...900).contains($0) ? $0 : nil }
        }
    }

    private static func families(_ value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
    }

    /// 按空白拆分，括号与引号内不拆
    static func tokens(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for char in value {
            if let q = quote {
                current.append(char)
                if char == q { quote = nil }
                continue
            }
            switch char {
            case "\"", "'": quote = char; current.append(char)
            case "(": depth += 1; current.append(char)
            case ")": depth = max(0, depth - 1); current.append(char)
            default:
                if depth == 0, char.isWhitespace {
                    if !current.isEmpty { result.append(current); current = "" }
                } else {
                    current.append(char)
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func urlName(_ token: String) -> String? {
        guard token.hasPrefix("url("), token.hasSuffix(")") else { return nil }
        let inner = token.dropFirst(4).dropLast().trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return inner.isEmpty ? nil : inner
    }
}

public struct ReaderStyleDiagnostic: Sendable, Hashable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// 解析后的页面样式；没写的项为 nil，由使用方套默认值
public struct ReaderPageStyle: Sendable, Hashable {
    public var body = ReaderTextStyle()
    public var chapterNumber = ReaderTextStyle()
    public var chapterTitle = ReaderTextStyle()
    public var header = ReaderTextStyle()
    public var footer = ReaderTextStyle()
    public var page = ReaderPageBox()
    public var classes: [String: ReaderTextStyle] = [:]

    public init() {}
}

public struct ReaderTextStyle: Sendable, Hashable {
    public var fontFamily: [String]?
    public var fontSize: ReaderLength?
    public var fontWeight: Int?
    public var italic: Bool?
    public var color: ReaderColor?
    public var opacity: Double?
    public var letterSpacing: ReaderLength?
    public var lineHeight: ReaderLength?
    public var textAlign: ReaderTextAlign?
    public var textIndent: ReaderLength?
    public var marginTop: ReaderLength?
    public var marginBottom: ReaderLength?
    public var hidden: Bool?

    public init() {}

    public var isBold: Bool? { fontWeight.map { $0 >= 600 } }
}

public struct ReaderPageBox: Sendable, Hashable {
    public enum ImageFit: String, Sendable, Hashable {
        case cover, contain, `repeat`
    }

    public var background: ReaderColor?
    public var backgroundImage: String?
    public var backgroundFit: ImageFit = .cover
    public var paddingTop: Double?
    public var paddingRight: Double?
    public var paddingBottom: Double?
    public var paddingLeft: Double?
    public var grain: Double?

    public init() {}
}

public enum ReaderTextAlign: String, Sendable, Hashable {
    case left, right, center, justify
}

public enum ReaderLength: Sendable, Hashable {
    case px(Double)
    case em(Double)
    case percent(Double)
    /// 不带单位的数字（line-height 专用：字号的倍数）
    case number(Double)

    public init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces).lowercased()
        func number(_ suffix: String) -> Double? {
            guard text.hasSuffix(suffix) else { return nil }
            return Double(text.dropLast(suffix.count))
        }
        if let value = number("px") ?? number("pt") {
            self = .px(value)
        } else if let value = number("rem") ?? number("em") {
            self = .em(value)
        } else if let value = number("%") {
            self = .percent(value)
        } else if let value = Double(text) {
            self = value == 0 ? .px(0) : .number(value)
        } else {
            return nil
        }
    }

    var isAbsoluteOrEm: Bool {
        switch self {
        case .px, .em, .percent: true
        case .number: false
        }
    }

    /// 换算成点；em、百分比与数字都相对 `fontSize`
    public func points(fontSize: Double) -> Double {
        switch self {
        case .px(let value): value
        case .em(let value), .number(let value): value * fontSize
        case .percent(let value): value / 100 * fontSize
        }
    }
}

public struct ReaderColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 0xRRGGBB（不含透明度）
    public var rgb: UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    public var platform: PlatformColor {
        PlatformColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let hex = Array(text.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            func pair(_ s: ArraySlice<Character>) -> Double { Double(Int(String(s), radix: 16) ?? 0) / 255 }
            switch hex.count {
            case 3, 4:
                let v = hex.map { pair([$0, $0][...]) }
                self.init(red: v[0], green: v[1], blue: v[2], alpha: hex.count == 4 ? v[3] : 1)
            case 6, 8:
                self.init(red: pair(hex[0..<2]), green: pair(hex[2..<4]), blue: pair(hex[4..<6]),
                          alpha: hex.count == 8 ? pair(hex[6..<8]) : 1)
            default:
                return nil
            }
            return
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let parts = inner.replacingOccurrences(of: "/", with: ",").split(whereSeparator: { $0 == "," || $0 == " " })
                .map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ s: String) -> Double? {
                s.hasSuffix("%") ? Double(s.dropLast()).map { $0 / 100 } : Double(s).map { $0 / 255 }
            }
            func alphaValue(_ s: String) -> Double? {
                s.hasSuffix("%") ? Double(s.dropLast()).map { $0 / 100 } : Double(s)
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            let a = parts.count == 4 ? alphaValue(parts[3]) : 1
            guard let a else { return nil }
            self.init(red: r, green: g, blue: b, alpha: a)
            return
        }
        let named: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "gray": 0x808080, "grey": 0x808080, "red": 0xFF0000,
            "green": 0x008000, "blue": 0x0000FF, "brown": 0xA52A2A, "orange": 0xFFA500, "ivory": 0xFFFFF0,
            "beige": 0xF5F5DC, "wheat": 0xF5DEB3, "linen": 0xFAF0E6, "navy": 0x000080, "teal": 0x008080,
            "maroon": 0x800000, "olive": 0x808000, "silver": 0xC0C0C0, "dimgray": 0x696969, "darkgray": 0xA9A9A9,
        ]
        if text == "transparent" {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        guard let value = named[text] else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// 逐字符扫描：注释、规则块、一层 @media
private struct CSSParser {
    private let chars: [Character]
    private var index = 0
    private var line = 1
    var diagnostics: [ReaderStyleDiagnostic] = []

    init(_ css: String) {
        chars = Array(css)
    }

    mutating func parse() -> [ReaderStyleSheet.Rule] {
        var rules: [ReaderStyleSheet.Rule] = []
        parseBlock(into: &rules, dark: nil, nested: false)
        return rules
    }

    private mutating func parseBlock(into rules: inout [ReaderStyleSheet.Rule], dark: Bool?, nested: Bool) {
        while true {
            skipSpaceAndComments()
            guard index < chars.count else {
                if nested { diagnostics.append(.init(line: line, message: "@media 缺少右花括号")) }
                return
            }
            if chars[index] == "}" {
                if nested {
                    advance()
                    return
                }
                diagnostics.append(.init(line: line, message: "多余的右花括号"))
                advance()
                continue
            }
            let startLine = line
            let prelude = readUntil(["{", ";", "}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard index < chars.count, chars[index] == "{" else {
                if index < chars.count, chars[index] == ";" { advance() }
                if !prelude.isEmpty { diagnostics.append(.init(line: startLine, message: "无法理解「\(prelude)」")) }
                continue
            }
            advance()
            if prelude.hasPrefix("@") {
                let lowered = prelude.lowercased().replacingOccurrences(of: " ", with: "")
                if lowered.hasPrefix("@media"), !nested, lowered.contains("prefers-color-scheme:dark") || lowered.contains("prefers-color-scheme:light") {
                    parseBlock(into: &rules, dark: lowered.contains(":dark"), nested: true)
                } else {
                    diagnostics.append(.init(line: startLine, message: "不支持「\(prelude)」，整块已忽略"))
                    skipBlock()
                }
                continue
            }
            let declarations = parseDeclarations()
            let selectors = prelude.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }.filter { !$0.isEmpty }
            guard !selectors.isEmpty else {
                diagnostics.append(.init(line: startLine, message: "规则缺少选择器"))
                continue
            }
            rules.append(.init(selectors: selectors, declarations: declarations, dark: dark))
        }
    }

    private mutating func parseDeclarations() -> [ReaderStyleSheet.Declaration] {
        var result: [ReaderStyleSheet.Declaration] = []
        while true {
            skipSpaceAndComments()
            guard index < chars.count else {
                diagnostics.append(.init(line: line, message: "缺少右花括号"))
                return result
            }
            if chars[index] == "}" {
                advance()
                return result
            }
            if chars[index] == ";" {
                advance()
                continue
            }
            let startLine = line
            let text = readUntil([";", "}"])
            if index < chars.count, chars[index] == ";" { advance() }
            guard let colon = text.firstIndex(of: ":") else {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { diagnostics.append(.init(line: startLine, message: "「\(trimmed)」缺少冒号")) }
                continue
            }
            let name = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasSuffix("!important") {
                value = String(value.dropLast(10)).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty, !value.isEmpty else {
                diagnostics.append(.init(line: startLine, message: "「\(name)」没有取值"))
                continue
            }
            let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // 字体名区分大小写（PostScript 名），变量原样保留，到引用处再按所在属性处理
            let keepCase = name.hasPrefix("--") || name == "font-family" || name == "font"
            result.append(.init(name: name, value: keepCase ? normalized : normalized.lowercasedKeepingQuotesAndURLs(), line: startLine))
        }
    }

    /// 读到任一停止符（不含），跳过注释、引号与括号内的内容
    private mutating func readUntil(_ stops: Set<Character>) -> String {
        var result = ""
        var depth = 0
        var quote: Character?
        while index < chars.count {
            let char = chars[index]
            if let q = quote {
                result.append(char)
                advance()
                if char == q { quote = nil }
                continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                skipComment()
                result.append(" ")
                continue
            }
            if depth == 0, stops.contains(char) { break }
            if char == "\"" || char == "'" { quote = char }
            if char == "(" { depth += 1 }
            if char == ")" { depth = max(0, depth - 1) }
            result.append(char)
            advance()
        }
        return result
    }

    private mutating func skipBlock() {
        var depth = 1
        while index < chars.count, depth > 0 {
            if chars[index] == "{" { depth += 1 }
            if chars[index] == "}" { depth -= 1 }
            advance()
        }
    }

    private mutating func skipSpaceAndComments() {
        while index < chars.count {
            if chars[index].isWhitespace {
                advance()
            } else if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                skipComment()
            } else {
                return
            }
        }
    }

    private mutating func skipComment() {
        index += 2
        while index < chars.count {
            if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "/" {
                index += 2
                return
            }
            advance()
        }
    }

    private mutating func advance() {
        if chars[index] == "\n" { line += 1 }
        index += 1
    }
}

private extension String {
    /// 关键字大小写不敏感，但字体名、url 里的文件名保持原样
    func lowercasedKeepingQuotesAndURLs() -> String {
        var result = ""
        var quote: Character?
        var inURL = false
        var chars = Array(self)[...]
        while let char = chars.first {
            chars = chars.dropFirst()
            if let q = quote {
                result.append(char)
                if char == q { quote = nil }
                continue
            }
            if inURL {
                result.append(char)
                if char == ")" { inURL = false }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                result.append(char)
                continue
            }
            if result.lowercased().hasSuffix("url"), char == "(" {
                inURL = true
                result.append(char)
                continue
            }
            result.append(contentsOf: char.lowercased())
        }
        return result
    }
}
