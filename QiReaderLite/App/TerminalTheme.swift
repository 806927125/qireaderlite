import SwiftUI

// =============================================================================
// ⭐⭐⭐⭐⭐ **「星澜终端」视觉层**（2026-11-24，按用户给的 HTML 原型做的换肤）⭐⭐⭐⭐⭐
//
// ⚠️ 原型：`阅读App全息终端.html`（深空底 + 玻璃拟态 + 青紫渐变 + 衬线标题）⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **三条硬纪律**（都是本仓库用真机换来的教训，不是审美偏好）⭐⭐⭐⭐⭐
//   ① ⭐⭐⭐ **光斑一律用「径向渐变」，不许用 `.blur()`** ⭐⭐⭐
//      （2026-10-24 真机崩溃日志实证：6 个全屏高斯模糊 + 玻璃采样 ⇒ `scene-update watchdog`
//        ⇒ **App 死机**；而且设备 Thermal serious ⇒ ⇒ 径向渐变零模糊成本、视觉几乎一样）⭐⭐⭐
//   ② ⭐⭐⭐ **玻璃一律委托给 `LiquidGlass`**（系统 `.glassEffect` / 手搓四层）
//      ⇒ **别自己叠半透明白** ⇒ 叠出来是"乳白板子"，不是玻璃（这坑踩过）⭐⭐⭐
//   ③ ⭐⭐⭐ **改配色只改 `Theme` / `Terminal` 的常量** ⇒ 全 App 一次换肤
//      ⇒ 不要去每个页面里手改颜色（会漂）⭐⭐⭐
// =============================================================================

/// 终端配色（原型 CSS 变量逐字搬过来）
enum Terminal {
    /// 底色 #070912
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.071)
    /// 主文字 #eef2ff
    static let ink = Color(red: 0.933, green: 0.949, blue: 1.0)
    /// 次级文字 rgba(238,242,255,.55)
    static let dim = Color(red: 0.933, green: 0.949, blue: 1.0).opacity(0.55)
    /// 青 #7dd3fc
    static let cyan = Color(red: 0.490, green: 0.827, blue: 0.988)
    /// 紫 #c084fc
    static let violet = Color(red: 0.753, green: 0.518, blue: 0.988)
    /// 粉 #f0abfc
    static let pink = Color(red: 0.941, green: 0.671, blue: 0.988)
    /// 玻璃底 rgba(255,255,255,.06)
    static let glass = Color.white.opacity(0.06)
    /// 玻璃底（第二层）rgba(255,255,255,.11)
    static let glass2 = Color.white.opacity(0.11)
    /// 描边 rgba(255,255,255,.14)
    static let edge = Color.white.opacity(0.14)
    /// 圆角 24px（原型 --r）
    static let radius: CGFloat = 24

    /// ⭐⭐⭐ 青→紫渐变（原型的主渐变，用在「继续阅读」按钮/进度环/进度条）⭐⭐⭐
    static let gradient = LinearGradient(
        colors: [cyan, violet],
        startPoint: .leading, endPoint: .trailing
    )
    /// 纵向渐变（用于竖向元素）
    static let gradientV = LinearGradient(
        colors: [cyan, violet],
        startPoint: .top, endPoint: .bottom
    )

    /// ⭐⭐⭐ **进度轨道的底色**（深色底上的「未填充」那段）⭐⭐⭐
    static let track = Color.white.opacity(0.10)
    /// ⭐⭐⭐ **书脊竖线**（最近阅读卡片左边那道）⭐⭐⭐
    static let spine = Color.white.opacity(0.25)
    /// ⭐⭐⭐ **Toast 的底色**（深色浮层）⭐⭐⭐
    static let toastBg = UIColor.black.withAlphaComponent(0.78)

    // ⭐⭐⭐ **标签配色**（胶囊标签）⇒ 也收进主题层 ⇒ 换肤只改这一处 ⭐⭐⭐
    static let tagPink = Color(red: 0.941, green: 0.420, blue: 0.720)

    /// ⭐⭐⭐ **书源彩色头像的调色板**（按书源名稳定散列）⇒ 收进主题层 ⭐⭐⭐
    static let sourcePalette: [Color] = [
        Color(red: 0.490, green: 0.827, blue: 0.988),   // 青
        Color(red: 0.753, green: 0.518, blue: 0.988),   // 紫
        Color(red: 0.941, green: 0.671, blue: 0.988),   // 粉
        Color(red: 0.353, green: 0.878, blue: 0.706),   // 薄荷
        Color(red: 0.647, green: 0.780, blue: 0.988),   // 天蓝
        Color(red: 0.549, green: 0.647, blue: 0.988),   // 靛
    ]
}

// =============================================================================
// 深空背景：渐变 + 星点 + 三个漂移光球
// =============================================================================

/// ⭐⭐⭐ **深空背景**（原型的 `.stars` + `.orb`）⭐⭐⭐
struct TerminalBackdrop: View {
    /// 光球缓慢漂移（原型的 `drift` 16s）
    @State private var drift = false

