#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Tokens.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Tokens.swift

import SwiftUI
import UIKit

enum Tok {
    static let bg = Color(light: UIColor(hex: 0xF7F4EF), dark: UIColor(hex: 0x0D0E18))
    static let bg1 = Color(light: UIColor(hex: 0xEFEBE4), dark: UIColor(hex: 0x151624))
    static let bg2 = Color(light: UIColor(hex: 0xE7E2D9), dark: UIColor(hex: 0x1D1E2E))
    static let card = Color(light: UIColor(hex: 0xFFFEFC), dark: UIColor(hex: 0x161725))
    static let fill = Color(light: UIColor(hex: 0x14142B, alpha: 0.06), dark: UIColor(hex: 0xFFF6E8, alpha: 0.065))
    static let fill2 = Color(light: UIColor(hex: 0x14142B, alpha: 0.11), dark: UIColor(hex: 0xFFF6E8, alpha: 0.12))
    static let edge = Color(light: UIColor(hex: 0x14142B, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.06))
    static let press = Color(light: UIColor(hex: 0x14142B, alpha: 0.05), dark: UIColor(white: 1, alpha: 0.045))
    static let raise = Color(light: UIColor(hex: 0xFFFEFC), dark: UIColor(white: 1, alpha: 0.07))
    static let tile = Color(light: UIColor(hex: 0xF0ECE5), dark: UIColor(hex: 0x25263A))
    static let btnGlass = Color(light: UIColor(hex: 0xFFFEFC, alpha: 0.72), dark: UIColor(white: 1, alpha: 0.09))
    static let line = Color(light: UIColor(hex: 0x14142B, alpha: 0.09), dark: UIColor(hex: 0xF5F2EC, alpha: 0.08))
    static let fg = Color(light: UIColor(hex: 0x14142B), dark: UIColor(hex: 0xF5F2EC))
    static let fg2 = Color(light: UIColor(hex: 0x5C5D72), dark: UIColor(hex: 0xABACBE))
    static let fg3 = Color(light: UIColor(hex: 0x9C9CAD), dark: UIColor(hex: 0x74758A))
    static let accent = Color(hex: 0xFFD508)
    static let accentPress = Color(hex: 0xEBC200)
    /// 明黄底上的文字与图标
    static let onAccent = Color(hex: 0x14142B)
    /// 当作文字色的强调色：浅色下明黄看不清，换成同色相的琥珀
    static let accentInk = Color(light: UIColor(hex: 0xA86F00), dark: UIColor(hex: 0xFFD508))
    static let accentSoft = Color(light: UIColor(hex: 0xFFD508, alpha: 0.24), dark: UIColor(hex: 0xFFD508, alpha: 0.16))
    static let veil = Color(light: UIColor(hex: 0xF7F4EF, alpha: 0.55), dark: UIColor(hex: 0x07080F, alpha: 0.42))

    // 毛玻璃色调
    static let gBg = Color(light: UIColor(hex: 0xFDFCF9, alpha: 0.7), dark: UIColor(hex: 0x22233A, alpha: 0.62))
    static let gBgStrong = Color(light: UIColor(hex: 0xFAF9F6, alpha: 0.9), dark: UIColor(hex: 0x1C1D30, alpha: 0.84))
    static let gFg = Color(light: UIColor(hex: 0x14142B), dark: UIColor(hex: 0xF5F2EC))
    static let gFg2 = Color(light: UIColor(hex: 0x14142B, alpha: 0.6), dark: UIColor(hex: 0xF5F2EC, alpha: 0.62))
    static let gFg3 = Color(light: UIColor(hex: 0x14142B, alpha: 0.36), dark: UIColor(hex: 0xF5F2EC, alpha: 0.36))
    static let gLine = Color(light: UIColor(white: 0, alpha: 0.07), dark: UIColor(white: 1, alpha: 0.09))
    static let gFill = Color(light: UIColor(white: 0, alpha: 0.05), dark: UIColor(white: 1, alpha: 0.08))
    static let gFill2 = Color(light: UIColor(white: 0, alpha: 0.1), dark: UIColor(white: 1, alpha: 0.15))
    static let gHi = Color(light: UIColor(white: 1, alpha: 0.75), dark: UIColor(white: 1, alpha: 0.16))
    static let gAccent = Color(light: UIColor(hex: 0xA86F00), dark: UIColor(hex: 0xFFD508))
    static let segBg = Color(light: UIColor.white, dark: UIColor(white: 1, alpha: 0.15))

    // 阴影色
    static let shadowWarm = Color(light: UIColor(hex: 0x3A2C18), dark: UIColor.black)
}

struct CoverShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var lifted = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let color = Tok.shadowWarm
        if lifted {
            content
                .shadow(color: color.opacity(dark ? 0.5 : 0.3), radius: 22, y: 24)
                .shadow(color: color.opacity(dark ? 0.32 : 0.12), radius: 7, y: 6)
        } else {
            content
                .shadow(color: color.opacity(dark ? 0.55 : 0.32), radius: 9, y: 9)
                .shadow(color: color.opacity(dark ? 0.28 : 0.12), radius: 2.5, y: 2)
        }
    }
}

struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Metrics.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Tok.card, in: shape)
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.05) : Color(hex: 0x14142B, alpha: 0.06), lineWidth: 0.5))
            .shadow(color: scheme == .dark ? .clear : Color(hex: 0x3A2C18).opacity(0.08), radius: 14, y: 8)
    }
}

struct RaisedSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var shape: S

    func body(content: Content) -> some View {
        content
            .background(Tok.raise, in: shape)
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color(hex: 0x14142B, alpha: 0.06), lineWidth: 0.5))
            .shadow(color: scheme == .dark ? .clear : Color(hex: 0x3A2C18).opacity(0.1), radius: 7, y: 4)
    }
}
#endif
