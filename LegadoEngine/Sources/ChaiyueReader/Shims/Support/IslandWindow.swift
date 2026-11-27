#if os(iOS)
// ⭐⭐⭐⭐⭐ **【平台守卫】本文件的依赖只在 iOS 存在**（2026-11-26）⭐⭐⭐⭐⭐
//   ⚠️ **为什么**：`LegadoEngine`（宿主门面模块）现在依赖 `ChaiyueReader`
//     ⇒ ⇒ **macOS / Linux 上会编译 `ChaiyueReader` 模块**（以前只编 iOS ⇒ 没暴露）⭐⭐⭐
//   ⇒ 而本文件引用的类型（Toast 等）在那些平台**不存在** ⇒ 编译失败 ⭐⭐⭐
//   ⇒ 正解：**把本文件也圈进 iOS** ⇒ 各平台一致 ⭐⭐⭐
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Shell/IslandWindow.swift 搬运（降级版）**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Shell/IslandWindow.swift
//
// ⭐⭐⭐⭐⭐ **降级说明（与上游的 diff）**⭐⭐⭐⭐⭐
//   柴阅的 `IslandWindow` 是**壳层的一个 `UIWindow` 浮层**（灵动岛/Toast 的宿主窗口）
//   ⇒ 它属于 App 的 Shell 层，**不在阅读器范围** ⇒ 整个搬进来会拖进窗口管理/动画等一大堆壳层代码 ⭐⭐⭐
//   ⇒ 这里只保留**阅读器用到的那一个接口** `raise()`，并做成**宿主可注入的钩子** ⭐⭐⭐
//     · 默认：空实现（阅读器里的 toast 不会弹窗，但**不崩**）⭐⭐⭐
//     · 宿主想显示 toast：给 `IslandWindow.raiser` 赋一个闭包即可 ⭐⭐⭐
import Foundation

/// 柴阅「灵动岛」浮层窗口的最小替身（宿主可注入自己的实现）
public enum IslandWindow {
    /// 宿主注入：把 toast 弹到自己的窗口上
    public static var raiser: (() -> Void)?

    static func raise() {
        raiser?()
    }
}
#endif  // #if os(iOS)
