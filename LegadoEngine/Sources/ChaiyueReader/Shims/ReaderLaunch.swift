// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/AppModel.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/AppModel.swift
//
// ⭐⭐⭐⭐⭐ **改动说明**⭐⭐⭐⭐⭐
//   ① 加 `public`（宿主要能 import 到并自己造 `ReaderLaunch`）⭐⭐⭐
//   ② **显式加 `public init`** —— `public struct` 的默认 memberwise init 是 **internal** ⭐⭐⭐
//      ⇒ 宿主 `ReaderLaunch(book:origin:coverKey:)` 才编得过 ⭐⭐⭐
import ChaiyueModels
import Foundation

/// 打开阅读器的请求。`origin` 为封面在窗口中的位置，用于开书动画
public struct ReaderLaunch: Identifiable, Equatable {
    public let id = UUID()
    public var book: Book
    public var origin: CGRect?
    /// 合书时按它取封面的最新位置（书架可能已重新排序）
    public var coverKey: String?

    public init(book: Book, origin: CGRect? = nil, coverKey: String? = nil) {
        self.book = book
        self.origin = origin
        self.coverKey = coverKey
    }
}

/// 书源脚本发给界面的一次性信号；`loginData` 为空表示整体刷新
public struct SourceSignal: Equatable {
    public let id = UUID()
    public var sourceKey: String
    public var loginData: [String: String]?

    public init(sourceKey: String, loginData: [String: String]? = nil) {
        self.sourceKey = sourceKey
        self.loginData = loginData
    }
}
