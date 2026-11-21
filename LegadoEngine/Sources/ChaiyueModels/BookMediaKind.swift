import Foundation

/// 书籍的内容形态。聚合书源在目录脚本里按设备写 `book.type`：
/// iOS 约定 0 文字、1 音频、2 图片、3 视频；Legado 安卓约定为位标记（8 文字、32 音频、64 图片）
public enum BookMediaKind: String, Sendable, CaseIterable {
    case text, audio, comic, video
}

extension Book {
    /// `sourceType` 为书源的 `bookSourceType`：文件书源（3）的书沿用书源类型，不当作视频。
    /// 本地书导入时写入 `type`：1 有声书、2 漫画，其余为文字
    public func mediaKind(sourceType: Int? = nil) -> BookMediaKind {
        if isLocal {
            switch type {
            case 1: return .audio
            case 2: return .comic
            default: return .text
            }
        }
        if type >= 8 {
            if type & 32 != 0 { return .audio }
            if type & 64 != 0 { return .comic }
            return .text
        }
        switch type {
        case 1: return .audio
        case 2: return .comic
        case 3: return sourceType == BookSourceType.file.rawValue ? .text : .video
        default: return .text
        }
    }
}
