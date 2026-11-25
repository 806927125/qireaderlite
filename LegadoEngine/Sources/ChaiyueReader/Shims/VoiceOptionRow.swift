#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/VoicePicker.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/VoicePicker.swift

import SwiftUI

struct VoiceOptionRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    var loading = false
    let action: () -> Void

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(16)).foregroundStyle(Tok.fg).lineLimit(1)
                    if let detail {
                        Text(detail).font(.ui(12)).foregroundStyle(Tok.fg3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(loading ? 1 : 0)
                    Image(icon: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tok.accentInk)
                        .opacity(selected && !loading ? 1 : 0)
                        .scaleEffect(selected ? 1 : 0.3)
                }
                .animation(.bouncy, value: selected)
                .animation(.snappy, value: loading)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }
}
#endif
