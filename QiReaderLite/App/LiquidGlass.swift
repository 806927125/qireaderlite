import SwiftUI

/// 液态玻璃（Liquid Glass）质感 —— **手搓版**，不依赖 iOS 26 的 `glassEffect()`。
///
/// 为什么不用系统的：构建机是 Xcode 16.4 / iOS 18.5 SDK，
/// `glassEffect` / `GlassEffectContainer` 写进去直接编译不过。
/// 栖阅自己也是 iOS 17 部署目标，它那套玻璃感同样是拼出来的。
///
/// 玻璃感的四层（缺一层就"塑料"）：
///   ① 毛玻璃底      Material
///   ② 竖向明暗      顶部亮（受光）→ 底部暗
///   ③ 边缘镜面描边  顶部最亮的那道高光，是"玻璃"最像的一笔
///   ④ 柔和投影      让它浮起来，不是贴上去
struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 20
    /// 玻璃里透出的环境色（栖阅那种淡蓝/淡紫）
    var tint: [Color] = [.white.opacity(0.22), .white.opacity(0.08)]
    var strength: Double = 1.0

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // ① 毛玻璃
                    Rectangle().fill(.ultraThinMaterial)
                    // ② 竖向明暗：顶亮底暗
                    LinearGradient(colors: [.white.opacity(0.26 * strength),
                                            .white.opacity(0.05 * strength),
                                            .black.opacity(0.05 * strength)],
                                   startPoint: .top, endPoint: .bottom)
                    // ③ 环境色
                    LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // ④ 镜面描边：左上最亮，这是玻璃感的关键一笔
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.62 * strength),
                                                .white.opacity(0.10 * strength),
                                                .white.opacity(0.30 * strength)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
            .overlay {
                // 内侧一圈漫反射，玻璃边缘的厚度感
                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                    .strokeBorder(.white.opacity(0.10 * strength), lineWidth: 1)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.13 * strength), radius: 12, x: 0, y: 5)
            .shadow(color: .white.opacity(0.10 * strength), radius: 2, x: 0, y: -1)
    }
}

extension View {
    /// 圆角液态玻璃卡片
    func liquidGlass(cornerRadius: CGFloat = 20,
                     tint: [Color] = [.white.opacity(0.22), .white.opacity(0.08)],
                     strength: Double = 1.0) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius, tint: tint, strength: strength))
    }

    /// 玻璃圆按钮（顶栏那个返回键）
    func glassCircle(tint: [Color] = [.white.opacity(0.26), .white.opacity(0.08)]) -> some View {
        modifier(LiquidGlass(cornerRadius: 999, tint: tint))
    }
}

/// 背景装饰：栖阅每个页面底下都有一层淡淡的插画。
/// 这里用代码画一组半透明符号当点缀，不依赖图片资源。
struct GlassBackdrop: View {
    var symbols: [String] = ["heart.fill", "book.closed.fill", "ticket.fill",
                             "backpack.fill", "envelope.fill", "sparkles"]
    var count: Int = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    // 固定摆位（不用随机，每次打开位置一样，视觉更稳）
                    let x = w * (0.06 + 0.42 * ((i * 7) % 10) / 10.0)
                    let y = h * (0.05 + 0.40 * ((i * 3) % 10) / 10.0)
                    let s = 14.0 + CGFloat((i * 13) % 5) * 7
                    Image(systemName: symbols[i % symbols.count])
                        .font(.system(size: s))
                        .foregroundStyle(.white.opacity(0.5))
                        .rotationEffect(.degrees(Double((i * 11) % 40) - 20))
                        .position(x: x, y: y)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
