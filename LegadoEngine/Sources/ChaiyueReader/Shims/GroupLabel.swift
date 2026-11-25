#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/SettingRows.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/SettingRows.swift

import SwiftUI

struct GroupLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.ui(13))
            .tracking(0.5)
            .foregroundStyle(Tok.fg3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}
#endif