    var body: some View {
        ZStack {
            // ① 底：深空 + 两团大范围辉光（径向渐变，**不 blur**）⭐⭐⭐
            Terminal.bg.ignoresSafeArea()
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    glow(w * 0.15, -h * 0.10, max(w, h) * 1.05,
                         Color(red: 0.11, green: 0.14, blue: 0.26))
                    glow(w * 1.05, h * 0.25, max(w, h) * 0.95,
                         Color(red: 0.16, green: 0.09, blue: 0.25))
                    glow(w * 0.62, h * 0.45, max(w, h) * 0.62,
                         Color(red: 0.22, green: 0.08, blue: 0.18), opacity: 0.5)
                }
            }
            .ignoresSafeArea()

            // ② 三个漂移光球（原型 .o1/.o2/.o3）⭐⭐⭐
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    orb(w * 0.16, h * 0.08, min(w, h) * 0.62,
                        Color(red: 0.23, green: 0.36, blue: 0.86), drift ? 1.0 : 0.0)
                    orb(w * 0.84, h * 0.72, min(w, h) * 0.56,
                        Color(red: 0.49, green: 0.23, blue: 0.93), drift ? 1.0 : 0.0)
                    orb(w * 0.72, h * 0.45, min(w, h) * 0.42,
                        Color(red: 0.86, green: 0.15, blue: 0.47), drift ? 1.0 : 0.0)
                }
            }
            .ignoresSafeArea()

            // ③ 星点（原型 `.stars`）—— 用 Canvas 画，**不生成几百个 View** ⭐⭐⭐
            StarField()
                .opacity(0.5)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .onAppear {
            // ⭐⭐⭐ **只动「漂移量」，不做持续动画** ⇒ 零 CPU 负担 ⭐⭐⭐
            //   （连续动画在低端机上会被系统判为「一直忙」⇒ 发热 ⇒ 掉帧）⭐⭐⭐
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    /// ⭐⭐⭐ **大范围辉光**（径向渐变，零模糊成本）⭐⭐⭐
    private func glow(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                      _ c: Color, opacity: Double = 0.85) -> some View {
        RadialGradient(colors: [c.opacity(opacity), c.opacity(0)],
                       center: .center, startRadius: 0, endRadius: size / 2)
            .frame(width: size, height: size)
            .position(x: x, y: y)
    }

    /// ⭐⭐⭐ **漂移光球**（径向渐变 + 缓慢位移）⭐⭐⭐
    private func orb(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                     _ c: Color, phase: Double) -> some View {
        RadialGradient(colors: [c.opacity(0.42), c.opacity(0)],
                       center: .center, startRadius: 0, endRadius: size / 2)
            .frame(width: size, height: size)
            .position(x: x, y: y)
            .offset(x: phase == 0 ? 0 : 26, y: phase == 0 ? 0 : 22)
            .scaleEffect(phase == 0 ? 1 : 1.12)
    }
}

/// ⭐⭐⭐ **星点层**（Canvas 一次画完 ⇒ 几十个 View 变成一次绘制）⭐⭐⭐
struct StarField: View {
    var body: some View {
        Canvas { ctx, size in
            // 固定种子 ⇒ 每次布局星点位置一样（不会每次滚动都换位置）⭐⭐⭐
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> Double {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return Double(seed % 10000) / 10000.0
            }
            let cols = 12, rows = 26
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = size.width * (Double(c) + rnd() * 0.9) / Double(cols)
                    let y = size.height * (Double(r) + rnd() * 0.9) / Double(rows)
                    let r0 = 0.6 + rnd() * 0.9
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r0, height: r0)),
                             with: .color(.white.opacity(0.35 + rnd() * 0.45)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// =============================================================================
// 品牌标题（原型的 `.topbar .brand`）
// =============================================================================

/// ⭐⭐⭐ **终端风格的品牌标题**（小字英文 + 衬线大字）⭐⭐⭐
struct TerminalTitle: View {
    /// 英文小标（原型：READING TERMINAL / CHANNELS / PROFILE）
    let kicker: String
    /// 中文主标（原型：星澜终端 / 书源频道 / 数据中心）
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(3)
                    .foregroundStyle(Terminal.dim)
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(Terminal.ink)
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
    }
}

// =============================================================================
// 进度环（原型 `.cabin .ring`）
// =============================================================================

/// ⭐⭐⭐ **进度环**（原型：圆环 + 渐变弧 + 中间封面）⭐⭐⭐
struct ProgressRing: View {
    /// 0…1
    let progress: Double
    var size: CGFloat = 128
    var lineWidth: CGFloat = 6
    /// 中间内容（封面）
    var center: AnyView

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(Terminal.gradientV,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .frame(width: size, height: size)
    }
}

// =============================================================================
// 玻璃卡片（终端风）
// =============================================================================

extension View {
    /// ⭐⭐⭐ **终端风玻璃卡片**（委托给 `LiquidGlass`，不自叠半透明白）⭐⭐⭐
    func terminalCard(cornerRadius: CGFloat = Terminal.radius,
                      strong: Bool = false) -> some View {
        glassCard(cornerRadius: cornerRadius, strong: strong)
    }

    /// ⭐⭐⭐ **终端风的渐变按钮底**（原型 `.cgo`）⭐⭐⭐
    func terminalGradientButton() -> some View {
        background(Terminal.gradient, in: Capsule(style: .continuous))
    }
}
