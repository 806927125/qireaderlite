import Foundation

/// URL 工具。
public enum NetworkUtils {
    /// 相对 URL 绝对化（协议相对 //、根相对 /、相对路径、data:、已绝对）。
    public static func absoluteURL(_ baseURL: String?, _ relative: String) -> String {
        let r = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return "" }
        if r.hasPrefix("data:") || r.hasPrefix("javascript:") { return r }
        if r.hasPrefix("http://") || r.hasPrefix("https://") { return r }
        guard let base = baseURL, !base.isEmpty, let bu = URL(string: base) else { return r }
        if r.hasPrefix("//") { return (bu.scheme ?? "https") + ":" + r }
        if let u = URL(string: r, relativeTo: bu) { return u.absoluteString }
        return r
    }

    static func unescapeHTML(_ s: String) -> String {
        var out = s
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&nbsp;", " "), ("&#39;", "'"),
        ]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        // 数字实体
        let pat = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        let ms = pat.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for m in ms.reversed() {
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
            }
        }
        return out
    }
}