import Foundation

/// **URL 规则**（纯 Foundation；语义照搬 Legado `AnalyzeUrl` + 栖阅 `AnalyzeUrl`）
///
/// ## 为什么搬到 Swift
/// 栖阅的 URL 规则是**原生 Swift**（`AnalyzeUrl.swift` + `+Request` + `+Network` + `+JSContextSetup`）。
/// 轻阅原来把它放在 JS 里（`engine.js · analyzeUrl`）⇒ **沙盒（Node fetch）和真机（URL(string:)）
/// 用了两套不同的 URL 实现** ⇒ 已经栽了两次：
///
/// 1. **build166**：query 只给 GET 重新编码 → 站方 POST 的 query 带**裸中文 + 裸 JSON**
///    → iOS 的 `URL(string:)` 判非法（返回 nil）→ **请求压根没发出去**
///    → 引擎把失败吞成空串 → 站方 `JSON.parse('')` → 「Unable to parse JSON string」
/// 2. **build167 后**：query 里的 `+` **原样留着** → 服务器按 form 解码 query 时
///    `'+'` 变**空格** → 大灰狼的 base64 `book_id` 被损坏 → **有的书能开、有的书开不了**
///    （Legado 的 `analyzeFields` 是 `'+'` → `%2B`；栖阅有 `formPercentEncodedComponent`）
///
/// ⇒ 放到 `Core/`（纯 Foundation，不 import WebKit/SwiftUI）→
///   **沙盒 swiftc 能真编真跑**，验的就是跟真机同一套 Foundation 代码。
///
/// ## 字符集（栖阅 `AnalyzeUrl+Request.swift` 的字面量，逐字照搬）
/// - URL 合法集：`A-Za-z0-9-._~:/?#[]@!$&'()*+,;=`
/// - 表单字段保留集：`A-Za-z0-9-._`（其余 `%XX`），`'+'` → `%2B`
public struct AnalyzedURL {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: String
    public var baseUrl: String
}

public enum AnalyzeUrl {

