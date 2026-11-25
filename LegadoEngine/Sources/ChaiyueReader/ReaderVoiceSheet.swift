// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
import SwiftUI

/// 阅读器朗读条里的换声音面板：点按立即从当前句改用新声音，面板不收起，方便连续对比
struct ReaderVoiceSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        let engines = app.library.httpTTS.enabledEngines
        let engine = app.selectedEngine
        let local = app.usesLocalVoice
        let system = engine == nil && !local
        let buffering = app.speech.buffering
        ScrollView {
            VStack(spacing: 0) {
                header(buffering: buffering)

                GroupLabel("本地神经语音")
                if app.localVoiceReady {
                    LocalVoiceGrid(selected: local ? settings.localVoice : nil,
                                   loading: local && buffering ? settings.localVoice : nil) { speaker in
                        pick {
                            settings.speechEngine = nil
                            settings.localVoice = speaker
                        }
                    }
                    .padding(16)
                    .cardSurface()
                    .padding(.horizontal, 16)
                } else {
                    VoicePackCard(store: app.voiceStore)
                        .padding(.horizontal, 16)
                }

                if !engines.isEmpty {
                    GroupLabel("在线朗读")
                    CardGroup(separatorInset: 20) {
                        ForEach(engines) { tts in
                            let selected = engine?.id == tts.id
                            VoiceOptionRow(title: tts.name.isEmpty ? "未命名" : tts.name.withoutEmoji,
                                           selected: selected, loading: selected && buffering) {
                                pick { settings.speechEngine = tts.id }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                GroupLabel("系统语音")
                CardGroup(separatorInset: 20) {
                    VoiceOptionRow(title: "默认", selected: system && settings.speechVoice == nil) {
                        pick { useSystem(nil) }
                    }
                    ForEach(app.voices.voices) { voice in
                        VoiceOptionRow(title: voice.name, detail: voice.detail,
                                       selected: system && settings.speechVoice == voice.id) {
                            pick { useSystem(voice.id) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .task { app.voices.load() }
    }

    private func header(buffering: Bool) -> some View {
        HStack(spacing: 12) {
            Text("声音")
                .font(.serif(22))
                .foregroundStyle(Tok.fg)
            Spacer(minLength: 8)
            Group {
                if buffering {
                    ProgressView().controlSize(.small)
                } else {
                    Equalizer(active: app.speech.state == .speaking)
                        .frame(width: 18, height: 14)
                }
            }
            .frame(width: 20)
            Text(app.voiceName)
                .font(.ui(14))
                .foregroundStyle(Tok.fg2)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.snappy, value: app.voiceName)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
    }

    private func useSystem(_ id: String?) {
        app.settings.speechVoice = id
        app.settings.speechEngine = nil
        app.settings.localVoice = -1
    }

    private func pick(_ change: () -> Void) {
        change()
        app.applyVoiceChange()
    }
}
#endif  // #if canImport(UIKit)
