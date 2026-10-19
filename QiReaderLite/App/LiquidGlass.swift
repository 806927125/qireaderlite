import SwiftUI

/// 液态玻璃（Liquid Glass）质感。
///
/// 两条路，自动选：
///   · iOS 26+ 且用 Xcode 26+ 编译 → **系统 `glassEffect()`**（真·液态玻璃：透镜折射、陀螺仪高光、动态阴影）
///   · 其余情况 → 手搓版（四层玻璃感，视觉上 90% 还原）
///
/// ── 为什么必须有 `#if compiler(>=6.2)` ──
/// `if #available(iOS 26.0, *)` **挡不住编译期不存在的 API**。
/// 用老 SDK（Xcode 16.x / iOS 18.5）编译时，编译器照样会编译那个分支，
/// 然后报 `no member 'glassEffect'` / `cannot find 'Glass' in scope`。
/// `#if compiler(...)` 才是编译期开关 —— Xcode 26 = Swift 6.2。
///
/// ── CI 报 glassEffect 相关的错怎么办 ──
/// 把下面 `USE_SYSTEM_GLASS` 改成 `false` 立刻回退到手搓版，不影响其它功能。
/// 改完推一次，CI 会重编。
///
/// ── 手搓版为什么保留 ──
/// 部署目标还是 iOS 17，iOS 17~25 的机器只能走手搓版。
private let USE_SYSTEM_GLASS = true

// MARK: - 玻璃填充 / 描边（手搓版专用）

private struct GlassFill: View {
    var tint: [Color]
    var strength: Double

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [.white.opacity(0.26 * strength),
                                    .white.opacity(0.05 * strength),
                                    .black.opacity(0.05 * strength)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct GlassRim: View {
    var cornerRadius: CGFloat
    var strength: Double

    var body: some View {
        // 镜面描边：左上最亮，这是玻璃感的关键一笔
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(0.62 * strength),
                                        .white.opacity(0.10 * strength),
                                        .white.opacity(0.30 * strength)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
    }
}

// MARK: - 修饰器

struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 20
    /// 玻璃里透出的环境色（栖阅那种淡蓝/淡紫）
    var tint: [Color] = [.white.opacity(0.22), .white.opacity(0.08)]
    var strength: Double = 1.0
    /// 圆形（顶栏返回键那种）
    var isCircle: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if USE_SYSTEM_GLASS {
            if #available(iOS 26.0, *) {
                systemGlass(content)
            } else {
                legacyGlass(content)
            }
        } else {
            legacyGlass(content)
        }
        #else
        legacyGlass(content)
        #endif
    }

    #if compiler(>=6.2)
    /// 系统液态玻璃。
    ///
    /// ⚠️ 系统的 glass 自带折射 / 高光 / 自适应阴影 / 前景文字增强对比度，
    ///    所以这里**不要**再叠 background / clipShape / overlay(描边) —— 叠了反而打架。
    /// ⚠️ 官方明确说：玻璃视图上**不要**用 `.clipShape()`。
    /// ⚠️ 官方最佳实践：glassEffect 放在修饰链**最后**。
    @available(iOS 26.0, *)
    @ViewBuilder
    private func systemGlass(_ content: Content) -> some View {
        if isCircle {
            content.glassEffect(.regular, in: .circle)
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
    #endif

    /// 手搓版：四层玻璃感。
    ///
    /// ⚠️ 每一层都拆成独立小 View / 局部 let：
    ///    整条修饰链直接串起来会触发 "unable to type-check in reasonable time"。
    private func legacyGlass(_ content: Content) -> some View {
        let fill = GlassFill(tint: tint, strength: strength)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: max(cornerRadius - 1, 1),
                                     style: .continuous)
            .strokeBorder(.white.opacity(0.10 * strength), lineWidth: 1)

        let withFill = content.background(fill).clipShape(shape)
        let withRim = withFill.overlay(GlassRim(cornerRadius: cornerRadius, strength: strength))
        let withInner = withRim.overlay(inner).compositingGroup()
        let withShadow = withInner
            .shadow(color: .black.opacity(0.13 * strength), radius: 12, x: 0, y: 5)
            .shadow(color: .white.opacity(0.10 * strength), radius: 2, x: 0, y: -1)
        return withShadow
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
        modifier(LiquidGlass(cornerRadius: 999, tint: tint, isCircle: true))
    }

    /// 玻璃胶囊（栖阅顶栏那种图标组、目录底部的搜索框）
    func glassCapsule(strength: Double = 1.1,
                      tint: [Color] = [.white.opacity(0.26), .white.opacity(0.08)]) -> some View {
        modifier(LiquidGlass(cornerRadius: 999, tint: tint, strength: strength))
    }

    /// 只设玻璃的**形状**，不碰别的修饰链。
    ///
    /// iOS 26 → `glassEffect(_:in:)`，形状可以是 `.capsule` / `.circle` /
    /// `.rect(cornerRadius:)`。iOS 17~25 → 手搓版按同一形状画。
    ///
    /// ⚠️ 别在 glassEffect 之后再叠 `.clipShape()` / `.background()` ——
    ///    系统玻璃自带高光和描边，叠上去会把折射盖掉，
    ///    效果退化成「半透明白卡片」（这坑 Components.swift 里也标注过）。
    @ViewBuilder
    func glassEffectShape(_ shape: GlassShape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            switch shape {
            case .capsule:
                self.glassEffect(.regular, in: .capsule)
            case .circle:
                self.glassEffect(.regular, in: .circle)
            case .rounded(let r):
                self.glassEffect(.regular, in: .rect(cornerRadius: r))
            }
        } else {
            self.liquidGlass(cornerRadius: shape.cornerRadiusFallback)
        }
        #else
        self.liquidGlass(cornerRadius: shape.cornerRadiusFallback)
        #endif
    }
}

