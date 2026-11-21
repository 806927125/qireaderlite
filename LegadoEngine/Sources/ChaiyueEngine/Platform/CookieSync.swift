#if canImport(WebKit) && !os(Linux)
import Foundation
import ChaiyueEngine
import WebKit

/// WebView 与规则引擎之间的 Cookie 同步。默认使用 `WKWebsiteDataStore.default()`，登录页与后台渲染共享同一份 Cookie
@MainActor
public enum CookieSync {
    /// 打开网页前：把引擎中该地址的 Cookie 写入 WebView
    public static func push(_ url: String, from cookies: CookieStore, to store: WKHTTPCookieStore? = nil) async {
        let header = cookies.getCookie(url: url)
        guard !header.isEmpty, let host = URL(string: url)?.host else { return }
        let store = store ?? WKWebsiteDataStore.default().httpCookieStore
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty,
                  let cookie = HTTPCookie(properties: [.name: parts[0], .value: parts[1], .domain: host, .path: "/"])
            else { continue }
            await store.setCookie(cookie)
        }
    }

    /// 网页加载完成或浏览器关闭后：把 WebView 中该地址可见的 Cookie 合并回引擎，保存在 `key`（书源地址）名下
    public static func pull(_ url: String, into cookies: CookieStore, key: String? = nil, from store: WKHTTPCookieStore? = nil) async {
        let header = await header(for: url, in: store ?? WKWebsiteDataStore.default().httpCookieStore)
        guard !header.isEmpty else { return }
        cookies.replaceCookie(url: key ?? url, cookie: header)
    }

    /// 把 WebView 里还有效的 Cookie 按各自的站点写回引擎。
    /// 书源用 `cookie.getCookie("fanqienovel.com")` 这类地址取登录态，不能只存在书源自己的 key 下
    @discardableResult
    public static func pullAll(into cookies: CookieStore, from store: WKHTTPCookieStore? = nil) async -> Bool {
        let before = cookies.digest()
        let now = Date()
        var groups: [String: [(String, String)]] = [:]
        for cookie in await (store ?? WKWebsiteDataStore.default().httpCookieStore).allCookies() {
            let alive = cookie.expiresDate.map { $0 > now } ?? true
            guard alive else { continue }
            let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard !host.isEmpty else { continue }
            let key = URLUtils.registrableDomain(host)
            var pairs = groups[key] ?? []
            if let index = pairs.firstIndex(where: { $0.0 == cookie.name }) {
                pairs[index].1 = cookie.value
            } else {
                pairs.append((cookie.name, cookie.value))
            }
            groups[key] = pairs
        }
        for (key, pairs) in groups {
            let header = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
            cookies.replaceCookie(url: "https://\(key)", cookie: header)
        }
        return cookies.digest() != before
    }

    /// WebView 中对该地址可见的 Cookie，拼成请求头格式
    public static func header(for url: String, in store: WKHTTPCookieStore) async -> String {
        guard let target = URL(string: url), let host = target.host else { return "" }
        let path = target.path.isEmpty ? "/" : target.path
        let now = Date()
        return await store.allCookies()
            .filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                let matchesDomain = host == domain || host.hasSuffix("." + domain)
                let alive = cookie.expiresDate.map { $0 > now } ?? true
                return matchesDomain && path.hasPrefix(cookie.path) && alive
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

#endif  // #if canImport(WebKit) && !os(Linux)
