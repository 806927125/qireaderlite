#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/Appearance.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/Appearance.swift

import Observation
import SwiftUI
import UIKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "自动"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

@Observable
final class AppearanceStore {
    private static let key = "appearance"
    private(set) var mode: AppearanceMode

    init() {
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
    }

    /// `origin` 为窗口坐标中的触点
    func set(_ newMode: AppearanceMode, origin: CGPoint? = nil) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.key)
        guard let window = Self.keyWindow else {
            apply()
            return
        }
        let before = window.traitCollection.userInterfaceStyle
        let after = newMode == .system ? (window.windowScene?.traitCollection.userInterfaceStyle ?? before) : newMode.style
        if before == after || UIAccessibility.isReduceMotionEnabled {
            apply()
            return
        }
        CircularReveal.perform(in: window, origin: origin) { self.apply() }
    }

    /// 恢复备份后重新读取
    func reload() {
        let stored = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
        guard stored != mode else { return }
        mode = stored
        apply()
    }

    static let defaultsKey = key

    /// 切到指定的深浅外观（阅读器「夜间/日间」、选择另一种外观的阅读主题时调用）
    func force(_ scheme: ColorScheme, origin: CGPoint? = nil) {
        set(scheme == .dark ? .dark : .light, origin: origin)
    }

    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                window.overrideUserInterfaceStyle = mode.style
            }
        }
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
#endif
