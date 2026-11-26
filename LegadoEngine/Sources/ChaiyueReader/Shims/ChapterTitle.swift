// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Shelf/HeroCard.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Shelf/HeroCard.swift

import ChaiyueModels
import SwiftUI
import Foundation

enum ChapterTitle {
    private static let prefix = try? NSRegularExpression(pattern: "^\\s*第\\s*[0-9零一二三四五六七八九十百千万两〇]+\\s*[章节回卷集部篇]\\s*[:：、.]?\\s*")

    /// 去掉开头的「第 N 章」，剩余为空时保留原标题
    static func display(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let ns = title as NSString
        guard let match = prefix?.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return title }
        let rest = ns.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    private static let numbered = try? NSRegularExpression(pattern: "^\\s*第\\s*([0-9零一二三四五六七八九十百千万两〇]+)\\s*([章节回卷集部篇])")

    /// 标题开头的序号，如「第五百零二章 夜雨」→「第 502 章」
    static func number(_ title: String?) -> String? {
        guard let title, let match = numbered?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let digits = Range(match.range(at: 1), in: title), let unit = Range(match.range(at: 2), in: title),
              let value = Int(title[digits]) ?? chineseNumber(String(title[digits])) else { return nil }
        return "第 \(value) \(title[unit])"
    }

    /// 标题开头的序号数值，如「第五百零二章 夜雨」→ 502
    static func value(_ title: String?) -> Int? {
        guard let title, let match = numbered?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let digits = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[digits]) ?? chineseNumber(String(title[digits]))
    }

    /// 中文数字：支持「一百零二」「两千三百」「一万二千」，也支持逐位写的「二〇二」
    static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        if !text.contains(where: { units[$0] != nil || $0 == "万" }) {
            var value = 0
            for character in text {
                guard let digit = digits[character] else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        var total = 0, section = 0, number = 0
        for character in text {
            if let digit = digits[character] {
                number = digit
            } else if let unit = units[character] {
                section += (number == 0 ? 1 : number) * unit
                number = 0
            } else if character == "万" {
                total += (section + number) * 10000
                section = 0
                number = 0
            } else {
                return nil
            }
        }
        return total + section + number
    }
}
