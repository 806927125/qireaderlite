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

struct ReaderLaunch: Identifiable, Equatable {
    let id = UUID()
    var book: Book
    var origin: CGRect?
    /// 合书时按它取封面的最新位置（书架可能已重新排序）
    var coverKey: String?
}

struct SourceSignal: Equatable {
    let id = UUID()
    var sourceKey: String
    var loginData: [String: String]?
}
