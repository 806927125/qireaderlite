#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/ReadingStats.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/ReadingStats.swift

import Foundation
import Observation

@Observable
final class ReadingStats {
    private static let key = "stats.seconds"
    private(set) var seconds: [String: Int]
    @ObservationIgnored private var sessionStart: Date?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        seconds = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
    }

    func begin() {
        if sessionStart == nil { sessionStart = Date() }
    }

    func end() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        // 单次超过 3 小时视为挂机，只记 3 小时
        let elapsed = min(Date().timeIntervalSince(start), 3 * 3600)
        guard elapsed >= 1 else { return }
        seconds[Self.formatter.string(from: Date()), default: 0] += Int(elapsed)
    }

    func flush() {
        if sessionStart != nil {
            end()
            begin()
        }
        UserDefaults.standard.set(seconds, forKey: Self.key)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }

    var todayMinutes: Int {
        (seconds[Self.formatter.string(from: Date())] ?? 0) / 60
    }

    /// 本周（周一起）每天的分钟数
    var weekMinutes: [Int] {
        let today = calendar.startOfDay(for: Date())
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -weekday, to: today) else { return Array(repeating: 0, count: 7) }
        return (0..<7).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return 0 }
            return (seconds[Self.formatter.string(from: day)] ?? 0) / 60
        }
    }

    var todayIndex: Int {
        (calendar.component(.weekday, from: Date()) + 5) % 7
    }

    var weekHours: Double {
        Double(weekMinutes.reduce(0, +)) / 60
    }
}
#endif
