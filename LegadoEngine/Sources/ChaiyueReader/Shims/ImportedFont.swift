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
