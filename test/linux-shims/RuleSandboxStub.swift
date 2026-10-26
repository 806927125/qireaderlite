// ============================================================
// ⭐ **RuleSandbox 的最小 stub**（只给签名，不给实现）
//
// ⚠️ **为什么单独一份**（2026-10-26 老引擎恢复）：
//   `Core/RuleSandbox.swift` 现在**又**是那台 WKWebView 壳（1700+ 行 · WebKit/UIKit）
//   ⇒ Linux 的 shim 覆盖不到 ⇒ 它**不进** Linux 类型检查（那一层明说「没验到」）
//   ⇒ ⇒ 但别的文件（SourceService 等）要用到 `RuleSandbox.shared.xxx`
//   ⇒ ⇒ 这里给一份**只有签名**的替身 ⇒ 类型错照样抓得到 ⇒ 真编交给 macOS CI ⭐
// ============================================================
import Foundation

@MainActor
final class RuleSandbox: NSObject, ObservableObject {
    static let shared = RuleSandbox()

    func appendLog(_ message: String) {}
    func boot() {}
    func resetEngine() {}
    func diagnose() -> String { "" }
    func fullLogText() -> String { "" }
    func clearLogs() {}
    func probePlainHTTP() async -> String { "" }
    func invoke(_ op: String, _ payload: [String: Any] = [:],
                source: BookSource? = nil) async throws -> Any { [:] }
    var recentLogs: [String] { [] }
    var ready: Bool { true }
    var statusText: String { "" }
}

/// ⭐ `Toast` 的 stub（真身也在 RuleSandbox.swift 里 ⇒ 那份不进 Linux 类型检查 ⇒ 这里补签名）
enum Toast {
    static func show(_ text: String) {}
}
