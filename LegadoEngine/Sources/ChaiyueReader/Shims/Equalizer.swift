#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Shell/IslandOverlay.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Shell/IslandOverlay.swift

import ChaiyueModels
import SwiftUI

struct Equalizer: View {
    var active: Bool
    var color: Color = Tok.accent

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = [0, 0.35, 0.7, 0.15][i]
                    let value = active ? 0.3 + 0.7 * abs(sin((t + phase) * .pi)) : 0.3
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 14 * value)
                }
            }
            .frame(height: 14)
        }
    }
}
#endif
