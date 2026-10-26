import Foundation

/// ⭐⭐⭐ **引擎标识** —— **老引擎（WKWebView）回来了**（2026-10-26）
///
/// ⭐⭐⭐ **为什么换回来**：新引擎把站方 JS 搬进了 **App 进程**（JSC）⇒
///   ① 站方脚本的每一次分配都算 **App 进程**的 ⇒ 一次 op 就能把进程顶到 GB 级 ⇒ jetsam 秒杀（闪退 + 没有 .ips）⭐⭐⭐
///   ② JSC 的 **VM 会抓住跑过脚本的 context** ⇒ `invalidate()` 放不掉 ⇒ 「清会话后内存不降」⭐⭐⭐
/// ⇒ 而**老引擎的规则求值全在 WKWebView 的 WebContent 独立进程**里 ⇒
///   ⇒ **App 进程压根不碰站方数据** ⇒ 内存有界 ⇒ 一直免疫这类闪退 ⭐⭐⭐
///
/// ⭐⭐⭐ **老引擎原样接回**（2026-10-25 物理删除、2026-10-26 恢复）：
///   · `RuleSandbox.swift` 的 WKWebView 壳（1727 行）
///   · `Resources/engine/` 的 12 个 JS + `engine.html`（规则解释器全在里面）
///   · `window.prompt` 同步通道（`__qrSync`）
///   ⇒ **op 词汇与新引擎完全一致**（`sourceVars` / `sourceHosts` / `exploreKinds` / `explore` /
///     `search` / `bookInfo` / `toc` / `content` / `login` / `loginProbe`）⇒ 可直接切换 ⭐⭐⭐
///
/// ⚠️ **JSC 已从 App 里彻底移除**（2026-10-26 用户明确：「JSC 给我彻底删掉」）
///   ⇒ 新引擎若被选中，它的 JS 后端也**只走 WKWebView**（`WebViewJSExecutor`）⇒ App 里再无 JSC ⭐⭐⭐
public enum EngineBackend {
    private static let key = "qr.engineBackend"

    /// 当前后端
    public enum Kind: String {
        case legacyJS = "老 JS 引擎（WKWebView·独立进程）"
        case swiftNew = "新 Swift 引擎（legado-engine · JS 也在 WKWebView）"
    }

    /// ⭐ 当前后端（**默认老引擎** ⇒ 进程隔离 ⇒ 闪退免疫）
    public static var current: Kind {
        get { Kind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .legacyJS }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// ⭐⭐⭐ **用哪个引擎**（默认 **老引擎**）
    public static var useNewEngine: Bool {
        get {
            if UserDefaults.standard.object(forKey: "qr.useNewEngine") == nil { return false }
            return UserDefaults.standard.bool(forKey: "qr.useNewEngine")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "qr.useNewEngine")
            current = newValue ? .swiftNew : .legacyJS
        }
    }

    /// 失败时自动回退老引擎（老引擎一直更稳 ⇒ 默认开）
    public static var fallbackToLegacy: Bool {
        get {
            if UserDefaults.standard.object(forKey: "qr.fallbackLegacy") == nil { return true }
            return UserDefaults.standard.bool(forKey: "qr.fallbackLegacy")
        }
        set { UserDefaults.standard.set(newValue, forKey: "qr.fallbackLegacy") }
    }

    // MARK: - ⭐⭐⭐ 三件**必须分开显示**的事（各管各的，别混成一句）

    /// **① 引擎**（可切换：老引擎 / 新引擎）
    public static var switchState: String { useNewEngine ? "新 Swift 引擎" : "老 JS 引擎（WKWebView）" }

    /// **② 当前是谁在服务**
    public static var servingText: String { current == .swiftNew ? "新 Swift 引擎" : "老 JS 引擎（WKWebView）" }

    /// **③ 最后一次失败原因**（没有它 ⇒ 用户只看到「引擎在服务」⇒ 不知道出了什么事）
    public static var lastError: String? {
        get { ErrorBox.shared.value }
        set { ErrorBox.shared.value = newValue }
    }

    /// 线程安全的单值盒（引擎在后台线程写、UI 在主线程读）
    private final class ErrorBox: @unchecked Sendable {
        static let shared = ErrorBox()
        private let lock = NSLock()
        private var v: String?
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    // MARK: - ⭐⭐⭐ UI 用的「状态行」（放 Core ⇒ 沙盒能真编真跑 + 能写门禁）

    /// 一行状态
    public struct StatusLine: Sendable, Equatable {
        public let label: String
        public let value: String
        /// ⭐ 这一行是不是**错误**（UI 用红色）
        public let isError: Bool
        public init(label: String, value: String, isError: Bool = false) {
            self.label = label; self.value = value; self.isError = isError
        }
    }

    /// ⭐⭐⭐ **状态行**（引擎 / 失败原因）—— **各管各的**
    public static func statusLines() -> [StatusLine] {
        var out: [StatusLine] = []
        out.append(StatusLine(label: "引擎", value: servingText))
        if let e = lastError, !e.isEmpty {
            out.append(StatusLine(label: "失败原因", value: e, isError: true))
        }
        return out
    }

    /// 一行说明（给 UI 显示）—— ⭐ **短版**（测书源面板那行）
    public static var description: String {
        if let e = lastError, !e.isEmpty {
            return "\(servingText) · 上次失败：\(e.prefix(40))"
        }
        return "\(servingText) · 运行中"
    }
}
