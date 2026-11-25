#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Components.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Components.swift

import SwiftUI

struct CardGroup<Content: View>: View {
    var separatorInset: CGFloat = 58
    @ViewBuilder var content: Content
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            ForEachSubview(content) { index, subview in
                subview
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(onGlass ? Tok.gLine : Tok.line).frame(height: 0.5).padding(.leading, separatorInset)
                        }
                    }
            }
        }
        .clipShape(shape)
        .modifier(GroupSurface(onGlass: onGlass, shape: shape))
    }
}

private struct GroupSurface: ViewModifier {
    let onGlass: Bool
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if onGlass {
            content.background(Tok.gFill, in: shape)
        } else {
            content.cardSurface()
        }
    }
}
#endif
