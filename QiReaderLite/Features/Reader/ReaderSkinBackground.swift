import SwiftUI
import UIKit

// =============================================================================
// ⭐⭐⭐⭐⭐ **阅读页「皮肤底」**（照**柴阅**的观感重写，2026-11-25）⭐⭐⭐⭐⭐
//
//   ⭐ 文件名/类型名从 `ReaderMixedBackground` 改成 `ReaderSkinBackground`：
//   ⇒ 「混色辉光」是**栖阅**的做法；**柴阅是「皮肤底 + 章节号装饰」** ⇒ 名字要跟参照对象一致 ⭐⭐⭐
//
// ⭐⭐⭐ **柴阅的阅读页观感**（读 Chaiyue 源码得出，见 `App/Sources/Reader/ReaderSkin.swift`）：
//   · 背景 = **每套皮肤一张底图/纯色底**（宣纸 / 晴窗 / 星夜 / 烛灯）⭐⭐⭐
//   · 字体 = 每套皮肤指定（宋 / 苹方 / 楷）⭐⭐⭐
//   · 章节号 = **每套皮肤有自己的装饰**（宣纸=朱印、晴窗=描边大号、星夜/烛灯=居中）⭐⭐⭐
//   · 强调色 = 每套皮肤一个（朱红 / 墨 / 金 / 暖橙）⭐⭐⭐
// ⇒ ⇒ **不能抄它的代码与背景图**（**GPL-3.0**）⇒ ⇒ 只**照观感重写**（参数与画法是我们自己的）⭐⭐⭐
//
// ⭐⭐⭐ **与栖阅的区别**（我一开始搞错了：栖阅是 `ColorMixedBackground` 混色辉光；
//    **柴阅是「皮肤底 + 章节号装饰」**）⇒ ⇒ 这里改成**皮肤底**，不搞辉光 ⭐⭐⭐
//
// ⭐⭐⭐ **为什么搬这个**：
//   栖阅的阅读页底**不是一块纯色**（`ColorMixedBackground`：渐变 + 三团辉光 + 一道高光）
//   ⇒ 而轻阅一直是 `theme.bg.ignoresSafeArea()`（**一块纯色**）⇒ 观感差一截 ⭐⭐⭐
//   ⇒ 栖阅 UI 反推件里 `ColorMixedBackground` 的成员清单（见 `files/ColorMixedBackground.swift.md`）：
//      `gradientColors` / `primaryGlow` / `secondaryGlow` / `tertiaryGlow` / `sheen`
//      / `intensity` / `opacity` / `legacyGradient` / `liquidGlass` / `backgroundImageView`
//   ⇒ 本文件按同一套结构实现（**背景图那部分我们没有对应功能，先不做**）⭐⭐⭐
//
// ⭐⭐⭐ **辉光的配色跟着 App 走**（青 / 紫 / 粉 = `Terminal`）⇒ 与外壳同一套美学 ⭐⭐⭐
//   ⇒ 浅色纸底 ⇒ 辉光很淡（0.10）；深色底 ⇒ 辉光更亮（0.22）⇒ 两种底都好看 ⭐⭐⭐
// =============================================================================

struct ReaderSkinBackground: View {
    /// 阅读主题（决定底色与明暗）
    let theme: ReaderTheme
    /// 强度 0…1（栖阅的 `intensity`）
    var intensity: Double = 1.0

    /// ⭐⭐⭐ 深色底？（`ReaderTheme.isDark` ⇒ 纸色那一排 vs 深色那一排）⭐⭐⭐
    private var isDark: Bool { ReaderTheme.isDark(theme) }

    /// ⭐⭐⭐ **底色渐变**（栖阅的 `gradientColors`）：从底色派生两档，纸色更暖、夜间更沉 ⭐⭐⭐
    private var gradientColors: [Color] {
        if isDark {
            return [theme.bg.mix(with: Terminal.violet, amount: 0.10),
                    theme.bg,
                    theme.bg.mix(with: .black, amount: 0.18)]
        }
        return [theme.bg.mix(with: .white, amount: 0.35),
                theme.bg,
                theme.bg.mix(with: Terminal.violet, amount: 0.06)]
    }

    var body: some View {
        ZStack {
            // ① 底：渐变（不是纯色）
            LinearGradient(colors: gradientColors,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // ② 柴阅的皮肤底是**纯色 + 一点层次** ⇒ 这里给一层**极轻的上下渐变**
            //    （纯色太「死」；但**不做大辉光** —— 那是栖阅的做法，不是柴阅的）⭐⭐⭐
            LinearGradient(colors: [
                theme.bg.mix(with: .white, amount: isDark ? 0.03 : 0.10),
                theme.bg,
                theme.bg.mix(with: .black, amount: isDark ? 0.10 : 0.03),
            ],
            startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // ③ 章节号装饰的**挂点**（柴阅每套皮肤在章首页画自己的装饰）
            //    ⇒ 本轮先留位（`ChapterDecorSlot` 还没画），下一步做 ⭐⭐⭐
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 颜色工具（混色要用）

extension Color {
    /// ⭐⭐⭐ **混色**：`self` 与 `other` 按 `amount` 混合（0 = 全自己，1 = 全对方）⭐⭐⭐
    func mix(with other: Color, amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let t = max(0, min(1, amount))
        return Color(red: Double(ar + (br - ar) * t),
                     green: Double(ag + (bg - ag) * t),
                     blue: Double(ab + (bb - ab) * t),
                     opacity: Double(aa + (ba - aa) * t))
    }
}
