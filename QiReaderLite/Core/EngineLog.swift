import Foundation

/// ⭐⭐⭐ **引擎日志出口**（独立文件 ⇒ 纯 Foundation 的门禁也能编 ⇒ 诊断能进面板）
///
/// ⚠️ **为什么要做成「闭包出口」**（2026-10-28）：
///   诊断要能被**隔离编译**的那层（`Core/SourceVariables.swift`）调用
///   ⇒ 而 `RuleSandbox` 依赖 UIKit ⇒ 隔离编译编不动 ⇒ 不能直接依赖它 ⭐⭐⭐
///   ⇒ 这里只留一个出口；App 启动时把真正的「写进引擎日志面板」挂上 ⭐⭐⭐
enum EngineLog {
    /// App 侧挂上（写进「引擎日志」面板 ⇒ 用户能直接看到）
    static var sink: ((String) -> Void)?
    static func write(_ message: String) {
        if let sink { sink(message) } else { NSLog("%@", message) }
    }
}

/// ⭐⭐⭐ **引擎日志**（App 内部统一用这个 ⇒ 别处直接用 NSLog ⇒ 用户看不到）
func engineLog(_ message: String) {
    EngineLog.write(message)
}
