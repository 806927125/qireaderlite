import Foundation

/// URL 工具。手写解析与合并，不做百分号编码，保留中文等字符，
/// 以便后续按书源指定的字符集（如 GBK）编码。
public enum URLUtils {
    /// URL 与选项 JSON 的分隔：`url,{...}`
    static let paramPattern = #"\s*,\s*(?=\{)"#

    struct Parts {
        var scheme: String
        var authority: String
        var path: String
        var query: String?
        var fragment: String?

        var origin: String { "\(scheme)://\(authority)" }

        var string: String {
            var s = "\(scheme)://\(authority)\(path)"
            if let query { s += "?\(query)" }
            if let fragment { s += "#\(fragment)" }
            return s
        }
    }

    /// 去掉 `,{选项}` 部分
    public static func stripOptions(_ url: String) -> String {
        guard let m = url.firstMatch(paramPattern) else { return url }
        return url.substring(with: NSRange(location: 0, length: m.range.location))
    }

    static func parse(_ url: String) -> Parts? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let scheme = String(url[..<schemeEnd.lowerBound])
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        var rest = String(url[schemeEnd.upperBound...])
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        var query: String?
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        let authority: String
        let path: String
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            path = String(rest[slash...])
        } else {
            authority = rest
            path = ""
        }
        return Parts(scheme: scheme.lowercased(), authority: authority, path: path, query: query, fragment: fragment)
    }

    /// 与 Legado `NetworkUtils.getAbsoluteURL` 一致
    public static func absoluteURL(base: String?, relative: String) -> String {
        let rel = relative.trimmedWhitespace
        guard let base, !base.isEmpty else { return rel }
        if rel.isAbsUrl || rel.isDataUrl { return rel }
        if rel.lowercased().hasPrefix("javascript") { return "" }
        guard let baseParts = parse(stripOptions(base)) else { return rel }
        return resolve(base: baseParts, reference: rel)
    }

    /// RFC 3986 5.2 引用解析
    static func resolve(base: Parts, reference ref: String) -> String {
        if ref.isEmpty {
            var b = base
            b.fragment = nil
            return b.string
        }
        // 带协议的引用（如 mailto:、ftp://）直接返回
        if let colon = ref.firstIndex(of: ":"),
           ref[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
           ref.first?.isLetter == true {
            return ref
        }
        if ref.hasPrefix("//") {
            return "\(base.scheme):\(ref)"
        }
        var refPath = ref
        var refFragment: String?
        if let hash = refPath.firstIndex(of: "#") {
            refFragment = String(refPath[refPath.index(after: hash)...])
            refPath = String(refPath[..<hash])
        }
        var refQuery: String?
        if let q = refPath.firstIndex(of: "?") {
            refQuery = String(refPath[refPath.index(after: q)...])
            refPath = String(refPath[..<q])
        }
        var target = base
        target.fragment = refFragment
        if refPath.isEmpty {
            if refQuery != nil { target.query = refQuery }
            return target.string
        }
        target.query = refQuery
        if refPath.hasPrefix("/") {
            target.path = removeDotSegments(refPath)
        } else {
            let basePath = base.path.isEmpty ? "/" : base.path
            let merged: String
            if let lastSlash = basePath.lastIndex(of: "/") {
                merged = String(basePath[...lastSlash]) + refPath
            } else {
                merged = "/" + refPath
            }
            target.path = removeDotSegments(merged)
        }
        return target.string
    }

    static func removeDotSegments(_ path: String) -> String {
        var output: [Substring] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, seg) in segments.enumerated() {
            if seg == "." {
                if index == segments.count - 1 { output.append("") }
                continue
            }
            if seg == ".." {
                if output.count > 1 { output.removeLast() }
                if index == segments.count - 1 { output.append("") }
                continue
            }
            output.append(seg)
        }
        var result = output.joined(separator: "/")
        if !result.hasPrefix("/") { result = "/" + result }
        return result
    }

    /// `scheme://host[:port]`，与 Legado `NetworkUtils.getBaseUrl` 一致
    public static func baseUrl(_ url: String?) -> String? {
        guard let url, url.isAbsUrl else { return nil }
        let nsurl = url as NSString
        let searchStart = min(9, nsurl.length)
        let r = nsurl.range(of: "/", options: [], range: NSRange(location: searchStart, length: nsurl.length - searchStart))
        return r.location == NSNotFound ? url : nsurl.substring(to: r.location)
    }

    public static func host(_ url: String?) -> String? {
        guard let url, let parts = parse(stripOptions(url)) else { return nil }
        var authority = parts.authority
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        if authority.hasPrefix("[") {
            if let end = authority.firstIndex(of: "]") {
                return String(authority[authority.index(after: authority.startIndex)..<end]).lowercased()
            }
            return authority.lowercased()
        }
        if let colon = authority.lastIndex(of: ":") {
            return String(authority[..<colon]).lowercased()
        }
        return authority.lowercased()
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// 可注册域名（eTLD+1），用于 Cookie 归组。IP 与 localhost 原样返回。
    public static func registrableDomain(_ urlOrHost: String) -> String {
        let host = (urlOrHost.contains("://") ? host(urlOrHost) : urlOrHost.lowercased()) ?? urlOrHost
        if isIPAddress(host) || !host.contains(".") { return host }
        return PublicSuffix.registrableDomain(host) ?? host
    }

    /// Legado `NetworkUtils.getSubDomain`：返回可注册域名；非 http 地址原样返回
    public static func subDomain(_ url: String) -> String {
        guard baseUrl(url) != nil else { return url }
        return registrableDomain(url)
    }
}

/// 公共后缀判断。优先使用 App 提供的 PSL 数据，没有时用内置的常见多级后缀兜底。
public enum PublicSuffix {
    nonisolated(unsafe) private static var rules: Set<String>?
    private static let lock = NSLock()

    private static let builtinMultiLevel: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "net.hk", "org.hk", "com.tw", "net.tw", "org.tw", "idv.tw",
        "co.jp", "ne.jp", "or.jp", "co.kr", "co.uk", "org.uk", "ac.uk",
        "com.au", "net.au", "org.au", "com.sg", "com.my", "co.in", "co.id",
        "com.br", "com.vn", "com.ru", "github.io", "gitee.io", "vercel.app",
        "pages.dev", "workers.dev", "netlify.app", "herokuapp.com",
    ]

    /// 载入 PSL 文本（publicsuffix.org 格式）
    public static func load(_ text: String) {
        var set = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("//") { continue }
            set.insert(String(t.split(separator: " ").first ?? Substring(t)).lowercased())
        }
        lock.lock()
        rules = set
        lock.unlock()
    }

    static func registrableDomain(_ host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        lock.lock()
        let psl = rules
        lock.unlock()
        // 找到最长匹配的公共后缀
        var suffixLength = 1
        for n in stride(from: labels.count - 1, through: 1, by: -1) {
            let candidate = labels.suffix(n).joined(separator: ".")
            if let psl {
                let wildcard = "*." + labels.suffix(n - 1).joined(separator: ".")
                if psl.contains("!" + candidate) {
                    suffixLength = n - 1
                    break
                }
                if psl.contains(candidate) || (n > 1 && psl.contains(wildcard)) {
                    suffixLength = n
                    break
                }
            } else if builtinMultiLevel.contains(candidate) {
                suffixLength = n
                break
            }
        }
        guard labels.count > suffixLength else { return nil }
        return labels.suffix(suffixLength + 1).joined(separator: ".")
    }
}
