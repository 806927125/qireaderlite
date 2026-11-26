#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/MediaKindStyle.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/MediaKindStyle.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import ChaiyueModels
import SwiftUI

/// 封面左下角的毛玻璃小标（设计稿「入口 · 书架小标」）
///
/// ⭐⭐⭐ **【改造】升 public**（2026-11-26）⭐⭐⭐：宿主在书架/详情页显示「漫画」角标要用 ⇒ 跨模块 ⇒ 必须 public
public struct MediaBadge: View {
    public let symbol: String
    public let label: String

    public init(symbol: String, label: String) {
        self.symbol = symbol
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(icon: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.ui(9.5, .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
        .background(.black.opacity(0.3), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

/// 各内容形态在入口处的文案与图标
///
/// ⭐⭐⭐ **【改造】三个成员升 public**（2026-11-26）⭐⭐⭐
///   宿主在详情页要写「**开始看漫画**」、在封面上要挂「**漫画**」角标 ⇒ 跨模块 ⇒ 必须 public
public extension BookMediaKind {
    public var symbol: String {
        switch self {
        case .text: "book"
        case .audio: "headphones"
        case .comic: "photo"
        case .video: "play.fill"
        }
    }

    /// 书架封面小标；文字书不加标
    public var badge: String? {
        switch self {
        case .text: nil
        case .audio: "听书"
        case .comic: "漫画"
        case .video: "短剧"
        }
    }

    public func actionTitle(for book: Book) -> String {
        let started = book.hasStarted
        switch self {
        case .text: return started ? "继续阅读" : "开始阅读"
        case .audio: return started ? "继续收听" : "开始收听"
        case .comic: return started ? "继续看漫画" : "开始看漫画"
        case .video: return "播放第 \(max(0, book.durChapterIndex) + 1) 集"
        }
    }
}

#endif  // #if os(iOS)
