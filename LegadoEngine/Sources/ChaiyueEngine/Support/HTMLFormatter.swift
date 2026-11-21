import Foundation

/// 正文 HTML 转纯文本（行为与 Legado HtmlFormatter 一致）
public enum HTMLFormatter {
    private static let nbsp = "(&nbsp;)+"
    private static let esp = "(&ensp;|&emsp;)"
    private static let noPrint = "(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})"
    private static let wrapHtml = "</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>"
    private static let comment = "<!--[^>]*-->"
    /// 正文保留图片与段评标记（`<comment count onPress>`，源阅读书源在段末输出）
    private static let notImgHtml = "</?(?!img|comment\\b)[a-zA-Z]+(?=[ >])[^<>]*>"
    private static let otherHtml = "</?[a-zA-Z]+(?=[ >])[^<>]*>"
    private static let imagePattern =
        #"<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>|<img[^>]*\s(?:data-src|src)\s*=\s*['"]([^'">]+)['"][^>]*>|<img[^>]*\sdata-[^=>]*=\s*['"]([^'">]*)['"][^>]*>"#

    public static func format(_ html: String?) -> String {
        format(html, otherRegex: otherHtml)
    }

    static func format(_ html: String?, otherRegex: String) -> String {
        guard let html else { return "" }
        return html
            .replacingRegex(nbsp, with: " ")
            .replacingRegex(esp, with: " ")
            .replacingRegex(noPrint, with: "")
            .replacingRegex("(?i)" + wrapHtml, with: "\n")
            .replacingRegex(comment, with: "")
            .replacingRegex(otherRegex, with: "")
            .replacingRegex("\\s*\\n+\\s*", with: "\n　　")
            .replacingRegex("^[\\n\\s]+", with: "　　")
            .replacingRegex("[\\n\\s]+$", with: "")
    }

    /// 保留图片标签，并把图片地址补全为绝对地址（保留 `,{选项}`）
    public static func formatKeepImg(_ html: String?, baseURL: String? = nil) -> String {
        guard let html else { return "" }
        let keepImg = format(html, otherRegex: notImgHtml)
        guard let re = try? RegexCache.shared.regex(imagePattern, options: .caseInsensitive) else { return keepImg }
        let ns = keepImg as NSString
        var out = ""
        var appendPos = 0
        for m in re.matches(in: keepImg, range: keepImg.fullRange) {
            out += ns.substring(with: NSRange(location: appendPos, length: m.range.location - appendPos))
            var param = ""
            var src: String
            if let g1 = keepImg.group(m, 1) {
                if let pm = g1.firstMatch(URLUtils.paramPattern) {
                    let g1ns = g1 as NSString
                    param = "," + g1ns.substring(from: pm.range.location + pm.range.length)
                    src = g1ns.substring(to: pm.range.location)
                } else {
                    src = g1
                }
            } else {
                src = keepImg.group(m, 2) ?? keepImg.group(m, 3) ?? ""
            }
            src = URLUtils.absoluteURL(base: baseURL, relative: src)
            out += "<img src=\"\(src)\(param)\">"
            appendPos = m.range.location + m.range.length
        }
        if appendPos < ns.length {
            out += ns.substring(from: appendPos)
        }
        return out
    }
}
