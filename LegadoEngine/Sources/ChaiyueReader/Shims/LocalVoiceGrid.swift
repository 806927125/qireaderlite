#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/VoicePicker.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/VoicePicker.swift

import SwiftUI

struct LocalVoiceGrid: View {
    let selected: Int?
    var loading: Int?
    var columns = 6
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("女声", LocalVoice.female)
            group("男声", LocalVoice.male)
        }
    }

    private func group(_ title: String, _ speakers: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(13)).foregroundStyle(Tok.fg3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(Array(speakers.enumerated()), id: \.element) { index, speaker in
                    cell(speaker, number: index + 1)
                }
            }
        }
    }

    private func cell(_ speaker: Int, number: Int) -> some View {
        let isSelected = selected == speaker
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            onPick(speaker)
        } label: {
            ZStack {
                if loading == speaker {
                    ProgressView().controlSize(.small).tint(Tok.onAccent)
                } else {
                    Text("\(number)").font(.num(14))
                }
            }
            .foregroundStyle(isSelected ? Tok.onAccent : Tok.fg2)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isSelected ? Tok.accent : Tok.fill, in: shape)
            .contentShape(shape)
            .animation(.snappy, value: isSelected)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(LocalVoice.name(of: speaker))
    }
}
#endif
