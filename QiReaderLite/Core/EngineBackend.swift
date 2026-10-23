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

    /// ⭐ **新引擎失败时要不要回退老引擎**
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

    /// 一行说明（给 UI 显示）
    public static var description: String {
        var s = current.rawValue
        if useNewEngine && current == .legacyJS { s += "（开关已关 · 走的是老引擎）" }
        if useNewEngine && fallbackToLegacy { s += " · 失败回退老引擎" }
        return s
    }
}
