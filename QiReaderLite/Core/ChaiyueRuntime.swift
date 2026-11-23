import Foundation
import LegadoEngine
#if canImport(WebKit) && !os(Linux)
import UIKit
#endif

// ⭐⭐⭐⭐⭐ **柴阅引擎的运行环境**（2026-11-21 移植柴阅/Chaiyue）
//
// ⚠️⚠️⚠️ **为什么必须有这一层**：
//   柴阅把书源状态写进 `KeyValueStore`，键名是 `cache_sourceVariable_<源URL>` /
//   `cache_v_<源URL>_<变量名>` / `cache_userInfo_<源URL>` ⭐⭐⭐
//   而轻阅的状态在 **UserDefaults 的几个槽**（`sourcevars.` / `sourcevariable.` / `sourcelogin.`）⭐⭐⭐
//   ⇒ 两边**键结构与值的形态都不同** ⇒ 必须有一层明确映射 ⭐⭐⭐
//   ⇒ ⚠️ **漏映射的后果极隐蔽**：解锁态存不下来 ⇒ 下次又是未解锁 ⇒ **发现页 0 分类**
//     （这正是 build297–302 反复踩的坑）⇒ 这一层**必须有门禁**⭐⭐⭐
//
// ⭐⭐⭐ **放在 Core/ 而不是 UI/** ⇒ UI 一行都不用改（用户明确要求）⭐⭐⭐
enum ChaiyueRuntime {

    // MARK: - 单例（引擎环境整个 App 共享一个 ⇒ 状态与缓存都共享）

    /// ⭐⭐⭐ **持久化后端**（⇒ 柴阅的书源变量/登录信息都落在这儿 ⇒ 跨会话保持）⭐⭐⭐
    ///
    /// ⚠️ **必须是同一个实例**（环境用它、宿主也用它 ⇒ 否则两套状态）⭐⭐⭐
    static let store: ChaiyueKeyValueStore = makeStore()

    /// ⭐⭐⭐ **引擎环境**（HTTP / Cookie / 缓存 / 变量存储 的持有者）⭐⭐⭐
    ///
    /// ⚠️⚠️ **初始化顺序**（`static let` 是惰性的 ⇒ 首次访问才构造）⭐⭐⭐
    ///   `store` 不依赖 `environment` ⇒ 先就绪；`environment` 依赖 `store` ⇒ 没问题 ⭐⭐⭐
    ///   ⚠️ **但 `androidID` 依赖 `environment`** ⇒ 它必须是 **computed**（不能是 `static let`）
    ///     ⇒ 否则会形成 **初始化循环** ⇒ 编译期死锁/崩溃 ⭐⭐⭐
    static let environment: LegadoEngineHost.Environment = {
        let env = LegadoEngineHost.Environment(store: store)
        // ⭐⭐⭐⭐⭐ **把引擎内部日志接进 App 的日志面板**（2026-11-24 真机「Token 格式错误」排查）⭐⭐⭐
        //   引擎自己会打：「ajax(...) error」「loginUi 脚本出错」「≡链接为详情页」…⭐⭐⭐
        //   ⇒ **以前这些日志全丢**（宿主没接 logger）⇒ 登录失败/请求失败时**没有任何证据**⭐⭐⭐
        //   ⇒ 现在：引擎的日志面板里能直接看到 ⇒ 真机一次就能定位 ⭐⭐⭐
        //   ⚠️ **回调来自后台线程** ⇒ `EngineLogPanel` 是 `@MainActor` ⇒ 必须切主线程 ⭐⭐⭐
        env.setLogger { key, message in
            Task { @MainActor in EngineLogPanel.shared.appendLog("[\(key)] \(message)") }
        }
        return env
    }()

    /// ⭐⭐⭐⭐⭐ **装上柴阅的界面委托**（浏览器 / 验证码 / 后台渲染 / toast …）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么是独立的方法（不是 environment 的 init 里）** ⭐⭐⭐
    ///   `platformUI` 需要 `environment`，而 `environment` 若在这里就装 delegate ⇒ **初始化循环** 💥⭐⭐
    ///   ⇒ 所以拆开：App 启动时调一次 `installUI()` ⇒ 站方第一次要浏览器之前一定装好了 ⭐⭐⭐
    @MainActor
    static func installUI() {
        #if canImport(WebKit) && !os(Linux)
        environment.setUIDelegate(platformUI)
        #endif
    }

    /// ⭐⭐⭐ **androidID**（柴阅用它派生登录信息的加密密钥）⭐⭐⭐
    ///
    /// ⚠️⚠️ **必须与柴阅自己算的完全一致**（否则登录信息解不开）⭐⭐⭐
    ///   柴阅的算法：`String(Hex.encode(SHA256(deviceID))).prefix(16)` ⇒ 16 个 hex 字符 ⭐⭐⭐
    ///   ⚠️ **这里从 `environment.androidID` 直接取**（不自己算 ⇒ 不会漂移）⭐⭐⭐
    ///   ⚠️ 必须是 **computed**（`static let` 会与 `environment` 形成初始化循环）⭐⭐⭐
    static var androidID: String { environment.androidID }

