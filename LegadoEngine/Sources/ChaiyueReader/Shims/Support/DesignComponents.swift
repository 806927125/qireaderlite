#if canImport(UIKit)
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

struct RowPressStyle: ButtonStyle {
    var color: Color = Tok.press

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? color : .clear)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
