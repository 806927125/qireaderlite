#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/SettingRows.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/SettingRows.swift

import SwiftUI

struct SettingRow<Value: View>: View {
    var icon: String?
    let title: String
    var chevron = true
    var tint: Color?
    @ViewBuilder var value: Value
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        HStack(spacing: 14) {
            if let icon { RowIcon(symbol: icon, tint: tint) }
            Text(title)
                .font(.ui(16))
                .foregroundStyle(tint ?? (onGlass ? Tok.gFg : Tok.fg))
                .lineLimit(1)
            Spacer(minLength: 8)
            value
                .font(.num(15))
                .foregroundStyle(onGlass ? Tok.gFg3 : Tok.fg3)
                .lineLimit(1)
            if chevron {
                Image(icon: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(onGlass ? Tok.gFg3 : Tok.fg3)
                    .padding(.leading, -6)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

struct RowIcon: View {
    let symbol: String
    var tint: Color?
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        Group {
            if symbol == "Aa" {
                Text("Aa").font(.system(size: 14, weight: .medium, design: .serif))
            } else {
                Image(icon: symbol).font(.system(size: 15, weight: .medium))
            }
        }
        .foregroundStyle(tint ?? (onGlass ? Tok.gFg : Tok.fg))
        .frame(width: 30, height: 30)
        .background(onGlass ? Tok.gFill2 : Tok.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct ToggleRow: View {
    var icon: String?
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(icon: icon, title: title, chevron: false) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Tok.accent)
        }
    }
}
#endif
