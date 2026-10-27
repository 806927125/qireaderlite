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
    /// ⭐⭐⭐ **「站方变量是什么形态」的证据**（**站方自己写的**才算）
    ///
    /// ⚠️ **为什么需要它**（2026-10-27 真机「获取 token 不了」）：
    ///   判「这个源的站方变量是 map 形态还是凭据形态」光看**内容**不可靠 ——
    ///   **旧实现灌进去的污染本身也是一份 map**（`{"androidId":…}`）⇒ 看着像 map 形态 ⭐⭐⭐
    ///   ⇒ 只能看**证据**：**站方自己写过什么**（`setVariable(…)`）⇒ 它才是这个形态的源 ⭐
    ///   ⇒ 没这个证据 ⇒ 站方变量里那份 map 就是**宿主灌的污染** ⇒ 该清 ⭐⭐⭐
    ///
    /// ⚠️⚠️⚠️ **v2：键名带版本**（2026-10-27 真机复盘）：
    ///   v1（`sourcevariable.stationmap.`）的证据**会被自己污染** ⇒
    ///   **回传**（`__sourceVariable`）里那份 map（其实就是宿主灌的污染被原样弹回来）
    ///   ⇒ 被当成「站方自己写过 map」⇒ 证据**自证**⇒ 迁移永远不触发 ⇒ 真机上的污染清不掉 ⭐⭐⭐
    ///   ⇒ **v2 换键名** ⇒ 旧的那份**自证的证据直接作废**（不是去修它，是**不看它**）⭐
    private static let stationFormPrefix = "sourcevariable.stationform.v2."

    /// ⭐⭐⭐ **「站方的默认变量表已经取过了」的标记**
    ///
    /// ⚠️ **为什么不能只看「默认表空不空」**（2026-10-27 真机复盘）：
    ///   「默认表是空的」有两种完全不同的意思 ——
    ///     ① **取过了，站方确实没有默认表**（✿UAA：站方变量 = **凭据的位置**）⇒ 该清污染 ⭐
    ///     ② **还没取过**（大灰狼第一次进来）⇒ **还不知道** ⇒ **不许清**（会把大灰狼的合法 map 清掉）⭐⭐⭐
    ///   ⇒ 必须**另立一个标记**记「取过没」⇒ 两种情况才分得开 ⭐
    private static let defaultTableFetchedPrefix = "sourcevars.defaultfetched."

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
    ///
    /// ⭐⭐⭐ **origin = 「这份是谁写的」** ⇒ 判形态的**证据**只认站方写的 ⭐
    ///   · `.station` = **站方自己改的**（引擎回传且**值确实变了**）⇒ 算证据 ⭐
    ///   · `.app` = **宿主自己合成的**（线路表 / 面板 / 回传时值没变）⇒ **不算证据** ⭐
    static func setVariable(_ value: String, for sourceUrl: String, origin: Origin = .station) {
        guard !sourceUrl.isEmpty else { return }
        if value.count > maxVarsLength {
            NSLog("[变量] 拒绝存超长站方变量（\(value.count) 字符 > \(maxVarsLength)）· \(sourceUrl)")
            UserDefaults.standard.set("", forKey: variablePrefix + sourceUrl)
            return
        }
        UserDefaults.standard.set(value, forKey: variablePrefix + sourceUrl)
        // ⭐⭐⭐ **记下「这份是谁写的」** ⇒ 判形态要有证据（不能只看内容）⭐
        switch origin {
        case .station:
            // 站方自己写的 ⇒ 它写什么形态 ⇒ 这个源的站方变量就是那个形态 ⭐
            // ⚠️ **「map」证据是黏的**（站方写过 map ⇒ 这一格就是 map 形态）⭐
            //   ⇒ 凭据形态的写**不覆盖**已有的 map 证据（站方两种都写过 ⇒ 按 map 处理，
            //   ⇒ 而真正写进去时 `canWriteMapIntoVariable` 还会挡一次 ⭐⭐⭐）
            if isMapStyleVariable(value) {
                UserDefaults.standard.set(StationVarForm.map.rawValue,
                                          forKey: stationFormPrefix + sourceUrl)
            } else if UserDefaults.standard.string(forKey: stationFormPrefix + sourceUrl)
                        != StationVarForm.map.rawValue {
                UserDefaults.standard.set(StationVarForm.credential.rawValue,
                                          forKey: stationFormPrefix + sourceUrl)
            }
        case .app:
            // 宿主自己合成的（线路表）⇒ **不算证据**（它正是污染的来源）⭐
            break
        }
    }

    /// ⭐⭐⭐ **谁写的站方变量**
    enum Origin {
        /// 站方自己（`setVariable`）或用户在面板里改的 ⇒ **算证据** ⭐
        case station
        /// 宿主自己合成的（线路表 / 默认表）⇒ **不算证据** ⭐
        case app
    }

    /// ⭐⭐⭐ **站方变量的形态**（**一整串** ⇒ 两种形态并存）
    ///
    /// | 形态 | 哪个源 | 站方怎么用 | 站方变量里放什么 |
    /// |---|---|---|---|
    /// | **map** | 🍅大灰狼 / NovelHub / 番茄 | `getArguments(source.getVariable(),'server')` / `JSON.parse(source.getVariable())` | `{"server":…,"tab":…}` |
    /// | **credential** | ✿UAA四合一（知秋） | `authorization: Bearer ${source.getVariable()}` | **token 那一串**（不是 JSON） |
    /// | **unknown** | 还没取过默认表 | —— | **别动** |
    enum StationVarForm: String {
        /// 站方拿它当 **JSON map** 用
        case map
        /// 站方拿它当**一整串凭据**用（token）
        case credential
        /// **还不知道** ⇒ 不许动这一格（宁可不改，也别把好状态弄坏）
        case unknown
    }

    /// ⭐⭐⭐ **这个源的站方变量是什么形态？**（**要证据**，不能只看内容）
    ///
    /// ⭐ **判据的顺序**（每一条都要有）：
    ///   ① **站方自己写过什么**（回传时**值确实变了**才算）⇒ 最硬的证据 ⭐⭐⭐
    ///      · 写过 map ⇒ **map 形态**（大灰狼 / 番茄 / NovelHub）
    ///      · 写过凭据（token 串）⇒ **凭据形态**（UAA）⭐⭐⭐
    ///   ② **站方自带默认变量表**（`getArguments('','')` 有东西）⇒ map（大灰狼）⭐
    ///   ③ **默认表取过了、且是空的** ⇒ **凭据形态**（UAA：这一格放的是 token）⭐⭐⭐
    ///   ④ 其余 ⇒ **unknown**（**不许动**：大灰狼第一次进来时默认表还没取到
    ///      ⇒ 那时候清一下就把它的合法 map 清掉了）⭐⭐⭐
    static func form(for sourceUrl: String) -> StationVarForm {
        guard !sourceUrl.isEmpty else { return .unknown }
        // ① 站方自己写过什么（证据：回传时值**确实变了**才算）
        if let raw = UserDefaults.standard.string(forKey: stationFormPrefix + sourceUrl) {
            if raw == StationVarForm.map.rawValue { return .map }
            if raw == StationVarForm.credential.rawValue { return .credential }
        }
        // ② 站方自带默认变量表 ⇒ 它把这格当 map 用（大灰狼）
        if !defaultVars(for: sourceUrl).isEmpty { return .map }
        // ③ 默认表取过了而且是空的 ⇒ 凭据形态（UAA）
        if defaultTableFetched(sourceUrl) { return .credential }
        // ④ 不知道 ⇒ 别动
        return .unknown
    }

    /// ⭐⭐⭐ **这个源的站方变量是不是「map 形态」？**（**要有证据**）
    ///
    /// ⚠️ 只在「**这一格能不能被宿主塞 map**」这个问题上用它 ⇒ 等价于 `form(for:) == .map`
    static func isStationMapStyle(_ sourceUrl: String) -> Bool {
        form(for: sourceUrl) == .map
    }

    /// ⭐⭐⭐ **宿主往站方变量里写一份 map**（发现页筛选 / 面板选线路）
    ///
    /// ⚠️⚠️ **凭据形态的源不许写 map**（✿UAA：这一格放的是 **token**）⭐⭐⭐
    ///   ⇒ 写了 ⇒ `Bearer {"androidId":"…"}` ⇒ 服务端 403「无效JWT」⇒ 「获取 token」永远失败 ⭐⭐⭐
    ///   ⇒ **书源变量**照写（那是宿主自己的变量表，跟站方变量是两套）⭐
    ///
    /// ⚠️ **形态还「不知道」的时候照写**（⇒ 宿主自己的功能得能用）
    ///   ⇒ 形态一旦判出来（默认表取过了）⇒ 下一轮就被拦住 / 被迁移清掉 ⭐
    static func setHostMap(_ value: String, for sourceUrl: String) {
        setVars(value, for: sourceUrl)                                   // 书源变量：总是写 ⭐
        guard form(for: sourceUrl) != .credential else { return }         // ⭐ 凭据形态 ⇒ 不许写 map ⭐⭐⭐
        setVariable(value, for: sourceUrl, origin: .app)                  // 宿主写的 ⇒ **不算证据** ⭐
    }

    /// ⭐⭐⭐ **站方变量该往引擎里灌什么**（顺带做**存量污染的迁移**）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么迁移必须在这里做**（2026-10-27 真机复盘）：
    ///   以前迁移写在 `setLineVars`（**选线**那条链）⇒
    ///   ⇒ **✿UAA 压根没有线路**（jsLib 里没有 `host` 数组）⇒ **那条链永远走不到**
    ///   ⇒ ⇒ 真机上的污染（`{"androidId":…}`）**永远清不掉** ⇒ `Bearer {"androidId":…}`
    ///   ⇒ 服务端 403「无效JWT」⇒ 「获取 token」永远失败 ⭐⭐⭐
    ///   ⇒ **每个 op 都要灌站方变量** ⇒ 迁移放这儿 ⇒ 一定会走到 ⭐
    ///
    /// - 判据：**凭据形态 + 这一格现在躺着一个 map** ⇒ 那是**宿主灌的污染** ⇒ 清掉 ⭐⭐⭐
    ///   （map 形态的源**不清**：那是站方自己的 map ⇒ 清了就把大灰狼的线路弄没了 ⭐）
    static func stationVariableToSeed(for sourceUrl: String) -> String {
        let current = variable(for: sourceUrl)
        // ⭐⭐⭐ **诊断**（2026-10-27 真机：污染还在 ⇒ 先量出来，别猜）⭐
        //   一次跑就能定位：槽里是什么 / 形态判成什么 / 为什么没清 ⭐
        let f = form(for: sourceUrl)
        let isMap = isMapStyleVariable(current)
        NSLog("[变量] 槽=\(current.prefix(60)) 形态=\(f.rawValue) 取过默认表=\(defaultTableFetched(sourceUrl)) 是map=\(isMap)")
        guard !current.isEmpty else { return "" }
        guard f == .credential, isMap else {
            if f == .credential && !isMap {
                NSLog("[变量] 迁移=没清（槽里不是 map，是凭据本身）")
            } else if f != .credential {
                NSLog("[变量] 迁移=没清（形态=\(f.rawValue)，不是凭据形态 ⇒ 不许动）")
            }
            return current
        }
        NSLog("[变量] 迁移=清了（凭据形态却躺着一个 map ⇒ 宿主灌的污染）")
        setVariable("", for: sourceUrl, origin: .app)
        return ""
    }

    /// ⭐⭐⭐ **同时写「站方变量」+「书源变量」**
    ///
    /// ⚠️ **什么时候用**：站方用 `setVariable(...)` 存的东西（线路 / 发现页筛选 / 设置）
    ///   ⇒ 按 Legado 语义那是**站方变量** ⇒ 宿主必须写进站方变量槽位 ⭐
    ///   ⇒ 同时**镜像一份**进书源变量（兼容仍读 map 的老站方 / 老宿主）⭐
    ///
    /// ⚠️⚠️ **只给「站方自己写的值」用**（回传 / 站方筛选写回）
    ///   ⇒ **App 自己合成的 map（线路 / 默认表）必须走 `setLineVars`** ⭐⭐⭐
    static func setVariableAndVars(_ value: String, for sourceUrl: String) {
        setVariable(value, for: sourceUrl)
        setVars(value, for: sourceUrl)
    }

    // MARK: - ⭐⭐⭐ 「站方变量」的两种形态（map 形态 vs 凭据形态）

    /// ⭐⭐⭐ **当前站方变量能不能被一份 map 覆盖？**
    ///
    /// ⚠️⚠️ **站方变量是「一整串」⇒ 两种形态并存**（2026-10-27 真机实证）：
    ///   · **map 形态**（🍅大灰狼 / NovelHub）：
    ///     `getArguments(source.getVariable(), 'server')` ⇒ 站方变量里放的是
    ///     `{"server":…,"tab":…}` 这种 **JSON map** ⭐
    ///   · **凭据形态**（✿UAA四合一（知秋））：
    ///     `authorization: Bearer ${source.getVariable()}` ⇒ 站方变量里放的是
    ///     **token 那一串**（不是 JSON）⭐
    ///
    /// ⇒⇒ **App 把「书籍变量 / 线路表」写进站方变量 ⇒ 凭据形态的源直接被毁** ⭐⭐⭐
    ///   （UAA：站方变量变成 `{"androidId":"…"}` ⇒ 请求头 `Bearer {"androidId":"…"}`
    ///     ⇒ 服务端 **403「无效JWT」** ⇒ 「获取 token」永远失败 ⭐⭐⭐）
    ///
    /// - Returns: true = 当前站方变量**允许**被 map 覆盖
    static func canWriteMapIntoVariable(_ current: String) -> Bool {
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }                        // 还没写过 ⇒ 随便
        if let d = t.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d),
           o is [String: Any] { return true }              // 本来就是 map 形态 ⇒ 允许
        return false                                       // 一串凭据（token）⇒ 不许被 map 覆盖 ⭐
    }

    /// ⭐⭐⭐ **当前站方变量是不是「map 形态」？**（不是空、且是合法 JSON object）
    ///
    /// ⚠️ **为什么要两个判据**（站方变量是「一整串」⇒ 两种形态并存）：
    ///   · **站方自带默认变量表**（`getArguments('','')` 有东西）⇒ 它把站方变量当 map 用
    ///     （🍅大灰狼：`getArguments(source.getVariable(),'server')`）⭐
    ///   · **站方变量里已经躺着一个 map** ⇒ 同上（站方自己写过 map）⭐
    ///   · 两条都不成立 ⇒ 它的站方变量是**凭据的位置**（✿UAA：token）⇒ **别塞 map** ⭐⭐⭐
    static func isMapStyleVariable(_ current: String) -> Bool {
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        guard let d = t.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d),
              o is [String: Any] else { return false }
        return true
    }

    /// ⭐⭐⭐ **线路 / 默认表写回**：**书源变量**总是写；**站方变量**只给「map 形态」的源 ⭐
    ///
    /// - Parameters:
    ///   - merged: 合并后的变量串（站方默认表做底 + 测速/用户的改动）
    ///   - isMapStyle: 这个源的站方变量**是不是 map 形态**（调用方按 `form(for:)` 算好）
    ///     ⇒ **false 时不许把 map 塞进站方变量**（凭据形态的源：站方变量 = token）⭐⭐⭐
    static func setLineVars(_ merged: String, for sourceUrl: String, isMapStyle: Bool) {
        setVars(merged, for: sourceUrl)                    // 书源变量：总是写 ⭐
        if isMapStyle {
            guard canWriteMapIntoVariable(variable(for: sourceUrl)) else { return }  // ⭐ 凭据形态 ⇒ 不许覆盖
            setVariable(merged, for: sourceUrl, origin: .app)
            return
        }
        // ⭐⭐⭐⭐⭐ **迁移**：旧实现把「线路表」整份灌进了站方变量 ⇒ 对「凭据形态」的源那是**污染** ⭐⭐⭐
        //   （不清 ⇒ 站方变量里躺着一份 map ⇒ `Bearer {"androidId":"…"}`
        //     ⇒ 服务端 **403「无效JWT」** ⇒ 「获取 token」永远失败 ⭐⭐⭐）
        // ⇒ 判据：**形态 = 凭据**（不是「不是 map」！）⇒ **unknown 时不许清** ⭐⭐⭐
        //   （大灰狼第一次进来时默认表还没取到 ⇒ 那时候清一下就把它的合法 map 清掉了 ⭐）
        if form(for: sourceUrl) == .credential, isMapStyleVariable(variable(for: sourceUrl)) {
            setVariable("", for: sourceUrl, origin: .app)
        }
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
        // ⭐⭐⭐ **记下「取过了」**（哪怕取回来是空的！）⭐
        //   「默认表是空的」有两种意思：① 取过了，站方确实没有 ② **还没取过**
        //   ⇒ 不记这个 ⇒ 分不清 ⇒ 会把大灰狼的合法 map 当污染清掉 ⭐⭐⭐
        UserDefaults.standard.set(true, forKey: defaultTableFetchedPrefix + sourceUrl)
    }

    /// ⭐⭐⭐ **站方的默认变量表**取过没有？（**取过但为空**也算取过 ⭐）
    static func defaultTableFetched(_ sourceUrl: String) -> Bool {
        guard !sourceUrl.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: defaultTableFetchedPrefix + sourceUrl)
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
    ///
    /// ⚠️⭐⭐ **站方变量 / 默认表 / 登录头也要一起清**（2026-10-27 补）
    ///   ⇒ 以前只清了「书籍变量 + 登录信息」⇒ **站方变量（token！）留在盘上** ⭐
    ///   ⇒ 删源再导入同名源 ⇒ 拿到**上一次的 token** ⇒ 「登录态乱了」查不到原因 ⭐⭐⭐
    static func clear(for sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: varsPrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: loginPrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: variablePrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: stationFormPrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: defaultVarsPrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: defaultTableFetchedPrefix + sourceUrl)
        UserDefaults.standard.removeObject(forKey: headerPrefix + sourceUrl)
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
