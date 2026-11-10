import Foundation

/// ⭐⭐⭐⭐⭐ **引擎模式**（2026-11-10 · 按「阅读2.0（YueduReader）」的架构重做引擎）
///
/// 两条引擎通路：
/// - `.webView` = **WebView 引擎**（`Core/RuleSandbox.swift` + `Resources/engine/*.js`）
///   ⇒ 架构与阅读2.0 同款：**Swift 宿主 + WebView 内规则求值 + 原生只传/收字符串**
///   ⇒ 站方 JS 跑在**独立 WebContent 进程** ⇒ 站方脚本再野也不占 App 进程 ⭐⭐⭐
///   ⇒ 原生侧只做：网络 / 存储 / 宿主 API（java.* / source.* / cookie.* / cache.*）
/// - `.swiftEngine` = **自研 Swift 引擎**（legado-engine）⇒ 保留作**回退**
///
/// ⚠️ 两条通路的**返回契约必须一致**（都有 `__sourceVars` / `__sourceVariable` /
///   `__sourceVariableChanged`）⇒ 否则「站方变量形态证据」会失效（证据自证 ⇒ 污染清不掉）。
enum EngineMode: String {
    case webView
    case swiftEngine

    /// ⭐ UserDefaults 键（自检面板里可一键切）
    static let defaultsKey = "qr.engine.mode"

    /// ⭐⭐⭐ **当前模式**（默认 = WebView 引擎 = 阅读2.0 同款架构）
    static var current: EngineMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return .webView }
            return EngineMode(rawValue: raw) ?? .webView
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// ⭐ 面板上显示的名字
    static var label: String {
        switch current {
        case .webView: return "WebView 引擎（阅读2.0 同款）"
        case .swiftEngine: return "自研 Swift 引擎"
        }
    }

    /// ⭐ 是否是 WebView 引擎（接线层只问这一句 ⇒ 以后加第三条路也只改这一处）
    static var usesWebViewEngine: Bool { current == .webView }
}
