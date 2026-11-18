import Foundation
// ⚠️ Linux（沙盒 swiftc）上 URLSession / HTTPCookieStorage 在 FoundationNetworking 里，iOS 上在 Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ⭐⭐⭐ **宿主基础件**（2026-11-19 · 从老 `RuleSandbox` 里拆出来）
// ⚠️ 老 `RuleSandbox` 是 **WKWebView 引擎壳** ⇒ 引擎退役后壳子删了
//   ⇒ 但这几个**宿主能力**（请求头编解码 / cookie 罐 / 缓存 / 沙盒 FS）App 还要用 ⇒ 留下 ⭐⭐⭐
// ⚠️ **纯 Foundation** ⇒ 沙盒 Linux 编译门禁能真编 ⭐⭐⭐

enum HeaderCodec {
    /// 解析书源 header 字符串：`key:value` 换行分隔，或 JSON。
    static func decode(_ s: String) -> [String: String]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.hasPrefix("{") {
            if let d = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] {
                return d.reduce(into: [:]) { acc, kv in
                    if let v = kv.value as? String { acc[kv.key] = v }
                    else if let v = kv.value as? NSNumber { acc[kv.key] = v.stringValue }
                }
            }
        }
        var out: [String: String] = [:]
        for line in t.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = String(l[l.startIndex..<c]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out.isEmpty ? nil : out
    }
}

enum CookieJar {
    static func cookieString(for url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 全量 cookie 快照：**host → "k=v; k2=v2"**
    ///
    /// ⚠️ 为什么需要快照：Legado 的 `cookie.getCookie(url)` 是**同步** API，
    ///    而原生桥只能 postMessage（异步）→ JS 里没法 await 一次同步调用。
    ///    所以原生侧先把 cookie 罐拍成快照塞进 payload，引擎侧同步读。
    static func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for c in HTTPCookieStorage.shared.cookies ?? [] {
            var host = c.domain
            if host.hasPrefix(".") { host.removeFirst() }
            guard !host.isEmpty else { continue }
            let pair = "\(c.name)=\(c.value)"
            if let prev = out[host], !prev.isEmpty {
                out[host] = prev + "; " + pair
            } else {
                out[host] = pair
            }
        }
        // ⚠️⚠️ **番茄 sessionid 别名**（2026-10-21 真机「番茄登了还是说过期」）：
        //   番茄新版登录的 cookie 键是 `sessionid_ss`，
        //   而站方（🍅大灰狼）有一行老正则 `rawCookie.match(/sessionid=[^;]+/)` **只认 `sessionid=`**
        //   ⇒ 站方抠不到 sessionid ⇒ 发现页一直 toast「您还未登陆番茄账号」
        //   ⇒ `ssionid` 参数空 ⇒ 大灰狼服务器回「番茄登录过期」
        //   ⇒ 这里补一条 `sessionid=<同值>` 别名（不覆盖已有的）⇒ 站方立刻能用 ✅
        //   （逻辑在 LegadoCompat（纯 Foundation）→ 沙盒 swiftc 能真编真跑）
        // ⚠️⚠️ **不能一边遍历一边改字典** ⇒ Swift 会崩
        //   （Fatal error: Collection was mutated while being enumerated）
        //   ⇒ 先收集要改的，再统一改
        var updates: [String: String] = [:]
        for (host, value) in out {
            if LegadoCompat.isFanqieHost(host) {
                let fixed = LegadoCompat.fanqieSessionAlias(value)
                if fixed != value { updates[host] = fixed }
            }
        }
        for (host, value) in updates { out[host] = value }
        return out
    }
    static func set(_ cookie: String, for url: String) {
        guard let u = URL(string: url) else { return }
        // 新 SDK 的 setCookies 多了第三个参数 mainDocumentURL，不给编译不过
        HTTPCookieStorage.shared.setCookies(cookies(from: cookie, host: u.host ?? ""),
                                            for: u, mainDocumentURL: nil)
    }

    /// 删某个站点下的 cookie（站方的「退出登录」用）
    ///
    /// ⚠️ `HTTPCookieStorage.shared.setCookies([])` **不一定**会清掉已有的
    ///    （实测不可靠）→ 这里显式遍历 deleteCookie。
    ///    域匹配：cookie.domain 是 "v5.langge.uk" 或 ".langge.uk"，
    ///    要把 **父域** 的 cookie 也删掉（站方 logout 会逐个清 host + langge.uk）。
    static func remove(for url: String) {
        guard let u = URL(string: url) else { return }
        let host = (u.host ?? "").lowercased()
        guard !host.isEmpty else { return }
        for c in HTTPCookieStorage.shared.cookies ?? [] {
            var d = c.domain.lowercased()
            if d.hasPrefix(".") { d.removeFirst() }
            if d.isEmpty { continue }
            if d == host || host.hasSuffix("." + d) || d.hasSuffix("." + host) {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
    }
    static func cookies(from header: String, host: String) -> [HTTPCookie] {
        var out: [HTTPCookie] = []
        for part in header.components(separatedBy: ";;") {
            let p = part.trimmingCharacters(in: .whitespaces)
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let c = HTTPCookie(properties: [
                .name: kv[0], .value: kv[1], .domain: host, .path: "/",
            ]) else { continue }
            out.append(c)
        }
        return out
    }
}

enum CacheFiles {
    private static let root = AppPaths.cacheDir

    /// Legado 的 `java.cacheFile(path, content)`，路径是书源自定的 key，不是真实路径
    static func write(_ path: String, _ text: String) -> Bool {
        let safe = safeName(path)
        guard let d = text.data(using: .utf8) else { return false }
        let p = root.appendingPathComponent(safe)
        do { try d.write(to: p, options: .atomic); return true } catch { return false }
    }
    static func read(_ path: String) -> String? {
        let p = root.appendingPathComponent(safeName(path))
        return try? String(contentsOf: p, encoding: .utf8)
    }
    private static func safeName(_ s: String) -> String {
        let h = abs(s.hashValue)
        return "cf_\(h).cache"
    }
}

