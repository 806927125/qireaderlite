import Foundation

/// **书籍变量** / 登录信息（Legado 的 `source.getVariable` / `putLoginInfo`）
///
/// 聚合源（🍅大灰狼这类）把「服务器地址 / 选中的来源 / 模式 / 音色」这些
/// 存在**书籍变量**里 —— Legado 里是挂在源上的一个 JSON 串：
///   `source.getVariable()` → 字符串，站方自己 `JSON.parse`
///   `source.setVariable(json)` → 整份替换
///
/// 这两个在 Legado 里是**同步** API，而轻阅的原生桥是异步的，
/// 所以做法是「原生侧读出来塞进 payload → 引擎侧同步读 → 改完回传落盘」。
/// 见 `Resources/engine/source-api.js`。
///
/// 按 `bookSourceUrl` 存 —— 一个源一份，互不串台。
enum SourceVariables {
    private static let varsPrefix = "sourcevars."
    private static let loginPrefix = "sourcelogin."

    // MARK: 书籍变量

    /// 读某个源的书籍变量（原始 JSON 串；没设置过 = 空串）
    static func vars(for sourceUrl: String) -> String {
        guard !sourceUrl.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: varsPrefix + sourceUrl) ?? ""
    }

    /// 写回某个源的书籍变量
    static func setVars(_ value: String, for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: varsPrefix + sourceUrl)
    }

    /// 清掉某个源的书籍变量（删源时用）
    static func clear(for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: varsPrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: loginPrefix + sourceUrl)
    }

    // MARK: 登录表单值（loginUi 的输入框）

    /// 登录面板填的值（邮箱/密码等）—— **按源存 UserDefaults**
    ///
    /// ⚠️ 为什么必须存（2026-10-21 用户反馈「账号密码重进登录页就没了」）：
    ///    登录面板的输入框原来只存在内存（@State）⇒ 关掉面板就没了 ❗
    ///    而登录动作要靠这些值（`result['邮箱']`）⇒ 用户每次都得重填。
    ///    ⚠️ 另外：**自签换了 bundle ID 就等于换了个 App** ⇒ UserDefaults 整个换容器
    ///    ⇒ 「覆盖更新后显示未登录」多半是这个，不是代码的锅 ✅
    private static let loginFormPrefix = "sourceform."

    static func loginFormValues(for sourceUrl: String) -> [String: String] {
        guard !sourceUrl.isEmpty else { return [:] }
        let raw = UserDefaults.standard.string(forKey: loginFormPrefix + sourceUrl) ?? ""
        guard let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return obj
    }

    static func setLoginFormValues(_ values: [String: String], for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        let keep = values.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard let d = try? JSONSerialization.data(withJSONObject: keep),
              let s = String(data: d, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: loginFormPrefix + sourceUrl)
    }

    // MARK: 登录信息

    /// 读某个源的登录信息（map）
    static func loginInfo(for sourceUrl: String) -> [String: String] {
        guard !sourceUrl.isEmpty else { return [:] }
        guard let raw = UserDefaults.standard.string(forKey: loginPrefix + sourceUrl),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    /// 写回某个源的登录信息（引擎回传的是 JSON 串）
    static func setLoginInfoJSON(_ json: String, for sourceUrl: String) {
        guard !sourceUrl.isEmpty, !json.isEmpty else { return }
        UserDefaults.standard.set(json, forKey: loginPrefix + sourceUrl)
    }

    // MARK: - loginHeader（栖阅机制）

    /// 登录头（栖阅 §9.2：**纯字符串，会自动注入到每次请求头**）
    ///
    /// 用途：番茄 sessionid 这类「不来自 cookie 罐、但每个请求都要带」的凭据。
    /// 聚合源（🍅大灰狼）要 sessionid 才能同步番茄数据，
    /// 而它只能从 cookie 罐里翻 → 在 Safari 登录的读不到 → 一直提示「未登录番茄」。
    /// 有了这个：填一次 → 之后每个请求自动带上 ✅
    private static let headerPrefix = "sourceheader."

    static func loginHeader(for sourceUrl: String) -> String {
        guard !sourceUrl.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: headerPrefix + sourceUrl) ?? ""
    }

    static func setLoginHeader(_ value: String, for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: headerPrefix + sourceUrl)
        } else {
            UserDefaults.standard.set(value, forKey: headerPrefix + sourceUrl)
        }
    }

    /// 改登录信息里的**一项**（不覆盖别的字段）
    ///
    /// ⚠️ 为什么要这个：站方（🍅大灰狼）的 exploreUrl 会读
    ///    `source.getLoginInfoMap()['手动填写番茄token(可不填)']` →
    ///    没有这个入口时，**在 Safari 里登录的番茄**（cookie 在 Safari 的罐里，
    ///    App 读不到）就永远同步不了数据 → 发现页一直提示「您还未登陆番茄账号」。
    ///    给了手动输入框，用户从番茄网页复制 sessionid 粘进来就能用 ✅
    @discardableResult
    static func setLoginInfoValue(_ key: String, _ value: String, for sourceUrl: String) -> [String: String] {
        guard !sourceUrl.isEmpty, !key.isEmpty else { return [:] }
        var map = loginInfo(for: sourceUrl)
        if value.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = value
        }
        if let data = try? JSONSerialization.data(withJSONObject: map),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: loginPrefix + sourceUrl)
        }
        return map
    }
}
