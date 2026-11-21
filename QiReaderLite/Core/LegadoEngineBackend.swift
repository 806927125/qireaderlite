import Foundation
import LegadoEngine

/// ⭐⭐⭐⭐⭐ **轻阅 ⇄ LegadoEngine 接线层**（2026-11-19 · 老的两条引擎全部退役）
///
/// **老引擎（已删）**
/// · ① WebView JS 引擎（`Resources/engine/*.js` + `Engine/WebViewJSExecutor.swift`）
/// · ② 自研 Swift 引擎（`legado-engine` 这个 SPM 包）
///
/// **新引擎**
/// · `LegadoEngine`（Legado 3.0 语义，从「六阅 LegadoR iOS」二进制逆向重建）
///   - 规则层：`AnalyzeRule` / `AnalyzeUrl` / `RuleSplitter`
///   - 解析层：SwiftSoup（默认规则）· **Kanna（真 XPath）** · JSONPath · 正则
///   - JS 层：JavaScriptCore + 从原二进制 1:1 提取的 Rhino 兼容 shim
///   - 网络层：自带 `HTTPClient`（用 `HTTPCookieStorage.shared` ⇒ **登录态与 App 共用一个罐** ✔）
///
/// ⚠️ **架构纪律**（沿用旧层的硬约束）
/// · 本文件**不许 import UIKit**（沙盒 swift 门禁在 Linux 上编译它）⭐⭐⭐
/// · 引擎调用**必须离开主线程**（引擎内部全同步 ⇒ 主线程会卡 UI）⭐⭐⭐
/// · 失败必须**如实抛错**（不假成功）⭐⭐⭐
final class LegadoEngineBackend {

    static let shared = LegadoEngineBackend()

    /// ⭐⭐⭐ **一个源一个会话**（站方变量/登录态要在 op 之间延续）
    fileprivate final class Session {
        /// ⭐⭐⭐⭐⭐ **站方变量通道（2026-11-19 真机 build297 实证）**
        ///
        /// ⚠️⚠️⚠️ **为什么需要它**（真机症状：发现页「只解析出 0 个分类」）：
        ///   · 引擎的站方 JS 读变量走 `source.get(k)` / `source.getVariable()`
        ///     ⇒ 落到引擎 `BookSource.variable` **这一格**（`srcGet`/`srcPut` 都指它）⭐⭐⭐
        ///   · 而 App 灌站方变量的地方是 **`srcDict["__variable"]` → `session.variables`**（另一格）⭐⭐⭐
        ///   ⇒ **两格不通** ⇒ 站方 JS 读 `source.get("nhAuthed")` **恒空** ⇒ `nhAuth()` 恒 false
        ///     ⇒ 站方 `exploreUrl` **主动交白卷**（`if (!nhAuth()) { return ""; }`）⇒ **0 个分类** ⭐⭐⭐
        ///   ⇒ 写方向同样断：站方 `source.put(...)` 写进引擎那格 ⇒ App 回传的是**另一格** ⇒ 写不回来 ⭐⭐⭐
        ///
        /// ⭐ **本类 = 那条通道的宿主端**：
        ///   · `stationVariable` = 站方变量那一格的 JSON 对象串（**引擎读写的正是它**）⭐⭐⭐
        ///   · 每次 op 前：把它灌进 `engineSource.variable` ⇒ 站方 JS 读得到 ⭐⭐⭐
        ///   · 每次 op 后：把 `engineSource.variable` 读回来 ⇒ 站方 JS 写得回来 ⭐⭐⭐
        ///
        /// ⚠️ **为什么不用 `session.variables`**（RuleVariables map）：
        ///   它是【书籍变量】那格（`book.getVariable` 走 `varGet`）⇒ 与站方变量**不是同一格** ⇒ 不能混 ⭐⭐⭐
        /// ⚠️⚠️⚠️ **必须是 var**（2026-11-19 真机 build298 实证）：
        ///   `Session` 是**按源缓存**的 ⇒ 第一次 op 时灌进去的变量会被**一直沿用**
        ///   ⇒ 用户后来在登录面板**解锁**（写了 `nhAuthed`）⇒ **缓存里的还是旧值（空）** ⭐⭐⭐
        ///   ⇒ 站方 `nhAuth()` 仍恒 false ⇒ **仍然交白卷** ⇒ 症状与没修一模一样 ⭐⭐⭐
        ///   ⇒ 正解：**每个 op 都用最新的 `__variable` 重新灌**（见 `refreshStationVariable`）⭐⭐⭐
        var engineSource: LegadoEngineHost.Source
        /// 站方变量（Legado 语义：一整串 JSON）⇒ **引擎读写的正是这一格** ⭐⭐⭐
        var stationVariable: String
        /// 站方变量（**书籍变量**那格；新引擎是一个 map）⇒ 走 `varGet`/`varPut`
        let variables: LegadoEngineHost.Vars
        /// 灌进去时的种子（判定「站方到底改没改」—— **证据不许自证**）⭐⭐⭐
        let seeded: String
        /// ⭐⭐⭐ **站方变量那格的种子**（判定站方有没有改它 ⇒ **证据不许自证**）⭐⭐⭐
        let stationSeeded: String
        /// ⭐⭐⭐⭐⭐ **书源变量（引擎那一格 sourceVars）的快照**（回传用 ⇒ 解锁态要能落盘）⭐⭐⭐
        var sourceVarsSnapshot: [String: String] = [:]

        init(engineSource: LegadoEngineHost.Source, payload: [String: Any]) {
            let raw = (payload["source"] as? [String: Any]) ?? [:]
            // ① 书籍变量（map）⇒ 走 `varGet`/`varPut`（**与站方变量不是同一格**）⭐⭐⭐
            let vars = LegadoEngineHost.Vars()
            if let seed = raw["__variables"] as? String, !seed.isEmpty,
               let d = seed.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { vars.put(k, "\(v)") }
            }
            self.variables = vars
            self.seeded = vars.getVariable()
            // ② ⭐⭐⭐⭐⭐ **站方变量那格**（Legado 语义：**一整串** JSON）⭐⭐⭐
            let sv = (raw["__variable"] as? String) ?? ""
            self.stationVariable = sv
            self.stationSeeded = sv
            // ③ ⭐⭐⭐⭐⭐ **【两格分开】灌**（2026-11-19 移植柴阅/Chaiyue 的 `SourceState` 实证）⭐⭐⭐
            //
            //   ⚠️⚠️⚠️ **Legado / 栖阅 / 柴阅都是【两套】** ⭐⭐⭐
            //     · **站方变量**（`source.getVariable()` / `setVariable(str)`）⇒ **一整串**
            //       （柴阅的存储键：`sourceVariable_<key>`）⭐⭐⭐
            //     · **书源变量**（`source.get(k)` / `put(k,v)`）⇒ **每个 k 一个独立项**
            //       （柴阅的存储键：`v_<key>_<k>`）⭐⭐⭐
            //   ⇒ 之前把两者**混在一格** ⇒ 站方 `put('nhAuthed', h)` 与站方变量的项**互相污染** ⭐⭐⭐
            //     ⇒ 而宿主灌进 `variable` 的是**站方变量整串** ⇒ `source.get("nhAuthed")` **读不到** ⭐⭐⭐
            //     ⇒ 站方 `nhAuth()` 恒 false ⇒ **exploreUrl 主动交白卷** ⇒ **0 个分类** ⭐⭐⭐
            //
            //   ⇒ 现在：**站方变量 ⇒ `variable`（整串）／书源变量 ⇒ `sourceVars`（每 k 一项）** ⭐⭐⭐
            var src = engineSource
            // ① 站方变量：原样进 `variable`（整串，**不解析、不合并**）
            if !sv.isEmpty { src.variable = sv }
            // ② 书源变量（`source.get/put` 的项）⇒ 进 `sourceVars`（独立格）
            var svMap = Self.sourceVarsMap(bookVars: vars)
            // ②' ⭐⭐⭐ **存量迁移**（2026-11-19 移植柴阅实证）：
            //     旧版本把书源变量（`nhAuthed` / `nhPlatSwitch` / `token` …）塞在
            //     **站方变量整串 `variable` 的项里** ⇒ 新引擎读 `sourceVars` ⇒ **存量看不见** ⭐⭐⭐
            //     ⇒ 而「解锁态存于旧格」正是之前 0 分类的根因之一 ⇒ 必须迁 ⭐⭐⭐
            let legacy = Self.legacySourceVars(from: sv)
            for (k, v) in legacy where svMap[k] == nil { svMap[k] = v }
            if !svMap.isEmpty { src.sourceVars = svMap }
            self.engineSource = src
        }

