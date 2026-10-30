import Foundation

// MARK: - ⭐⭐⭐ 引擎调用的错误类型
// ⚠️ `ServiceError` 在**独立文件** `Core/ServiceError.swift` ⇒ 任何层都能引用 ⭐⭐⭐
//   （原来它是 `SourceService` 的嵌套类型 ⇒ 带主 actor 隔离 ⇒ 后台层引用不了 ⇒ CI 挂）

/// Swift 侧调用 JS 引擎的唯一入口。
/// 引擎返回的是普通 JSON 对象，这里统一转成 Codable。
@MainActor
final class SourceService {
    static let shared = SourceService()
    private init() {}

    // MARK: 登录

    /// 跑书源的登录动作（loginUrl 里的 `login(true)` / `register()` / `checkStatus()` …）
    ///
    /// - Parameters:
    ///   - action: loginUi 里按钮的 action（如 `login(true)`）
    ///   - formValues: 表单值（字段名 → 值）。引擎把它挂在 `result` 上，
    ///     站方 login() 里读的就是 `result['邮箱']` / `result['密码']`。
    /// - Returns: 是否成功 + 失败原因 + **站方自己吐出来的原文**
    ///
    /// ⚠️ `messages` 才是**真话**：`ok == true` 只说明「JS 跑完了没抛异常」，
    ///    站方报的是「✅️登录成功」还是「💔登录失败」全在 messages 里。
    ///    以前这些只弹 toast 就没了 → 用户永远不知道登录成没成。
    func login(source: BookSource, action: String,
               formValues: [String: String]) async throws -> (ok: Bool, message: String, messages: [String]) {
        var p: [String: Any] = ["action": action, "formValues": formValues]
        // ⭐⭐⭐ 走缓存（同上）
        var srcDict = await SourceDictCache.dict(for: source)
        srcDict["__variables"] = await effectiveVars(for: source)
        // ⭐⭐⭐ 站方变量（Legado 语义：一整串）⇒ 与「书籍变量」分开 ⭐
        //   ⭐⭐⭐ 走 `stationVariableToSeed` ⇒ **顺带做污染迁移**（凭据形态却躺着一个 map ⇒ 清掉）⭐
        srcDict["__variable"] = SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        // 栖阅机制：loginHeader（自动注入到每次请求头）→ JS 侧 source.getLoginHeader()
        srcDict["__loginHeader"] = SourceVariables.loginHeader(for: source.bookSourceUrl)
        p["source"] = srcDict
        p["cookieSnapshot"] = CookieJar.snapshot()
        // ⚠️⚠️⚠️ **登录【必须走老引擎】**（2026-10-29 真机回归实证 ⇒ 改回来了）
        //   ⇒ 原因：引擎的 `runLoginAction` 构造求值上下文时**没传 `source:`**
        //     ⇒ `ctx.source == nil` ⇒ **全局 `source` 对象没有宿主方法**
        //     ⇒ 站方 loginUrl 里的 `source.setVariable(token)` / `source.put('type',…)`
        //        **全部失效** ⇒ token / 排序选项写不进去 ⭐⭐⭐
        //     ⇒ 症状：发现页「筛选栏 0 个」+ explore 的 `order_type` 取旧值 ⇒ **HTTP 500** ⭐⭐⭐
        //   ⇒ 老引擎的 login op **会把 `g.source` 挂上**（engine.js:1249）⇒ 站方写变量才有效 ⭐
        //   ⇒ ⚠️ **代价**：登录用的站方变量语义仍是老引擎那套（整份书源变量）
        //     ⇒ 但登录本来就是「写」的 ⇒ 语义一致 ⇒ **不影响** ⭐⭐⭐
        let raw = try await RuleSandbox.shared.invoke("login", p, source: source)
        // 登录动作会改书籍变量 / 登录信息 → 落盘
        if let obj = raw as? [String: Any] {
            if let v = obj["__sourceVars"] as? String {
                SourceVariables.setVars(v, for: source.bookSourceUrl)
            }
            // ⭐⭐⭐ 站方变量（Legado 语义）⇒ 落盘（与书籍变量**分开**存）⭐
            //   ⭐⭐⭐ **只有站方真改过这一格**才当成「站方写的」⇒ 不然证据会**自证** ⭐⭐⭐
            if let v = obj["__sourceVariable"] as? String {
                SourceVariables.setVariable(v, for: source.bookSourceUrl,
                                           origin: Self.stationWroteIt(obj) ? .station : .app)
                // ⭐⭐⭐⭐⭐ **凭据双写**（2026-10-29 真机 401「目录 0 章」根因）
                //   ⇒ 新版站方源把 token 放**书源变量**的 `token` 项（`put`/`get`）
                //   ⇒ 只写站方变量 ⇒ `source.get('token')` = 空 ⇒ `Bearer ` 空 ⇒ 401 ⭐⭐⭐
                SourceVariables.mirrorCredentialToVars(v, for: source.bookSourceUrl, jsLib: source.jsLib)
            }
            if let l = obj["__loginInfo"] as? String {
                SourceVariables.setLoginInfoJSON(l, for: source.bookSourceUrl)
            }
            // 栖阅机制：loginHeader（自动注入到每次请求头）
            if let h = obj["__loginHeader"] as? String {
                SourceVariables.setLoginHeader(h, for: source.bookSourceUrl)
            }
        }
        let dict = raw as? [String: Any] ?? [:]
        let ok = dict["ok"] as? Bool ?? false
        let err = dict["error"] as? String ?? ""
        // 站方原文（toast / log）。这是判断「登录成没成」的唯一依据。
        let msgs = (dict["messages"] as? [String]) ?? []
        return (ok, err, msgs)
    }

    /// 登录状态检测（引擎侧）
    ///
    /// 跑站方自己的 `checkStatus()`，并把服务器地址解析出来。
    /// 返回的 `messages` 是站方的原文（会员卡片 / 失败原因）。
    func probeLogin(source: BookSource) async throws
        -> (baseUrl: String, messages: [String], stationCheck: Bool) {
        // ⭐⭐⭐ 走缓存（同上：别每个 op 都编码+解析 158KB）
        var srcDict = await SourceDictCache.dict(for: source)
        srcDict["__variables"] = await effectiveVars(for: source)
        // ⭐⭐⭐ 站方变量（Legado 语义：一整串）⇒ 与「书籍变量」分开 ⭐
        //   ⭐⭐⭐ 走 `stationVariableToSeed` ⇒ **顺带做污染迁移**（凭据形态却躺着一个 map ⇒ 清掉）⭐
        srcDict["__variable"] = SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        // 栖阅机制：loginHeader（自动注入到每次请求头）→ JS 侧 source.getLoginHeader()
        srcDict["__loginHeader"] = SourceVariables.loginHeader(for: source.bookSourceUrl)
        var p: [String: Any] = ["source": srcDict]
        p["cookieSnapshot"] = CookieJar.snapshot()
        // ⭐⭐⭐⭐⭐ **登录态检测也走新引擎**（同上 ⇒ 两套语义的问题）
        let raw = try await Self.invokeEngine("loginProbe", p, source: source)
        let dict = raw as? [String: Any] ?? [:]
        if let e = dict["error"] as? String, !e.isEmpty {
            throw ServiceError.engineFailed(e)
        }
        return (
            baseUrl: (dict["baseUrl"] as? String) ?? "",
            messages: (dict["messages"] as? [String]) ?? [],
            stationCheck: (dict["stationCheck"] as? Bool) ?? false
        )
    }

    // MARK: 桥接

    private func json(_ payload: [String: Any]) -> [String: Any] { payload }

    private func call<T: Decodable>(_ op: String, _ payload: [String: Any],
                                    as type: T.Type, source: BookSource) async throws -> T {
        var p = payload
        // 必须是**嵌套对象**。塞 JSON 字符串的话，引擎里 src.ruleSearch 全是 undefined，
        // 表现是「所有字段都空」这种很难查的问题。
        // ⭐⭐⭐ **源字典走缓存**（2026-10-24 真机「app 死机」的真凶）
        //   大灰狼的源 158KB ⇒ 以前**每个 op** 都编码 + Foundation 解析一遍
        //   ⇒ 每次 op 几 MB 的分配 ⇒ **主线程在 malloc 锁上被拖死**
        //   ⇒ 现在：**同一个源只算一次** ⇒ 之后每个 op 直接拿缓存
        var srcDict = await SourceDictCache.dict(for: source)
        // 书籍变量 / 登录信息：Legado 的 source.getVariable() 是**同步** API，
        // 我们的原生桥是异步的（只能 postMessage）→ 只能原生侧读出来塞进去，
        // 引擎侧同步读。改完由引擎回传（见下面 __sourceVars）。
        srcDict["__variables"] = await effectiveVars(for: source)
        // ⭐⭐⭐ 站方变量（Legado 语义：一整串）⇒ 与「书籍变量」分开 ⭐
        //   ⭐⭐⭐ 走 `stationVariableToSeed` ⇒ **顺带做污染迁移**（凭据形态却躺着一个 map ⇒ 清掉）⭐
        srcDict["__variable"] = SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        // 栖阅机制：loginHeader（自动注入到每次请求头）→ JS 侧 source.getLoginHeader()
        srcDict["__loginHeader"] = SourceVariables.loginHeader(for: source.bookSourceUrl)
        p["source"] = srcDict
        // cookie 快照：同理，Legado 的 cookie.getCookie(url) 也是同步的。
        p["cookieSnapshot"] = CookieJar.snapshot()
        // ⭐⭐⭐ **新引擎（自研 Swift 引擎）优先** —— 老引擎已被完全替换
        let raw = try await Self.invokeEngine(op, p, source: source)
        // 站方 JS 改过的书籍变量 / 登录信息 → 落盘（下次调用直接生效）
        if let obj = raw as? [String: Any] {
            if let v = obj["__sourceVars"] as? String {
                SourceVariables.setVars(v, for: source.bookSourceUrl)
            }
            // ⭐⭐⭐ 站方变量（Legado 语义）⇒ 落盘（与书籍变量**分开**存）⭐
            //   ⭐⭐⭐ **只有站方真改过这一格**才当成「站方写的」⇒ 不然证据会**自证** ⭐⭐⭐
            if let v = obj["__sourceVariable"] as? String {
                SourceVariables.setVariable(v, for: source.bookSourceUrl,
                                           origin: Self.stationWroteIt(obj) ? .station : .app)
                // ⭐⭐⭐⭐⭐ **凭据双写**（2026-10-29 真机 401「目录 0 章」根因）
                //   ⇒ 新版站方源把 token 放**书源变量**的 `token` 项（`put`/`get`）
                //   ⇒ 只写站方变量 ⇒ `source.get('token')` = 空 ⇒ `Bearer ` 空 ⇒ 401 ⭐⭐⭐
                SourceVariables.mirrorCredentialToVars(v, for: source.bookSourceUrl, jsLib: source.jsLib)
            }
            if let l = obj["__loginInfo"] as? String {
                SourceVariables.setLoginInfoJSON(l, for: source.bookSourceUrl)
            }
        }
        // ⭐⭐⭐ **后台解码**（大灰狼的分类响应 100KB+ ⇒ 主线程解会卡）
        return try await Self.decodeAsync(T.self, from: raw)
    }

