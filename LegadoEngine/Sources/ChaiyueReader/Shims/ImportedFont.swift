#if os(iOS)
// ⭐⭐⭐⭐⭐ **【平台守卫】本文件的依赖只在 iOS 存在**（2026-11-26）⭐⭐⭐⭐⭐
//   ⚠️ **为什么**：`LegadoEngine`（宿主门面模块）现在依赖 `ChaiyueReader`
//     ⇒ ⇒ **macOS / Linux 上会编译 `ChaiyueReader` 模块**（以前只编 iOS ⇒ 没暴露）⭐⭐⭐
//   ⇒ 而本文件引用的类型（FontStore 等）在那些平台**不存在** ⇒ 编译失败 ⭐⭐⭐
//   ⇒ 正解：**把本文件也圈进 iOS** ⇒ 各平台一致 ⭐⭐⭐
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/FontStore.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/FontStore.swift

import CoreText
import Foundation
import Observation
import UniformTypeIdentifiers
import ZIPFoundation

struct ImportedFont: Identifiable, Hashable, Sendable {
    /// PostScript 名，排版时用它取字体
    let id: String
    let name: String
    let file: String
}
#endif  // #if os(iOS)
