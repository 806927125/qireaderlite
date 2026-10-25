import Foundation

/// **登录状态检测** —— 「登录到底成没成功」的可证伪答案。
///
/// 背景（这个坑踩得很深）：
/// 站方书源（🍅大灰狼这类）**只用 `java.toast` 报登录结果**：
///     java.toast("\n\n✅️登录成功")
///     java.toast("\n\n💔登录失败，请重试！")
///     java.log(一大张会员卡片)
///
/// 以前这些只弹个 toast 就没了 → 用户在登录面板里只能看到轻阅自己编的一句
/// 「执行完成（登录信息已存到本地）」——**这句话跟服务器认不认你毫无关系**。
/// 于是「登录到底成没成功」变成一个只能靠猜的问题。
///
/// 所以这里做三层检测，**从弱到强**：
///
/// 1. **本地事实**（客观、不需要网络）
///    · 登录信息 map 里有没有邮箱 / 密钥
///    · cookie 罐里有没有 `qttoken`
///    · 书籍变量里有没有 `server` / `qttoken`
/// 2. **站方自检**（走引擎跑站方自己的 `checkStatus()`，拿它的原文）
/// 3. **独立硬验证**（❗ 不经过站方 JS，原生直接打服务器）
///    POST `{服务器}/user_api` 带 cookie：
///      · 返回里有 `id` → **服务器认这个 cookie** → 真的登录了
///      · 返回 `{"code":-1,"msg":"请求参数中未找到密钥"}` → **没登录**（硬证据）
///
/// 第 3 层是关键：只有服务器自己说了算才算数。
/// 站方 JS 可能写错、可能被 cookie 没同步（浏览器里登出来的 cookie 拿不到），
/// 只有直连服务器的那次请求骗不了人。
struct LoginStatusReport {
    /// 结论：`已登录` / `未登录` / `不确定`
    var verdict: String
    /// 结论是不是「已登录」
    var loggedIn: Bool
    /// 明细，一行一条，给人看
    var lines: [String]
    /// 站方自己吐出来的原文（会员卡片等）
    var stationMessages: [String]
    /// 服务器地址（如果解析出来了）
    var baseUrl: String

    /// 复制给别人的全文
    var text: String {
        var s = "【\(verdict)】\(baseUrl.isEmpty ? "" : "  \(baseUrl)")\n"
        s += lines.joined(separator: "\n")
        if !stationMessages.isEmpty {
            s += "\n—— 站方原文 ——\n" + stationMessages.joined(separator: "\n")
        }
        return s
    }
}

@MainActor
enum LoginStatus {

    /// 跑一次完整检测
    static func probe(_ source: BookSource) async -> LoginStatusReport {
        var lines: [String] = []
        var station: [String] = []
        var base = ""

        // ── ① 本地事实 ─────────────────────────────────────────
        let loginMap = SourceVariables.loginInfo(for: source.bookSourceUrl)
        let email = loginMap["邮箱"] ?? ""
        let key = loginMap["密钥"] ?? ""
        lines.append("本地登录信息：" + describe(email: email, key: key))

        let vars = SourceVariables.vars(for: source.bookSourceUrl)
        var varServer = ""
        var varToken = ""
        if let d = vars.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            varServer = (obj["server"] as? String) ?? ""
            varToken = (obj["qttoken"] as? String) ?? ""
        }
        lines.append("书籍变量：server=\(varServer.isEmpty ? "（空）" : varServer)"
                     + "  qttoken=\(varToken.isEmpty ? "（空）" : mask(varToken))")

        // ── ② 站方自检（引擎跑 checkStatus） ─────────────────────
        var stationOK = false
        do {
            let p = try await SourceService.shared.probeLogin(source: source)
            base = p.baseUrl
            station = p.messages
            stationOK = p.stationCheck
            if !p.stationCheck {
                lines.append("站方 checkStatus：没跑成（这个书源可能没有自检函数）")
            }
        } catch {
            lines.append("站方 checkStatus 失败：\(error.localizedDescription)")
        }
        if base.isEmpty {
            lines.append("服务器地址：解析不出来")
        } else {
            lines.append("服务器地址：\(base)")
        }

        // cookie 罐里有没有 qttoken（登录成功的标志物）
        let cookieStr = base.isEmpty ? "" : CookieJar.cookieString(for: base)
        let hasToken = cookieStr.contains("qttoken")
        lines.append("本机 cookie：" + (cookieStr.isEmpty
            ? "（空）"
            : (hasToken ? "有 qttoken" : "没有 qttoken（\(cookieStr.prefix(60))…）")))

