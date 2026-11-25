// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/DebugLaunch.swift 搬运（**仅取阅读器用到的 `flag`**）**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/DebugLaunch.swift
//
// ⭐⭐⭐⭐⭐ **搬运范围说明（与上游的 diff）**⭐⭐⭐⭐⭐
//   柴阅的 `DebugLaunch.run(_ app:)` 是**整个 App 的调试启动器**（导入种子书源/书籍、切标签页、跳路由、
//   跑本地语音测速 …）⇒ 依赖 `MainTab` / `Route` / `app.library.search` / `app.importFile` 等**整个 App 层** ⭐⭐⭐
//   ⇒ 我们只 vendor 了阅读器 ⇒ **只搬运阅读器真正用到的 `flag(_:)`**（`-readerMenu` / `-readerPanel` / `-chapter` …）⭐⭐⭐
//   ⇒ `run(_:)` 的能力（App 级调试入口）请宿主 App 自己接 ⭐⭐⭐
import Foundation

enum DebugLaunch {
    /// 读启动参数：`-chapter 3` / `-readerMenu 1` / `-readerPanel style|toc` / `-autoTurn 1` / `-speak 1`
    static func flag(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-" + key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
