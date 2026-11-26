// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/SettingRows.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/SettingRows.swift

import SwiftUI
import Foundation

enum Formats {
    static func size(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        if mb < 1024 { return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// 刚刚 / x 分钟前 / 今天 HH:mm / 昨天 / M月d日
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 导出文件名里的日期：20261107-0815
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }
}
