import SwiftUI
import UIKit

/// 引擎自检 / 日志面板
///
/// ⚠️ 原来是 `.alert`，只能显示一行 Text —— 而自检要显示的是**几十上百条日志**：
///    · alert 装不下 → 只能截 12 条 → 站方登录时打的那张会员卡片
///      会被后来的日志直接挤掉 → 用户什么都看不见
///    · alert 也没有「复制」按钮 → 想把日志发给对方只能靠手抄
///
/// 所以改成 sheet：摘要 + 全量日志（懒加载），工具栏上直接一个「复制日志」。
struct EngineLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var resetNote = ""
    /// 同步通道（window.prompt）—— **默认关**：它有把 JS 线程卡死的风险
    @AppStorage(EngineSyncChannel.key) private var syncChannel = false

    private var summary: String { RuleSandbox.shared.diagnose() }
    private var logs: [String] { RuleSandbox.shared.recentLogs }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // ── 急救区：引擎卡死时先点这个 ──
                    VStack(alignment: .leading, spacing: 8) {
                        Text("引擎急救")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("点什么都没反应 = 引擎的 op 队列被一个卡死的 op 堵住了。点「重置引擎」换掉那个卡死的 JS 线程（不用重装 App）。")
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button {
                                RuleSandbox.shared.resetEngine()
                                resetNote = "引擎已重置，正在重新注入脚本…"
                            } label: {
                                Label("重置引擎", systemImage: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            if !resetNote.isEmpty {
                                Text(resetNote)
                                    .font(.caption)
                                    .foregroundStyle(Theme.sub)
                            }
                        }
                        Toggle(isOn: $syncChannel) {
                            Text("用 Swift 同步通道（实验）")
                                .font(.system(size: 13))
                        }
                        .onChange(of: syncChannel) { _, on in
                            // 立刻生效：不用重启引擎
                            Task { @MainActor in
                                _ = try? await RuleSandbox.shared.applySyncChannel(on)
                            }
                        }
                        Text(syncChannel
                             ? "已开：java.timeFormat 走 Swift 原生实现。若又卡了，先关掉它再「重置引擎」。"
                             : "默认关：走纯 JS 兜底（语义跟 Swift 一致）。开着有把 JS 线程卡死的风险。")
                            .font(.caption2)
                            .foregroundStyle(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))

                    section("自检摘要", summary)

                    HStack {
                        Text("引擎日志（\(logs.count) 条）")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        if logs.isEmpty {
                            Text("（一条都没有）")
                                .font(.caption)
                                .foregroundStyle(Theme.sub)
                        }
                    }
                    if logs.isEmpty {
                        Text("引擎还没打过日志。回书源页点一次登录/搜索，这里就会有内容。")
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                    } else {
                        // 逐行懒加载 —— 300 行塞进一个 Text 会卡
                        ForEach(Array(logs.enumerated()), id: \.offset) { idx, line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(String(format: "%3d", idx + 1))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.sub)
                                    .frame(width: 30, alignment: .trailing)
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .navigationTitle("引擎自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = RuleSandbox.shared.fullLogText()
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制日志",
                              systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(body)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))
    }
}