    // MARK: - ⭐⭐⭐⭐⭐ 线路变量的【备份 / 复位 / 恢复】（explore 失败自愈用）

    /// ⭐⭐⭐ **线路变量名**（站方把「当前线路」写在哪）
    /// ⚠️ 不同源叫法不同：`server`（大灰狼）、`jmHost`（禁漫天堂）… ⇒ ⇒ 都试 ⭐⭐⭐
    static let lineVarNames = ["server", "jmHost", "host", "nhDlhHost"]

    /// ⭐⭐⭐ **备份当前线路变量**（自愈失败时要恢复）⭐⭐⭐
    static func takeLineBackup(for sourceUrl: String) -> [String: String] {
        let vars = SourceVariables.varsMap(for: sourceUrl)
        var out: [String: String] = [:]
        for k in lineVarNames { if let v = vars[k], !v.isEmpty { out[k] = v } }
        return out
    }

    /// ⭐⭐⭐ **清掉线路变量**（⇒ 站方回落**默认主站**）⭐⭐⭐
    @discardableResult
    static func resetLineVars(for sourceUrl: String) -> Bool {
        let vars = SourceVariables.varsMap(for: sourceUrl)
        var changed = false
        for k in lineVarNames where vars[k] != nil {
            SourceVariables.setSourceVarItem(k, "", for: sourceUrl)
            changed = true
        }
        return changed
    }

    /// ⭐⭐⭐ **恢复线路变量**（自愈失败时用）⭐⭐⭐
    static func restoreLineBackup(_ backup: [String: String], for sourceUrl: String) {
        for (k, v) in backup { SourceVariables.setSourceVarItem(k, v, for: sourceUrl) }
    }

    // MARK: - ⭐⭐⭐ 登录配套设施（柴阅的 ReaderPlatform）

    #if canImport(WebKit) && !os(Linux)
    /// ⭐⭐⭐⭐⭐ **柴阅的 `PlatformSourceUI`**（= `SourceUIDelegate` 的完整实现）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么必须有它**（2026-11-21 移植柴阅的登录配套设施）⭐⭐⭐
    ///   柴阅的引擎把「浏览器 / 验证码 / 后台渲染 / toast / 复制 / 外链 / 视频」交给宿主 ⭐⭐⭐
    ///   ⇒ 轻阅之前**没有实现这个委托** ⇒ 站方登录要开浏览器/要验证码时 ⇒ **静默失败** ⭐⭐⭐
    ///   ⇒ 聚合源的「🍅番茄登录 / 🔐注册书源 / 🏝用户后台」**全是浏览器流程** ⭐⭐⭐
    ///     ⇒ 浏览器不工作 ⇒ 拿不到 token/cookie ⇒ **登录永远失败** ⭐⭐⭐
    /// ⇒ 现在：柴阅的默认实现（后台 WKWebView 渲染 + Cookie 同步）+ 轻阅的 UI presenter ⭐⭐⭐
    // ⚠️⚠️⚠️ **必须 `@MainActor`**（2026-11-21 CI 实证）⭐⭐⭐
    //   柴阅的 `presenter` 是 `@MainActor` 属性 ⇒ 在非隔离上下文赋值 ⇒ **编译错误** ⭐⭐⭐
    //   ⇒ 整个 `platformUI` 的初始化也必须在主线程 ⇒ 标 `@MainActor`（static let 惰性 ⇒ 安全）⭐⭐⭐
    @MainActor
    static let platformUI: LegadoEngineHost.PlatformUI = {
        let ui = LegadoEngineHost.PlatformUI(environment: environment)
        ui.presenter = ChaiyueInteractionPresenter.shared
        // ⚠️ toast ⇒ 走轻阅的 Toast（站方登录结果就是用 toast 报的）⭐⭐⭐
        ui.onToast = { message, _ in
            Task { @MainActor in Toast.show(message) }
        }
        return ui
    }()