        /// ⭐⭐⭐⭐⭐ **存量迁移**：从【站方变量整串】里挑出【书源变量语义】的项 ⭐⭐⭐
        ///
        /// ⚠️⚠️⚠️ **为什么必须迁**（2026-11-19 移植柴阅实证）：
        ///   旧版本（我们自己的实现）把 `source.get/put` 的项写进**站方变量整串**的项里 ⭐⭐⭐
        ///   ⇒ 新引擎按 Legado 语义读【独立的 sourceVars 格】⇒ **存量数据看不见** ⭐⭐⭐
        ///   ⇒ 而「解锁态（nhAuthed）存于旧格」正是之前「0 个分类」的根因之一 ⭐⭐⭐
        ///   ⇒ 迁移判据：**键名是站方【书源变量】语义**（不是 NH_D 那种站方变量的项）⭐⭐⭐
        ///   ⇒ ⚠️ 宁可不迁（站方读不到就报错）也别**迁错**（把 NH_D 塞进书源变量 ⇒ 语义乱）⭐⭐⭐
        static func legacySourceVars(from stationRaw: String) -> [String: String] {
            guard let o = Self.jsonObject(stationRaw) else { return [:] }
            var out: [String: String] = [:]
            for (k, v) in o {
                // ⭐⭐⭐ **只迁【明确的站方书源变量键】**（白名单 ⇒ 不猜）⭐⭐⭐
                //   ⚠️ 这几个键都是站方脚本里 `source.put(...)` 写的 ⇒ 语义确定 ⭐⭐⭐
                guard ["nhAuthed", "nhPwdHash", "nhPlatSwitch", "nhPlatLog", "nhPlatSync",
                       "nhLoginState", "nhSafeMode", "nhHostCaps", "nhImgRef", "token"].contains(k) else { continue }
                out[k] = v is String ? (v as! String) : "\(v)"
            }
            return out
        }

