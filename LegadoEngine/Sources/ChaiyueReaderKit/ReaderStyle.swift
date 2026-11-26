import Foundation

/// 排版设置（变更后需要重新分页）
public struct ReaderTypography: Codable, Hashable, Sendable {
    public var fontSize: Double = 20
    /// 字体 PostScript 名称，nil 表示系统字体
    public var fontName: String?
    /// 行距，字号的倍数
    public var lineSpacing: Double = 0.55
    /// 行高（字号的倍数，同 CSS line-height）；设了就按它算行距，忽略 `lineSpacing`
    public var lineHeight: Double?
    /// 段距，字号的倍数
    public var paragraphSpacing: Double = 0.7
    /// 字距，字号的倍数
    public var letterSpacing: Double = 0
    /// 首行缩进字数
    public var indent: Double = 2
    public var titleScale: Double = 1.3
    public var justified: Bool = true
    public var horizontalPadding: Double = 22
    public var topPadding: Double = 6
    public var bottomPadding: Double = 6

    public init() {}

    public static let fontSizeRange: ClosedRange<Double> = 12...36
    public static let lineSpacingRange: ClosedRange<Double> = 0...1.5
    public static let paragraphSpacingRange: ClosedRange<Double> = 0...2
}

/// 阅读主题（只影响颜色，不需要重新分页）
public struct ReaderTheme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var background: String
    public var text: String
    public var secondaryText: String
    public var isDark: Bool

    public init(id: String, name: String, background: String, text: String, secondaryText: String, isDark: Bool) {
        self.id = id
        self.name = name
        self.background = background
        self.text = text
        self.secondaryText = secondaryText
        self.isDark = isDark
    }

    public static let `default` = ReaderTheme(id: "light", name: "浅色", background: "#FFFFFF", text: "#1C1C1E",
                                              secondaryText: "#8E8E93", isDark: false)
    public static let defaultDark = ReaderTheme(id: "dark", name: "深色", background: "#000000", text: "#D1D1D6",
                                                secondaryText: "#636366", isDark: true)
}

/// 翻页方式（与原 App 的五种模式对应）
public enum PageTurnStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case curl
    case scroll
    case slide
    case none
    case vertical

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .curl: "仿真"
        case .scroll: "平移"
        case .slide: "滑动"
        case .none: "无动画"
        case .vertical: "上下滚动"
        }
    }

    /// 分页显示（上下滚动模式按章连续排版，不分页）
    public var isPaged: Bool { self != .vertical }
}
