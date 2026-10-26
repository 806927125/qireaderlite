import Foundation

/// ⭐⭐ **引擎标识** —— 现在**只有一个引擎**（新 Swift 引擎 `legado-engine`）。
///
/// ⭐⭐⭐ **老 JS 引擎（WKWebView）已于 2026-10-25 退役**（用户明确要求：「老引擎给我去掉先」）
/// ⇒ 「用哪个引擎」的开关、「失败自动回退」的开关 ⇒ **全部删除** ⇒ 用户不再需要操心这件事 ⭐⭐⭐
///
/// ⚠️ **唯一残留**：`login` / `loginProbe` 两个 op（站方登录）**暂时**还跑在老引擎的 WKWebView 上
/// ⇒ 它们迁到新引擎后 ⇒ `RuleSandbox.swift` 的 WKWebView 壳 + `Resources/engine/*.js` 一并物理删除 ⭐⭐⭐
public enum EngineBackend {
    private static let key = "qr.engineBackend"

    /// 当前后端（**只有新引擎** ⇒ 恒为 `.swiftNew`）
    public enum Kind: String {
        case swiftNew = "新 Swift 引擎（legado-engine）"
    }

    /// 当前后端
    public static var current: Kind { .swiftNew }

    // MARK: - ⭐⭐⭐ 三件**必须分开显示**的事（各管各的，别混成一句）

    /// **① 引擎**（只有一个 ⇒ 恒为新引擎）
    public static var switchState: String { "新 Swift 引擎（legado-engine）" }

    /// **② 当前是谁在服务**
    public static var servingText: String { "新 Swift 引擎" }

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
            return "新 Swift 引擎（legado-engine）· 上次失败：\(e.prefix(40))"
        }
        return "新 Swift 引擎（legado-engine）· 运行中"
    }
}
