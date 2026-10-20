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

    private var summary: String { RuleSandbox.shared.diagnose() }
    private var logs: [String] { RuleSandbox.shared.recentLogs }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
