import Foundation

/// ⭐⭐ **引擎后端标识** —— 让用户一眼看出「现在跑的是哪个引擎」。
///
/// ⚠️ 背景：新引擎（`legado-engine`，Swift 自研）已作为 SPM 依赖编进 App，
/// 但**主链路暂时仍走老的 JS 引擎**（`Resources/engine/*.js`，源码保留）。
/// ⇒ 这个标识就是「替换进度」的**可见仪表盘**。
///
/// ⭐ 取值：
/// - `legacyJS` ⇒ 老 JS 引擎（WKWebView）—— **当前**
/// - `swiftNew` ⇒ 新 Swift 引擎（legado-engine）
public enum EngineBackend {
    public enum Kind: String {
        case legacyJS = "老 JS 引擎（WKWebView）"
        case swiftNew = "新 Swift 引擎（legado-engine）"
    }

    private static let key = "qr.engineBackend"

    /// 当前后端（默认老 JS 引擎）
    public static var current: Kind {
        get { Kind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .legacyJS }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// **是否走新引擎**（开关）
    public static var useNewEngine: Bool {
        get { UserDefaults.standard.bool(forKey: "qr.useNewEngine") }
        set { UserDefaults.standard.set(newValue, forKey: "qr.useNewEngine") }
    }

    /// 一行说明（给 UI 显示）
    public static var description: String {
        "\(current.rawValue)\(useNewEngine && current == .legacyJS ? "（开关已开 · 待接线）" : "")"
    }
}
