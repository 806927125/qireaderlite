#if os(iOS)
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
        // ⚠️ 写盘挪到 `apply()`（见下）⇒ 这样 CircularReveal 的快照拍到的是**切换前**的样子 ⇒ 转场动画还在 ⭐⭐⭐
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
        // ⭐⭐⭐⭐⭐ **【改造】不再遍历窗口改 `overrideUserInterfaceStyle`**（2026-11-26 · 真机反馈）⭐⭐⭐⭐⭐
        //   **症状**：阅读器底部悬浮栏的「日间 / 夜间」点了没反应 ⭐⭐⭐
        //   **根因**：柴阅原版在这里改**所有窗口**的 `overrideUserInterfaceStyle`，
        //     而轻阅**根部强制 `.preferredColorScheme(.dark)`**（2026-11-24 真机反馈：玻璃按钮乳白）⇒
        //     ⇒ **两边打架**：SwiftUI 一直要 .dark、UIKit 这边要 .light ⇒ 切不动 ⭐⭐⭐
        //     ⇒ 连带「选浅色主题」也切不动（柴阅 `select()` 会把浅色主题写进 `lightTheme` 槽，
        //       而当前 scheme 恒为 .dark ⇒ `theme(for:)` 一直读 `darkTheme`）⭐⭐⭐
        //   ⇒ **正解**：外观**只作用在阅读器这一层**，由宿主用 SwiftUI 的 `.preferredColorScheme` 施加
        //     （`QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderScreen.swift`）⭐⭐⭐
        //     ⇒ 轻阅其它界面永远深色（不受影响）⇒ 玻璃按钮仍不乳白 ⭐⭐⭐
        //
        // ⭐⭐⭐ **写盘挪到这里**（原来在 `set()` 开头就写）：
        //   那样 CircularReveal 拍到的快照已经是浅色 ⇒ **转场动画失效**（瞬间跳色）⭐⭐⭐
        //   ⇒ 现在：先拍快照（深色）→ 再写盘 → 宿主切浅色 → 揭开快照看到浅色 ⇒ **转场还在** ⭐⭐⭐
        UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
#endif
