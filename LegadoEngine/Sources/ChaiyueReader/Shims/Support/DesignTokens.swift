// ⭐⭐⭐ **直接搬自柴阅 `App/Sources/Design/Tokens.swift`**（原样 ⇒ 令牌齐全：Tok.press / Tok.large / …）
//   之前我们手写的残缺 Tok ⇒ 柴阅阅读器里的 `Tok.press` / `Tok.large` 全部编译不过 ⭐⭐⭐
#if os(iOS)

import SwiftUI
import UIKit
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// 随外观切换的颜色；SwiftUI 会在后台渲染线程取色，闭包不能带主线程隔离
    nonisolated static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { @Sendable traits in traits.userInterfaceStyle == .dark ? dark : light }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(uiColor: UIColor(hex: hex, alpha: alpha))
    }

    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: .dynamic(light: light, dark: dark))
    }

    /// 解析 `#RRGGBB`
    init(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        self.init(hex: UInt32(text, radix: 16) ?? 0)
    }
}

/// 设计令牌：取自 App 图标——墨蓝描边、柴犬杏色、书页明黄
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

/// 统一的弹簧曲线（原型 `--spring-soft / snappy / bouncy`）
extension Animation {
    static let soft = Animation.spring(duration: 0.52, bounce: 0.06)
    static let snappy = Animation.spring(duration: 0.38, bounce: 0.08)
    static let bouncy = Animation.spring(duration: 0.5, bounce: 0.32)
    static let out = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)
    static let ios = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.5)
}

enum Metrics {
    static let coverRatio: CGFloat = 172.0 / 120.0
    static let coverRadius: CGFloat = 6
    static let cardRadius: CGFloat = 22
}

// MARK: - 阴影

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

extension View {
    func coverShadow(lifted: Bool = false) -> some View { modifier(CoverShadow(lifted: lifted)) }
    func cardSurface(radius: CGFloat = Metrics.cardRadius) -> some View { modifier(CardSurface(radius: radius)) }
    func raisedSurface<S: InsettableShape>(_ shape: S) -> some View { modifier(RaisedSurface(shape: shape)) }
}

#endif  // #if os(iOS)