    /// ⭐⭐⭐ **站方这一格到底改没改？**（引擎回传 `__sourceVariableChanged`）
    ///
    /// ⚠️⚠️ **为什么必须有它**（2026-10-27 真机复盘）：
    ///   站方变量的**形态证据**必须是「**站方自己改过**」——
    ///   ⇒ 回传时值**一模一样** ⇒ 那是**宿主灌进去的污染被原样弹回来** ⇒ 不是证据 ⭐⭐⭐
    ///   ⇒ 拿它当证据 = **自证** ⇒ 「凭据形态」永远判不出来 ⇒ 污染永远清不掉 ⭐⭐⭐
    static func stationWroteIt(_ obj: [String: Any]) -> Bool {
        (obj["__sourceVariableChanged"] as? Bool) == true
    }

    // MARK: - ⭐⭐⭐ 引擎分流

    /// ⭐⭐⭐ **跑一个 op**：**新引擎优先**，失败才回退老引擎。
    ///
    /// ⚠️ **为什么新引擎优先**（2026-10-23）：
    ///   老 JS 引擎（11 个 JS 文件 · 9845 行 · WKWebView 异步桥）已被自研 Swift 引擎替换
    ///   ⇒ 主链路（搜索 / 发现 / 详情 / 目录 / 正文）**一律走新引擎**。
    ///
    /// ⚠️ **为什么还留一条退路**：
    ///   新引擎在**个别源**上还有缺口（站方怪写法）⇒ 直接报错会让 App「像坏了」
    ///   ⇒ **回退 + 明确记一笔** ⇒ 用户能在自检面板看到「哪些源新引擎跑不通」⭐
    ///   ⇒ 老引擎已于 2026-10-25 退役 ⇒ **没有回退** ⇒ 失败就是失败（如实报出来）⭐⭐⭐
    ///
    /// ⚠️ **新引擎不支持的 op**（登录 / 诊断 / 站方变量）⇒ 直接落老引擎。
    /// ⭐ **只播报一次**（免得刷屏）
    private static var newEngineAnnounced = false
    /// ⭐⭐⭐ **新引擎连续超时次数**（≥2 ⇒ 永久切回老引擎）
    private static var newEngineTimeouts = 0

    private static func invokeEngine(_ op: String, _ payload: [String: Any],
                                     source: BookSource) async throws -> Any {
        // ⭐⭐⭐ **只有一个引擎了**（老 JS 引擎 2026-10-25 退役）
        //   ⇒ 不再有「开关」⇒ 不再有「回退」⇒ **失败就是失败**，如实报出来 ⭐⭐⭐
        //
        do {
            guard let r = try await invokeNewEngine(op, payload, source: source) else {
                // 新引擎不认识这个 op ⇒ 明确报错（**不再悄悄落老引擎**）
                throw ServiceError.engineFailed("新引擎不支持「\(op)」这个操作")
            }
            // ⭐⭐⭐⭐⭐ **「成功」不等于「对」**（2026-10-24 真机）
            //   新引擎对某些源会返回**假成功**（分类只有兜底的「未分组」/ 书单 0 本 / bookUrl 空）
            //   ⇒ **结果不可信就当失败** ⇒ 如实告诉用户 ⇒ **不再回退老引擎**
            //   （老引擎已退役 ⇒ 没得回退 ⇒ 与其给假结果，不如说清楚）
            if Self.isTrustworthy(op, r) {
                EngineBackend.lastError = nil
                if !newEngineAnnounced {
                    newEngineAnnounced = true
                    RuleSandbox.shared.appendLog(
                        "[引擎] 主链路使用**新 Swift 引擎**（legado-engine）· 搜索/发现/详情/目录/正文")
                }
                return r
            }
            let why = Self.untrustworthyReason(op, r)
            RuleSandbox.shared.appendLog(
                "[引擎] 新引擎的「\(op)」结果不可信（\(why)）")
            EngineBackend.lastError = "「\(op)」结果不可信：\(why)"
            throw ServiceError.engineFailed("「\(op)」结果不可信：\(why)")
        } catch {
            let msg = "[引擎] 新引擎跑「\(op)」失败：\(error)"
            RuleSandbox.shared.appendLog(msg)
            // ⭐⭐⭐ **失败原因留下来** ⇒ UI 能直接告诉用户「为什么」
            EngineBackend.lastError = "「\(op)」失败：\(error)"
            throw error
        }
    }

    /// ⭐⭐⭐ **新引擎调用**（**必须离开主线程**）
    ///
    /// ⚠️⚠️ **引擎内部全同步**（URLSession 用信号量等回调）⇒ 在主线程跑会卡死 UI
    /// ⇒ 丢到后台队列 ⇒ 主线程只等结果。
    private static func invokeNewEngine(_ op: String, _ payload: [String: Any],
                                         source: BookSource) async throws -> Any? {
        // ⭐⭐⭐ **新引擎的 op 也必须有超时**（2026-10-24 真机「app 死机」）
        //   以前**完全没有** ⇒ 站方服务器不通 / 引擎里死循环 ⇒ **永远不返回**
        //   ⇒ UI 永远转圈 ⇒ 用户以为 App 死了
        //   ⇒ 引擎是**全同步**的（URLSession + 信号量等回调）⇒ 卡住就是卡住
        //
        // ⚠️ **按 op 分档**（同老引擎）：
        //   · 交互类（发现/搜索/分类）⇒ 60 秒
        //   · 取内容类（详情/目录/正文）⇒ 300 秒
        //     （站方详情页会**逐条试 8 条线路** ⇒ 8×29 秒 = 232 秒是**正常的**）
        let budget = Self.newEngineTimeoutSeconds(for: op)
        // ⭐⭐⭐⭐⭐ **卡死线程配额检查**（第二层防线 ⇒ 别让手机被烧死）
        //   JSC 死循环的线程收不回来 ⇒ 满载 CPU ⇒ 多个叠加 ⇒ 热保护杀 App ⭐⭐⭐
        //   ⇒ 满额 ⇒ **不再启动新的引擎调用**，如实报错（宁可报错也别被杀）⭐
        guard Self.hasStuckThreadBudget() else {
            throw ServiceError.engineFailed(
                "已有 \(Self.maxStuckThreads) 个站方 JS 死循环在烧 CPU（手机会发烫）"
                + " ⇒ 已暂停新的引擎调用 ⇒ 请重启 App 或换本书源")
        }
        // ⭐⭐⭐⭐⭐ **真超时**（2026-10-25 真机闪退实证 + 沙盒可证伪实验）
        //
        // ⚠️⚠️⚠️ **旧写法（`withThrowingTaskGroup`）的致命缺陷**：
        //   TaskGroup 在**退出作用域时必须等所有子任务结束** ⇒ 站方 JS 死循环那个子任务
        //   **永不结束** ⇒ 「超时」分支虽然先拿到，但 `group.cancelAll()` **救不了它**
        //   （子任务跑在 `DispatchQueue.global().async` 里 ⇒ 不可取消）
        //   ⇒ **超时永远不生效** ⇒ 调用方一直等 ⇒ App 主线程被拖住
        //   ⇒ 站方 JS 死循环在 **App 进程内** 100% CPU 空转 ⇒ 设备发烫
        //   ⇒ iOS 热保护 / 看门狗杀 App ⇒ **表现为「闪退」**（不是崩溃日志，是被系统杀）⭐⭐⭐
        //
        //   ⭐ **沙盒实证**（`swiftc` 复刻同款结构，可复现）：
        //     旧写法：1 秒超时 ⇒ **实际耗时 8 秒**（等到了卡死子任务）⇒ 超时形同虚设
        //     新写法：1 秒超时 ⇒ **实际 1.0 秒**返回 ⇒ 超时真生效 ⭐⭐⭐
        //
        // ⇒ 修法：**不用 TaskGroup** ⇒ 改用「一次性 resume 闸门 + 独立超时定时器」
        //   ⇒ 超时信号与引擎线程**解耦** ⇒ 卡死的引擎线程不会拖住返回 ⭐⭐⭐
        //
        // ⚠️ **超时后引擎线程还在烧 CPU**（JSC 没有中断 API）⇒
        //   ⇒ 必须**换掉卡死的会话**（JSC context 复用 ⇒ 死循环会传染）⭐
        //   ⇒ 并且**熔断**（否则反复烧 CPU ⇒ 设备发烫 ⇒ 又被杀）⭐⭐⭐
        return try await Self.withRealTimeout(seconds: budget) {
            try LegadoEngineBackend.shared.invoke(op, payload, source: source)
        } onTimeout: {
            // ⭐⭐⭐ **换掉卡死的会话**（JSC context 是复用的 ⇒ 里面死循环 ⇒ 后面每个 op 都卡在锁上）
            //   ⇒ 换掉它 ⇒ 这个源立刻能用 ⭐
            LegadoEngineBackend.shared.dropSession(for: source.bookSourceUrl)
            // ⭐⭐⭐ **记一笔卡死线程**（JSC 没有中断 API ⇒ 这个线程收不回来 ⇒ 一直在烧 CPU）⭐
            Self.noteStuckThread()
            // ⚠️ **不再有「永久切回老引擎」**（老引擎 2026-10-25 退役）⇒
            //   ⇒ 超时就是超时 ⇒ 如实报错 ⇒ 用户知道哪儿有问题 ⭐⭐⭐
            // ⇒ 但**必须有兜底**：同一个源反复死循环 ⇒ 会反复烧 CPU ⇒ 设备发烫 ⇒ 又被杀
            //   ⇒ **连续超时 ⇒ 熔断这个源**（明确告诉用户，不再无限重试）⭐⭐⭐
            Self.newEngineTimeouts += 1
            let fatal = Self.newEngineTimeouts >= Self.newEngineFatalTimeoutCount
            RuleSandbox.shared.appendLog(
                "[引擎] 新引擎「\(op)」超时（\(Int(budget)) 秒）⇒ 已换掉卡死的会话"
                + (fatal ? " ⇒ ⚠️ **连续 \(Self.newEngineTimeouts) 次超时 ⇒ 这个源的站方 JS 死循环了 ⇒ 已熔断**"
                         : "（这个源现在能用）"))
            if fatal {
                Self.newEngineTimeouts = 0
                throw ServiceError.engineFailed(
                    "新引擎「\(op)」连续 \(Self.newEngineFatalTimeoutCount) 次超时"
                    + " ⇒ 这个书源的站方 JS 死循环了（引擎已熔断，避免 App 被拖死）"
                    + " ⇒ 请换一条线路或换本书源")
            }
        }
    }

