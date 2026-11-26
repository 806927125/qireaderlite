#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Components.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Components.swift

import SwiftUI

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .bouncy, value: configuration.isPressed)
    }
}

/// ⭐⭐⭐⭐⭐ **【补】`ButtonStyle` 的静态成员 `.press` / `.pressSoft`**（2026-11-26 · CI327 实证）⭐⭐⭐⭐⭐
///   柴阅上游 `App/Sources/Design/Components.swift` 里，`PressStyle` 结构体**下面**跟着这个 extension：
///   ```swift
///   extension ButtonStyle where Self == PressStyle {
///       static var press: PressStyle { PressStyle() }
///       static var pressSoft: PressStyle { PressStyle(scale: 0.97) }
///   }
///   ```
///   ⇒ 我们上一版**只搬了结构体、没搬这个 extension** ⇒ 文字阅读器没用 `.press` 所以没暴露
///   ⇒ 搬漫画进来后它用了 `.buttonStyle(.press)` ⇒ CI 报
///   「reference to member 'press' cannot be resolved without a contextual type」⭐⭐⭐
extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
    static var pressSoft: PressStyle { PressStyle(scale: 0.97) }
}

struct RowPressStyle: ButtonStyle {
    var color: Color = Tok.press

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? color : .clear)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RowPressStyle {
    static var row: RowPressStyle { RowPressStyle() }
    static var glassRow: RowPressStyle { RowPressStyle(color: Tok.gFill) }
}

// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Components.swift 搬运**（明黄主按钮）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件位置：App/Sources/Design/Components.swift（`AccentButton` + `AccentPressStyle`，**一字未改**）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么必须搬**（不是「顺手补的」）：⭐⭐⭐
//   上游 `SourcePresenter.swift` 的**验证码页**用 `AccentButton(title:icon:wide:)` 提交验证码
//   ⇒ 它是**阅读器验证码流程的实现件**（不是可选装饰）⇒ 不搬 ⇒ `cannot find 'AccentButton' in scope`
//   ⇒ 验证码页整页编不出来 ⇒ 书源登录（`java.getVerificationCode`）直接废掉 ⭐⭐⭐
//   ⇒ 注意：**只搬这一颗按钮**，不搬上游 Components.swift 的其它组件（书架/详情/设置页用不到）⭐⭐⭐
/// 明黄主按钮（原型 `.btn-accent`）
struct AccentButton: View {
    let title: String
    var icon: String? = "book"
    var detail: String?
    var wide = false
    /// 半透明磨砂：浅色下白、深色下黑，用在有底色的卡片上
    var frosted = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if frosted { frostedBody } else { accentBody }
    }

    private var frostedBody: some View {
        let light = scheme == .light
        return Button(action: action) {
            label
                .foregroundStyle(light ? Tok.fg : .white)
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(light ? Color.white.opacity(0.5) : Color.black.opacity(0.32)))
                }
                .overlay(Capsule().strokeBorder(light ? Color.white.opacity(0.7) : Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(light ? 0.08 : 0.25), radius: 12, y: 6)
        }
        .buttonStyle(AccentPressStyle())
    }

    private var label: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(icon: icon).font(.system(size: wide ? 17 : 15, weight: .semibold))
            }
            Text(title).font(.ui(wide ? 17 : 16, .semibold))
            if let detail {
                Text(detail).font(.num(13, .medium)).opacity(0.72).padding(.leading, 2)
            }
        }
        .padding(.leading, wide ? 0 : 18)
        .padding(.trailing, wide ? 0 : 22)
        .frame(maxWidth: wide ? .infinity : nil)
        .frame(height: wide ? 56 : 46)
        .contentShape(Capsule())
    }

    private var accentBody: some View {
        Button(action: action) {
            label
            .foregroundStyle(Tok.onAccent)
            .background(Tok.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5).blendMode(.overlay))
            .shadow(color: Tok.accent.opacity(0.5), radius: 14, y: 9)
        }
        .buttonStyle(AccentPressStyle())
    }
}

private struct AccentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .bouncy, value: configuration.isPressed)
    }
}

struct SegmentedChips: View {
    let items: [String]
    @Binding var selection: Int
    var height: CGFloat = 34
    var font: Font = .ui(14)
    var itemWidth: CGFloat?
    var inset: CGFloat = 4
    var glass = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let on = index == selection
                Button {
                    guard index != selection else { return }
                    withAnimation(.snappy) { selection = index }
                } label: {
                    Text(item)
                        .font(font)
                        .fontWeight(on ? .semibold : .regular)
                        .foregroundStyle(on ? (glass ? Tok.gFg : Tok.fg) : (glass ? Tok.gFg2 : Tok.fg2))
                        .lineLimit(1)
                        .padding(.horizontal, itemWidth == nil ? 16 : 0)
                        .frame(width: itemWidth, height: height)
                        .background {
                            if on {
                                Capsule()
                                    .fill(Tok.segBg)
                                    .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(inset)
        .background(glass ? Tok.gFill : Tok.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(glass ? .clear : Tok.edge, lineWidth: 0.5))
    }
}

struct Hairline: View {
    var value: Double
    var track: Color = Tok.fill2
    var tint: Color = Tok.fg2
    var height: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

extension EnvironmentValues {
    /// 内容位于玻璃弹层上：卡片、行与图标改用玻璃色调
    @Entry var onGlass = false
}
#endif
