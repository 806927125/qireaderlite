import Foundation
// ⚠️ Linux（沙盒 swiftc）上 URLSession 在 FoundationNetworking 里，iOS 上在 Foundation
//    ⇒ 条件导入，两边都能编 ✅（沙盒 Swift 门禁的价值就在这）
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch

/// ⭐⭐⭐ **宿主的纯计算能力** —— 站方 `java.*` / `cookie.*` 的**精确语义**都在这实现。
///
/// ⚠️⚠️ **2026-10-25 更名**（原名 `LegadoCompat`）：
///   老 JS 引擎（WKWebView）退役并**物理删除** ⇒ 这里**不再是「老引擎的兼容层」**
///   ⇒ 现在它是**新引擎也用的宿主工具** ⇒ 改名 `HostTools`（免得误导）⭐⭐⭐
///
/// ⭐ **为什么不写在 JS 里**：
/// 1. `Core/` 是**纯 Foundation 层** ⇒ 沙盒里能 `swiftc` 真编真测 → 改完 **3 秒**出结果，
///    不用等 CI（SwiftUI 层在沙盒里只能靠 CI 验编译）⭐⭐⭐
/// 2. 逻辑沉在原生侧 ⇒ 行为**不受 JS 引擎差异影响**（JSC / Node / 浏览器都一样）⭐⭐⭐
/// 3. 站方依赖这些能力的**精确语义**（`java.timeFormat` 是 Long → String），
///    在 JS 里自己实现很容易搞成「差不多但不一样」，然后站方拼卡片时炸在一个莫名其妙的地方 ⭐⭐⭐
enum HostTools {

    // MARK: - java.timeFormat

    /// Legado 的 `java.timeFormat` —— **Long(epoch 毫秒) → 字符串**。
    ///
    /// 站方拼会员卡片就是这么用的：
    ///     java.timeFormat(res.register_time*1000).padEnd(20, "\t")
    ///     java.timeFormat(new Date()).slice(0,10) == java.timeFormat(res.last_read_time*1000).slice(0,10)
    /// 后者还要求 `.slice(0,10)` 正好是 `yyyy-MM-dd`。
    enum TimeFormat {
        /// 毫秒 → "yyyy-MM-dd HH:mm:ss"（本地时区）
        static func format(ms: Int64) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
        }