        // ── ③ 独立硬验证（直连服务器，不经过站方 JS） ─────────────
        var loggedIn = false
        var serverBroken = false
        if base.isEmpty {
            lines.append("独立验证：跳过（拿不到服务器地址）")
        } else {
            switch await serverProbe(base: base, cookie: cookieStr, source: source) {
            case .loggedIn(let info):
                loggedIn = true
                let nick = (info["nickname"] as? String) ?? ""
                let mail = (info["email"] as? String) ?? ""
                let uid = info["id"].map { String(describing: $0) } ?? "?"
                lines.append("独立验证：✅️ 服务器认这个 cookie（id=\(uid)"
                             + (nick.isEmpty ? "" : " 昵称=\(nick)")
                             + (mail.isEmpty ? "" : " 邮箱=\(mask(mail))") + "）")
            case .notLoggedIn(let msg):
                lines.append("独立验证：❌ 未登录（服务器说：\(msg)）")
            case .serverError(let msg):
                // ⚠️ 服务器 5xx / 返回 HTML 错误页 → **不是用户的锅**，
                //    别报成「未登录」（会让人以为白登了）。
                serverBroken = true
                lines.append("独立验证：⚠️ 服务器异常（\(msg)）——不是你的问题，过几分钟再检一次")
            }
        }

        // 站方到底说啥？**不能只看「JS 有没有抛错」** ——
        // 站方 checkStatus 自己 catch 住错误并 toast「检测登录失败」，
        // 那样 JS 根本不抛 → 会被误判成「站方说已登录」（用户真机就遇到这个）。
        let stationText = station.joined(separator: "\n")
        let stationSaysLoggedIn = stationText.contains("会员状态")
            || stationText.contains("在线设备")
            || stationText.contains("注册时间")
        let stationSaysFailed = stationText.contains("检测登录失败")
            || stationText.contains("登录失败")
            || stationText.contains("未找到密钥")
        if stationSaysLoggedIn {
            lines.append("站方自检：说已登录（会员卡片出来了）")
        } else if stationSaysFailed {
            lines.append("站方自检：**说没登录**（别被这句误导，以服务器为准）")
        } else if stationOK {
            lines.append("站方自检：跑了但没给出结论")
        }

        // 结论：独立验证说了算
        let verdict: String
        if loggedIn {
            verdict = "已登录"
        } else if serverBroken {
            verdict = "服务器异常，这次测不出来（不是你的问题，过几分钟再试）"
        } else if base.isEmpty {
            verdict = "不确定（拿不到服务器地址，没法独立验证）"
        } else if stationSaysLoggedIn {
            verdict = "站方说已登录，但独立验证没通过（以服务器为准 = 未登录）"
        } else {
            verdict = "未登录"
        }

        return LoginStatusReport(verdict: verdict,
                                 loggedIn: loggedIn,
                                 lines: lines,
                                 stationMessages: station,
                                 baseUrl: base)
    }

    // MARK: - 直连服务器

    typealias ProbeResult = HostTools.ProbeResult

    /// POST `{base}/user_api` 带 cookie —— 站方 checkStatus 用的同一个接口。
    ///
    /// ⚠️ **必须带 User-Agent**：不带的话边缘直接 503
    ///    （"upstream connect error or disconnect/reset before headers"），
    ///    看起来像"服务器挂了"，其实是 UA 被拦了。
    static func serverProbe(base: String, cookie: String, source: BookSource) async -> ProbeResult {
        let urlString = base.hasSuffix("/")
            ? String(base.dropLast()) + "/user_api"
            : base + "/user_api"
        guard let url = URL(string: urlString) else { return .serverError("URL 非法") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // UA / Referer 用书源自己的 header
        var header: [String: String] = [:]
        if let h = source.header, let parsed = HeaderCodec.decode(h) { header = parsed }
        if let ua = header["User-Agent"] { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let rf = header["Referer"] { req.setValue(rf, forHTTPHeaderField: "Referer") }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(RuleSandbox.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }

        // 超时给 6 秒：检测不能把界面卡住
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 10
        // 别带 cookie 罐 —— 我们要自己控制 Cookie 头
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return HostTools.classify(code: code, data: data)
        } catch {
            return .serverError(error.localizedDescription)
        }
    }


    // MARK: - 小工具

    /// 密钥只露头尾
    static func mask(_ s: String) -> String {
        guard s.count > 8 else { return s.isEmpty ? "" : "（太短）" }
        return String(s.prefix(4)) + "***" + String(s.suffix(4))
    }

    private static func describe(email: String, key: String) -> String {
        if email.isEmpty && key.isEmpty { return "（空）" }
        var s = ""
        s += email.isEmpty ? "邮箱=（无）" : "邮箱=\(mask(email))"
        s += "  密钥=" + (key.isEmpty ? "（无）" : mask(key))
        return s
    }
}
