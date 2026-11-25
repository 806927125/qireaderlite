import Foundation

/// 稳定偏移与排版偏移的换算。
///
/// 稳定文本 = 处理后的段落以 "\n" 连接（不含标题），进度、书签、朗读、书内搜索都按稳定 UTF-16 偏移保存，
/// 改字号、换主题、重新分页后仍能回到同一个字。排版文本在前面多了标题，图片段落被替换成占位文字，
/// 段末可能多出段评气泡，所以两者的偏移需要按段换算；图片段落内部的位置统一落到段首。
public struct TextOffsetMap: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let stable: Int
        let layout: Int
        let stableLength: Int
        /// 含段末附加字符
        let layoutLength: Int
        /// 段末只在排版里存在的字符数（段评气泡）
        let trailing: Int

        var bodyLength: Int { layoutLength - trailing }
    }

    public let titleLength: Int
    /// 稳定文本总长度
    public let stableLength: Int
    /// 排版文本总长度（含标题）
    public let layoutLength: Int
    let segments: [Segment]

    /// `paragraphs` 为稳定文本的段落，`layoutLengths` 为各段在排版文本中的长度（不含换行、含段末附加字符），
    /// `trailingLengths` 为各段段末附加字符数，缺省为 0
    init(titleLength: Int, paragraphs: [String], layoutLengths: [Int], trailingLengths: [Int] = []) {
        var segments: [Segment] = []
        segments.reserveCapacity(paragraphs.count)
        var stable = 0
        var layout = titleLength
        for (index, (paragraph, layoutLength)) in zip(paragraphs, layoutLengths).enumerated() {
            let length = (paragraph as NSString).length
            let trailing = trailingLengths.indices.contains(index) ? min(trailingLengths[index], layoutLength) : 0
            segments.append(Segment(stable: stable, layout: layout, stableLength: length, layoutLength: layoutLength,
                                    trailing: trailing))
            stable += length + 1
            layout += layoutLength + 1
        }
        self.titleLength = titleLength
        self.segments = segments
        stableLength = segments.isEmpty ? 0 : stable - 1
        layoutLength = segments.isEmpty ? titleLength : layout - 1
    }

    public func layoutOffset(forStable offset: Int) -> Int {
        guard offset > 0, let segment = segment(containing: offset, key: \.stable) else { return titleLength }
        let delta = min(offset - segment.stable, segment.stableLength)
        return segment.layout + Self.map(delta, from: segment.stableLength, to: segment.bodyLength)
    }

    public func stableOffset(forLayout offset: Int) -> Int {
        guard offset > titleLength, let segment = segment(containing: offset, key: \.layout) else { return 0 }
        let delta = min(offset - segment.layout, segment.bodyLength)
        return segment.stable + Self.map(delta, from: segment.bodyLength, to: segment.stableLength)
    }

    /// 文字段两边长度相同，逐字对应；图片段只有段首和段尾两个可定位的点
    private static func map(_ delta: Int, from source: Int, to target: Int) -> Int {
        if source == target { return delta }
        return delta >= source ? target : 0
    }

    private func segment(containing offset: Int, key: KeyPath<Segment, Int>) -> Segment? {
        guard !segments.isEmpty else { return nil }
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid][keyPath: key] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return segments[low]
    }
}
