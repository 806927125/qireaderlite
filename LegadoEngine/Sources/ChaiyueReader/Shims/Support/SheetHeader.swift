#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/Sheets.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/Sheets.swift

import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

struct SheetHeader<Trailing: View>: View {
    let title: String
    var count: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.serif(22)).foregroundStyle(Tok.gFg)
            if let count {
                Text(count)
                    .font(.num(14))
                    .foregroundStyle(Tok.gFg3)
                    .contentTransition(.numericText())
            }
            Spacer()
            trailing
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }
}

private struct SheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(38)
        }
    }
}

struct ProgressLine: View {
    var value: Double
    var done: Bool

    var body: some View {
        Hairline(value: value, track: Tok.gFill, tint: Tok.accent, height: 2)
            .animation(.out, value: value)
            .opacity(done ? 0 : 1)
            .animation(.easeOut(duration: 0.4).delay(done ? 0.4 : 0), value: done)
    }
}
#endif
