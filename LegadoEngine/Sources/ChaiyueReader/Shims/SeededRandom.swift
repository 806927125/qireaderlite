// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/CoverArt.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/CoverArt.swift

import SwiftUI
import UIKit
import Foundation

#if os(iOS)

struct SeededRandom {
    private var state: UInt32

    init(_ seed: String) {
        var s: UInt32 = 2_166_136_261
        for unit in seed.utf16 {
            s = (s ^ UInt32(unit)) &* 16_777_619
        }
        state = s
    }

    mutating func next() -> CGFloat {
        state = state &* 1_664_525 &+ 1_013_904_223
        return CGFloat(state) / 4_294_967_296
    }
}
#endif  // #if os(iOS)
