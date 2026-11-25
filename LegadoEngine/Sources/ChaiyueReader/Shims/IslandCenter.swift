#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/AppModel.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/AppModel.swift

import Observation
import ChaiyueModels
import ChaiyueEngine
import ChaiyueReaderServices
import ChaiyueEngine
import SwiftUI

@Observable
final class IslandCenter {
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var icon: String
        var text: String
        var danger: Bool
    }

    private(set) var current: Toast?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ icon: String, _ text: String, danger: Bool = false, duration: Double = 2.2) {
        let toast = Toast(icon: icon, text: text, danger: danger)
        current = toast
        IslandWindow.raise()
        hideTask?.cancel()
        // 长消息按字数多停留一会儿，最长 6 秒
        let visible = max(duration, min(6, 1.2 + Double(text.count) * 0.08))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(visible))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }
}
#endif
