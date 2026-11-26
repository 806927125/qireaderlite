#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Compat.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Compat.swift

import SwiftUI
import UIKit

struct ForEachSubview<Content: View, Row: View>: View {
    let content: Content
    let row: (_ index: Int, _ subview: AnyView) -> Row

    init(_ content: Content, @ViewBuilder row: @escaping (_ index: Int, _ subview: AnyView) -> Row) {
        self.content = content
        self.row = row
    }

    var body: some View {
        if #available(iOS 18, *) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    row(index, AnyView(subview))
                }
            }
        } else {
            _VariadicView.Tree(VariadicRows(row: row)) { content }
        }
    }
}

private struct VariadicRows<Row: View>: _VariadicView_MultiViewRoot {
    let row: (Int, AnyView) -> Row

    func body(children: _VariadicView.Children) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            row(index, AnyView(child))
        }
    }
}
#endif

// ═══════════════════════════════════════════════════════════════════
// ↓↓↓ 本轮补：柴阅阅读器用到的 5 个 App 层设计修饰符（照搬柴阅 Design/Glass.swift、Compat.swift、Sheets.swift、Appearance.swift）

import UIKit

// =============================================================================
// ⭐⭐⭐⭐⭐ **柴阅 App 层的设计修饰符（补齐 vendor 缺口）**（2026-11-25）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么需要** ⭐⭐⭐：
//   柴阅的阅读界面（`App/Sources/Reader`）大量使用它自己 App 层的视觉修饰符：
//   `glassSurface` / `glassCircle` / `qSheet` / `readFrame` / `Color.blend(with:by:)` ⭐⭐⭐
//   ⇒ 那些定义在 `App/Sources/Design/*` 与 `App/Sources/App/Appearance.swift` 里
//   ⇒ 我们只 vendor 了阅读器 ⇒ 这些修饰符**缺失** ⇒ 编译报
//      「value of type 'some View' has no member 'glassSurface'」⭐⭐⭐
//
// ⭐⭐⭐ **做法：照柴阅原样搬**（柴阅 = GPL-3.0，本仓库已整包 vendor 阅读器，许可口径一致）⭐⭐⭐
//   · iOS 26 用系统 `glassEffect`（**本 App deployment target = iOS 26 ⇒ 走的就是系统玻璃**）⭐⭐⭐
//   · 更早的系统用材质叠加原型色调（降级路径）⭐⭐⭐
// =============================================================================

#if os(iOS)

extension View {
    /// 毛玻璃表面：iOS 26 起用系统 Liquid Glass，更早的系统用材质叠加原型色调
    /// （照搬自柴阅 `App/Sources/Design/Glass.swift`）
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, strong: Bool = false, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(strong ? Tok.gBgStrong : Tok.gBg)
                }
            }
            .overlay { shape.stroke(Tok.gLine, lineWidth: 0.5) }
            .shadow(color: Tok.shadowWarm.opacity(0.2), radius: 24, y: 14)
        }
    }

    /// 浮在内容上的小圆按钮底（原型 `.circle-btn`；照搬自柴阅）
    @ViewBuilder
    func glassCircle(_ size: CGFloat = 40) -> some View {
        if #available(iOS 26, *) {
            self.frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .background(Tok.btnGlass, in: Circle())
                .overlay(Circle().stroke(Tok.edge, lineWidth: 0.5))
        }
    }

    /// 统一的弹层外观（照搬自柴阅 `App/Sources/Screens/Common/Sheets.swift`）
    func qSheet(_ detents: Set<PresentationDetent> = [.large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .modifier(SheetBackground())
    }

    /// 把自己的 frame 写回绑定（照搬自柴阅 `App/Sources/App/Appearance.swift`）
    func readFrame(_ frame: Binding<CGRect>) -> some View {
        modifier(WindowFrameReader(frame: frame))
    }
}

/// 弹层背景（iOS 26 用系统玻璃；更早用材质）
private struct SheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

/// 把视图的 frame 写回绑定
private struct WindowFrameReader: ViewModifier {
    @Binding var frame: CGRect

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(key: FrameKey.self, value: proxy.frame(in: .global))
            }
        }
        .onPreferenceChange(FrameKey.self) { frame = $0 }
    }
}

private struct FrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

extension CGRect {
    /// 中心点（柴阅 `App/Appearance.swift` 里同一个扩展）
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension Color {
    /// `Color.mix(with:by:)` 的兼容版（照搬自柴阅 `App/Sources/Design/Compat.swift`）
    func blend(with other: Color, by fraction: Double) -> Color {
        if #available(iOS 18, *) {
            return mix(with: other, by: fraction)
        }
        let t = CGFloat(min(max(fraction, 0), 1))
        let a = UIColor(self), b = UIColor(other)
        return Color(uiColor: UIColor { traits in
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            a.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            b.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                           blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
        })
    }
}

#endif  // #if os(iOS)
