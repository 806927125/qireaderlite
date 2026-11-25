import SwiftUI

// =============================================================================
// ⭐⭐⭐ **柴阅的按钮样式（照搬 `App/Sources/Design/Components.swift`）**（2026-11-25）⭐⭐⭐
//
// ⚠️ 柴阅阅读器里到处 `.buttonStyle(.press)` / `.row` / `.glassRow`
//   ⇒ 这些 `static var` 挂在 `ButtonStyle` 的 where 扩展上 ⇒ 属于柴阅 App 层 ⇒ 我们缺 ⭐⭐⭐
// =============================================================================

#if os(iOS)

/// 按下缩小、松手回弹（原型 `.press`）
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .bouncy, value: configuration.isPressed)
    }
}

/// 列表行按压高亮（原型 `.row.is-pressed`）
struct RowPressStyle: ButtonStyle {
    var color: Color = Tok.press

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? color : .clear)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
    static var pressSoft: PressStyle { PressStyle(scale: 0.97) }
}

extension ButtonStyle where Self == RowPressStyle {
    static var row: RowPressStyle { RowPressStyle() }
    static var glassRow: RowPressStyle { RowPressStyle(color: Tok.gFill) }
}

#endif  // #if os(iOS)
