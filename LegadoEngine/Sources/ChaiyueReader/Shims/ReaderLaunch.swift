#if os(iOS)
// ⭐⭐⭐⭐⭐ **【平台守卫】本文件的依赖只在 iOS 存在**（2026-11-26）⭐⭐⭐⭐⭐
//   ⚠️ **为什么**：`LegadoEngine`（宿主门面模块）现在依赖 `ChaiyueReader`
//     ⇒ ⇒ **macOS / Linux 上会编译 `ChaiyueReader` 模块**（以前只编 iOS ⇒ 没暴露）⭐⭐⭐
//   ⇒ 而本文件引用的类型（ReaderContainer 等）在那些平台**不存在** ⇒ 编译失败 ⭐⭐⭐
//   ⇒ 正解：**把本文件也圈进 iOS** ⇒ 各平台一致 ⭐⭐⭐
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/AppModel.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/AppModel.swift

import Observation
import ChaiyueModels
import ChaiyueEngine
import ChaiyueReaderServices
import ChaiyueEngine
import SwiftUI

/// ⭐⭐⭐⭐⭐ **【改造】升 public**（2026-11-26 · CI28 实证）⭐⭐⭐⭐⭐
///   宿主要 `ReaderContainer(launch:)` ⇒ `ReaderLaunch` 必须跨模块可见 ⭐⭐⭐
public struct ReaderLaunch: Identifiable, Equatable {
    public let id = UUID()
    public var book: Book
    public var origin: CGRect?
    /// 合书时按它取封面的最新位置（书架可能已重新排序）
    public var coverKey: String?

    /// ⭐⭐⭐ **显式 public init**（2026-11-26 · CI28 实证）⭐⭐⭐
    ///   `public struct` 的**默认 memberwise init 是 internal** ⇒ 宿主 `ReaderLaunch(book:…)` 编不过 ⭐⭐⭐
    public init(book: Book, origin: CGRect? = nil, coverKey: String? = nil) {
        self.book = book
        self.origin = origin
        self.coverKey = coverKey
    }
}

struct SourceSignal: Equatable {
    let id = UUID()
    var sourceKey: String
    var loginData: [String: String]?
}
#endif  // #if os(iOS)