    /// ⭐⭐⭐⭐⭐ **全局「卡死线程」配额**（2026-10-25 真机闪退的第二层防线）
    ///
    /// ⚠️⚠️ **为什么需要它**：JSC **没有中断 API** ⇒ 站方 JS 死循环 ⇒ 那个线程
    ///   **永远烧 CPU**（在 App 进程内）⇒ 换掉会话也停不下它（线程已经进去了）⭐⭐⭐
    ///   ⇒ 一个源死循环 = 1 个满载线程 ⇒ 两个源 = 2 个 ⇒ 手机发烫 ⇒ **iOS 热保护杀 App** ⭐
    ///   ⇒ 老引擎在时：JS 跑在**独立 WebContent 进程** ⇒ 死循环不烧 App 进程 ⇒ App 不死
    ///   ⇒ 老引擎退役后：**这一层保护没了** ⇒ 必须在 App 侧自己补 ⭐⭐⭐
    ///
    /// ⇒ 办法：**记录当前有多少个「已知卡死」的引擎线程**
    ///   ⇒ 达到配额 ⇒ **不再启动新的引擎调用**，直接如实报错
    ///   ⇒ 宁可告诉用户「有源死循环了」，也不要让 App 被系统杀掉 ⭐⭐⭐
    private static let stuckThreadLock = NSLock()
    private static var stuckThreadCount = 0
    /// ⭐⭐⭐ **配额**（2 个满载线程就够让手机发烫了 ⇒ 保守取 2）
    static let maxStuckThreads = 2

    /// ⭐ **占用一个卡死线程配额**（超时 ⇒ 引擎线程还在烧 ⇒ 记一笔）
    static func noteStuckThread() {
        stuckThreadLock.lock()
        stuckThreadCount += 1
        let n = stuckThreadCount
        stuckThreadLock.unlock()
        RuleSandbox.shared.appendLog(
            "[引擎] ⚠️ 站方 JS 死循环 ⇒ 引擎线程收不回来了（当前 \(n)/\(Self.maxStuckThreads)）"
            + " ⇒ 手机会发烫 ⇒ 满额后不再启动新引擎调用")
    }

    /// ⭐ **有没有空余配额**（没有 ⇒ 不许再启动引擎调用）
    static func hasStuckThreadBudget() -> Bool {
        stuckThreadLock.lock(); defer { stuckThreadLock.unlock() }
        return stuckThreadCount < Self.maxStuckThreads
    }

    /// ⭐⭐⭐⭐⭐ **连续多少次超时 ⇒ 熔断**（避免反复烧 CPU ⇒ 设备发烫 ⇒ 被系统杀）
    ///
    /// ⭐ **为什么需要它**（build252 删掉「回退老引擎」后暴露的缺口）：
    ///   老引擎退役前 ⇒ 超时 ⇒ 回老引擎（独立进程 ⇒ 死循环不烧 App 进程）⇒ App 活着
    ///   老引擎退役后 ⇒ 超时 ⇒ 只能自己扛 ⇒ 而 JSC 死循环的线程**还在烧 CPU**
    ///   ⇒ 不熔断 ⇒ 用户每点一次就烧一轮 ⇒ 设备发烫 ⇒ iOS 杀 App ⇒ 又是「闪退」⭐⭐⭐
    /// ⇒ 所以：**熔断 = 老引擎「永久切回」能力的等价物**（不是回退，是不再重试）⭐
    static let newEngineFatalTimeoutCount = 2

