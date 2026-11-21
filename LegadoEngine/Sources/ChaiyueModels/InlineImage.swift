import Foundation

/// 正文里的图片段落 `<img src="地址">`。地址可以带 Legado 的 `,{选项}`，选项中的引号不会截断地址
public enum InlineImage {
    private static let sourcePattern = try! NSRegularExpression(
        pattern: #"\ssrc\s*=\s*(['"])([^'"]*(?:['"][^>]+\})?)\1"#, options: .caseInsensitive)
    private static let tagPattern = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)

    /// 行内小图在段落文字中的占位字符（排版时换成图片）
    public static let inlineMark = "\u{FFFC}"

    public static func isImage(_ paragraph: String) -> Bool {
        paragraph.count > 4 && paragraph.prefix(4).lowercased() == "<img" && paragraph.hasSuffix(">")
    }

    /// 图片段落中的地址（原样，未补全）；不是图片段落或没有地址时为 nil
    public static func source(of paragraph: String) -> String? {
        guard isImage(paragraph) else { return nil }
        let ns = paragraph as NSString
        guard let match = sourcePattern.firstMatch(in: paragraph, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// 地址选项带 click / js 的图片是点按动作（段评气泡、神评论卡片、本章说卡片）。Legado 的 js 选项本是请求前改写地址，
    /// 但书源在苹果环境下把它当点按脚本，请求图片前要去掉（见 `InlineImageSource.requestURL`）
    public static func isAction(_ source: String) -> Bool {
        guard let start = source.range(of: #",\s*\{"#, options: .regularExpression) else { return false }
        return source[start.lowerBound...].range(of: #"['"]?\b(click|js)\b['"]?\s*:"#, options: .regularExpression) != nil
    }

    /// 把夹在文字之间的图片拆成单独的段落；没有图片时原样返回
    public static func split(_ paragraph: String) -> [String] {
        guard paragraph.range(of: "<img", options: .caseInsensitive) != nil else { return [paragraph] }
        let ns = paragraph as NSString
        var parts: [String] = []
        var start = 0
        for match in tagPattern.matches(in: paragraph, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            parts.append(ns.substring(with: match.range))
            start = NSMaxRange(match.range)
        }
        parts.append(ns.substring(from: start))
        return parts
    }

    /// `data:` 地址的内容：支持 base64 与 URL 编码两种写法，`,{选项}` 会先去掉；不是 data 地址或解码失败时为 nil
    public static func dataURLContent(_ url: String) -> Data? {
        let address = InlineImageSource(url).url
        guard address.prefix(5).lowercased() == "data:", let comma = address.firstIndex(of: ",") else { return nil }
        let header = address[address.index(address.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(address[address.index(after: comma)...])
        if header.hasSuffix(";base64") {
            let cleaned = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters)
        }
        return (payload.removingPercentEncoding ?? payload).data(using: .utf8)
    }
}

/// 图片地址拆出的 Legado 选项：`style` 排版方式、`click`/`js` 点按脚本，其余选项（请求头等）留给请求
public struct InlineImageSource: Hashable, Sendable {
    public enum Style: String, Sendable {
        /// 铺满正文宽度
        case full
        /// 与文字同高的小图
        case text
    }

    /// 原始地址（图片段落里的写法）
    public let raw: String
    /// 去掉选项的地址
    public let url: String
    public let style: Style?
    /// 点按时在书源环境里执行的脚本
    public let action: String?
    /// 用于请求的地址：去掉 style、click、js 后的其余选项原样保留
    public let requestURL: String

    private static let optionStart = try! NSRegularExpression(pattern: #"\s*,\s*(?=\{)"#)
    private static let viewKeys: Set<String> = ["style", "click", "js"]

    public init(_ raw: String) {
        self.raw = raw
        let ns = raw as NSString
        guard let match = Self.optionStart.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
            url = raw
            style = nil
            action = nil
            requestURL = raw
            return
        }
        let address = ns.substring(to: match.range.location)
        let optionText = ns.substring(from: NSMaxRange(match.range))
        url = address
        guard let options = Self.parseOptions(optionText) else {
            style = nil
            action = nil
            requestURL = InlineImage.isAction(raw) ? address : raw
            return
        }
        style = (options.first { $0.key.lowercased() == "style" }?.value as? String).flatMap { Style(rawValue: $0.lowercased()) }
        let script = { (key: String) in (options[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        action = [script("click"), script("js")].compactMap { $0 }.first { !$0.isEmpty }
        let rest = options.filter { !Self.viewKeys.contains($0.key.lowercased()) }
        if rest.count == options.count {
            requestURL = raw
        } else if rest.isEmpty {
            requestURL = address
        } else if let data = try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) {
            requestURL = address + "," + text
        } else {
            requestURL = address
        }
    }

    /// 选项是 JSON；安卓书源常用单引号，按 JSON5 兼容解析
    static func parseOptions(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        #if canImport(Darwin)
        // ⭐⭐⭐ **Apple 平台支持 JSON5**（安卓书源常用单引号）⇒ 柴阅的强项 ⇒ 保持原样 ⭐⭐⭐
        if let o = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any] {
            return o
        }
        #endif
        // ⭐⭐⭐ **非 Apple 平台退化为标准 JSON**（Linux 沙盒门禁用）⭐⭐⭐
        //   ⚠️ 这是一处**平台差异** ⇒ 沙盒门禁里 JSON5 用例会与真机不同 ⭐⭐⭐
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
