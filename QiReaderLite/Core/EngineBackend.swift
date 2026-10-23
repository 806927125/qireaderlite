import Foundation

/// ⭐⭐ **引擎后端标识** —— 让用户一眼看出「现在跑的是哪个引擎」。
///
/// ⚠️ 背景：新引擎（`legado-engine`，Swift 自研）已作为 SPM 依赖编进 App。
/// ⇒ 这个标识就是「替换进度」的**可见仪表盘**。
///
/// ⭐ 取值：
/// - `legacyJS` ⇒ 老 JS 引擎（WKWebView）
/// - `swiftNew` ⇒ 新 Swift 引擎（legado-engine）—— **当前**
public enum EngineBackend {
    public enum Kind: String {
        case legacyJS = "老 JS 引擎（WKWebView）"
        case swiftNew = "新 Swift 引擎（legado-engine）"
    }

    private static let key = "qr.engineBackend"

    /// 当前后端
    public static var current: Kind {
        get { Kind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .swiftNew }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// ⭐⭐⭐ **是否走新引擎**（开关）
    ///
    /// ⚠️ **默认 = 开**（2026-10-23：老引擎已被完全替换 ⇒ 主链路走新引擎）
    /// ⇒ 用户可以手动关掉，回到老引擎（出问题时有个退路）。
    public static var useNewEngine: Bool {
        get {
            // ⚠️ **没写过这个键 ⇒ 默认 true**（UserDefaults.bool 默认 false ⇒ 必须自己判）
            if UserDefaults.standard.object(forKey: "qr.useNewEngine") == nil { return true }
            return UserDefaults.standard.bool(forKey: "qr.useNewEngine")
        }
        set { UserDefaults.standard.set(newValue, forKey: "qr.useNewEngine") }
    }

    /// ⭐⭐ **新引擎失败时要不要回退老引擎**
    ///
    /// ⚠️ 默认 **开**（安全网）⇒ 新引擎跑不通的源，老引擎还能出结果 ⇒ App 不会变成砖。
    /// ⇒ 关掉它 = **纯新引擎**（新引擎报错就报错，不兜底）。
    public static var fallbackToLegacy: Bool {
        get {
            if UserDefaults.standard.object(forKey: "qr.fallbackLegacy") == nil { return true }
            return UserDefaults.standard.bool(forKey: "qr.fallbackLegacy")
        }
        set { UserDefaults.standard.set(newValue, forKey: "qr.fallbackLegacy") }
    }

    // MARK: - ⭐⭐⭐ 三件**必须分开显示**的事（2026-10-23 用户实测踩出来的）

    /// **① 新引擎开关**（用户设的）
    public static var switchState: String { useNewEngine ? "已开启" : "已关闭" }

    /// **② 当前是谁在服务**（上一次 op 实际走的引擎）
    public static var servingText: String {
        current == .swiftNew ? "新 Swift 引擎" : "老 JS 引擎"
    }

    /// **③ 最后一次新引擎的失败原因**（回退时才有 ⇒ 其它时候为 nil）
    ///
    /// ⭐ 没有它 ⇒ 用户只看到「老引擎在服务」⇒ **不知道是开关关了还是新引擎坏了**
    /// ⇒ 而这两种情况的处理方式**完全相反**（一个去开开关，一个去修引擎）⭐
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

    /// ⭐⭐⭐ **三行状态**（开关 / 当前服务 / 失败原因）—— **各管各的，别混成一句**
    ///
    /// ⚠️⚠️ **为什么必须分开**（2026-10-23 用户实测踩出来的）：
    ///   只写一句「老 JS 引擎」⇒ 用户以为**开关被关了** ⇒ 去开开关
    ///   ⇒ 实际是「新引擎**开着**但这次失败回退了」⇒ **该去修引擎，不是去开开关**⭐
    ///   ⇒ 两种情况的处理方式**完全相反** ⇒ 必须能一眼分开
    public static func statusLines() -> [StatusLine] {
        var out: [StatusLine] = []
        out.append(StatusLine(label: "新引擎开关", value: switchState))
        out.append(StatusLine(label: "当前服务", value: servingText))
        if useNewEngine, let e = lastError, !e.isEmpty {
            out.append(StatusLine(label: "失败原因", value: e, isError: true))
        }
        return out
    }

    /// 一行说明（给 UI 显示）—— ⭐ **短版**（测书源面板那行）
    public static var description: String {
        guard useNewEngine else {
            return "老 JS 引擎（WKWebView）· 新引擎开关已关"
        }
        if current == .swiftNew {
            return "新 Swift 引擎（legado-engine）· 运行中"
        }
        // ⚠️ 新引擎开着，但这次是老引擎在服务 ⇒ **说明发生了回退**
        if fallbackToLegacy {
            return "新 Swift 引擎 · 已开启，但本次**回退老引擎**"
        }
        return "新 Swift 引擎 · 已开启（纯新引擎，无回退）"
    }
}
