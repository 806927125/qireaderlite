import Foundation

// =============================================================================
// ⭐⭐⭐⭐⭐ **柴阅的「调试启动器」最小实现**（2026-11-26）⭐⭐⭐⭐⭐
//
// ⚠️ 柴阅阅读器里用到它的**只有一处能力**：读启动参数
//   `DebugLaunch.flag("chapter")` / `flag("readerPanel")` / `flag("autoTurn")` /
//   `flag("selectAt")` / `flag("speak")` / `flag("loginAction")` / `flag("loginKey")` …⭐⭐⭐
// ⇒ 轻阅**没有**那套「调试启动器」（它是柴阅开发期的 App 内调试面板）⭐⭐⭐
//   ⇒ 所以：**只保留 `flag(_:)` 这一面，恒返回 nil** ⇒ 阅读器走正常路径 ⭐⭐⭐
//   ⇒ 原 shim 里那一整套 App 层调试 UI（标签栏/搜索路由/本地导入…）**全部删掉**
//     —— 它们会拖进 `SearchBook`/`Route`/搜索服务等一整串我们用不到的东西 ⭐⭐⭐
//
// ✅ 保留 `MainTab` 类型面（别的 shim/宿主可能引用）⭐⭐⭐
// =============================================================================

#if os(iOS)

/// 柴阅的调试启动器（轻阅：只保留读启动参数这一面）
enum DebugLaunch {
    /// 读一个启动参数；轻阅没有调试启动器 ⇒ 恒 nil ⭐⭐⭐
    static func flag(_ name: String) -> String? { nil }
}

/// 柴阅的标签栏枚举（App 层；轻阅阅读器用不到 ⇒ 保留类型面）⭐⭐⭐
enum MainTab: Int, CaseIterable, Identifiable {
    case shelf, explore, me

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .shelf: "书架"
        case .explore: "发现"
        case .me: "我的"
        }
    }
}

#endif  // #if os(iOS)