    /// ⭐⭐⭐⭐⭐ **真超时**（不用 TaskGroup ⇒ 不会被卡死的子任务拖住）
    ///
    /// ⚠️⚠️ **为什么不能用 `withThrowingTaskGroup`**：
    ///   TaskGroup 退出时**必须等所有子任务结束** ⇒ 站方 JS 死循环那个子任务永不结束
    ///   ⇒ 「超时」拿到的瞬间，`group.cancelAll()` **救不了已经跑在
    ///   `DispatchQueue.global().async` 里的引擎线程**（不可取消）⇒ 仍然等到它结束
    ///   ⇒ **超时形同虚设** ⇒ App 被拖死 ⇒ 沙盒实证：1 秒超时实际耗时 8 秒 ⭐⭐⭐
    ///
    /// ⇒ 本实现：**一次性 resume 闸门**（谁先到谁赢）+ **独立定时器**发超时信号
    ///   ⇒ 超时信号与引擎线程完全解耦 ⇒ 卡死线程拖不住返回 ⭐⭐⭐
    ///
    /// - Parameters:
    ///   - work: 在**后台线程**跑的引擎调用（同步）
    ///   - onTimeout: 超时后的补救（可抛错 ⇒ 抛出去）
    static func withRealTimeout<T>(seconds: Double,
                                  work: @escaping () throws -> T,
                                  onTimeout: @escaping () throws -> Void) async throws -> T {
        let gate = TimeoutGate<T>(onTimeout: onTimeout)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            gate.arm(cont, timeout: seconds)
            // ⭐ 引擎调用跑在**后台队列**（引擎内部全同步 ⇒ 不能占主线程）
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try work()
                    gate.succeed(r)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    /// ⭐⭐⭐⭐⭐ **新引擎的结果可不可信**（不可信就当失败 ⇒ 如实告诉用户）
    ///
    /// ⚠️ 判据必须**按 op**定（有的 op 空结果是对的，有的不对）：
    ///   · `exploreKinds` ⇒ 分类数 **< 3** 就是假成功（站方兜底只有 1~2 个「未分组」）
    ///   · `explore`     ⇒ 书单 0 本 = 不可信（大灰狼任何分类都有书）
    ///   · `bookInfo`    ⇒ 没有书名/书 URL = 不可信
    ///   · `toc`         ⇒ 0 章 = 不可信
    static func isTrustworthy(_ op: String, _ r: Any?) -> Bool {
        guard let dict = r as? [String: Any] else { return false }
        switch op {
        case "exploreKinds":
            let kinds = dict["kinds"] as? [[String: Any]] ?? []
            return kinds.count >= 3
        case "explore":
            let books = dict["books"] as? [[String: Any]] ?? []
            return !books.isEmpty
        case "bookInfo":
            // ⭐⭐⭐⭐⭐ **兼容嵌套形状**（2026-10-25 真机 build253 实证）
            //   `runBookInfo` 返回的是 `["book": {name, bookUrl, …}]`（**嵌套一层**）
            //   而判据原来读**顶层** `dict["name"]` ⇒ **永远空** ⇒ 永远判「不可信」
            //   ⇒ **详情页 100% 失败**（发现/目录/正文都过 ⇒ 因为它们是顶层 key）⭐⭐⭐
            //   ⇒ 症状离根因极远：引擎明明出对了 ⇒ 却被自己的判据否掉 ⭐
            //   ⇒ 修法：**两种形状都认**（不改成扁平 ⇒ 免得动到别的调用方）⭐⭐⭐
            let book = (dict["book"] as? [String: Any]) ?? dict
            let name = book["name"] as? String ?? ""
            let url = book["bookUrl"] as? String ?? ""
            return !name.isEmpty && !url.isEmpty
        case "toc":
            let chapters = dict["chapters"] as? [[String: Any]] ?? []
            return !chapters.isEmpty
        default:
            return true
        }
    }

    /// 不可信的原因（写进日志，让用户一眼看懂）
    ///
    /// ⭐⭐⭐⭐⭐ **必须说清「哪个字段空」+「引擎实际返回了什么」**（2026-10-25 真机）
    ///   以前只说「书名/书 URL 是空的」⇒ 用户看到这句话**完全不知道该查哪** ⇒
    ///   ⇒ 白等一轮（真机就是这么卡住的）⭐⭐⭐
    ///   ⇒ 现在：**逐个字段点名** + **带上引擎的实际返回**（截断）⇒ 一次就能定位 ⭐⭐⭐
    static func untrustworthyReason(_ op: String, _ r: Any?) -> String {
        guard let dict = r as? [String: Any] else { return "返回格式不对" }
        switch op {
        case "exploreKinds":
            let n = (dict["kinds"] as? [[String: Any]])?.count ?? 0
            return "只解析出 \(n) 个分类（站方正常是几十上百个 ⇒ 多半是站方兜底的「未分组」）"
        case "explore":
            return "书单 0 本"
        case "bookInfo":
            // ⭐ 兼容嵌套形状（`["book": {...}]`）
            let book = (dict["book"] as? [String: Any]) ?? dict
            let name = (book["name"] as? String) ?? ""
            let url = (book["bookUrl"] as? String) ?? ""
            let author = (book["author"] as? String) ?? ""
            let kind = (book["kind"] as? String) ?? ""
            let intro = (book["intro"] as? String) ?? ""
            var missing: [String] = []
            if name.isEmpty { missing.append("书名") }
            if url.isEmpty { missing.append("书 URL") }
            // ⭐⭐⭐ **带上引擎实际返回了什么** ⇒ 一次定位，不用猜 ⭐⭐⭐
            let got = "引擎返回：书名=\(name.prefix(20))｜URL=\(url.prefix(60))"
                + "｜作者=\(author.prefix(12))｜类型=\(kind.prefix(12))｜简介=\(intro.prefix(20))"
            if missing.isEmpty {
                return "字段都非空但仍判不可信（\(got)）"
            }
            return "\(missing.joined(separator: "、"))是空的（\(got)）"
        case "toc":
            return "目录 0 章"
        default:
            return "结果不可信"
        }
    }

    /// 新引擎每个 op 的超时（秒）
    private static func newEngineTimeoutSeconds(for op: String) -> Double {
        switch op {
        case "bookInfo", "toc", "content": return 300
        default: return 60
        }
    }

    /// ⭐⭐⭐ **解码也必须离开主线程**（2026-10-24 真机「进大灰狼发现页就死机」）
    ///   大灰狼的分类响应是 **365 个分类**（100KB+）⇒ Foundation 解码在主线程上 ⇒ **主线程卡** ⭐⭐⭐
    ///   ⇒ 现在：**后台解码** ⇒ 主线程只等结果
    private static func decodeAsync<T: Decodable>(_ type: T.Type, from raw: Any?) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try Self.decode(type, from: raw)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// ⭐⭐⭐ **纯函数 ⇒ 标 `nonisolated`**（2026-10-25 build253 编译门禁抓到）
    ///   · 它只在后台线程被调（`decodeAsync`）⇒ 而类整体标了 `@MainActor`
    ///   ⇒ 不标 `nonisolated` ⇒ **主 actor 隔离的方法被后台线程调** ⇒ 编译告警/错误
    ///   ⇒ 标了之后：① 语义正确（纯解码，不碰任何 UIKit/主线程状态）② Swift 6 模式也能编 ⭐⭐⭐
    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from raw: Any?) throws -> T {
        guard let obj = raw, !(obj is NSNull) else { throw ServiceError.badPayload }
        if let dict = obj as? [String: Any], let msg = dict["error"] as? String, !msg.isEmpty {
            throw ServiceError.engineFailed(msg)
        }
        // 书单走宽松解析：单本书坏掉不该让整页消失
        if type == BookListDTO.self, let lenient = BookListDTO.lenient(obj) {
            return lenient as! T
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        do {
            return try AppDecoder.decode(type, from: data)
        } catch let e as DecodingError {
            // 把「哪一列出的问题」带出来，别只丢一句"解码失败"。
            // ⚠️ codingPath 挂在每个 case 的 **context** 上，不在 DecodingError 本体上。
            var keys: [CodingKey] = []
            let why: String
            switch e {
            case .keyNotFound(let key, let ctx):
                keys = ctx.codingPath; why = "缺字段 \(key.stringValue)"
            case .typeMismatch(let t, let ctx):
                keys = ctx.codingPath; why = "类型不匹配，要的是 \(t)"
            case .valueNotFound(let t, let ctx):
                keys = ctx.codingPath; why = "值缺失（\(t)），该字段是 null"
            case .dataCorrupted(let ctx):
                keys = ctx.codingPath; why = "数据损坏：\(ctx.debugDescription)"
            @unknown default:
                why = e.localizedDescription
            }
            let path = keys.map { k -> String in
                k.intValue.map { "[\($0)]" } ?? k.stringValue
            }.joined(separator: ".")
            let preview = String(data: data, encoding: .utf8)?.prefix(1200) ?? ""
            throw ServiceError.engineFailed(
                "解析 \(type) 失败 —— 出错字段：\(path.isEmpty ? "(根)" : path) / \(why)\n返回：\(preview)")
        } catch {
            // 引擎某一列的形状变了时，把原文带出来，别让上层只看到"解码失败"
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw ServiceError.engineFailed("解析 \(type) 失败: \(error.localizedDescription) | 返回: \(preview)")
        }
    }

    // MARK: 返回模型

    struct BookDTO: Codable {
        var name: String = ""
        var author: String = ""
        var intro: String = ""
        var kind: String = ""
        /// ⭐⭐⭐ **分组**（站方的 `ruleBookInfo.group` / `category`）
        /// ⚠️ 2026-10-25 真机：详情页那格「分组」之前**硬编码「未分组」** ⇒ 现在取站方真值 ⭐⭐⭐
        var group: String = ""
        var lastChapter: String = ""
        var coverUrl: String = ""
        var bookUrl: String = ""
        var wordCount: String = ""
        /// 引擎 bookInfo 会返回 tocUrl。之前这个字段压根没在 DTO 里声明，
        /// 解码时直接丢掉、toBook 再硬传 `tocUrl: ""`，于是**每本书的 tocUrl 都是空的**
        /// → 目录永远退回书籍页 → 0 章且不报错。
        var tocUrl: String = ""
        /// ⭐⭐⭐ **列表项的【原始字段】**（2026-10-22 真机栽在这）
        ///   站方 jsLib 生成 `data:;base64,<载荷>` 时要用 **book_id / bid / item_id** 之类，
        ///   而宿主原先只把 name/author/… 九个字段送给站方 ⇒ **book_id 压根没传过去**
        ///   ⇒ 站方只生成了 `{"tab":"小说","url":""}` ⇒ 详情/目录请求全是 book_id=undefined
        ///      ⇒ 服务器回「illegal base64 data at input byte 9」⇒ 整本书崩 ⭐
        ///   ⇒ 这里把**原始 item 的所有键**留一份 ⇒ 往下传（见 Book.rawJSON）
        var raw: [String: String]? = nil

        init() {}

        /// ⚠️ 逐列 `decodeIfPresent` + 默认值兜底，**不依赖编译器合成的行为** ——
        ///    少一个字段（列表书没有 tocUrl）、某列是 null、或者站方换了字段形状，
        ///    都只影响那一列，不会让整本书解不出来，进而让整页书单挂掉。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func g(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            name = g(.name);           author   = g(.author)
            intro = g(.intro);         kind     = g(.kind)
            group = g(.group)
            lastChapter = g(.lastChapter); coverUrl = g(.coverUrl)
            bookUrl = g(.bookUrl);     wordCount = g(.wordCount)
            tocUrl = g(.tocUrl)
            raw = (try? c.decodeIfPresent([String: String].self, forKey: .raw)) as? [String: String]
        }
        private enum K: String, CodingKey {
            case name, author, intro, kind, group, lastChapter, coverUrl, bookUrl, wordCount, tocUrl, raw
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(name, forKey: .name);         try c.encode(author, forKey: .author)
            try c.encode(intro, forKey: .intro);       try c.encode(kind, forKey: .kind)
            try c.encode(group, forKey: .group)
            try c.encode(lastChapter, forKey: .lastChapter); try c.encode(coverUrl, forKey: .coverUrl)
            try c.encode(bookUrl, forKey: .bookUrl);   try c.encode(wordCount, forKey: .wordCount)
            try c.encode(tocUrl, forKey: .tocUrl)
            try c.encodeIfPresent(raw, forKey: .raw)
        }
    }
    struct BookListDTO: Codable {
        var books: [BookDTO] = []
        var total: Int = 0
        var nextUrl: String = ""
        /// 引擎失败时会把原因放在这里。以前这个字段直接被丢掉，
        /// 结果就是「搜不出东西」但界面什么都不显示。
        var error: String? = nil

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            books    = (try? c.decodeIfPresent([BookDTO].self, forKey: .books)) as? [BookDTO] ?? []
            total    = (try? c.decodeIfPresent(Int.self, forKey: .total)) as? Int ?? 0
            nextUrl  = (try? c.decodeIfPresent(String.self, forKey: .nextUrl)) as? String ?? ""
            error    = try? c.decodeIfPresent(String.self, forKey: .error)
        }
        private enum K: String, CodingKey { case books, total, nextUrl, error }