        /// 日期字符串 → epoch 毫秒（解析不了给 0，跟 Legado 一样不抛）
        ///
        /// 语料里大量这种写法，拿来当章节时间戳：
        ///     java.timeFormat(java.getString('$.updateDate'))
        ///
        /// ⚠️ 用 **UTC** 解释（跟原来 JS 版 `Date.UTC(...)` 一致）——
        ///    换成本地时区会差一个时区偏移，章节时间就全变了。
        static func parse(_ text: String) -> Int64 {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return 0 }
            // 纯数字：秒还是毫秒？（10 位及以下当秒）
            if s.allSatisfy({ $0.isNumber }) {
                let n = Int64(s) ?? 0
                return s.count <= 10 ? n * 1000 : n
            }
            let patterns = [
                "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
                "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "yyyy年MM月dd日 HH:mm:ss",
                "yyyy年MM月dd日"
            ]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)   // ← UTC
            for p in patterns {
                formatter.dateFormat = p
                if let d = formatter.date(from: s) {
                    return Int64(d.timeIntervalSince1970 * 1000)
                }
            }
            // 兜底：交给系统解析（"Mon Oct 20 2026 ..." 这类）
            if let d = ISO8601DateFormatter().date(from: s) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
            return 0
        }

        /// **统一入口**：按输入形态决定语义。
        ///
        /// - 数字 / 纯数字字符串 → epoch 毫秒 → **格式化字符串**（Legado 语义）
        /// - 其它字符串 → 解析成 **epoch 毫秒**（语料里当章节时间戳用）
        ///
        /// 返回 `Any` 是因为两种语义的结果类型不同（String / Int64），
        /// 同步通道走 JSON，类型会原样带过去。
        static func apply(_ input: String) -> Any {
            let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return "" }
            if s.allSatisfy({ $0.isNumber }) {
                let n = Int64(s) ?? 0
                let ms = s.count <= 10 ? n * 1000 : n
                return format(ms: ms)
            }
            return parse(s)
        }
    }

    // MARK: - cache.put / cache.get / cache.remove

    /// Legado 的 `cache`（BookCacheManager 那种 KV）。
    ///
    /// ⚠️ **注意站方怎么用它**（🍅大灰狼的 `putLoginInfo`）：
    ///     try {
    ///         let encodeStr = Base64.encodeToString(createSymmetricCrypto("AES", androidId).encrypt(info), 2)
    ///         cache.put(`userInfo_${source.getKey()}`, encodeStr)
    ///         return true
    ///     } catch (e) {
    ///         java.log(e)
    ///         return source.putLoginInfo(info)     // ← 轻阅走的是这条
    ///     }
    /// 站方把登录信息**加密**后存 cache，而它自己从来不读回（没有 cache.get）。
    /// 轻阅的登录信息必须留在 `source.putLoginInfo`（书源登录信息表），
    /// 否则下次启动 `login()` 读 `source.getLoginInfo()` 会拿到空 → **登录态丢失**。
    /// 所以 JS 侧 `cache.put` 存完之后**仍要抛错**，好让站方走那条 fallback。
    enum Cache {
        private static let prefix = "legadocache."

        static func put(_ key: String, _ value: String) {
            UserDefaults.standard.set(value, forKey: prefix + key)
        }

        static func get(_ key: String) -> String {
            UserDefaults.standard.string(forKey: prefix + key) ?? ""
        }

        static func remove(_ key: String) {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        }
    }

    // MARK: - 登录检测：服务器响应的分类

    /// 登录探测的结果 —— **三档必须分清**
    enum ProbeResult {
        /// 服务器认这个 cookie（返回里有 id）
        case loggedIn([String: Any])
        /// 服务器**明确**说没登录（没带密钥 / 密钥无效）
        case notLoggedIn(String)
        /// 服务器异常（5xx / 返回 HTML 错误页）—— **不是用户的锅**
        case serverError(String)
    }

    /// 把服务器的响应分类 —— **纯函数**（沙盒里能真跑）
    ///
    /// ⚠️ 以前把「不是 JSON」也归成 notLoggedIn → 服务器 502 会被报成「未登录」
    ///    → 用户以为白登了。真机踩过（HTTP 502 + `<!DOCTYPE html>`，
    ///    站方那边同一个响应直接 `JSON.parse` 炸成 "Unrecognized token '<'"）。
    // MARK: - ⭐⭐⭐ cookie 快照 ⇒ 引擎的 cookie 罐（2026-10-24 真机栽的）

    /// ⭐⭐⭐ **把 App 的 cookie 快照拆成一条条 cookie**
    ///
    /// ⚠️⚠️ **为什么必须有它**（🍅大灰狼真机）：
    ///   · 老引擎的 `java.ajax` 走**原生桥** ⇒ 用的是 **App 的 cookie 罐**（**有登录态**）✅
    ///   · 新引擎的 `java.ajax` 用**引擎自己的罐** ⇒ 每个源从空开始 ⇒ **登录态丢了** ❌
    ///   ⇒ 站方 `/discovestyle`（拿真分类）要登录态 ⇒ 失败 ⇒ 只剩兜底分类「未分组」⭐⭐
    ///
    /// ⚠️ **解析要点**：
    ///   · 快照格式 = `[host: "k=v; k2=v2"]`
    ///   · **值里可能有 `=`**（base64 的 padding！）⇒ 只切**第一个** `=`
    ///   · 空的 name / host 跳过
    ///
    /// - Returns: `(host, name, value)` 三元组
    static func cookiePairs(from snapshot: [String: String]) -> [(host: String, name: String, value: String)] {
        var out: [(host: String, name: String, value: String)] = []
        for (host, pair) in snapshot {
            let h = host.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { continue }
            for one in pair.split(separator: ";").map(String.init) {
                let kv = one.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let name = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                out.append((host: h, name: name, value: value))
            }
        }
        return out
    }

    static func classify(code: Int, data: Data) -> ProbeResult {
        if code >= 500 {
            return .serverError("HTTP \(code)（服务器临时抽风，过几分钟再试）")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if obj["id"] != nil { return .loggedIn(obj) }
            return .notLoggedIn((obj["msg"] as? String) ?? ("HTTP \(code)"))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let head = text.prefix(60).description
            .replacingOccurrences(of: "\n", with: " ")
        return .serverError("HTTP \(code) 返回的不是 JSON（服务器异常）：\(head)")
    }

    // MARK: - loginHeader（栖阅机制）

    /// 解析 loginHeader 字符串 → [(头名, 头值)]
    ///
    /// 格式：`名称: 值`，一行一个（最常用 `Cookie: sessionid=xxx`）。
    /// 栖阅《书源制作文档》§9.2：loginHeader「存的是纯字符串，**会自动注入到每次请求头**」。
    ///
    /// ⚠️ 放在这里（纯 Foundation 层）→ **沙盒 swiftc 能真编真跑**，
    ///    语法错当场发现，不用等 CI。
    static func parseLoginHeader(_ raw: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let name = String(t[t.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            out.append((name, value))
        }
        return out
    }

    // MARK: - 番茄 sessionid 别名（站方大灰狼的坑）

    /// 番茄域判定（cookie 罐里番茄相关的域）
    static func isFanqieHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.contains("fanqienovel.com") || h.contains("fqnovel.com")
    }

    /// 把番茄 cookie 串里的 `sessionid_ss` 补一条 `sessionid=` 别名
    ///
    /// ⚠️⚠️ **为什么**（2026-10-21 真机：「番茄明明登了，发现页一直提示已过期」）：
    ///
    /// 站方 exploreUrl 里这段：
    /// ```js
    /// var rawCookie = getFanqieCookie() || sdtoken;
    /// var match = rawCookie.match(/sessionid=[^;]+/);   // ← 只认 sessionid=
    /// var fqcookie = match ? match[0] : '';
    /// if (!fqcookie && (sources == '番茄' || sources == '全部')) {
    ///     java.toast('您还未登陆番茄账号，无法同步数据哦！');
    /// } else { fqssionid = getSessionId(fqcookie) }
    /// ```
    /// 而站方自己的 `getSessionId` 用的是 `sessionid(?:_ss)?=`（**两种都认**），
    /// `getFanqieCookie` 里的判定也是 `sessionid(?:_ss)?=`（**也认**）。
    /// ⇒ **只有中间那行老正则不认** ⇒ 站方自己把路堵死了。
    ///
    /// 番茄**新版**登录发的 cookie 键是 `sessionid_ss` ⇒ 老正则匹配不到
    /// ⇒ `fqcookie` 为空 ⇒ 一直 toast「您还未登陆番茄账号」
    /// ⇒ `ssionid` 参数是空的 ⇒ 大灰狼服务器回「用户未登录番茄账号」
    ///   /「番茄登录过期，已隐藏番茄书架」⇒ **发现页十几个平台一个都出不来** ⭐
    ///
    /// ⇒ 修：**宿主侧补一条 `sessionid=<同值>` 别名**（**不覆盖**已有的 `sessionid`）
    ///   ⇒ 站方那条老正则立刻能匹配 ⇒ **所有聚合源都受益**（不用改站方书源）✅
    ///
    /// ⚠️ 放在这里（纯 Foundation 层）→ **沙盒 swiftc 能真编真跑**，语法错当场发现。
    static func fanqieSessionAlias(_ cookie: String) -> String {
        let s = String(cookie)
        guard !s.isEmpty else { return s }
        // 已经有标准 `sessionid=` ⇒ 不动（别覆盖站方/服务器真正认的那个）
        if s.range(of: #"(?:^|;\s*)sessionid="#, options: .regularExpression) != nil {
            return s
        }
        // 找 `sessionid_ss=` 的值
        guard let r = s.range(of: #"(?:^|;\s*)sessionid_ss=([^;]+)"#, options: .regularExpression) else {
            return s
        }
        let matched = String(s[r])
        // ⚠️⚠️ **别用 `.last` 取值** —— sessionid 是 base64，**结尾可能有 `=` padding**
        //   ⇒ "sessionid_ss=abc==" 会被截成 "abc" ⇒ 别名是错的 ⇒ 服务器不认 ❗
        //   ⇒ 取**第一个 `=` 之后的全部**
        let value = matched
            .components(separatedBy: "=").dropFirst().joined(separator: "=")
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return s }
        return s + "; sessionid=" + value
    }

    // MARK: - 同步通道分发

    /// 同步通道的**唯一**入口：JS 通过 `window.prompt` 把 {fn, args} 送过来，
    /// 这里回一个 JSON 串（`{"ok":true,"value":...}` 或 `{"ok":false,"error":...}`）。
    // MARK: - 线路测速

    /// **并发测速一组线路**，返回「地址 + 毫秒」列表（快的在前）
    ///
    /// ⚠️ 为什么需要：🍅大灰狼把线路放在站方 jsLib 的 `host` 数组里，
    ///    默认那台（v5.langge.uk）**在某些网络下直接超时** ⇒
    ///    详情页逐条兜底 → 转圈一两分钟 ❗
    /// ⇒ 一次并发测速 → 自动选一条通的写进书源变量 ✅
    ///
    /// - Parameters:
    ///   - hosts: 线路地址数组
    ///   - timeout: 每条线路的超时秒数（默认 6 秒，够短才不会干等）
    /// - Returns: `[{host, ms, ok}]`，ok=false 的排最后
    public static func pingHosts(_ hosts: [String], timeout: Double = 6) async -> [[String: Any]] {
        // ⚠️⚠️ **必须 async，不能在主线程上阻塞**（2026-10-21 闪退事故）：
        //    原来这个函数是同步的（URLSession 回调 + usleep 轮询等结果），
        //    而调用方在**主 actor**上 → 主线程被阻塞 5~7 秒
        //    ⇒ iOS watchdog 判定「主线程无响应」→ **直接杀进程闪退** ❗
        //    而且它在**每次进任何书源的发现页**时都会跑 ⇒ 别的源也崩 ✅
        // ⇒ 现在用 URLSession 的 async API + TaskGroup：**完全不占主线程** ✅
        await withTaskGroup(of: (String, Int, Bool).self, returning: [[String: Any]].self) { group in
            for host in hosts {
                group.addTask {
                    guard let u = URL(string: host) else { return (host, -1, false) }
                    var req = URLRequest(url: u)
                    req.httpMethod = "GET"
                    req.timeoutInterval = timeout
                    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    let cfg = URLSessionConfiguration.ephemeral
                    cfg.timeoutIntervalForRequest = timeout
                    cfg.timeoutIntervalForResource = timeout
                    let session = URLSession(configuration: cfg)
                    let t0 = Date()
                    var ok = false
                    if let (_, resp) = try? await session.data(for: req) {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        // ⚠️ **有响应就算通**（不管状态码）—— 服务器回 4xx/5xx 也说明网络是通的
                        ok = code > 0
                    }
                    return (host, Int(Date().timeIntervalSince(t0) * 1000), ok)
                }
            }
            var out: [[String: Any]] = []
            for await (host, ms, ok) in group {
                out.append(["host": host, "ms": ms, "ok": ok])
            }
            // 通的排前面，按耗时升序
            return out.sorted { a, b in
                let ao = (a["ok"] as? Bool) ?? false
                let bo = (b["ok"] as? Bool) ?? false
                if ao != bo { return ao }
                return ((a["ms"] as? Int) ?? 999999) < ((b["ms"] as? Int) ?? 999999)
            }
        }
    }

    /// 引擎/请求用的 UA（和书源请求一致）
    static var userAgent: String {
        "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0"
    }

    static func handle(fn: String, args: [String: Any]) -> [String: Any] {
        switch fn {
        case "timeFormat":
            let input = args["input"] as? String ?? ""
            let v = TimeFormat.apply(input)
            // 数字结果在 JSON 里会变成 number，字符串就是 string —— 原样带回去
            if let n = v as? Int64 { return ["ok": true, "value": n] }
            return ["ok": true, "value": String(describing: v)]

        case "cachePut":
            let key = args["key"] as? String ?? ""
            let value = args["value"] as? String ?? ""
            Cache.put(key, value)
            return ["ok": true, "value": "1"]

        case "cacheGet":
            let key = args["key"] as? String ?? ""
            return ["ok": true, "value": Cache.get(key)]

        case "cacheRemove":
            let key = args["key"] as? String ?? ""
            Cache.remove(key)
            return ["ok": true, "value": "1"]

        default:
            return ["ok": false, "error": "未知能力: \(fn)"]
        }
    }
}
