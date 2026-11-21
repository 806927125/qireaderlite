import Foundation

/// 段评标记：书源在段落末尾放的 `<comment count="12" onPress="java.showReadingBrowser('地址','番茄段评')">`。
/// 不属于正文文字，处理正文时从段落里拿掉，单独记录，排版时在段末画成评论气泡
public struct ParagraphComment: Hashable, Sendable {
    /// 评论数原文
    public var count: String
    /// 点按时在书源环境里执行的脚本
    public var action: String?

    public init(count: String, action: String?) {
        self.count = count
        self.action = action
    }

    /// 气泡上的文字：超过 99 显示 99+
    public var label: String {
        if let number = Int(count), number > 99 { return "99+" }
        return count
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<comment\b([^>]*)>|</comment\s*>"#, options: .caseInsensitive)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_][\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    /// 拿掉一行里的段评标记，返回去掉标记后的文字和最后一个有效标记；没有标记时原样返回
    public static func extract(from line: String) -> (text: String, comment: ParagraphComment?) {
        guard line.range(of: "<comment", options: .caseInsensitive) != nil
            || line.range(of: "</comment", options: .caseInsensitive) != nil else { return (line, nil) }
        let ns = line as NSString
        var comment: ParagraphComment?
        var text = ""
        var start = 0
        for match in tagPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: start, length: match.range.location - start))
            start = NSMaxRange(match.range)
            let attributes = match.range(at: 1)
            if attributes.location != NSNotFound, let parsed = parse(ns.substring(with: attributes)) {
                comment = parsed
            }
        }
        text += ns.substring(from: start)
        return (text, comment)
    }

    static func parse(_ attributes: String) -> ParagraphComment? {
        var values: [String: String] = [:]
        let ns = attributes as NSString
        for match in attributePattern.matches(in: attributes, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            values[name] = ns.substring(with: value)
        }
        let count = (values["count"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !count.isEmpty, count != "0" else { return nil }
        var action = values["onpress"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action?.isEmpty != false, let url = values["ident"], !url.isEmpty {
            // 没经过 paraForiOS 转换的原始标记只有评论页地址
            let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            action = "java.showReadingBrowser('\(escaped)','段评')"
        }
        return ParagraphComment(count: count, action: action?.isEmpty == true ? nil : action)
    }
}

/// 段落附带的、不属于正文文字的内容
public struct ParagraphExtras: Hashable, Sendable {
    /// 行内小图：段内 UTF-16 偏移（该处为 `InlineImage.inlineMark`）→ 图片地址
    public var inlineImages: [Int: String]
    public var comment: ParagraphComment?

    public init(inlineImages: [Int: String] = [:], comment: ParagraphComment? = nil) {
        self.inlineImages = inlineImages
        self.comment = comment
    }

    public var isEmpty: Bool { inlineImages.isEmpty && comment == nil }
}
