import Foundation

/// 对应 Legado `CookieStore`：按可注册域名（非网址原样）保存 Cookie 字符串
public final class CookieStore: @unchecked Sendable {
    private let store: KeyValueStore
    private static let prefix = "cookie_"

    public init(store: KeyValueStore) {
        self.store = store
    }

    private func domainKey(_ url: String) -> String {
        Self.prefix + URLUtils.subDomain(url)
    }

    public func getCookie(url: String) -> String {
        store.string(forKey: domainKey(url)) ?? ""
    }

    public func getKey(url: String, key: String) -> String {
        Self.cookieToMap(getCookie(url: url)).first { $0.0 == key }?.1 ?? ""
    }

    public func setCookie(url: String, cookie: String) {
        store.set(cookie, forKey: domainKey(url))
    }

    /// 与已有 Cookie 合并，新值覆盖同名项
    public func replaceCookie(url: String, cookie: String) {
        guard !cookie.isBlank else { return }
        let old = getCookie(url: url)
        guard !old.isBlank else {
            setCookie(url: url, cookie: cookie)
            return
        }
        let merged = Self.merge(Self.cookieToMap(old), Self.cookieToMap(cookie))
        setCookie(url: url, cookie: Self.mapToCookie(merged))
    }

    public func removeCookie(url: String) {
        store.set(nil, forKey: domainKey(url))
        store.set(nil, forKey: Self.prefix + url)
    }

    /// 全部 Cookie 的摘要，只用于比较前后是否有变化
    public func digest() -> String {
        let joined = store.keys(withPrefix: Self.prefix).sorted()
            .map { "\($0)\u{1}\(store.string(forKey: $0) ?? "")" }
            .joined(separator: "\u{2}")
        return Hex.encode(Digests.digest("MD5", Data(joined.utf8)) ?? Data())
    }

    /// 解析 `a=1; b=2`，保持顺序；值中的 `=` 原样保留
    static func cookieToMap(_ cookie: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for part in cookie.split(separator: ";") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<eq]).trimmedWhitespace
            let value = String(part[part.index(after: eq)...]).trimmedWhitespace
            guard !key.isEmpty, !value.isBlank || value == "null" else { continue }
            if let i = out.firstIndex(where: { $0.0 == key }) {
                out[i].1 = value
            } else {
                out.append((key, value))
            }
        }
        return out
    }

    static func merge(_ base: [(String, String)], _ overrides: [(String, String)]) -> [(String, String)] {
        var out = base
        for (k, v) in overrides {
            if let i = out.firstIndex(where: { $0.0 == k }) {
                out[i].1 = v
            } else {
                out.append((k, v))
            }
        }
        return out
    }

    static func mapToCookie(_ map: [(String, String)]) -> String {
        map.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}
