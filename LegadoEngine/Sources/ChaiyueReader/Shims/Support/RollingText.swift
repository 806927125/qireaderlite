#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Explore/ExploreScreen.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Explore/ExploreScreen.swift

import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

struct RollingText: View {
    let text: String

    var body: some View {
        Text(text)
            .id(text)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .clipped()
            .animation(.snappy, value: text)
    }
}
#endif
