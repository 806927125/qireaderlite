// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/BookText.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/BookText.swift

import ChaiyueModels
import SwiftUI

enum BookText {
    static func kind(_ text: String?) -> String? {
        guard let text = text?.withoutEmoji else { return nil }
        let parts = text.split(whereSeparator: { ",，、 \n\t".contains($0) }).prefix(2)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func oneLine(_ text: String?) -> String? {
        guard let text = text?.withoutEmoji else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    static func join(_ parts: String?...) -> String {
        parts.compactMap { ($0?.withoutEmoji).nilIfEmpty }.joined(separator: " · ")
    }

    static func subtitle(_ book: SearchBook) -> String {
        join(book.author, kind(book.kind), book.wordCount)
    }
}

extension BookText {
    /// 发现分类名常用符号包边（如「°✧ 排行榜 ✧°」），只保留首尾之间的文字；括号算作文字，避免「[小说] 频道」被拆坏
    static func label(_ text: String) -> String {
        let text = text.withoutEmoji
        let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]【】()（）《》<>「」『』"))
        let trimmed = text.trimmingCharacters(in: kept.inverted)
        return trimmed.isEmpty ? text : trimmed
    }
}

extension String {
    /// 书源文字里的 emoji（连同变体选择符、肤色、组合序列）一律不显示；去掉后合并多余空格，保留换行
    nonisolated var withoutEmoji: String {
        guard contains(where: \.isEmojiGlyph) else { return self }
        let lines = split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.filter { !$0.isEmojiGlyph }.split(separator: " ").joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    /// 数字、#、©、™ 等也带 isEmoji 属性，按码位排除
    nonisolated var isEmojiGlyph: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
                || scalar.value == 0xFE0F || scalar.value == 0x20E3
        }
    }
}

enum SourceName {
    /// 完整书源名，只去掉 emoji（列表、详情等需要区分版本的地方）
    static func full(_ name: String) -> String {
        let text = name.withoutEmoji
        return text.isEmpty ? name : text
    }

    static func display(_ name: String) -> String {
        var text = name.withoutEmoji
        for (open, close) in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("《", "》"), ("<", ">")] {
            while let start = text.range(of: open),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        text = text.replacingOccurrences(of: #"[vV]?\d+(\.\d+)+"#, with: "", options: .regularExpression)
        text = String(text.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || scalar.properties.generalCategory == .otherSymbol)
        }.map(Character.init))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? name : text
    }
}
