#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Fonts.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Fonts.swift

import CoreText
import Observation
import SwiftUI
import UIKit

extension Font {
    /// 标题宋体。下载完成前用苹方（粗体），视图读取 `songtiReady` 后会在下载完成时自动刷新
    static func serif(_ size: CGFloat, bold: Bool = true) -> Font {
        if FontLibrary.shared.songtiReady {
            return .custom(bold ? FontLibrary.songtiBold : FontLibrary.songti, fixedSize: size)
        }
        return .system(size: size, weight: bold ? .bold : .regular)
    }

    static func kai(_ size: CGFloat) -> Font {
        if FontLibrary.shared.kaitiReady {
            return .custom(FontLibrary.kaitiName(bold: false), fixedSize: size)
        }
        return .system(size: size)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 等宽数字
    static func num(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension UIFont {
    static func serif(_ size: CGFloat, bold: Bool = true) -> UIFont {
        UIFont(name: bold ? FontLibrary.songtiBold : FontLibrary.songti, size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
#endif
