import Foundation
import ChaiyueModels

/// 阅读位置：章节索引 + 章内稳定 UTF-16 偏移。
/// 稳定文本 = 处理后的段落以 "\n" 连接（不含标题），与 ReaderKit `TextOffsetMap` 的定义一致，
/// 进度、书签、朗读、书内搜索都用它，重新分页或切换翻页方式后仍能回到同一个字
public struct ReadingPosition: Codable, Hashable, Sendable {
    public var chapterIndex: Int
    public var offset: Int

    public init(chapterIndex: Int, offset: Int = 0) {
        self.chapterIndex = chapterIndex
        self.offset = offset
    }
}

/// 处理后的一章：显示标题 + 段落（已去重复标题、简繁转换、替换净化，图片段落保持 `<img …>` 原样）
public struct ChapterText: Hashable, Sendable {
    public let index: Int
    public let title: String
    public let paragraphs: [String]
    /// 段落附带内容（行内小图、段评），不计入稳定文本
    public let extras: [Int: ParagraphExtras]
    public let isVolume: Bool
    /// 本章插图是否已全部取完（成功或失败）。为 false 时先按占位排版，取完后会话发布一个该值为 true 的新实例，
    /// 界面据此重新排版；没有插图的章节始终为 true
    public let imagesLoaded: Bool

    public init(index: Int, title: String, paragraphs: [String], extras: [Int: ParagraphExtras] = [:], isVolume: Bool = false,
                imagesLoaded: Bool = true) {
        self.index = index
        self.title = title
        self.paragraphs = paragraphs
        self.extras = extras
        self.isVolume = isVolume
        self.imagesLoaded = imagesLoaded
    }

    public var content: String { paragraphs.joined(separator: "\n") }

    /// 与 `content` 等长、偏移一一对应的纯文字：图片段落与行内小图换成空格，朗读和书签摘录用它
    public var plainContent: String {
        paragraphs.map { paragraph in
            if InlineImage.isImage(paragraph) { return String(repeating: " ", count: (paragraph as NSString).length) }
            return paragraph.replacingOccurrences(of: InlineImage.inlineMark, with: " ")
        }.joined(separator: "\n")
    }

    /// 图片地址（原样、去重、按出现顺序），含行内小图
    public var imageSources: [String] {
        var seen = Set<String>()
        var sources: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if let src = InlineImage.source(of: paragraph) { sources.append(src) }
            if let inline = extras[index]?.inlineImages, !inline.isEmpty {
                sources += inline.sorted { $0.key < $1.key }.map(\.value)
            }
        }
        return sources.filter { seen.insert($0).inserted }
    }

    func withImagesLoaded() -> ChapterText {
        ChapterText(index: index, title: title, paragraphs: paragraphs, extras: extras, isVolume: isVolume, imagesLoaded: true)
    }

    /// 稳定文本长度（UTF-16）
    public var length: Int {
        paragraphs.reduce(0) { $0 + ($1 as NSString).length } + max(0, paragraphs.count - 1)
    }

    /// 稳定偏移 → (段落索引, 段内偏移)，用于竖向滚动模式和朗读定位
    public func location(of offset: Int) -> (paragraph: Int, offset: Int) {
        var start = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let length = (paragraph as NSString).length
            if offset <= start + length || index == paragraphs.count - 1 {
                return (index, min(max(0, offset - start), length))
            }
            start += length + 1
        }
        return (0, 0)
    }

    /// (段落索引, 段内偏移) → 稳定偏移
    public func offset(paragraph: Int, offset inner: Int = 0) -> Int {
        guard !paragraphs.isEmpty else { return 0 }
        let target = min(max(0, paragraph), paragraphs.count - 1)
        let start = paragraphs[..<target].reduce(0) { $0 + ($1 as NSString).length + 1 }
        return start + min(max(0, inner), (paragraphs[target] as NSString).length)
    }

    /// 从稳定偏移开始的一段文字（书签摘录），跳过图片
    public func excerpt(from offset: Int, maxLength: Int = 50) -> String {
        let text = plainContent as NSString
        var start = min(max(0, offset), text.length)
        while start < text.length, let scalar = UnicodeScalar(text.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start += 1
        }
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(maxLength, text.length - start)))
        return text.substring(with: range).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ChapterLoadState: Hashable, Sendable {
    case loading
    case loaded(ChapterText)
    case failed(String)
}
