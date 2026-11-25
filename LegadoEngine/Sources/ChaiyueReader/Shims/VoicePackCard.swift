#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/VoicePicker.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/VoicePicker.swift

import SwiftUI

struct VoicePackCard: View {
    let store: LocalVoiceStore

    var body: some View {
        HStack(spacing: 14) {
            Image(icon: "waveform")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Tok.accentInk)
                .frame(width: 44, height: 44)
                .background(Tok.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("自然人声").font(.ui(16, .medium)).foregroundStyle(Tok.fg)
                Text(subtitle)
                    .font(.num(12))
                    .foregroundStyle(failed ? Tok.accentInk : Tok.fg3)
                    .lineLimit(2)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            action
        }
        .padding(16)
        .cardSurface()
    }

    private var failed: Bool {
        if case .failed = store.phase { return true }
        return false
    }

    private var amount: String { "\(Formats.size(store.received)) / \(Formats.size(store.total))" }

    private var subtitle: String {
        switch store.phase {
        case .downloading: store.total > 0 ? amount : "准备下载"
        case .failed(let message): message
        default: store.isPartial ? amount : "离线可用 · 约 370 MB"
        }
    }

    @ViewBuilder
    private var action: some View {
        if store.phase == .downloading {
            Button {
                store.cancel()
            } label: {
                ZStack {
                    Circle().stroke(Tok.fill2, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: store.progress)
                        .stroke(Tok.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: store.progress)
                    Image(icon: "pause.fill").font(.system(size: 10)).foregroundStyle(Tok.fg2)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.press)
            .accessibilityLabel("暂停下载")
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.download()
            } label: {
                Text(failed ? "重试" : store.isPartial ? "继续" : "下载")
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Tok.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Tok.accent, in: Capsule())
            }
            .buttonStyle(.press)
        }
    }
}
#endif