    /// ⭐⭐⭐ **当前能弹窗的顶层控制器**（验证码弹窗用）⭐⭐⭐
    static var topPresenter: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }

    /// ⭐⭐⭐ **后台渲染一段 HTML**（站方 `java.startBrowser(html)` 场景）⭐⭐⭐
    static func renderWebView(html: String, url: String?, js: String?, sourceKey: String) -> String? {
        let req = LegadoEngineHost.WebViewRequest(html: html, url: url, js: js, sourceKey: sourceKey)
        return try? platformUI.renderWebView(req)
    }
    #endif

    // MARK: - 存储适配

    /// ⭐⭐⭐ **构造 store**（把轻阅的槽接给柴阅）⭐⭐⭐
    private static func makeStore() -> ChaiyueKeyValueStore {
        ChaiyueKeyValueStore(
            readSlot: { readSlot($0) },
            writeSlot: { writeSlot($0, $1) },
            listAllSourceVars: { allSourceVars() },
            listPlainCacheKeys: { prefix in
                UserDefaults.standard.dictionaryRepresentation().keys
                    .filter { $0.hasPrefix(cachePrefix) && $0.hasPrefix(prefix) }
                    .map { String($0.dropFirst(cachePrefix.count)) }
            },
            loginInfoToChaiyue: { plain in loginInfoToChaiyue(plain) },
            loginInfoFromChaiyue: { stored in loginInfoFromChaiyue(stored) }
        )
    }

    /// ⭐⭐⭐ **读槽**（柴阅键 ⇒ 轻阅槽）⭐⭐⭐
    static func readSlot(_ slot: ChaiyueKeyValueStore.SlotRef) -> String? {
        switch slot {
        case .stationVariable(let sourceKey):
            // ⭐⭐⭐ 站方变量 = **一整串**（Legado 语义）⭐⭐⭐
            let v = SourceVariables.variable(for: sourceKey)
            return v.isEmpty ? nil : v
        case .sourceVar(let sourceKey, let name):
            // ⭐⭐⭐ 书源变量 = 轻阅那边存的是**一个 JSON map** ⇒ 取其中一项 ⭐⭐⭐
            let v = SourceVariables.varsMap(for: sourceKey)[name] ?? ""
            return v.isEmpty ? nil : v
        case .loginInfo(let sourceKey):
            let v = SourceVariables.loginInfoJSON(for: sourceKey)
            return v.isEmpty ? nil : v
        case .loginHeader(let sourceKey):
            let v = SourceVariables.loginHeader(for: sourceKey)
            return v.isEmpty ? nil : v
        case .deviceID:
            return UserDefaults.standard.string(forKey: deviceIDKey)
        case .plainCache(let key), .opaque(let key):
            return UserDefaults.standard.string(forKey: cachePrefix + key)
        }
    }

    /// ⭐⭐⭐ **写槽**（轻阅槽 ← 柴阅值）⭐⭐⭐
    static func writeSlot(_ slot: ChaiyueKeyValueStore.SlotRef, _ value: String?) {
        switch slot {
        case .stationVariable(let sourceKey):
            SourceVariables.setVariable(value ?? "", for: sourceKey)
        case .sourceVar(let sourceKey, let name):
            // ⚠️⚠️ **单写一项**（保留其它项 ⇒ 走 SourceVariables 的专用方法）⭐⭐⭐
            SourceVariables.setSourceVarItem(name, value ?? "", for: sourceKey)
        case .loginInfo(let sourceKey):
            SourceVariables.setLoginInfoJSON(value ?? "", for: sourceKey)
        case .loginHeader(let sourceKey):
            SourceVariables.setLoginHeader(value ?? "", for: sourceKey)
        case .deviceID:
            UserDefaults.standard.set(value, forKey: deviceIDKey)
        case .plainCache(let key), .opaque(let key):
            UserDefaults.standard.set(value, forKey: cachePrefix + key)
        }
    }

    /// ⭐⭐⭐ **枚举全部书源变量**（源 URL + 变量名）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么要全量枚举**（而不是按源查）：
    ///   柴阅用 `keys(withPrefix: "cache_v_<源URL>_")` 枚举 ⇒ 要**从前缀反推源 URL** ⭐⭐⭐
    ///   ⚠️ 但**源 URL 里可能含下划线** ⇒ 反推**有歧义** ⇒ 全量枚举 + 前缀过滤才无歧义 ⭐⭐⭐
    static func allSourceVars() -> [(sourceKey: String, name: String)] {
        var out: [(sourceKey: String, name: String)] = []
        for sourceUrl in SourceVariables.allSourceUrls() {
            for name in SourceVariables.varsMap(for: sourceUrl).keys {
                out.append((sourceKey: sourceUrl, name: name))
            }
        }
        return out
    }

    // MARK: - loginInfo 的形态转换（柴阅存**密文**、轻阅存**明文 JSON**）

    /// ⭐⭐⭐ **明文 ⇒ 柴阅形态**（Base64 密文）⭐⭐⭐
    static func loginInfoToChaiyue(_ plain: String) -> String {
        #if canImport(JavaScriptCore) && !os(Linux)
        return (try? LegadoEngineHost.LoginCrypto.encrypt(plain, androidID: androidID)) ?? plain
        #else
        return plain
        #endif
    }

    /// ⭐⭐⭐ **柴阅形态 ⇒ 明文**⭐⭐⭐
    static func loginInfoFromChaiyue(_ stored: String) -> String {
        #if canImport(JavaScriptCore) && !os(Linux)
        return (try? LegadoEngineHost.LoginCrypto.decrypt(stored, androidID: androidID)) ?? stored
        #else
        return stored
        #endif
    }

    // MARK: - 常量

    /// 柴阅的设备 ID 键（轻阅侧持久化位置）
    static let deviceIDKey = "qr.chaiyue.deviceID"
    /// 柴阅「其它缓存」在轻阅侧的命名空间
    static let cachePrefix = "qr.chaiyue.cache."
}