        /// ⭐⭐⭐ **书源变量 map（`source.get/put` 的项）⇒ 独立格的字典**⭐⭐⭐
        ///
        /// ⚠️ ⚠️ **只取【站方语义上属于书源变量】的项**：`source.get(k)` / `source.put(k,v)` 这一族
        ///   （含 `nhAuthed` / `nhPlatSwitch` / `nhPlatLog` / `token` …）⭐⭐⭐
        ///   ⇒ 站方变量的项（`src` / `gender` / `status` …）**归 `variable`**，不在这儿 ⭐⭐⭐
        static func sourceVarsMap(bookVars: LegadoEngineHost.Vars) -> [String: String] {
            var out: [String: String] = [:]
            let raw = bookVars.getVariable()
            guard let d = raw.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return out }
            for (k, v) in o { out[k] = v is String ? (v as! String) : "\(v)" }
            return out
        }

        /// ⭐⭐⭐ **合并两格变量**（书籍变量 map + 站方变量整串）⇒ 引擎那一格的 JSON map ⭐⭐⭐
        ///
        /// ⚠️⚠️ **优先级**：
        ///   · 书籍变量的项（`nhAuthed` / `nhPlatSwitch` / `token` …）**优先**
        ///     ⇒ 它们是 `source.get/put` 的项 ⇒ 站方按 map 项读 ⭐⭐⭐
        ///   · 站方变量的项（`src` / `gender` / `status` …）填进去 ⇒ `source.getVariable()`
        ///     解析出来就有它们（站方 `JSON.parse` 整串拿 NH_D）⭐⭐⭐
        static func mergeStationMap(bookVars: LegadoEngineHost.Vars, stationRaw: String,
                                    loginInfo: String = "") -> String {
            var out: [String: Any] = [:]
            // ① 站方变量整串（可能是一份 map ⇒ 直接并入；也可能是一串凭据 ⇒ 跳过）
            if let d = stationRaw.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { out[k] = v }
            }
            // ② 书籍变量 map 的项（优先）
            let bv = bookVars.getVariable()
            if let d = bv.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { out[k] = v }
            }
            // ③ ⭐⭐⭐⭐⭐ **登录信息**（站方 `source.getLoginInfoMap()` 读的就是这一项）⭐⭐⭐
            //
            //   ⚠️⚠️⚠️ **为什么必须并进去**（2026-11-19 真机 build299 实证）：
            //     引擎的 `loginInfoGet` ⇒ `BookSource.variable["loginInfo"]` ⭐⭐⭐
            //     而站方 `nhAuthUiMap()` ⇒ `source.getLoginInfoMap()` ⇒ **同一项** ⭐⭐⭐
            //     ⇒ 「整源解锁密码」就是从这儿读的 ⭐⭐⭐
            //     ⇒ **不并进去 ⇒ 站方读到空 map ⇒ 点「🔓 解锁整个源」必然提示
            //       「请在下面输入框里填密码」⇒ 永远解锁不了 ⇒ 永远交白卷** ⭐⭐⭐
            if !loginInfo.isEmpty,
               let d = loginInfo.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                out["loginInfo"] = o
            }
            guard !out.isEmpty else { return "" }
            guard let d = try? JSONSerialization.data(withJSONObject: out),
                  let s = String(data: d, encoding: .utf8) else { return "" }
            return s
        }

        /// ⭐⭐⭐⭐⭐ **把「变量通道」的事实打进引擎日志**（让真机一次定位断点）⭐⭐⭐
        ///
        /// ⚠️⚠️ **为什么必须有**（2026-11-19 真机连错三轮的教训）：
        ///   「0 个分类」我连猜了三个原因（求值 / 两格不通 / 门禁未解锁）**全错或不全**
        ///   ⇒ **靠推理不行 ⇒ 必须让真机把事实摆出来** ⭐⭐⭐
        ///
        /// ⚠️⚠️ **不打印值**（站方变量里有 token / 密码）⇒ 只打【键名 + 长度】⭐⭐⭐
        static func logExploreGateState(engineSource: LegadoEngineHost.Source, session: Session) {
            let merged = engineSource.variable ?? ""
            let keys: [String] = {
                guard let d = merged.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
                return o.keys.sorted()
            }()
            let hasAuthed = keys.contains("nhAuthed")
            let hasPwdHash = keys.contains("nhPwdHash")
            let bookVars = session.variables.getVariable()
            let bookKeys: [String] = {
                guard let d = bookVars.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
                return o.keys.sorted()
            }()
            engineLog("[变量通道] 合并后引擎那一格 \(merged.count) 字 · 键=\(keys.joined(separator: ","))"
                      + " · nhAuthed=\(hasAuthed) nhPwdHash=\(hasPwdHash)"
                      + " · 书源变量 \(bookVars.count) 字 · 键=\(bookKeys.joined(separator: ","))"
                      + " · 站方变量 \(session.stationVariable.count) 字")
        }

        /// ⭐⭐⭐⭐⭐ **回传站方变量时【剥掉 loginInfo 项】**（2026-11-19 实证）⭐⭐⭐
        ///
        /// ⚠️⚠️⚠️ **为什么必须剥**：
        ///   引擎那一格里含 `loginInfo` 项（**用户填的明文密码**在里头）
        ///   ⇒ 回传 `__sourceVariable` ⇒ App 落盘到**站方变量槽** ⇒ **明文密码躺盘** ⭐⭐⭐
        ///   ⇒ 站方自己的 `nhAuthWipe()` 也是为了这个（「密码就明文躺在源文件里了」）⭐⭐⭐
        ///   ⇒ 而 `loginInfo` **有独立的落盘通道**（`__loginInfo` ⇒ `sourceform.` / `sourcelogin.`）
        ///     ⇒ 剥掉不丢东西 ⭐⭐⭐
        static func stripLoginInfo(from stationVar: String) -> String {
            guard var d = stationVar.data(using: .utf8),
                  var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o.removeValue(forKey: "loginInfo") != nil else { return stationVar }
            guard let dd = try? JSONSerialization.data(withJSONObject: o),
                  let s = String(data: dd, encoding: .utf8) else { return stationVar }
            return s
        }

        /// ⭐⭐⭐ **站方 JS 跑完之后：把引擎那格读回来**（站方 `source.put(...)` 的写回）⭐⭐⭐
        ///
        /// ⚠️⚠️ **为什么必须用 JS 读、不能直接读 `engineSource.variable`**：
        ///   站方 JS 写的是 **`JSBridge` 内的副本**（`JSBridge.source` 是模块内可见 ⇒ 宿主读不到）⭐⭐⭐
        ///   ⇒ 正解：`bridge.eval("source.getVariable()")` ⇒ **纯 JS 读副本** ⇒ 零引擎改动 ⭐⭐⭐
        /// ⚠️⚠️ **参数用闭包、不写 `LegadoEngineHost.Bridge` 类型**：
        ///   那个别名只在 Apple 平台存在（`#if canImport(JavaScriptCore)`）
        ///   ⇒ Linux 沙盒编译时**类型不存在** ⇒ 写死会编不过 ⭐⭐⭐
        ///   ⇒ 闭包在调用点（Apple 分支）里构造 ⇒ 类型由编译器在那儿推断 ⭐⭐⭐
        func collectStationVariable(read: () -> String?) -> String {
            var v = stationVariable
            if let s = read(), !s.isEmpty { v = s }
            stationVariable = v
            return v
        }

        /// ⭐⭐⭐⭐⭐ **读回引擎那一格的书源变量 ⇒ JSON 串**（回传给宿主落盘）⭐⭐⭐
        ///
        /// ⚠️⚠️⚠️ **为什么必须读回**（2026-11-19 移植柴阅/Chaiyue 实证）：
        ///   站方 `source.put('nhAuthed', h)`（解锁）写的是**引擎那一格的 sourceVars** ⭐⭐⭐
        ///   ⇒ 不读回 ⇒ **解锁态存不下来** ⇒ 下次又是未解锁 ⇒ **永远交白卷** ⭐⭐⭐
        ///   ⇒ 读回用引擎的 `source.getAllVars()`（一次导出整张 map ⇒ 比逐项 get 快）⭐⭐⭐
        /// ⚠️⚠️ **参数用闭包、不写 `LegadoEngineHost.Bridge` 类型**：
        ///   那个别名只在 Apple 平台存在 ⇒ Linux 沙盒编译时类型不存在 ⇒ 写死会编不过 ⭐⭐⭐
        static func sourceVarsJSON(from session: Session, read: (() -> [String: String]?)?) -> String {
            if let read,
               let got = read() {
                session.sourceVarsSnapshot = got
            }
            let map = session.sourceVarsSnapshot
            guard !map.isEmpty,
                  let d = try? JSONSerialization.data(withJSONObject: map),
                  let js = String(data: d, encoding: .utf8) else { return "" }
            return js
        }

        /// ⭐⭐⭐⭐⭐ **合并登录信息**（已存的做底 + 本次表单值覆盖）⭐⭐⭐
        ///
        /// ⚠️⚠️ **为什么必须合并而不是只用表单值**：
        ///   登录面板上**同时**有「上次填过的账号」和「这次填的密码」
        ///   ⇒ 只用表单值 ⇒ 站方 `getLoginInfoMap()` 读不到别的字段 ⇒ 登录失败 ⭐⭐⭐
        static func mergeLoginInfo(existing: [String: Any]?, formValues: [String: Any]) -> [String: Any] {
            var out: [String: Any] = existing ?? [:]
            for (k, v) in formValues {
                // ⚠️ 空值**不覆盖**已有的（用户可能只想改一项）
                if v is String, (v as! String).isEmpty, out[k] != nil { continue }
                out[k] = v
            }
            return out
        }

        /// 从引擎那一格（JSON map 串）里取出 `loginInfo` 项
        static func loginInfoDict(from variable: String) -> [String: Any]? {
            guard let d = variable.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let li = o["loginInfo"] as? [String: Any] else { return nil }
            return li
        }

        /// 把引擎那一格（JSON map 串）解析成字典
        static func variableDict(_ variable: String) -> [String: Any]? {
            guard let d = variable.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }

        /// ⭐⭐⭐ **给 JS 用的 engineSource**（已灌好站方变量那一格）⭐⭐⭐
        var engineSourceForJS: LegadoEngineHost.Source { engineSource }

        /// ⭐⭐⭐⭐⭐ **准备【带 loginInfo 的】engineSource**（login op 用）
        ///
        /// ⚠️⚠️⚠️ **为什么必须放在【非平台相关】的位置**（2026-11-19 CI build300 实证）：
        ///   这段逻辑原先在 `#if canImport(JavaScriptCore) && !os(Linux)` **里面**
        ///   ⇒ **Linux 编译门禁编不到** ⇒ 类型错（`String?` 没解包）**只有 CI 能抓** ⭐⭐⭐
        ///   ⇒ 沙盒全绿、CI 连红 ⇒ **白等 5 分钟** ⭐⭐⭐
        ///   ⇒ 正解：**纯 Swift 的数据处理逻辑放外面**（只把「跑 JS」留在 #if 里）⇒ Linux 编得到 ⭐⭐⭐
        ///
        /// - Parameters:
        ///   - formValues: 本次登录面板填的表单值
        /// - Returns: 一份 engineSource，其引擎那一格含 `loginInfo` 项（站方 `getLoginInfoMap()` 读它）
        func engineSourceWithLoginInfo(formValues: [String: Any]) -> LegadoEngineHost.Source {
            var src = engineSource
            // ⭐⭐⭐ **登录信息也在【书源变量那一格】**（引擎的 `loginInfoGet` ⇒ `getVariable(key:)`）
            //   ⇒ 键名固定是 `loginInfo` ⭐⭐⭐
            let merged = Self.mergeLoginInfo(existing: src.sourceVars["loginInfo"]
                                                .flatMap { Self.jsonObject($0) },
                                            formValues: formValues)
            guard !merged.isEmpty else { return src }
            var m = src.sourceVars
            m["loginInfo"] = Self.jsonString(merged)
            src.sourceVars = m
            return src
        }

        /// ⭐⭐⭐ **JSON 对象串 ⇒ 字典**
        static func jsonObject(_ raw: String) -> [String: Any]? {
            guard let d = raw.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }

        /// ⭐⭐⭐ **字典 ⇒ JSON 对象串**
        static func jsonString(_ o: [String: Any]) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: o),
                  let s = String(data: d, encoding: .utf8) else { return "" }
            return s
        }

        /// ⭐⭐⭐⭐⭐ **每个 op 前：用【最新的】站方变量重新灌**（build298 真机实证的关键）⭐⭐⭐
        ///
        /// ⚠️⚠️⚠️ **为什么必须每次重灌**（Session 是按源缓存的）：
        ///   ① 用户先进发现页 ⇒ Session 创建（此时 `nhAuthed` 还**没有** ⇒ 灌的是空的）
        ///   ② 用户去登录面板**解锁** ⇒ App 落盘了 `nhAuthed`
        ///   ③ 用户回发现页 ⇒ **复用同一个 Session** ⇒ 变量还是**旧的（空）** ⭐⭐⭐
        ///      ⇒ 站方 `nhAuth()` 恒 false ⇒ **交白卷** ⇒ 症状与「没修」一模一样 ⭐⭐⭐
        ///   ⇒ 正解：每次 op 都把 payload 里**最新的** `__variable` 灌进去 ⭐⭐⭐
        ///   ⇒ （同时保留 Session 里已写回的改动：站方 put 的值不能被空值覆盖 ⭐⭐⭐）
        func refreshStationVariable(from payload: [String: Any]) {
            let raw = (payload["source"] as? [String: Any]) ?? [:]
            let sv = (raw["__variable"] as? String) ?? ""
            // ⭐⭐⭐ **书籍变量也要刷新**（`nhAuthed` 就在这一格 ⇒ 用户解锁后要立刻生效）⭐⭐⭐
            if let seed = raw["__variables"] as? String, !seed.isEmpty,
               let d = seed.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { variables.put(k, "\(v)") }
            }
            guard !sv.isEmpty else { return }   // ⚠️ 空值**不覆盖**（别把已写回的解锁态抹掉）
            if sv == stationVariable { return }
            stationVariable = sv
            // ⭐⭐⭐ **重新合并两格**（不是只灌站方整串！`nhAuthed` 在书籍变量那格）⭐⭐⭐
            let merged = Self.mergeStationMap(bookVars: variables, stationRaw: sv)
            if !merged.isEmpty { engineSource.variable = merged }
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    // MARK: - 入口

    /// ⭐ **同步外壳 + 异步内核**（App 的调用点是同步的 ⇒ 这里用 Task + 信号量桥接）
    /// ⚠️ 调用方**必须**在后台线程（`SourceService` 已经保证）⭐⭐⭐
    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Any?, Error> = .success(nil)
        Task.detached(priority: .userInitiated) {
            do {
                let v = try await Self.run(op, payload, source: source, sessions: self)
                result = .success(v)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        // ⚠️ **必须有上限**：引擎内部死循环（站方脚本）⇒ 不加就会永久卡住 ⭐⭐⭐
        let budget = Self.timeoutSeconds(for: op)
        if sem.wait(timeout: .now() + budget) == .timedOut {
            throw ServiceError.engineFailed("「\(op)」超时（\(Int(budget))s）—— 引擎里可能有死循环")
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    /// 换掉卡死的会话（这个源的变量/登录态重置 ⇒ 下一个 op 重新开始）
    func dropSession(for key: String) {
        lock.lock(); sessions.removeValue(forKey: key); lock.unlock()
    }

    /// ⭐⭐⭐ **清空所有会话**（诊断面板「重置会话」）
    func dropAllSessions() {
        lock.lock(); sessions.removeAll(); lock.unlock()
    }

    /// op 的超时预算（内容类给得宽，因为站方会逐条试多条线路）
    static func timeoutSeconds(for op: String) -> TimeInterval {
        switch op {
        case "bookInfo", "toc", "content": return 300
        case "login", "loginProbe": return 120
        default: return 60
        }
    }

    // MARK: - 真正的实现（异步）

    private static func run(_ op: String, _ payload: [String: Any],
                            source: BookSource,
                            sessions: LegadoEngineBackend) async throws -> Any? {
        let parsedSource = try parseSource(payload, fallback: source)
        let session = LegadoEngineBackend.session(for: parsedSource.bookSourceUrl,
                                                 engineSource: parsedSource,
                                                 payload: payload, sessions: sessions)
        // ⭐⭐⭐⭐⭐ **站方变量通道（2026-11-19 真机 build297 实证）**
        //
        //   ⚠️⚠️⚠️ **为什么需要它**（真机症状：发现页「只解析出 0 个分类」）：
        //     引擎的站方 JS 读变量走 `source.get(k)` / `source.getVariable()`
        //     ⇒ 落到引擎 `BookSource.variable` **那一格**（`srcGet`/`srcPut` 都指它）⭐⭐⭐
        //     而 App 灌站方变量的地方是 `srcDict["__variable"]` ⇒ **另一格** ⇒ 两格不通 ⭐⭐⭐
        //     ⇒ 站方 JS 读 `source.get("nhAuthed")` **恒空** ⇒ `nhAuth()` 恒 false
        //       ⇒ 站方 `exploreUrl` **主动交白卷**（`if (!nhAuth()) { return ""; }`）⇒ **0 个分类** ⭐⭐⭐
        //
        //   ⭐ **修法（零引擎改动）**：
        //     ① **读**：把 App 的站方变量灌进 `engineSource.variable` ⇒ 站方 JS 读得到 ⭐⭐⭐
        //     ② **写**：站方 JS 写的是 **JSBridge 内的副本**（`JSBridge.source` 模块内可见 ⇒ 宿主读不到）
        //        ⇒ 正解：**用 `bridge.eval("source.getVariable()")` 把副本里的值读出来**（纯 JS ⇒ 不碰引擎）⭐⭐⭐
        //
        //   ⚠️ **为什么不能用 `session.variables`（RuleVariables map）**：那是【书籍变量】那格
        //     （`book.getVariable` 走 `varGet`）⇒ 与站方变量**不是同一格** ⇒ 不能混 ⭐⭐⭐
        // ⭐⭐⭐⭐⭐ **每个 op 都用【最新的】站方变量重新灌**（Session 缓存 ⇒ 不重灌就吃旧值）⭐⭐⭐
        session.refreshStationVariable(from: payload)
        let engineSource = session.engineSourceForJS
        var out: [String: Any]
        #if canImport(JavaScriptCore) && !os(Linux)
        // ⭐⭐⭐⭐⭐ **筛选栏 action**（2026-11-19 新引擎接线）
        //   ⇒ 站方 action 里的 `source.put('order', 2)` / `source.put('type', …)` **必须写进去**
        //   ⇒ 写不进去 ⇒ explore 的 `order_type` 取旧值 ⇒ **服务端 HTTP 500** ⇒ 发现页全空 ⭐⭐⭐
        //   ⇒ 用引擎的 `JSBridge` 跑（它会自动加载站方 jsLib ⇒ 站方函数都在）⭐⭐⭐
        if op == "filterAction" {
            let action = (payload["action"] as? String) ?? ""
            guard !action.isEmpty else {
                out = ["ok": false, "error": "没有筛选动作", "msgs": []]
                // ⚠️⚠️ **这里原来写的是 `break`**（老代码是 switch 分支 ⇒ break 跳 switch）
                //   ⇒ 现在改成 **if 链** ⇒ break 不在 loop/switch 里 ⇒ 编不过
                //      「unlabeled 'break' is only allowed inside a loop or switch」⭐⭐⭐
                //   ⇒ 正解：直接 return（下面 switch op 的分支都走 return out）⭐⭐⭐
                return out
            }
            let host = LegadoJSHost()
            let bridge = LegadoEngineHost.Bridge(source: engineSource, book: book(from: payload),
                                                 chapter: nil, variables: session.variables, host: host)
            do {
                _ = try bridge.eval(action, bindings: ["result": [:]])
                out = ["ok": true, "msgs": host.messages]
            } catch {
                out = ["ok": false, "error": String(describing: error), "msgs": host.messages]
            }
            // ⭐⭐⭐ **站方变量读回**（站方 JS 里的 `source.put(...)` 写进副本了 ⇒ 取出来）⭐⭐⭐
            // ⭐⭐⭐ **剥掉 loginInfo 项**（明文密码不许混进站方变量槽）⭐⭐⭐
            let stationVar = Session.stripLoginInfo(from: session.collectStationVariable {
                (try? bridge.eval("source.getVariable()")) as? String
            })
            out["__sourceVars"] = Session.sourceVarsJSON(from: session, read: {
                (try? bridge.eval("source.getAllVars()")) as? [String: String]
            })
            out["__sourceVariable"] = stationVar
            out["__sourceVariableChanged"] = (stationVar != session.stationSeeded)
            return out
        }
        // ⭐⭐⭐ **登录链路**：新引擎不含登录 UI ⇒ 宿主自己跑站方的 `loginUrl` 动作 / `loginCheckJs`
        //   ⇒ 用引擎的 `JSBridge`（它会自动加载站方 jsLib ⇒ 站方函数都在）⭐⭐⭐
        if op == "login" || op == "loginProbe" {
            let host = LegadoJSHost()
            // ⚠️⚠️ **必须是 var**：login 分支要把它换成【带 loginInfo 的那一份】⇒
            //   执行与【回传】必须用**同一个** bridge ⇒ 否则回传读的是另一份副本
            //   ⇒ 站方 `source.put(...)`（含解锁态 nhAuthed）**读不回来** ⭐⭐⭐
            var bridge = LegadoEngineHost.Bridge(source: engineSource, book: book(from: payload),
                                                 chapter: nil, variables: session.variables, host: host)
            if op == "login" {
                let action = (payload["action"] as? String) ?? ""
                guard !action.isEmpty else {
                    out = ["ok": false, "error": "没有登录动作", "msgs": []]
                    return out   // ⭐ 同上：if 链里不能 break ⇒ 直接 return ⭐⭐⭐
                }
                // 表单值先并进 `result`（站方 login(true) 第一步就是 putLoginInfo(result)）
                let formValues = (payload["formValues"] as? [String: Any]) ?? [:]
                // ⭐⭐⭐⭐⭐ **表单值要并进【引擎那一格的 loginInfo 项】** ⭐⭐⭐
                //
                //   ⚠️⚠️⚠️ **为什么必须并**（2026-11-19 真机 build299 实证）：
                //     站方读密码的方式是 `nhAuthUiMap()` ⇒ `source.getLoginInfoMap()`
                //     ⇒ 引擎的 `loginInfoGet` ⇒ **`BookSource.variable["loginInfo"]`** ⭐⭐⭐
                //     ⇒ 只把表单值放进 `result` ⇒ **站方读到空 map**
                //     ⇒ 点「🔓 解锁整个源」必然提示「请在下面输入框里填密码」⇒ **永远解锁不了** ⭐⭐⭐
                //   ⇒ 而「整源解锁密码」正是**这次表单填的** ⇒ 必须并进去 ⭐⭐⭐
                //   ⇒ 合并规则：**已存的登录信息做底 + 本次表单值覆盖**（与 Legado 语义一致）⭐⭐⭐
                //
                // ⭐⭐⭐ **合并逻辑放在【非平台相关】的 Session 方法里** ⇒ Linux 沙盒门禁能编到
                //   ⇒ 类型错 3 秒暴露（否则只有 CI 能抓 ⇒ 白等 5 分钟）⭐⭐⭐
                let srcWithLogin = session.engineSourceWithLoginInfo(formValues: formValues)
                // ⭐⭐⭐ **换成带 loginInfo 的那一份**（站方 getLoginInfoMap() 读的就是它）⭐⭐⭐
                bridge = LegadoEngineHost.Bridge(source: srcWithLogin, book: book(from: payload),
                                                 chapter: nil, variables: session.variables, host: host)
                do {
                    _ = try bridge.eval(action, bindings: ["result": formValues])
                    out = ["ok": true, "msgs": host.messages]
                } catch {
                    out = ["ok": false, "error": String(describing: error), "msgs": host.messages]
                }
            } else {
                // 登录态探测：跑站方的 `loginCheckJs`
                let js = engineSource.loginCheckJs ?? ""
                if js.isEmpty {
                    out = ["ok": false, "error": "书源没有 loginCheckJs", "msgs": []]
                } else {
                    do {
                        _ = try bridge.eval(js, bindings: [:])
                        out = ["ok": true, "msgs": host.messages]
                    } catch {
                        out = ["ok": false, "error": String(describing: error), "msgs": host.messages]
                    }
                }
            }
            // ⭐⭐⭐ **站方 JS 改过的变量 ⇒ 回传**（宿主落盘 ⇒ 下次直接生效）
            // ⭐⭐⭐ **站方变量读回**（站方 JS 里的 `source.put(...)` 写进副本了 ⇒ 取出来）⭐⭐⭐
            // ⭐⭐⭐ **剥掉 loginInfo 项**（明文密码不许混进站方变量槽）⭐⭐⭐
            let stationVar = Session.stripLoginInfo(from: session.collectStationVariable {
                (try? bridge.eval("source.getVariable()")) as? String
            })
            out["__sourceVars"] = Session.sourceVarsJSON(from: session, read: {
                (try? bridge.eval("source.getAllVars()")) as? [String: String]
            })
            out["__sourceVariable"] = stationVar
            out["__sourceVariableChanged"] = (stationVar != session.stationSeeded)
            return out
        }
        #endif
        switch op {
        case "search":
            let key = (payload["keyword"] as? String) ?? ""
            let page = (payload["page"] as? Int) ?? 1
            let books = try await LegadoEngine.search(source: engineSource, key: key,
                                                      page: page, variables: session.variables)
            out = ["books": books.map { bookListItem($0) }]
            out["total"] = books.count
            out["nextUrl"] = ""
        case "exploreKinds":
            // ⭐⭐⭐⭐⭐ **动态 exploreUrl 必须【求值】才能拿到分类**（2026-11-19 真机 build296 实证）
            //
            //   ⚠️⚠️ **根因**：`LegadoEngine.exploreKinds` 是**静态**解析 `source.exploreUrl`
            //     （只认 JSON 数组 / `标题::url` 两行式）⇒ **从不求值 `@js:`** ⭐⭐⭐
            //     而 NovelHub（🍒NovelHub）的 `exploreUrl` 是 **`@js:` 薄壳**（正文在 jsLib 里）
            //     ⇒ 静态解析把 `@js:` 那行当成 `标题::url` 的「标题」⇒ **url 为空**
            //     ⇒ `AnalyzeUrl` 对空 url 求值 ⇒ `url 解析失败: ` ⇒ **LegadoError 错误 1** ⭐⭐⭐
            //     ⇒ **与真机日志逐字吻合**（「url 解析失败:」冒号后为空）⭐⭐⭐
            //
            //   ⭐ **权威规格 = 已删的旧引擎**（git `0b5c481^:QiReaderLite/Resources/engine/engine.js`
            //     的 `exploreKinds`）：**先求值 `@js:`** ⇒ 再 `normalizeKinds`（分类 + 筛选栏 + 分组）
            //     ⇒ 本函数照抄那条语义 ⭐⭐⭐（引擎换装时丢的就是这条能力 ⇒ 属**能力回退**）
            //
            //   ⭐ **为什么在宿主层补、而不是改引擎包**：
            //     · `LegadoEngine/` 是用户在另一窗口自研的引擎 ⇒ **不越界改它的语义**
            //     · 宿主层已有先例：`filterAction` / `login` 都是「宿主自己跑站方 JS」
            //     · 引擎的 `JSBridge` 会自动加载站方 jsLib ⇒ 站方 helper 全都在 ⭐⭐⭐
            let spec = engineSource.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if spec.isEmpty {
                out = ["kinds": [], "filters": []]
            } else if ExploreKindsNormalizer.isJSRule(spec) {
                #if canImport(JavaScriptCore) && !os(Linux)
                // ⭐⭐⭐ **站方 JS 求值**（`@js:` / `<js>`）⇒ 拿站方给的分类 + 筛选栏
                let host = LegadoJSHost()
                let bridge = LegadoEngineHost.Bridge(source: engineSource, book: nil,
                                                     chapter: nil, variables: session.variables, host: host)
                // ⭐⭐⭐⭐⭐ **决定性诊断**（2026-11-19 真机 build299/300 实证）：
                //   连续三轮「0 个分类」⇒ 我靠推理连错三次 ⇒ **必须让真机把事实摆出来** ⭐⭐⭐
                //   ⇒ 打印【真正喂给站方的那一格】的关键项 + 两槽状态 ⇒ 一次定位断点 ⭐⭐⭐
                //   ⇒ ⚠️ 站方变量是**凭据/敏感信息** ⇒ 只打【键名 + 长度】，不打值 ⭐⭐⭐
                Session.logExploreGateState(engineSource: engineSource, session: session)
                do {
                    let raw = try bridge.eval(ExploreKindsNormalizer.stripJSWrapper(spec),
                                              bindings: ["result": NSNull(), "baseUrl": engineSource.bookSourceUrl,
                                                         "page": 1, "key": ""])
                    let norm = ExploreKindsNormalizer.normalizeKinds(raw, baseUrl: engineSource.bookSourceUrl)
                    out = ["kinds": norm.kinds, "filters": norm.filters]
                } catch {
                    // ⚠️⚠️ **不许假成功**（静默返回空 ⇒ 用户看到「没解析出分类」却不知道哪错了）⭐⭐⭐
                    out = ["kinds": [], "filters": [],
                           "error": "exploreUrl 求值失败: \(String(describing: error))"]
                }
                #else
                // ⚠️ Linux CI 沙盒没有 JSC ⇒ 无法求值 ⇒ **如实报错**（不假成功）
                out = ["kinds": [], "filters": [],
                       "error": "当前平台没有 JavaScriptCore，无法求值 @js: 形式的 exploreUrl"]
                #endif
            } else {
                // ⭐ **静态写法**（JSON 数组 / `标题::url` 两行式）⇒ 引擎那条路是对的，保留
                let kinds = LegadoEngine.exploreKinds(source: engineSource)
                out = ["kinds": kinds.map { ["title": $0.title, "url": $0.url] }, "filters": []]
            }
        case "explore":
            let kind = LegadoEngineHost.Kind(title: (payload["kindTitle"] as? String) ?? "",
                                            url: (payload["kindUrl"] as? String) ?? "")
            let page = (payload["page"] as? Int) ?? 1
            let books = try await LegadoEngine.explore(source: engineSource, kind: kind,
                                                      page: page, variables: session.variables)
            out = ["books": books.map { bookListItem($0) }]
            out["total"] = books.count
            out["nextUrl"] = ""
        case "bookInfo":
            let info = try await LegadoEngine.bookInfo(source: engineSource, book: book(from: payload),
                                                       variables: session.variables)
            out = ["book": bookPayload(info)]
        case "toc":
            let b = book(from: payload)
            let chapters = try await LegadoEngine.chapters(source: engineSource, book: b,
                                                          variables: session.variables)
            let list: [[String: Any]] = chapters.map { c in
                ["url": c.url, "title": c.title, "index": c.index,
                 "isVolume": c.isVolume, "isVip": c.isVip, "isPay": c.isPay,
                 "updateTime": c.updateTime ?? "", "tag": ""]
            }
            out = ["chapters": list, "rawCount": chapters.count, "bookName": b.name]
        case "explain", "explainToc":
            // ⭐⭐⭐ **诊断 op**（老引擎的 `explain` / `explainToc` 随老引擎一起退役）
            //   ⇒ 用**新引擎的 AnalyzeUrl** 复刻：发一次请求，把 URL/状态/字节报出来 ⭐⭐⭐
            let ruleUrl = (payload["tocUrl"] as? String) ?? (payload["kindUrl"] as? String)
                ?? (payload["bookUrl"] as? String) ?? ""
            do {
                let au = try LegadoEngineHost.UrlBuilder(ruleUrl: ruleUrl,
                                                        key: payload["keyword"] as? String,
                                                        page: (payload["page"] as? Int) ?? 1,
                                                        source: engineSource,
                                                        book: book(from: payload),
                                                        variables: session.variables)
                let resp = try await au.fetch()
                out = ["请求URL": ruleUrl, "最终URL": resp.url.absoluteString,
                       "状态码": String(resp.statusCode), "响应字节": String(resp.body.utf8.count),
                       "页面标题": "", "说明": "诊断已随老引擎退役 ⇒ 这里用新引擎的 AnalyzeUrl 复刻"]
            } catch {
                out = ["请求URL": ruleUrl, "错误": String(describing: error)]
            }
        case "content":
            let ch = chapter(from: payload)
            let text = try await LegadoEngine.content(source: engineSource, book: book(from: payload),
                                                       chapter: ch, variables: session.variables)
            out = ["title": ch.title, "content": text, "nextUrl": ""]
        default:
            // ⚠️ **不认识就明确报错**（不静默返回空 ⇒ 不假成功）⭐⭐⭐
            throw ServiceError.engineFailed("新引擎不支持「\(op)」这个操作")
        }
        // ⭐⭐⭐ **站方 JS 改过的变量 ⇒ 回传**（宿主落盘 ⇒ 下次直接生效）
        //
        // ⭐⭐⭐⭐⭐ **站方变量必须回传【站方那一格】**（2026-11-19 真机 build297 实证）：
        //   ⚠️ 以前这里回传的是 `session.variables`（**书籍变量**那一格）⇒ **回传错格** ⭐⭐⭐
        //     ⇒ 宿主落盘时把【书籍变量的 map】写进了【站方变量槽】⇒ 两格互相污染 ⭐⭐⭐
        //     ⇒ 且站方 JS 读 `source.get("nhAuthed")` 读不到 ⇒ **发现页 0 分类** ⭐⭐⭐
        //   ⇒ 现在：`__sourceVars` = 书籍变量（RuleVariables map）
        //           `__sourceVariable` = **站方变量那一格**（`session.stationVariable`）⭐⭐⭐
        out["__sourceVars"] = Session.sourceVarsJSON(from: session, read: nil)
        out["__sourceVariable"] = session.stationVariable
        // ⭐⭐⭐ **「改没改」只认与种子比较**（证据不许自证）⭐⭐⭐
        out["__sourceVariableChanged"] = (session.stationVariable != session.stationSeeded)
        return out
    }

    /// 取（or 建）这个源的会话
    fileprivate static func session(for key: String, engineSource: LegadoEngineHost.Source,
                                     payload: [String: Any], sessions: LegadoEngineBackend) -> Session {
        sessions.lock.lock()
        if let s = sessions.sessions[key] { sessions.lock.unlock(); return s }
        sessions.lock.unlock()
        let s = Session(engineSource: engineSource, payload: payload)
        sessions.lock.lock(); sessions.sessions[key] = s; sessions.lock.unlock()
        return s
    }

    // MARK: - 形状对齐（App 侧的契约）

    // MARK: - ⭐⭐⭐⭐⭐ 站方 exploreUrl 的 JS 求值 + 归一化（2026-11-19 build296 真机实证）

    /// 归一化结果：**分类**（点得动的）+ **筛选栏**（点不动的 select 项）+ 分组

    private static func bookListItem(_ b: LegadoEngineHost.SearchResult) -> [String: Any] {
        [
            "name": b.name,
            "author": b.author,
            "intro": b.intro ?? "",
            "kind": b.kind ?? "",
            "lastChapter": b.lastChapter ?? "",
            "coverUrl": b.coverUrl ?? "",
            "bookUrl": b.bookUrl,
            "wordCount": b.wordCount ?? "",
            "tocUrl": "",
            "group": b.originName,
            "updateTime": b.updateTime ?? "",
            "origin": b.origin,
        ]
    }

    private static func bookPayload(_ b: LegadoEngineHost.BookModel) -> [String: Any] {
        [
            "name": b.name,
            "author": b.author,
            "intro": b.intro ?? "",
            "kind": b.kind ?? "",
            "group": "",
            "lastChapter": b.latestChapterTitle ?? "",
            "coverUrl": b.coverUrl ?? "",
            "bookUrl": b.bookUrl,
            "tocUrl": b.tocUrl,
            "wordCount": b.wordCount ?? "",
            "updateTime": String(b.latestChapterTime),
        ]
    }

    /// 从 payload 里还原引擎的 `Book`
    private static func book(from payload: [String: Any]) -> LegadoEngineHost.BookModel {
        let raw = (payload["book"] as? [String: Any]) ?? [:]
        var b = LegadoEngineHost.BookModel(bookUrl: (raw["bookUrl"] as? String) ?? (payload["bookUrl"] as? String) ?? "",
                     origin: (raw["origin"] as? String) ?? "")
        b.originName = (raw["group"] as? String) ?? ""
        b.name = (raw["name"] as? String) ?? ""
        b.author = (raw["author"] as? String) ?? ""
        b.kind = raw["kind"] as? String
        b.intro = raw["intro"] as? String
        b.coverUrl = raw["coverUrl"] as? String
        b.wordCount = raw["wordCount"] as? String
        b.latestChapterTitle = raw["lastChapter"] as? String
        b.tocUrl = (payload["tocUrl"] as? String) ?? (raw["tocUrl"] as? String) ?? ""
        b.variable = raw["variable"] as? String
        return b
    }

    /// 从 payload 里还原引擎的 `BookChapter`
    private static func chapter(from payload: [String: Any]) -> LegadoEngineHost.ChapterModel {
        let raw = (payload["chapter"] as? [String: Any]) ?? [:]
        let c = LegadoEngineHost.ChapterModel()
        c.url = (payload["chapterUrl"] as? String) ?? (raw["url"] as? String) ?? ""
        c.title = (raw["title"] as? String) ?? ""
        c.index = (raw["index"] as? Int) ?? 0
        c.isVolume = (raw["isVolume"] as? Bool) ?? false
        c.isVip = (raw["isVip"] as? Bool) ?? false
        c.isPay = (raw["isPay"] as? Bool) ?? false
        c.updateTime = raw["updateTime"] as? String
        c.variable = raw["variable"] as? String
        return c
    }

    // MARK: - 书源解析

    /// ⭐⭐⭐ **书源 JSON 优先用 payload 里那份**（带 `__variables` ⇒ 宿主注入的解锁态/登录态）
    ///   ⇒ 不用 App 自己的模型回编 JSON（少一层漂移）⭐⭐⭐
    private static func parseSource(_ payload: [String: Any],
                                    fallback: BookSource) throws -> LegadoEngineHost.Source {
        if let dict = payload["source"] as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let parsed = try? LegadoEngineHost.Source.parse(data), !parsed.isEmpty {
            return parsed[0]
        }
        // 兜底：用 App 的模型回编
        if let data = try? JSONEncoder().encode(fallback),
           let parsed = try? LegadoEngineHost.Source.parse(data), !parsed.isEmpty {
            return parsed[0]
        }
        throw ServiceError.engineFailed("书源 JSON 解析失败")
    }
}

/// ⭐⭐⭐ **站方 JS 的宿主**（新引擎 `JSHost` 协议）
///
/// ⚠️ 站方**只用 toast / log 报登录结果**（「✅️登录成功」/「💔登录失败」）
///   ⇒ toast 一闪而过 ⇒ 用户根本不知道成没成 ⇒ 这里**把原文收回来**给 UI 显示 ⭐⭐⭐
#if canImport(JavaScriptCore) && !os(Linux)
// ⭐⭐⭐ **把引擎日志挂到「引擎日志」面板**（App 启动时挂一次 ⇒ 别处直接用 `engineLog`）
///
/// ⚠️ **为什么要挂**（2026-10-28）：诊断写在 `NSLog` 里 ⇒ **只进设备控制台，用户看不到**
///   ⇒ 真机排查只能靠「让用户去 Xcode 看控制台」⇒ 一轮一条信息 ⇒ 极慢 ⭐⭐⭐
///   ⇒ 挂上面板 ⇒ 用户「复制日志」就有 ⭐⭐⭐
///
/// ⚠️⚠️⚠️ **2026-11-19：引擎换血那轮把这个类型连同老引擎壳（RuleSandbox）一起删了，
///   可 `QiReaderLiteApp.init()` 里的 `EngineLogBootstrap.install()` 调用点还留着**
///   ⇒ App 直接编不过（「cannot find 'EngineLogBootstrap' in scope」）⭐⭐⭐
///   ⇒ 现在**恢复**它（位置也放回原处 ⇒ 沙盒 Linux 门禁编得到 ⇒ 以后删了能被抓到）⭐⭐⭐
///
/// ⭐⭐⭐⭐⭐ **必须 `Task { @MainActor in … }`**：
///   · 引擎回调在**后台线程** ⇒ 面板 `EngineLogPanel` 是 `@MainActor`
///   ⇒ 直接调 `appendLog` ⇒ **后台线程改 @Published 状态** ⇒ UI 更新在后台线程 ⇒ 闪退风险 ⭐⭐⭐
///   ⇒ 切主线程再写 ⭐⭐⭐
enum EngineLogBootstrap {
    static func install() {
        EngineLog.sink = { message in
            Task { @MainActor in EngineLogPanel.shared.appendLog(message) }
        }
    }
}

final class LegadoJSHost: LegadoEngineHost.Host {
    private(set) var messages: [String] = []

    func jsLog(_ msg: String) {
        messages.append(msg)
    }

    func jsToast(_ msg: String) {
        messages.append(msg)
    }
}
#endif