/// 玻璃形状。用自己的 enum 统一两条路，避免在调用点写 `#if`。
enum GlassShape {
    case capsule
    case circle
    case rounded(CGFloat)

    var cornerRadiusFallback: CGFloat {
        switch self {
        case .capsule, .circle: return 999
        case .rounded(let r): return r
        }
    }
}

/// 背景装饰：栖阅每个页面底下都有一层淡淡的插画。
/// 这里用系统符号画一组半透明小图案当点缀，不依赖图片资源。
/// 位置固定（不用随机），每次打开布局一样，视觉更稳。
struct GlassBackdrop: View {
    var symbols: [String] = ["heart.fill", "book.closed.fill", "ticket.fill",
                             "backpack.fill", "envelope.fill", "sparkles"]
    var count: Int = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let x = w * (0.06 + 0.42 * CGFloat((i * 7) % 10) / 10.0)
                    let y = h * (0.05 + 0.40 * CGFloat((i * 3) % 10) / 10.0)
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


// MARK: - sheet 手势行为修正（SwiftUI 没暴露，得走 UIKit）

/// 关掉「列表滚到边缘后继续拖 → sheet 自动展开」。
///
/// ## 症状
/// 用户在目录里**上滑**想翻看前面的章节，结果**页面自己变大了** ——
/// 期望是「目录滚动」，实际是「sheet resize」。
///
/// ## 根因
/// `UISheetPresentationController.prefersScrollingExpandsWhenScrolledToEdge`
/// **默认就是 `true`**：滚动内容到边缘后，剩余手势会被 sheet 接管去展开到下一个 detent。
/// SwiftUI 的 `.presentationDetents` **完全没有**暴露这个开关
/// （也没有任何等价修饰符），所以纯 SwiftUI 写不出栖阅那个行为。
///
/// 栖阅能用是因为它有 UIKit 层 / 或者它关了这个属性。
/// 轻阅这里用一个透明 UIViewController 往上找 `sheetPresentationController` 把它设成 false：
/// · 拖列表内容 → 永远是滚列表，滚到顶就 bounce，**页面尺寸不动**
/// · 拖 grabber → 系统 detent 手势不受影响，照样能在 .fraction / .large 之间切
///
/// 这才是「按住横线上滑才变大，目录上滑只滚目录」的正确拆法。
struct NoScrollExpand: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ vc: Host, context: Context) { vc.apply() }

    final class Host: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // sheet 的 presentingViewController 要等 present 完才拿得到，
            // 所以两个时机都试一遍（缺一个就可能不生效）。
            DispatchQueue.main.async { [weak self] in self?.apply() }
            apply()
        }

        func apply() {
            guard let sheet = findSheet() else { return }
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }

        private func findSheet() -> UISheetPresentationController? {
            var v: UIViewController? = self
            while let cur = v {
                if let s = cur.sheetPresentationController { return s }
                v = cur.parent
            }
            // contentViewController 自己的 presenting 链上再找一次
            v = presentingViewController
            while let cur = v {
                if let s = cur.sheetPresentationController { return s }
                v = cur.presentingViewController
            }
            return nil
        }
    }
}