    /// Legado 的 `analyzeFields`：查询串 / 表单体的字段编码
    ///
    /// - `=` `&` 原样保留（结构符）
    /// - 已经合法的 `%XX` **不重复编码**
    /// - **`+` → `%2B`**（⚠️ 关键：留着 `+` 的话，服务器 form 解码时会变成**空格**）
    /// - 字母数字与 `-._` 保留，其余按 UTF-8 字节 `%XX`
    public static func analyzeFields(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count * 2)
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=" || c == "&" {
                out.unicodeScalars.append(c); i += 1; continue
            }
            if c == "%", i + 2 < chars.count,
               isHexDigit(chars[i + 1]), isHexDigit(chars[i + 2]) {
                out.unicodeScalars.append(contentsOf: chars[i...i + 2])
                i += 3; continue
            }
            if c == "+" {
                out += "%2B"; i += 1; continue
            }
            if isPlainFieldChar(c) {
                out.unicodeScalars.append(c); i += 1; continue
            }
            // 其余按 UTF-8 字节逐个编码
            for b in String(c).utf8 {
                out += String(format: "%%%02X", b)
            }
            i += 1
        }
        return out
    }

    /// URL 里的**非法字符**百分号编码（栖阅 `smartPercentEncode`）
    /// ⚠️ 只动 URL 本身**不在合法集里**的字符；已有的 `%XX` 不重复编码。
    public static func smartPercentEncode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%", i + 2 < chars.count,
               isHexDigit(chars[i + 1]), isHexDigit(chars[i + 2]) {
                out.unicodeScalars.append(contentsOf: chars[i...i + 2])
                i += 3; continue
            }
            if isURLChar(c) {
                out.unicodeScalars.append(c); i += 1; continue
            }
            for b in String(c).utf8 {
                out += String(format: "%%%02X", b)
            }
            i += 1
        }
        return out
    }

    /// 相对地址 → 绝对地址（用 Foundation 的 URL 解析，和真机同一套）
    public static func absolutize(_ raw: String, baseUrl: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if let u = URL(string: s), u.scheme != nil { return u.absoluteString }
        if baseUrl.isEmpty { return s }
        guard let b = URL(string: baseUrl) else { return s }
        if let u = URL(string: s, relativeTo: b)?.absoluteURL { return u.absoluteString }
        return s
    }

    /// 取 URL 的目录部分（`https://x.com/a/b.html` → `https://x.com/a/`）
    public static func dirOf(_ raw: String) -> String {
        guard let u = URL(string: raw) else { return raw }
        var dir = u.deletingLastPathComponent()
        dir.appendPathComponent("")
        return dir.absoluteString
    }

    /// 切掉站方的 URL 选项后缀 `,{...}`（**只有逗号后紧跟 `{` 才算**）
    public static func splitOptions(_ raw: String) -> (url: String, options: [String: Any]) {
        let s = String(raw)
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "," {
                let rest = String(chars[(i + 1)...])
                    .trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{") {
                    let head = String(chars[0..<i])
                    if let data = rest.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return (head, obj)
                    }
                }
            }
            i += 1
        }
        return (s, [:])
    }

    /// **解析一条 URL 规则**（Legado `AnalyzeUrl` 语义）
    public static func parse(_ raw: String, baseUrl: String) -> AnalyzedURL {
        let (urlPart, opt) = splitOptions(raw)

        let method = String((opt["method"] as? String) ?? "GET").uppercased()

        var headers: [String: String] = [:]
        if let h = opt["headers"] as? [String: Any] {
            for (k, v) in h { headers[k] = String(describing: v) }
        }

        // body：对象 → 正规 JSON 串；字符串 → 原样
        var body = ""
        var isJsonBody = false
        if let b = opt["body"] {
            if b is [String: Any] || b is [Any] {
                if let d = try? JSONSerialization.data(withJSONObject: b),
                   let s = String(data: d, encoding: .utf8) {
                    body = s; isJsonBody = true
                }
            } else if let s = b as? String {
                body = s
            } else {
                body = String(describing: b)
            }
        }

        // 绝对化 + query 重新编码（**所有方法**）
        var abs = absolutize(urlPart, baseUrl: baseUrl)
        if let q = abs.firstIndex(of: "?"), q != abs.index(before: abs.endIndex) {
            let query = String(abs[abs.index(after: q)...])
            abs = String(abs[..<q]) + "?" + analyzeFields(query)
        }
        // URL 里的非法字符（裸中文等）→ 百分号编码
        abs = smartPercentEncode(abs)

        if method == "GET" { body = "" }

        if !body.isEmpty {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if isJsonBody || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                if !hasHeader(headers, "Content-Type") {
                    headers["Content-Type"] = "application/json; charset=utf-8"
                }
            } else {
                body = analyzeFields(body)
                if !hasHeader(headers, "Content-Type") {
                    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
                }
            }
        }

        return AnalyzedURL(url: abs, method: method, headers: headers,
                           body: body, baseUrl: dirOf(abs))
    }

    // MARK: - 字符判定

    private static func hasHeader(_ h: [String: String], _ name: String) -> Bool {
        for k in h.keys where k.lowercased() == name.lowercased() { return true }
        return false
    }

    private static func isHexDigit(_ c: Unicode.Scalar) -> Bool {
        (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }

    /// 表单字段保留字符（Legado：`A-Za-z0-9-._`）
    private static func isPlainFieldChar(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
            || c == "-" || c == "_" || c == "."
    }

    /// URL 合法字符（栖阅 `AnalyzeUrl+Request` 的字符集，逐字）
    private static func isURLChar(_ c: Unicode.Scalar) -> Bool {
        if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") {
            return true
        }
        return "-._~:/?#[]@!$&'()*+,;=".unicodeScalars.contains(c)
    }
}
