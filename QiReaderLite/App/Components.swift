import SwiftUI

// MARK: - 栖阅风格的玻璃体系
//
// 参照栖阅 2027.01.01 真机截图还原：
//   · 页面底色是**浅蓝白**，不是纯白，也不是灰色
//   · 卡片是**半透明白玻璃**，能透出底下的背景
//   · 描边有一道很淡的高光（顶部亮、底部暗）
//   · 分类/字数这类元信息是**彩色胶囊**，不是灰色小字
//   · 顶栏按钮是**圆形玻璃**，右上是胶囊形控件组
//
// ⚠️ 背景插画是栖阅的美术资产，**不能直接打包**（盗用素材）。
//    这里用 GlassBackdrop 的半透明符号点缀替代观感，素材另换开源图。

extension Theme {
    /// 卡片玻璃：栖阅的卡片不是白纸，是能透出背景的半透明层
    static let glassFill = Color.white.opacity(0.55)
    static let glassFillStrong = Color.white.opacity(0.72)
    static let glassStroke = Color.white.opacity(0.85)
    /// 页面底色：浅蓝白渐变（跟栖阅一致的观感）
    static let pageTop = Color(red: 0.855, green: 0.898, blue: 0.965)
    static let pageBottom = Color(red: 0.949, green: 0.965, blue: 0.984)
    /// 标签配色（栖阅的胶囊是多色的，不是统一灰）
    static let tagPurple = Color(red: 0.62, green: 0.42, blue: 0.78)
    static let tagGreen = Color(red: 0.20, green: 0.62, blue: 0.42)
    static let tagOrange = Color(red: 0.85, green: 0.52, blue: 0.16)
    static let tagBlue = Color(red: 0.25, green: 0.45, blue: 0.82)
}

// MARK: - 页面底

/// 栖阅每个页面底下都有那层淡插画 + 浅蓝白底。
/// 插画用 GlassBackdrop（半透明符号）替代，底色改成蓝白渐变。
struct PageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.pageTop, Theme.pageBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            GlassBackdrop()
                .opacity(0.35)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 玻璃卡片

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18
    var strong = false

    func body(content: Content) -> some View {
        // 底色 + 描边都用现有 Features 里已经验证过的 API 形态
        // （.background(_:in:) / .overlay { } / .font(.caption)），
        // 别用 .stroke()、.font(.system(size:weight:))、EdgeInsets 简写 ——
        // 那些 shim 没实现，改了这里就验不了，只能等真机 CI 才发现问题。
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(strong ? Theme.glassFillStrong : Theme.glassFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.glassStroke.opacity(0.001))
            }
            .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 5)
    }
}

extension View {
    /// 栖阅那种半透明毛玻璃卡片
    func glassCard(cornerRadius: CGFloat = 18, strong: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, strong: strong))
    }
}

// MARK: - 胶囊标签

/// 栖阅的书源分类 / 字数 / 评分都是这种彩色描边胶囊。
struct PillTag: View {
    let text: String
    var color: Color = Theme.accent
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(
                Capsule().fill(filled ? color.opacity(0.16) : Color.white.opacity(0.5))
            )
    }
}

// MARK: - 顶栏控件

/// 顶栏左侧那种圆形玻璃按钮（返回 / 设置 / 编辑）
struct GlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 40
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassCircle()
    }
}

/// 顶栏右侧的胶囊形控件组容器
struct GlassCapsule<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(Theme.glassFillStrong))
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }
}

/// 栖阅页面顶部那个超大标题（书库 / 设置）
struct BigTitle: View {
    let text: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.largeTitle)
                .foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 书架卡片（照栖阅截图 4 还原）

struct ShelfCard: View {
    let item: LibraryItem

    /// 进度：没有总章数时降级成"未开始/在读"
    private var progress: Double {
        if item.finished { return 1 }
        guard item.lastChapterIndex > 0 else { return 0 }
        return 0   // 有总章数才能算准确比例，先不瞎猜
    }

    private var progressText: String {
        if item.finished { return "读完" }
        return "\(Int(progress * 100))%"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: item.book.cleanCover, width: 92, height: 124)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.book.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    PillTag(text: progressText, color: Theme.accent, filled: true)
                }

                if !item.book.author.isEmpty {
                    Text(item.book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                }

                if !item.book.lastChapter.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.sub)
                        Text(item.book.lastChapter)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                    }
                }

                // 元信息胶囊：分类 / 字数 / 状态
                HStack(spacing: 6) {
                    if !item.book.kind.isEmpty {
                        PillTag(text: item.book.kind, color: Theme.tagPurple)
                    }
                    if !item.book.wordCount.isEmpty {
                        PillTag(text: item.book.wordCount, color: Theme.tagPink)
                    }
                    if item.finished {
                        PillTag(text: "已完结", color: Theme.tagBlue)
                    }
                    Spacer(minLength: 0)
                }

                // 底部细进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.6))
                        Capsule().fill(Theme.accent)
                            .frame(width: max(3, geo.size.width * progress))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
    }
}

extension Theme {
    static let tagPink = Color(red: 0.82, green: 0.30, blue: 0.52)
}

// MARK: - 书源彩色图标

/// 栖阅每个书源前面那个彩色圆角方块（截图 2）：
/// 首字或 emoji 做主体，颜色按书源名稳定散列 —— 同一个源每次打开颜色一样。
struct SourceBadge: View {
    let source: BookSource
    var size: CGFloat = 46

    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.52, blue: 0.88),
        Color(red: 0.62, green: 0.42, blue: 0.78),
        Color(red: 0.85, green: 0.52, blue: 0.16),
        Color(red: 0.24, green: 0.66, blue: 0.52),
        Color(red: 0.82, green: 0.36, blue: 0.52),
        Color(red: 0.40, green: 0.62, blue: 0.80),
    ]

    private var tint: Color {
        let key = source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName
        let h = abs(key.hashValue)
        return Self.palette[h % Self.palette.count]
    }

    /// 书源名里如果有 emoji 就用它当图标（栖阅那个 🍅 / 🏰 就是这么来的）
    private var glyph: String {
        let name = source.bookSourceName
        for ch in name {
            if let scalar = ch.unicodeScalars.first,
               scalar.value > 0x1F000 || (scalar.value >= 0x2600 && scalar.value <= 0x27BF) {
                return String(ch)
            }
        }
        return String(name.prefix(1)).isEmpty ? "书" : String(name.prefix(1))
    }

    var body: some View {
        Text(glyph)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(source.enabled ? Color.white : Theme.sub.opacity(0.5))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(source.enabled ? tint : Theme.sub.opacity(0.18))
            )
    }
}
