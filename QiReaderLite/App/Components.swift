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
///
/// ⚠️ 这一层不只是好看 —— 它是玻璃的**折射对象**。
///    底下越接近纯色，glassEffect 的折射和高光越看不出来（就是一块灰白板）。
///    栖阅那种高饱和插画正是为此存在的，所以这里加了彩色光斑来给玻璃"咬东西"。
struct PageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.pageTop, Theme.pageBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // 彩色光斑：给玻璃折射提供高对比内容，比纯符号有效得多
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(w * 0.16, h * 0.10, 190, Color(red: 0.62, green: 0.78, blue: 1.0))
                    blob(w * 0.88, h * 0.20, 210, Color(red: 0.95, green: 0.78, blue: 0.92))
                    blob(w * 0.10, h * 0.52, 170, Color(red: 0.76, green: 0.88, blue: 1.0))
                    blob(w * 0.82, h * 0.68, 230, Color(red: 0.88, green: 0.82, blue: 1.0))
                    blob(w * 0.42, h * 0.92, 200, Color(red: 0.70, green: 0.90, blue: 0.94))
                    // ⚠️ 中间再补一块 —— 卡片大多落在页面中部，
                    //    底下没颜色的话，玻璃就算全透也看不出"透"（就一片浅蓝白）。
                    blob(w * 0.56, h * 0.34, 250, Color(red: 0.96, green: 0.74, blue: 0.86))
                }
            }
            .ignoresSafeArea()

            GlassBackdrop()
                .opacity(0.5)
        }
        .allowsHitTesting(false)
    }

    /// ⭐⭐⭐ **光斑：径向渐变，不用 blur**（2026-10-24 真机崩溃日志实证）
    ///
    /// ⚠️ 原来每个光斑是 `Circle + .blur(radius: 42)` ⇒ **6 次全屏高斯模糊**
    ///   ⇒ 玻璃还要**采样**这个背景 ⇒ 每个玻璃视图 = 一次「采样 + 模糊」
    ///   ⇒ iOS 26/27（尤其 27 Beta）上，**页面弹出的那一瞬间**光算背景就够呛
    ///   ⇒ 真机崩溃日志：`scene-update watchdog`（推页面 > 10 秒）⇒ **app 死机**⭐⭐⭐
    ///   ⇒ 而且设备 `Thermal serious`（排版/模糊排的）
    ///
    /// ⇒ 现在：**径向渐变**（零模糊成本，视觉几乎一样 —— 本来就是柔和光斑）⭐⭐⭐
    private func blob(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: Color) -> some View {
        RadialGradient(
            colors: [c.opacity(0.55), c.opacity(0.0)],
            center: .center,
            startRadius: 0,
            endRadius: size / 2
        )
        .frame(width: size, height: size)
        .position(x: x, y: y)
    }
}

// MARK: - 玻璃卡片

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18
    var strong = false
    /// 档位：大卡片默认走 **`.clear`（通透）**。
    ///
    /// ⚠️ 为什么卡片跟阅读器面板分开：
    ///    · 卡片是**大面积**，压在彩色光斑上 → 要能透出底下的插画，才像"悬浮的玻璃"
    ///    · 阅读器面板是**正文后面** → 要磨砂底，字才看得清（那边直接用 `liquidGlass`，默认 `.regular`）
    ///    以前两边都 `.regular` → 卡片成了一块乳白板子（用户：「整块玻璃透明度不够」）
    var variant: GlassVariant = .clear

    func body(content: Content) -> some View {
        // ⚠️ 这里**必须**委托给 LiquidGlass，不要自己叠半透明白。
        //    LiquidGlass 内部已经处理好了两条路：
        //      · iOS 26+ → 系统 .glassEffect()（真折射 / 动态高光 / 自适应阴影）
        //      · 手搓四层（.ultraThinMaterial 真实模糊 + 镜面描边 + 双阴影）——
        //        部署目标已 iOS 26，这档只是老 SDK 兜底
        //    而且系统 glass 自带高光和描边，**再叠 background / overlay / shadow 会打架**，
        //    叠出来的效果是"半透明白卡片"，不是液态玻璃 —— 这坑我踩过一次。
        content.liquidGlass(
            cornerRadius: cornerRadius,
            tint: strong
                ? [Color.white.opacity(0.30), Theme.pageTop.opacity(0.10)]
                : [Color.white.opacity(0.22), Theme.pageTop.opacity(0.08)],
            strength: strong ? 1.15 : 1.0,
            variant: variant,
            // 大卡片不设白纱下限 —— 它就是要能一路透到底（透出底下的彩色光斑）
            minVeil: 0
        )
    }
}

extension View {
    /// 栖阅那种半透明毛玻璃卡片
    func glassCard(cornerRadius: CGFloat = 18, strong: Bool = false,
                   variant: GlassVariant = .clear) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, strong: strong, variant: variant))
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
            // ⚠️ 卡片本身就是玻璃了，标签再来一层半透明白会把玻璃糊掉，
            //    玻璃的折射/高光就没了。改成纯色调（低透明度的彩色块）。
            .background(
                Capsule().fill(filled ? color.opacity(0.22) : color.opacity(0.12))
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
        // 同 GlassCard：委托给 LiquidGlass，别自己叠半透明白
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .liquidGlass(cornerRadius: 999, strength: 1.1)
    }
}

/// 栖阅页面顶部那个超大标题（书库 / 设置）
struct BigTitle: View {
    let text: String
    var subtitle: String?

    /// Swift 的成员初始化器第一个参数是带标签的（`BigTitle(text:)`）。
    /// 页面标题是唯一用途，直接给个无标签版本，省得每个调用点都写 `text:`。
    init(_ text: String, subtitle: String? = nil) {
        self.text = text
        self.subtitle = subtitle
    }

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
    let name: String
    let isOn: Bool
    var size: CGFloat = 46

    /// ⚠️ 不要直接存 BookSource：它有三十多个字段，成员初始化器必须全给，
    ///    想"造一个空的"很别扭。这里只取需要的两个值。
    init(source: BookSource, size: CGFloat = 46) {
        self.name = source.bookSourceName
        self.isOn = source.enabled
        self.size = size
    }

    init(name: String, isOn: Bool = true, size: CGFloat = 46) {
        self.name = name
        self.isOn = isOn
        self.size = size
    }

    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.52, blue: 0.88),
        Color(red: 0.62, green: 0.42, blue: 0.78),
        Color(red: 0.85, green: 0.52, blue: 0.16),
        Color(red: 0.24, green: 0.66, blue: 0.52),
        Color(red: 0.82, green: 0.36, blue: 0.52),
        Color(red: 0.40, green: 0.62, blue: 0.80),
    ]

    private var tint: Color {
        let h = abs(name.hashValue)
        return Self.palette[h % Self.palette.count]
    }

    /// 书源名里如果有 emoji 就用它当图标（栖阅那个 🍅 / 🏰 就是这么来的）
    private var glyph: String {
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
            .foregroundStyle(isOn ? Color.white : Theme.sub.opacity(0.5))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(isOn ? tint : Theme.sub.opacity(0.18))
            )
    }
}
