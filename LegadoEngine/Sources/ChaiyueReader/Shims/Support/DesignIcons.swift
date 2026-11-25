#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Icons.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Icons.swift

import SwiftUI
import UIKit

import SwiftUI
import UIKit

// 柴阅自绘图标：Assets.xcassets/Icons 里的自定义 SF Symbol（资源名 cy.<SF 名>），由 Tools/build_icons.py 从图集描出。
// 和系统图标一样跟着 .font 缩放、跟着前景色着色；图标包里没有的名字退回系统 SF Symbol

extension Image {
    nonisolated init(icon name: String) {
        if IconNames.all.contains(name) {
            self.init("cy." + name)
        } else {
            self.init(systemName: name)
        }
    }
}

extension UIImage {
    nonisolated static func icon(_ name: String, withConfiguration configuration: UIImage.Configuration? = nil) -> UIImage? {
        guard IconNames.all.contains(name) else { return UIImage(systemName: name, withConfiguration: configuration) }
        return UIImage(named: "cy." + name, in: nil, with: configuration)
    }
}

extension Label where Title == Text, Icon == Image {
    nonisolated init(_ title: some StringProtocol, icon: String) {
        self.init { Text(title) } icon: { Image(icon: icon) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    nonisolated init(_ title: some StringProtocol, icon: String, role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    nonisolated init(_ title: some StringProtocol, icon: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }
}
#endif