        /// 从 WKWebView 桥过来的字典里**尽力**取出书单。
        /// 之前是整份 JSON 丢给 JSONDecoder，一旦有**一本书**的字段形状对不上，
        /// 整个数组就解不出来 → 页面直接显示「解析 BookListDTO 失败」+ 一个空列表。
        /// 改成逐本单独解：坏的那本跳过，好的照常显示。
        static func lenient(_ obj: Any?) -> BookListDTO? {
            guard let dict = obj as? [String: Any] else { return nil }
            var out = BookListDTO()
            out.error = dict["error"] as? String
            out.total = (dict["total"] as? NSNumber)?.intValue ?? 0
            out.nextUrl = (dict["nextUrl"] as? String) ?? ""
            var list: [BookDTO] = []
            if let arr = dict["books"] as? [Any] {
                for item in arr {
                    guard let one = item as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: one),
                          var b = try? AppDecoder.decode(BookDTO.self, from: data)
                    else { continue }
                    // ⭐⭐⭐ **原始 item 的所有键都留一份**（站方 jsLib 生成 data: 载荷时要用
                    //   book_id 之类；宿主原先只送九���字段 ⇒ 站方拿不到 ⇒ 载荷缺 book_id ⇒ 全崩）
                    var rawMap: [String: String] = [:]
                    for (rk, rv) in one {
                        if rv is NSNull { continue }
                        rawMap[rk] = (rv as? String) ?? String(describing: rv)
                    }
                    b.raw = rawMap
                    list.append(b)
                }
            }
            out.books = list
            return out
        }
    }
    struct BookInfoDTO: Codable {
        var book: BookDTO?
        var error: String? = nil
    }
    struct ChapterDTO: Codable {
        var url: String = ""
        var title: String = ""
        var index: Int = 0
        var isVolume: Bool = false
        var tag: String = ""

        /// ⚠️⚠️ **容错解码**（2026-10-23 真机踩到）
        ///   Swift 的 `Codable` **不会用属性默认值兜底** ⇒ 引擎少给一个键
        ///   ⇒ `keyNotFound` ⇒ **整个 op 的结果全废**（目录页整页报错）
        ///   ⇒ 一律 `decodeIfPresent ?? 默认值`（跟 BookDTO 一样）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func g(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            url = g(.url); title = g(.title)
            index = (try? c.decodeIfPresent(Int.self, forKey: .index)) ?? 0
            isVolume = (try? c.decodeIfPresent(Bool.self, forKey: .isVolume)) ?? false
            tag = g(.tag)
        }
        private enum K: String, CodingKey { case url, title, index, isVolume, tag }
    }
    struct TocDTO: Codable {
        var chapters: [ChapterDTO] = []
        var error: String? = nil
        /// 站方返回的**原始**条数（过滤「书自己」那条占位之前）
        /// ⚠️ 用来区分「服务器没这本书的章节」和「chapterList 规则没命中」——
        ///    以前一律报「规则没命中」⇒ **误导**（规则其实命中了）
        var rawCount: Int? = nil
        /// 是否过滤掉了「书自己」那条占位（= 站方服务器没抓到这本书的章节）
        var placeholderFiltered: Bool? = nil
        var bookName: String? = nil
    }

    /// 目录结果 + 诊断信息
    struct TocResult {
        var chapters: [Chapter] = []
        var rawCount: Int = 0
        var placeholderFiltered: Bool = false
        var bookName: String = ""
    }
    struct ContentDTO: Codable {
        var title: String = ""
        var content: String = ""
        var nextUrl: String = ""
        var error: String? = nil

        /// ⚠️ **容错解码**（同 KindDTO：Swift 不用属性默认值兜底）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func g(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            title = g(.title); content = g(.content); nextUrl = g(.nextUrl)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
        }
        private enum K: String, CodingKey { case title, content, nextUrl, error }
    }
    struct KindDTO: Codable {
        var title: String = ""
        var url: String = ""
        var style: String = ""
        /// **所属分组**（站方用装饰行当组标题，如「☆ 排行榜 ☆」）
        /// ⇒ 照抄栖阅 `ExploreCategorySplit.groups()` ✅
        var group: String = ""

        /// ⚠️⚠️ **容错解码**（2026-10-23 真机踩到）
        ///   老式静态分类（`标题::URL`）的 kind **没有 group 字段**
        ///   ⇒ Swift 的 `Codable` **不会用属性默认值兜底** ⇒ `keyNotFound(group)`
        ///   ⇒ **整个发现页报错**（「解析 KindsDTO 失败 —— 缺字段 group」）
        ///   ⇒ 一律 `decodeIfPresent ?? 默认值`
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func g(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            title = g(.title); url = g(.url); style = g(.style); group = g(.group)
        }
        private enum K: String, CodingKey { case title, url, style, group }
    }
    struct KindsDTO: Codable {
        var kinds: [KindDTO] = []
        /// **发现页筛选栏**（站方 exploreUrl 的 `type:"select"` 契约）
        ///
        /// ⚠️ 2026-10-21 补：站方（🍅大灰狼）的 exploreUrl 返回
        ///    `qtsj.concat(infoData, groupDatas, style_list)`，
        ///    其中 `qtsj` 是**筛选栏**（平台 / 模式 / 频道 / 字数 / 状态 / 排序 / 线路），
        ///    **不是分类**。它们没有 url 字段 ⇒ 以前混在分类列表里，点不动 ⇒
        ///    用户看到的「平台」那几项「没有 api」。
        var filters: [FilterDTO] = []
        var error: String? = nil
    }

    /// 发现页的一个筛选项（栖阅契约）
    ///
    /// 站方写法（jsLib 的 `createFilter`）：
    /// ```js
    /// createFilter("平台", ["番茄","七猫","书旗",…], sources, "find_source", 1)
    /// //  → { title:"平台", type:"select", chars:[…], default:sources,
    /// //      action:"show(infoMap['平台'],'find_source')", style:{…} }
    /// ```
    struct FilterDTO: Codable, Identifiable {
        var title: String = ""
        var type: String = "select"
        /// 可选值（「平台」有 42 个）
        var chars: [String] = []
        /// 站方给的默认值
        var `default`: String = ""
        /// **源级变量名**（引擎侧从 action 里抠出来的，如 `find_source`）
        ///
        /// ⚠️ 选中后要写的是**这个源级变量** ⇒ 站方 exploreUrl 重跑时
        ///    `getArguments(open_argument,'find_source')` 就能读到新的平台 ✅
        var paramKey: String = ""
        var action: String = ""
        var id: String { title + "|" + paramKey }

        /// ⚠️⚠️ **容错解码**（2026-10-23 真机踩到，同 KindDTO）
        ///   站方给的筛选项可能没有 `paramKey` / `action` / `default`
        ///   ⇒ 缺一个键就**整个发现页**报错 ⇒ 一律兜底
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func g(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            title = g(.title); type = g(.type)
            chars = (try? c.decodeIfPresent([String].self, forKey: .chars)) ?? []
            `default` = g(.default)
            paramKey = g(.paramKey); action = g(.action)
        }
        private enum K: String, CodingKey {
            case title, type, chars, `default`, paramKey, action
        }

        /// 该筛选项**当前生效的值**
        ///
        /// ⚠️ 优先读**源级变量**（用户改过的），没有才用站方的 default。
        ///
        /// ⚠️⚠️ **再往前一步：先看「用户刚选过什么」**（2026-10-22）
        ///   站方（🍒NovelHub）的 action 自己写源级变量（键名是站方定的）⇒
        ///   宿主抠不出 paramKey ⇒ 读不到当前值 ⇒ 只能显示站方的 `default`
        ///   （而站方的 default 恒为 `chars[0]` ⇒ 切了番茄还显示书旗 ⇒ 用户以为没生效）❗
        static func currentValue(_ f: FilterDTO, sourceUrl: String) -> String {
            let chosen = SourceVariables.filterChoice(for: sourceUrl, title: f.title)
            if !chosen.isEmpty { return chosen }
            if !f.paramKey.isEmpty {
                let raw = SourceVariables.effectiveVars(for: sourceUrl)
                if let d = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let v = obj[f.paramKey] as? String, !v.isEmpty {
                    return v
                }
            }
            return f.default
        }

        /// 全部筛选项的当前值（paramKey → 值）
        static func currentValues(filters: [FilterDTO], sourceUrl: String) -> [String: String] {
            var out: [String: String] = [:]
            for f in filters where !f.paramKey.isEmpty {
                out[f.paramKey] = currentValue(f, sourceUrl: sourceUrl)
            }
            return out
        }
    }

    // MARK: 对外方法

    func search(source: BookSource, keyword: String, page: Int = 1) async throws -> [Book] {
        let dto: BookListDTO = try await call("search",
            json(["keyword": keyword, "page": page]), as: BookListDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto.books.map { $0.toBook(origin: source.bookSourceUrl, sourceName: source.name) }
    }

    // MARK: - 自动选线

    /// 一次启动里已经测过的源（避免每次都测）
    private static var probedSources: Set<String> = []
    private static let probedLock = NSLock()

    /// **自动选线**：测速站方所有线路 → 把最快的一条写进书源变量的 `server`
    ///
    /// ⚠️ 为什么必须自动（2026-10-21 用户原话）：
    ///    「**检测当前服务器只是看线路快不快的，没有别的用处**」——
    ///    站方的 `checkNet()` 只**测**不**切**（切线是 `set_server()`）⇒
    ///    让人手点没意义 ⇒ **App 自己测自己切** ✅
    ///
    /// 逻辑：
    /// - 当前线路通且不比最快的慢 2 倍以上 → **不动**（别折腾）
    /// - 否则 → 把最快的那条写进 `server` ✅（站方下一次请求就用它）
    ///
    /// - Returns: 选中的线路（没换就是原来的）
    @discardableResult
    func autoPickFastestLine(source: BookSource) async -> String? {
        // ⚠️⚠️ **这里绝不能抛、绝不能卡**（2026-10-21 闪退事故）：
        //    整个函数包在 do/catch 里 ⇒ 任何异常都静默跳过 ❗
        //    （它只是「锦上添花」的选线功能，不值得为它崩整个 App）
        do {
            return try await autoPickFastestLineImpl(source: source)
        } catch {
            NSLog("[选线] 失败，忽略：%@", String(describing: error))
            return nil
        }
    }

    private func autoPickFastestLineImpl(source: BookSource) async throws -> String? {
        let url = source.bookSourceUrl
        guard !url.isEmpty else { return nil }
        Self.probedLock.lock()
        let alreadyProbed = Self.probedSources.contains(url)
        if !alreadyProbed { Self.probedSources.insert(url) }
        Self.probedLock.unlock()
        if alreadyProbed { return nil }

        // ① 站方的全部线路（jsLib 的 host 数组）+ 当前线路
        var hosts = (try? await sourceHosts(source: source)) ?? []
        let varsText = SourceVariables.vars(for: url)
        var current = ""
        if let m = try? JSONSerialization.jsonObject(with: Data(varsText.utf8)) as? [String: Any],
           let sv = m["server"] as? String { current = sv }
        if !current.isEmpty && !hosts.contains(current) { hosts.insert(current, at: 0) }
        guard hosts.count > 1 else { return current.isEmpty ? nil : current }

        // ② 并发测速（5 秒超时）—— **async，不占主线程**（主线程被阻塞会被 watchdog 杀 ❗）
        //
        // ⚠️⚠️⚠️ **测两轮，按「成功次数」排**（2026-10-21 真机实测踩到的）：
        //   原来只测**一轮**，取「最快的那条」⇒ 但一轮里通一次**可能只是侥幸**
        //   ⇒ 真机上选中了 **v10**（而 v10 恰恰是偶发 502/超时最狠的那条）
        //   ⇒ 之后 fquser / group_name 反复超时重试
        //   ⇒ **一次 exploreKinds 要 40 秒**，而且结果不稳（时好时坏）⭐
        //   ⇒ 现在测两轮：**两轮都通 > 只通一轮**，同档再比延迟
        let results = await LegadoCompat.pingHosts(hosts, timeout: 5)
        let results2 = await LegadoCompat.pingHosts(hosts, timeout: 5)
        var score: [String: (okCount: Int, ms: Int)] = [:]
        for r in results + results2 {
            let h = (r["host"] as? String) ?? ""
            if h.isEmpty { continue }
            let ok = (r["ok"] as? Bool) == true
            let ms = (r["ms"] as? Int) ?? 999999
            var e = score[h] ?? (0, 999999)
            if ok { e.0 += 1 }
            if ok && ms < e.1 { e.1 = ms }
            score[h] = e
        }
        // 成功次数多的优先；次数一样比延迟
        let ranked = score.sorted { a, b in
            if a.value.0 != b.value.0 { return a.value.0 > b.value.0 }
            return a.value.1 < b.value.1
        }
        guard let top = ranked.first, top.value.0 > 0 else {
            // 全都不通 → 保持原样（让站方自己逐条兜底）
            return current.isEmpty ? nil : current
        }
        let bestHost = top.key
        let bestMs = top.value.1
        let curScore = score[current]
        let curOK = (curScore?.okCount ?? 0) >= 2
        let curMs = curScore?.ms ?? -1

        // ③ 当前线路**两轮都通**且够快 → 不折腾
        if curOK && curMs >= 0 && curMs <= bestMs * 2 { return current }

        // ④ 换线：写进书源变量
        guard var m = (try? JSONSerialization.jsonObject(with: Data(varsText.utf8)) as? [String: Any]) else {
            return bestHost
        }
        m["server"] = bestHost
        if let d = try? JSONSerialization.data(withJSONObject: m),
           let t = String(data: d, encoding: .utf8) {
            // ⚠️⚠️ **必须合并站方默认变量**（2026-10-21 真机「目录 0 章」的根因之一）：
            //   站方的 `getArguments` 只在变量串**解析失败**时才给默认表；
            //   只写 `{"server":…}` 这种**只含一项**的合法 JSON ⇒ 它不再给默认
            //   ⇒ `tab / sources / source_type / proxy …` 全变 undefined ⇒ 源被改坏。
            let defaults = await sourceDefaultVars(source: source)
            // ⭐⭐⭐ **判据要准** ⇒ 这里 **await** 一次（同步读缓存可能拿到空表）
            //   （空表 ⇒ 误判成「非 map 形态的源」⇒ 线路写不进站方变量 ⇒ 大灰狼又变慢）
            let merged = SourceVariables.mergeVars(userJSON: t, defaults: defaults)
            // ⭐⭐⭐⭐ 只有「map 形态」的源才把 map 写进**站方变量**
            //   ⇒ 凭据形态的源（✿UAA：站方变量 = token 的位置）**绝不能**被 map 覆盖 ⭐⭐⭐
            //   ⇒ 覆盖 ⇒ `Bearer {"androidId":"…"}` ⇒ 服务端 403「无效JWT」⇒ 「获取 token」永远失败 ⭐
            //   ⇒ 判据：**站方自己怎么用这一格**（证据）⇒ map / 凭据 / 不知道 ⭐⭐⭐
            SourceVariables.setLineVars(merged, for: url,
                                       isMapStyle: SourceVariables.form(for: url, jsLib: source.jsLib) == .map,
                                       jsLib: source.jsLib)
        }
        let msg = "[选线] 已切到 \(bestHost)（\(bestMs)ms）"
        NSLog("%@", msg)
        RuleSandbox.shared.appendLog(msg)
        return bestHost
    }

    /// 该源**最终生效**的变量串（站方默认 + 用户的改动）
    ///
    /// ⭐ 用户从没打开过登录面板时，本地没有站方的默认变量表 ⇒
    ///    这里**顺手向站方要一份并缓存**（每个源只问一次）⇒
    ///    之后每次请求都带完整变量（站方 JS 才拿得到 server/tab/sources/proxy）✅
    func effectiveVars(for source: BookSource) async -> String {
        if SourceVariables.defaultVars(for: source.bookSourceUrl).isEmpty {
            _ = await sourceDefaultVars(source: source)
        }
        return SourceVariables.effectiveVars(for: source.bookSourceUrl)
    }

    /// **站方的默认变量表**（jsLib 的 `getArguments('', '')`）—— 写变量时拿它做底
    ///
    /// ⭐ 缓存起来（站方的默认值不会变，除非书源更新）⇒ 不给每次请求加开销。
    func sourceDefaultVars(source: BookSource) async -> [String: Any] {
        let cached = SourceVariables.defaultVars(for: source.bookSourceUrl)
        if !cached.isEmpty { return cached }
        // ⭐⭐⭐ 走缓存（别再编码+解析一遍 158KB）
        var srcDict = await SourceDictCache.dict(for: source)
        // ⚠️ 这里不能用 effectiveVars(for:)（会递归）⇒ 用原始变量
        srcDict["__variables"] = SourceVariables.vars(for: source.bookSourceUrl)
        // ⭐⭐⭐ 站方变量（Legado 语义：一整串）⇒ 与「书籍变量」分开 ⭐
        //   ⭐⭐⭐ 走 `stationVariableToSeed` ⇒ **顺带做污染迁移**（凭据形态却躺着一个 map ⇒ 清掉）⭐
        srcDict["__variable"] = SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        // ⭐⭐⭐⭐⭐ **走新引擎**（2026-10-29 ⇒ 与登录/目录同一套站方变量语义）
        guard let raw = try? await Self.invokeEngine("sourceVars", ["source": srcDict], source: source),
              let dict = raw as? [String: Any],
              let vars = dict["vars"] as? [String: Any] else { return [:] }
        // ⭐⭐⭐ **哪怕是空的也要落盘** ⇒ 记下「取过了」⭐
        //   （「默认表是空的」有两种意思：① 取过了、站方确实没有 ② **还没取过**）
        //   ⇒ 不记这个 ⇒ 分不清 ⇒ 判不出「凭据形态」⇒ 真机上的污染清不掉 ⭐⭐⭐
        SourceVariables.setDefaultVars(vars, for: source.bookSourceUrl)
        return vars
    }

    /// ⭐⭐⭐ **挑一条最快的线路**（2026-10-24 真机「唯独大灰狼卡死」的根治）
    ///
    /// ⚠️⚠️ **为什么只有大灰狼卡**：它的 jsLib 里 `host` 数组有 **8 条线路**
    ///   （v5 / 219.154.201.122:5006 / v4 / v2 / v7 / v8 / v9 / v10）
    ///   ⇒ 站方的 catch 循环会**挨个试** ⇒ 死线路每条要等超时
    ///   ⇒ 沙盒实测：v5 要 4.1 秒、v8 直接不通 ⇒ 8 条加起来**每个 op 十几秒**
    ///   ⇒ 别的聚合源线路少/服务器活 ⇒ **就不卡** ⭐⭐⭐
    ///
    /// ⇒ **修法**：进页面时**先测速**，把最快的一条写进 `server` 变量
    ///   ⇒ 站方 `getArguments('server')` 拿到它 ⇒ **只走那一条** ⇒ 每个 op 一次请求 ⇒ 秒回 ⭐⭐⭐
    ///
    /// ⚠️ 写 `server` **必须以站方默认表做底**（`mergeVars`）
    ///   ⇒ 只写一项会把 server/tab/sources/proxy 全丢掉 ⇒ 源被改坏（老坑）
    ///
    /// - Returns: 用上的线路（空 = 没挑到 / 不影响本次）
    @discardableResult
    func ensureFastLine(source: BookSource, timeout: Double = 5) async -> String {
        // ⭐ 30 分钟内选过就不重选
        if let cached = Self.fastLineCache[source.bookSourceUrl],
           Date().timeIntervalSince(cached.at) < 30 * 60 {
            return cached.host
        }
        guard let hosts = try? await sourceHosts(source: source), !hosts.isEmpty else { return "" }
        let results = await LegadoCompat.pingHosts(hosts, timeout: timeout)
        guard let best = results.first(where: { ($0["ok"] as? Bool) == true }),
              let host = best["host"] as? String, !host.isEmpty else { return "" }
        // ⭐ 写进书源变量（**以站方默认表做底**）
        let defaults = await sourceDefaultVars(source: source)
        let payload = "{\"server\":\"\(host)\"}"
        let merged = SourceVariables.mergeVars(userJSON: payload, defaults: defaults)
        // ⭐⭐⭐⭐ 只有「map 形态」的源才把 map 写进**站方变量**（凭据形态的源：站方变量 = token）⭐
        // ⭐⭐⭐⭐ 判据：**站方自己怎么用这一格**（证据）⇒ map / 凭据 / 不知道 ⭐
        SourceVariables.setLineVars(merged, for: source.bookSourceUrl,
                                    isMapStyle: SourceVariables.form(for: source.bookSourceUrl, jsLib: source.jsLib) == .map,
                                    jsLib: source.jsLib)
        Self.fastLineCache[source.bookSourceUrl] = (host, Date())
        RuleSandbox.shared.appendLog("[线路] 测速 8 条 ⇒ 选了最快的：\(host)")
        return host
    }

    /// **已选的线路缓存**（30 分钟）
    private static var fastLineCache: [String: (host: String, at: Date)] = [:]

    /// **站方的全部线路**（jsLib 里的 `host` 数组）—— 用来测速挑一条通的
    func sourceHosts(source: BookSource) async throws -> [String] {
        // ⭐⭐⭐ 走缓存（同上）
        var srcDict = await SourceDictCache.dict(for: source)
        srcDict["__variables"] = await effectiveVars(for: source)
        // ⭐⭐⭐ 站方变量（Legado 语义：一整串）⇒ 与「书籍变量」分开 ⭐
        //   ⭐⭐⭐ 走 `stationVariableToSeed` ⇒ **顺带做污染迁移**（凭据形态却躺着一个 map ⇒ 清掉）⭐
        srcDict["__variable"] = SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        // ⭐⭐⭐⭐⭐ **走新引擎**（2026-10-29 ⇒ 与登录/目录同一套站方变量语义）
        let raw = try await Self.invokeEngine("sourceHosts", ["source": srcDict], source: source)
        let dict = raw as? [String: Any] ?? [:]
        return (dict["hosts"] as? [String]) ?? []
    }

    // MARK: - 发现页分类缓存

    /// 分类 + 筛选栏的**内存缓存**
    ///
    /// ⚠️⚠️ **为什么**（2026-10-22 真机：「发现页加载就番茄很慢很慢，其他挺快的」）：
    ///   实测各平台的 `exploreKinds` 耗时 / 数据量：
    ///     · 番茄  → **2283ms / 74,750 字节 / 376 个分类**  🐌
    ///     · 七猫  → 515ms  / 12,182 字节 / 51 个分类
    ///     · QQ阅读 → 768ms /  4,386 字节 / 23 个分类
    ///   ⇒ 番茄的分类列表**大 20 倍** ⇒ 每次切平台都要重新拉 74KB ⇒ 白等两秒多。
    ///   ⇒ 缓存一下 ⇒ 切回番茄**秒开** ✅
    ///
    /// ⚠️ 缓存 key 必须带**平台 + 模式**（站方的 `find_source` / `find_tab` 变了 ⇒ 分类就变了）
    private static var kindsCache: [String: KindsDTO] = [:]
    private static var kindsCacheAt: [String: Date] = [:]
    /// 缓存有效期（30 分钟）—— 站方的分类很少变，但线路故障时可能变
    private static let kindsCacheTTL: TimeInterval = 30 * 60

    private static func kindsCacheKey(source: BookSource) -> String {
        var platform = ""
        var tab = ""
        if let d = SourceVariables.effectiveVars(for: source.bookSourceUrl).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            platform = (obj["find_source"] as? String) ?? ""
            tab = (obj["find_tab"] as? String) ?? ""
        }
        return "\(source.bookSourceUrl)|\(platform)|\(tab)"
    }

    /// 拿发现页的**分类 + 筛选栏**
    ///
    /// ⚠️ 2026-10-21：返回整个 `KindsDTO`（多了 `filters`）——
    ///    分类和筛选栏是**两回事**，别再混在一起。
    /// - Parameter force: 强制绕过缓存（用户下拉刷新 / 线路故障后重试）
    func exploreKinds(source: BookSource, force: Bool = false) async throws -> KindsDTO {
        let key = Self.kindsCacheKey(source: source)
        if !force,
           let dto = Self.kindsCache[key],
           let at = Self.kindsCacheAt[key],
           Date().timeIntervalSince(at) < Self.kindsCacheTTL {
            return dto
        }
        let dto: KindsDTO = try await call("exploreKinds", json([:]), as: KindsDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        // ⚠️⚠️ **站方挂了的时候别把坏结果缓存住**（2026-10-22 实测）：
        //   `discovestyle` 接口会返 503（`DNS cache overflow` / Cloudflare 522）
        //   ⇒ 分类只剩「个人中心 / 登录番茄」**2 个**（正常是 365 个）
        //   ⇒ 要是把这个坏结果缓存 30 分钟 ⇒ 用户切平台再切回来还是 2 个 ⇒ 分类像「消失了」
        // ⇒ **只有分类数看着正常才写缓存**（≤4 个的一律不缓存 ⇒ 下次自动重试）
        if dto.kinds.count >= 5 {
            Self.kindsCache[key] = dto
            Self.kindsCacheAt[key] = Date()
        }
        // 缓存别无限长（换很多平台会攒一堆）
        if Self.kindsCache.count > 24 {
            let old = Self.kindsCacheAt.min { ($0.value ?? .distantPast) < ($1.value ?? .distantPast) }
            if let k = old?.key {
                Self.kindsCache.removeValue(forKey: k)
                Self.kindsCacheAt.removeValue(forKey: k)
            }
        }
        return dto
    }

    /// 发现页筛选栏：**执行站方的 action**（栖阅同款，2026-10-22）
    ///
    /// ⚠️ 为什么要单独一条路（不能一律「自己写 paramKey」）：
    ///   站方（🍅大灰狼）的 action 是 `show(infoMap['平台'],'find_source')`
    ///   ⇒ 引擎能抠出 paramKey ⇒ 宿主自己写变量就行；
    ///   但站方（🍒NovelHub 聚合源）的 action **自己写变量、自己刷新**：
    ///     (function(){ … var v=infoMap['平台']; c['src']=v;
    ///       source.setVariable(JSON.stringify(c)); java.refreshExplore(); })()
    ///   ⇒ 抠不出 paramKey ⇒ 宿主自己写不了 ⇒ **只能让站方自己执行** ✅
    ///
    /// - Returns: 站方 action 有没有跑成功
    func applySourceFilter(source: BookSource, action: String,
                           title: String, value: String) async throws -> Bool {
        var p: [String: Any] = ["action": action, "title": title, "value": value]
        // ⭐⭐⭐ 走缓存（同上）
        var srcDict = await SourceDictCache.dict(for: source)
        srcDict["__variables"] = await effectiveVars(for: source)
        // ⭐⭐⭐ 站方变量（Legado 语义：一整串）⇒ 与「书籍变量」分开 ⭐
        //   ⭐⭐⭐ 走 `stationVariableToSeed` ⇒ **顺带做污染迁移**（凭据形态却躺着一个 map ⇒ 清掉）⭐
        srcDict["__variable"] = SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        srcDict["__loginHeader"] = SourceVariables.loginHeader(for: source.bookSourceUrl)
        p["source"] = srcDict
        p["cookieSnapshot"] = CookieJar.snapshot()
        // ⚠️⚠️⚠️ **筛选栏 action【必须走老引擎】**（2026-10-29 真机回归实证 ⇒ 改回来了）
        //   ⇒ 同 login：引擎的 `runFilterAction` **没传 `source:`** ⇒ 全局 `source` 没有宿主方法
        //     ⇒ 站方 action 里的 `source.put('order', 2)` / `source.put('type', …)` **写不进去** ⭐⭐⭐
        //     ⇒ 症状：发现页「**筛选栏 0 个**」+ explore 的 `order_type` 取旧值 ⇒ **HTTP 500** ⭐⭐⭐
        //   ⇒ 老引擎的 filterAction **会把 `g.source` 挂上**（engine.js:1468）⇒ 站方写变量才有效 ⭐
        let raw = try await RuleSandbox.shared.invoke("filterAction", p, source: source)
        // 站方自己写的源级变量 → 落盘（下次 exploreKinds 直接生效）
        if let obj = raw as? [String: Any],
           let v = obj["__sourceVars"] as? String {
            SourceVariables.setVars(v, for: source.bookSourceUrl)
        }
        // ⭐⭐⭐ 站方变量（Legado 语义）⇒ 落盘 ⭐
        //   ⭐⭐⭐ **只有站方真改过这一格**才当成「站方写的」⇒ 不然证据会**自证** ⭐⭐⭐
        if let obj = raw as? [String: Any],
           let v = obj["__sourceVariable"] as? String {
            SourceVariables.setVariable(v, for: source.bookSourceUrl,
                                       origin: Self.stationWroteIt(obj) ? .station : .app)
        }
        let dict = raw as? [String: Any] ?? [:]
        return dict["ok"] as? Bool ?? false
    }

    func explore(source: BookSource, kindUrl: String, page: Int = 1) async throws -> [Book] {
        let dto: BookListDTO = try await call("explore",
            json(["kindUrl": kindUrl, "page": page]), as: BookListDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto.books.map { $0.toBook(origin: source.bookSourceUrl, sourceName: source.name) }
    }

    /// 诊断一次目录请求：URL / 状态 / 命中数 / 第一条章节的 HTML 都摆出来
    func explainToc(source: BookSource, tocUrl: String, bookUrl: String,
                    book: Book? = nil) async throws -> String {
        var payload: [String: Any] = ["tocUrl": tocUrl, "bookUrl": bookUrl]
        // ⚠️ 必须带 book：站方 chapterList 第一句就调 book.getVariable('custom')
        //   → 不给就抛异常 → 目录一条不剩 → 诊断还误报「规则没命中」。
        if let b = book { payload["book"] = b.rawJSON }
        let raw = try await RuleSandbox.shared.invoke("explainToc", payload, source: source)
        guard let dict = raw as? [String: Any] else { return "引擎没有返回诊断数据" }
        var out: [String] = []
        for k in ["请求URL", "最终URL", "状态码", "响应字节", "页面标题",
                  "chapterList规则", "chapterName规则", "chapterUrl规则",
                  "规则命中元素", "JS路径命中", "JS报错",
                  "取到的章节名", "取到的章节URL",
                  "选择器报错", "解析报错", "元素统计", "命中条目样本",
                  "候选容器", "目录容器样本", "结论"] {
            if let v = dict[k] {
                let s = (v is String) ? (v as! String) : String(describing: v)
                if s.isEmpty { continue }
                out.append("\(k)：\(s)")
            }
        }
        return out.isEmpty ? "没有诊断信息" : out.joined(separator: "\n")
    }

    /// 诊断一次发现页请求，把 URL / 状态码 / 字节数 / 命中元素数拼成人话。
    func explain(source: BookSource, kindUrl: String, page: Int = 1) async throws -> String {
        let raw = try await RuleSandbox.shared.invoke("explain",
            ["kindUrl": kindUrl, "page": page], source: source)
        guard let dict = raw as? [String: Any] else { return "引擎没有返回诊断数据" }
        var out: [String] = []
        for k in ["请求URL", "最终URL", "方式", "状态码", "响应字节", "页面标题",
                  "用的规则", "bookList规则", "规则命中元素", "元素统计", "选择器报错",
                  "解析报错", "结论", "候选列表容器", "书单条目样本"] {
            if let v = dict[k] {
                let s = (v is String) ? (v as! String) : String(describing: v)
                if s.isEmpty { continue }
                out.append("\(k)：\(s)")
            }
        }
        let head = dict["正文开头"] as? String ?? ""
        if !head.isEmpty { out.append("正文开头：\(head)") }
        return out.isEmpty ? "没有诊断信息" : out.joined(separator: "\n")
    }

    /// 👁️ 观测用：把几个 URL 压成一行日志进自检面板。
    ///    URL 可能极长（`data:;base64,…` 载荷动辄几千字符）→ 必须截断，
    ///    否则 300 条日志窗口会被一条撑爆，真正的信息反而看不见了。
    private func logURL(_ tag: String, bookUrl: String, tocUrl: String,
                        bookUrlOfBook: String, bookTocUrl: String = "") {
        func b(_ s: String) -> String {
            if s.isEmpty { return "(空)" }
            return s.count > 200 ? String(s.prefix(200)) + "…[全长\(s.count)]" : s
        }
        let msg = "[Swift·\(tag)] 传入tocUrl=" + b(tocUrl)
            + " | 传入bookUrl=" + b(bookUrl)
            + " | book.tocUrl=" + b(bookTocUrl)
            + " | book.cleanBookUrl=" + b(bookUrlOfBook)
        RuleSandbox.shared.appendLog(msg)
    }

    func bookInfo(source: BookSource, bookUrl: String, fallback: Book? = nil) async throws -> Book {
        var p: [String: Any] = ["bookUrl": bookUrl]
        if let f = fallback { p["book"] = f.rawJSON }
        // 👁️ 观测（2026-10-21 真机 0 章排查）：Swift 侧看到的 URL 是什么形状
        logURL("详情入参", bookUrl: bookUrl,
               tocUrl: fallback?.tocUrl ?? "", bookUrlOfBook: fallback?.cleanBookUrl ?? "")
        let dto: BookInfoDTO = try await call("bookInfo", p, as: BookInfoDTO.self, source: source)
        guard var b = dto.book?.toBook(origin: source.bookSourceUrl, sourceName: source.name) else {
            throw ServiceError.engineFailed("详情页没解析出书名")
        }
        b.origin = source.bookSourceUrl
        b.sourceName = source.name
        b.bookUrl = bookUrl
        b.detailLoaded = true
        if b.tocUrl.isEmpty { b.tocUrl = bookUrl }
        logURL("详情出参", bookUrl: bookUrl, tocUrl: b.tocUrl, bookUrlOfBook: b.cleanBookUrl)
        return b
    }

    /// 目录（只要章节）
    func toc(source: BookSource, tocUrl: String, bookUrl: String, book: Book? = nil) async throws -> [Chapter] {
        try await tocDetailed(source: source, tocUrl: tocUrl, bookUrl: bookUrl, book: book).chapters
    }

    /// 目录 + **诊断信息**（原始条数 / 有没有「书自己」那条占位）
    ///
    /// ⚠️ 2026-10-22 真机「QQ 阅读目录出不来」查出来的：
    ///   大灰狼服务器对**它没抓到章节的书**，`/catalog` 会返回**一条占位**（title = 书名）
    ///   ⇒ 以前被当成 1 个章节、或被报成「chapterList 规则没命中」⇒ **提示是误导的**
    ///   ⇒ 现在把原始条数带回来 ⇒ UI 能说清楚到底是「服务器没数据」还是「规则没命中」
    func tocDetailed(source: BookSource, tocUrl: String, bookUrl: String, book: Book? = nil) async throws -> TocResult {
        var p = json(["tocUrl": tocUrl, "bookUrl": bookUrl, "maxPages": 20])
        // ⚠️⚠️ **必须传 book**！
        //    站方目录 JS（🍅大灰狼的 ruleToc.chapterList）会调
        //    `book.getVariable('custom')` → 没有 book → 站方 JS 直接抛
        //    「Cannot read properties of undefined (reading 'getVariable')」
        //    → **整条目录规则静默失效 → 一条章节都解析不出来**
        if let b = book { p["book"] = b.rawJSON }
        // 👁️ 观测（2026-10-21 真机 0 章排查）：
        //   **重点看 `book.tocUrl` 是不是空的** —— 空的话详情页回退成书籍页，
        //   站方的 `data:;base64,…` 目录载荷就压根没进来。
        logURL("目录入参", bookUrl: bookUrl, tocUrl: tocUrl,
               bookUrlOfBook: book?.cleanBookUrl ?? "", bookTocUrl: book?.tocUrl ?? "")
        let dto: TocDTO = try await call("toc", p, as: TocDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        RuleSandbox.shared.appendLog("[目录出参] 章节数=\(dto.chapters.count)")
        return TocResult(
            chapters: dto.chapters.map {
                Chapter(url: $0.url, title: $0.title, index: $0.index, isVolume: $0.isVolume, tag: $0.tag)
            },
            rawCount: dto.rawCount ?? dto.chapters.count,
            placeholderFiltered: dto.placeholderFiltered ?? false,
            bookName: dto.bookName ?? (book?.name ?? "")
        )
    }

    func content(source: BookSource, chapter: Chapter, book: Book? = nil) async throws -> ContentDTO {
        var p: [String: Any] = ["chapterUrl": chapter.url]
        p["chapter"] = ["title": chapter.title, "url": chapter.url]
        // ⚠️⚠️ **必须传 book**！站方正文 JS（🍅大灰狼的 ruleContent.content）第一句就调
        //    `book.getVariable('custom')` → 没有 book → 站方 JS 抛
        //    「Cannot read properties of undefined (reading 'getVariable')」
        //    → 整条正文规则静默失效 → **正文是空的**（标题倒是对的，那条规则不用 book）
        if let b = book { p["book"] = b.rawJSON }
        let dto = try await call("content", p, as: ContentDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto
    }
}

extension SourceService.BookDTO {
    func toBook(origin: String, sourceName: String) -> Book {
        Book(origin: origin, bookUrl: bookUrl, name: name, author: author, intro: intro,
             kind: kind, group: group, lastChapter: lastChapter, coverUrl: coverUrl, wordCount: wordCount,
             tocUrl: tocUrl, sourceName: sourceName, raw: raw ?? [:], detailLoaded: false)
    }
}

extension Book {
    /// 送进沙盒的原始字典（引擎不认识 Swift 的 Book 类型）
    var rawJSON: [String: Any] {
        // ⭐⭐⭐ **把列表项的原始字段平铺进来**（2026-10-22 真机）
        //   站方 jsLib 生成 `data:;base64,<载荷>` 时要读 **book.book_id** 之类
        //   ⇒ 宿主原先只送九个字段 ⇒ 站方拿不到 ⇒ 载荷只有 {tab,url} ⇒ book_id=undefined
        //      ⇒ 服务器回「illegal base64 data at input byte 9」⇒ 详情/目录全空 ⭐
        var out: [String: Any] = ["bookUrl": bookUrl, "name": name, "author": author, "intro": intro,
         "kind": kind, "group": group, "lastChapter": lastChapter, "coverUrl": coverUrl, "wordCount": wordCount,
         "tocUrl": tocUrl,
         // ⚠️ 必须有 variables —— 站方会调 `book.getVariable('custom')`
         //    （🍅大灰狼的 ruleToc.chapterList / ruleContent.content 都调）
         //    → 没有这个键，wrapBook 的 vars 是空的 → 取不到 → 规则照常跑（返回 ''）
         "variables": [String: String]()]
        for (rk, rv) in raw { if out[rk] == nil { out[rk] = rv } }
        return out
    }
}

// MARK: - ⭐⭐⭐⭐⭐ 真超时的「一次性闸门」（2026-10-25 真机闪退的修法）

/// ⭐⭐⭐ **真超时专用错误**（放在顶层 ⇒ `TimeoutGate` 能引用）
struct TimeoutGateError: LocalizedError {
    /// ⭐ 静态构造（`TimeoutGateError.timedOut` ⇒ 是个**实例**，不是 Bool）
    static let timedOut = TimeoutGateError()
    var errorDescription: String? { "引擎调用超时（站方 JS 卡住或服务器没响应）" }
}

/// ⭐⭐⭐⭐⭐ **一次性 resume 闸门** —— 站方 JS 死循环时，**超时信号必须能独立返回**
///
/// ⚠️⚠️ **为什么不能用 `withThrowingTaskGroup`**：
///   TaskGroup 退出时**必须等所有子任务结束** ⇒ 站方 JS 死循环那个子任务永不结束
///   ⇒ `group.cancelAll()` 救不了它 ⇒ **超时永远不生效**
///   ⇒ 沙盒实测：1 秒超时 ⇒ **实际耗时 8 秒** ⭐⭐⭐
///   ⇒ 站方 JS 死循环在 App 进程内 100% CPU 空转 ⇒ 设备发烫 ⇒ **iOS 热保护杀 App**
///   ⇒ 表现为「闪退」（系统杀的 ⇒ 没有崩溃日志 ⇒ 之前一直查不到）⭐⭐⭐
///
/// ⇒ 本类型：**引擎线程**与**超时定时器**谁先到谁赢 ⇒ 只恢复一次续体
///   ⇒ 卡死的引擎线程**拖不住返回** ⭐⭐⭐
///
/// ⚠️ **必须放在类型里、不能是泛型函数里的嵌套类型**
///   （Swift 报 `type 'X' cannot be nested in generic function` ⇒ 硬编译错误）⭐⭐⭐
final class TimeoutGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var finished = false
    private var timer: DispatchSourceTimer?
    /// ⭐ 超时补救（换掉卡死的会话 / 熔断）
    private let onTimeout: () throws -> Void

    init(onTimeout: @escaping () throws -> Void) { self.onTimeout = onTimeout }

    /// ⭐ 引擎那边完成 ⇒ 尝试恢复
    func succeed(_ value: T) { finish(.success(value)) }
    /// ⭐ 引擎那边抛错 ⇒ 尝试恢复
    func fail(_ error: Error) { finish(.failure(error)) }

    /// ⭐ 超时信号 ⇒ 尝试恢复（**只对尚未完成的那一次生效**）
    func timeout() {
        // ⭐⭐⭐ **超时后先跑补救**（换掉卡死的会话 / 熔断）⇒ 补救抛错就抛那个错
        lock.lock()
        let already = finished
        lock.unlock()
        if !already {
            do {
                try onTimeout()
            } catch {
                finish(.failure(error))
                return
            }
        }
        finish(.failure(TimeoutGate.timeoutError))
    }

    /// ⭐ 超时错误（统一构造 ⇒ 免得各处写不同的文案）
    ///
    /// ⚠️ **不能引用 `SourceService.ServiceError`**（本类型在**类外面** ⇒ 拿不到嵌套类型）
    ///   ⇒ 用一个**自己的错误类型** ⇒ 语义清晰 ⇒ 也不依赖类的嵌套结构 ⭐
    static var timeoutError: Error { TimeoutGateError.timedOut }

    private func finish(_ r: Result<T, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let c = cont
        cont = nil
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        c?.resume(with: r)
    }

    /// 装上 continuation 并起超时定时器
    func arm(_ c: CheckedContinuation<T, Error>, timeout: Double) {
        lock.lock()
        if finished {
            lock.unlock()
            c.resume(throwing: TimeoutGate.timeoutError)
            return
        }
        cont = c
        lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { [weak self] in self?.timeout() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }
}

// MARK: - 视图用的异步包装

/// SwiftUI 里直接 await 引擎，用这个轻量 view model 驱动 loading / error 状态。
@MainActor
final class AsyncLoader: ObservableObject {
    @Published var isLoading = false
    @Published var errorText: String?

    func run<T>(_ work: @escaping () async throws -> T) async -> T? {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do { return try await work() }
        catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Toast.show(errorText ?? "出错了")
            return nil
        }
    }
}
