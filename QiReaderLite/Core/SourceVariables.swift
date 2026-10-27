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
    /// ⭐⭐⭐ **站方变量**（Legado `source.variable`）的键前缀 —— 与「书籍变量」**分开存** ⭐
    private static let variablePrefix = "sourcevariable."

    // MARK: 书籍变量

    /// 读某个源的书籍变量（原始 JSON 串；没设置过 = 空串）
    static func vars(for sourceUrl: String) -> String {
        guard !sourceUrl.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: varsPrefix + sourceUrl) ?? ""
    }

    /// 写回某个源的书籍变量
    ///
    /// ⭐⭐⭐ **超长不许存**（2026-10-24 真机崩溃日志）
    ///   变量串是**回流**的（引擎回传的 `__sourceVars` ⇒ 存成用户变量 ⇒ 下次再喂回去）
    ///   ⇒ 一旦存进巨量文本就会**永久**拖垮：登录面板排版炸 + 每个 op 都背着它跑 ⭐⭐⭐
    ///   ⇒ 现在：**超 8K 直接拒收**（并回一份空 ⇒ 调用方能察觉）⭐
    static func setVars(_ value: String, for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        if value.count > maxVarsLength {
            NSLog("[vars] 拒绝存超长变量（\(value.count) 字符 > \(maxVarsLength)）· \(sourceUrl)")
            UserDefaults.standard.set("", forKey: varsPrefix + sourceUrl)
            return
        }
        UserDefaults.standard.set(value, forKey: varsPrefix + sourceUrl)
    }

    // MARK: - ⭐⭐⭐ 站方变量（Legado `source.getVariable()` / `setVariable(str)`）

    /// ⭐⭐⭐ 读某个源的**站方变量**（Legado 语义：**一整串**，不是 map）
    ///
    /// ⚠️⚠️ **为什么必须跟「书籍变量」分开**（2026-10-27 实证）：
    ///   · Legado 是**两套**：`getVariable()/setVariable(str)` = **站方变量**（一串）
    ///     `get(key)/put(key,v)` = **书源变量**（map）⇒ **互不污染** ⭐
    ///   · 轻阅以前**混成一份** ⇒ 站方 `setVariable(token)` 会把 `put` 存的项**整份冲掉**
    ///     ⇒ 聚合源（UAA）把 token 塞进「书籍变量」⇒ 请求头 `Bearer {"androidId":"…"}`
    ///     ⇒ 服务端 **403「无效JWT」** ⇒ **永远拿不到 token** ⭐⭐⭐
    ///   · 混成一份还有第二个后果：聚合源改一次发现页筛选（`setVariable(JSON…)`）
    ///     ⇒ **解锁态被冲掉** ⭐
    ///
    /// ⭐ **迁移策略（懒迁移，零风险）**：站方变量**从空开始**（= Legado 的初始状态）
    ///   ⇒ 站方的 `getArguments('', 'server')` 会走**站方默认表**（Legado 行为）⇒
    ///   ⇒ 旧的「书籍变量」里那份 init 快照由站方自己重新 setVariable 写回来 ⇒ **自愈** ⭐
    static func variable(for sourceUrl: String) -> String {
        guard !sourceUrl.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: variablePrefix + sourceUrl) ?? ""
    }

    /// 写回某个源的站方变量（引擎回传的 `__sourceVariable`）
    ///
    /// ⚠️ **同样不许超长**（跟书籍变量一个规矩 ⇒ 防「登录面板排版炸」那个老坑）
    static func setVariable(_ value: String, for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        if value.count > maxVarsLength {
            NSLog("[变量] 拒绝存超长站方变量（\(value.count) 字符 > \(maxVarsLength)）· \(sourceUrl)")
            UserDefaults.standard.set("", forKey: variablePrefix + sourceUrl)
            return
        }
        UserDefaults.standard.set(value, forKey: variablePrefix + sourceUrl)
    }

    /// ⭐ **存量变量是不是超长了**（面板用它提示用户「你之前存了一份超大的变量」）
    static func varsTooLong(for sourceUrl: String) -> Bool {
        vars(for: sourceUrl).count > maxVarsLength
    }

    // MARK: - 站方默认变量（jsLib 的 getArguments 兜底）

    /// 站方的**默认变量表**（从 jsLib 的 `getArguments('', '')` 取）—— 缓存在本地
    ///
    /// ⭐ 为什么要有它：站方的 `getArguments` 只在变量串**解析失败**（空串）时
    /// 才给默认值；只要我们写入任何一项，��方就不再给默认 ⇒
    /// `tab / sources / source_type / proxy …` 全变 undefined ⇒ 源被改坏。
    /// ⇒ 写变量时用这张表**做底**，用户的改动盖在上面 ✅
    private static let defaultVarsPrefix = "sourcevars.default."

    static func defaultVars(for sourceUrl: String) -> [String: Any] {
        guard !sourceUrl.isEmpty else { return [:] }
        guard let raw = UserDefaults.standard.string(forKey: defaultVarsPrefix + sourceUrl),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    static func setDefaultVars(_ value: [String: Any], for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: defaultVarsPrefix + sourceUrl)
    }

    /// **合并**：站方默认值（底）＋ 用户的改动（盖）
    ///
    /// - Parameters:
    ///   - userJSON: 用户/引擎存下来的变量串（可能是空串或非法 JSON）
    ///   - defaults: 站方默认变量表
    /// - Returns: 合并后的 JSON 串（可直接喂给 `source.getVariable()`）
    static func mergeVars(userJSON: String, defaults: [String: Any]) -> String {
        var merged = defaults
        if let data = userJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj { merged[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let s = String(data: data, encoding: .utf8) else { return userJSON }
        return s
    }

    /// 该源**最终生效**的变量串（站方默认值 + 用户的改动）
    ///
    /// ⚠️ 这一串才是喂给引擎的 `__variables` —— 少了它，
    ///    站方 JS 拿不到 `server / tab / sources / proxy` ⇒ 行为跟安卓/栖阅不一致。
    static func effectiveVars(for sourceUrl: String) -> String {
        // ⭐⭐⭐ **长度上限**（2026-10-24 真机崩溃日志实证）
        //   变量是**回流**的：引擎回传的 `__sourceVars` 被存成「用户变量」⇒ 下次再当用户变量喂回去
        //   ⇒ 一旦某次把大段文本存进去（手滑粘了 158KB 的源 JSON 之类）⇒ **永久撑大**
        //   ⇒ 后果：① 登录面板的 TextEditor 排版巨量文本 ⇒ **10 秒排不完 ⇒ watchdog 杀进程**
        //        ② 每个 op 都背着它跑 ⇒ 发现页又慢又卡 ⭐⭐⭐
        //   ⇒ 现在：**超长的一律忽略**（只留前 8K）⇒ 老数据也不会再撑爆 ⭐
        let merged = mergeVars(userJSON: vars(for: sourceUrl), defaults: defaultVars(for: sourceUrl))
        return String(merged.prefix(Self.maxVarsLength))
    }

    /// **变量串的最大长度**（8K）—— 超了就当没有
    static let maxVarsLength = 8_000

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

    // MARK: 发现页筛选项的「当前值」

    /// ⭐⭐ **用户选过的筛选项值**（2026-10-22）
    ///
    /// 站方（🍒NovelHub 聚合源）的筛选 action **自己写源级变量**（键名是站方定的 `src`/`kind`/…），
    /// 宿主抠不出 paramKey ⇒ 读不到「当前值」⇒ 胶囊上永远显示站方给的 `default`
    /// （而站方的 default 恒为 `chars[0]` ⇒ 切了番茄还显示书旗 ⇒ **用户以为没生效**）❗
    ///
    /// ⇒ 宿主自己记一份「用户选过什么」⇒ 胶囊显示它 ✅
    /// （站方那边的真实状态由站方自己维护，宿主这份只是**显示**用的）
    private static let filterChoicePrefix = "sourcefilter."

    /// 读某个源、某个筛选项的当前值（没选过 = 空串）
    static func filterChoice(for sourceUrl: String, title: String) -> String {
        guard !sourceUrl.isEmpty, !title.isEmpty else { return "" }
        return UserDefaults.standard.string(
            forKey: filterChoicePrefix + sourceUrl + "|" + title) ?? ""
    }

    /// 记下用户选了哪个
    static func setFilterChoice(_ value: String, for sourceUrl: String, title: String) {
        guard !sourceUrl.isEmpty, !title.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: filterChoicePrefix + sourceUrl + "|" + title)
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
