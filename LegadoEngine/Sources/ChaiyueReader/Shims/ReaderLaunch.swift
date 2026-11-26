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
