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

    // MARK: - 诊断时间线（对齐栖阅：分步 + 计时 + 出错一眼看见）

    /// 一个步骤的日志组
    private struct StepGroup: Identifiable {
        let id: String
        var lines: [String] = []
        var errors: Int = 0
    }

    /// 日志行 → 步骤名。格式是 `[HH:mm:ss.SSS] [步骤] 内容`
    private static func stepOf(_ line: String) -> String {
        let parts = line.split(separator: "]", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return "其它" }
        let s = parts[1].trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "其它" : s
    }

    /// 出错？—— 这些词出现就当错误（栖阅用 ⚠️ 标，我们用关键词）
    private static func isError(_ line: String) -> Bool {
        let marks = ["失败", "异常", "错误", "轮数用尽", "不可用", "超时", "崩"]
        return marks.contains { line.contains($0) }
    }

    /// 按步骤分组（保持首次出现的顺序 = 时间顺序）
    private var groups: [StepGroup] {
        var order: [String] = []
        var map: [String: StepGroup] = [:]
        for line in logs {
            let step = Self.stepOf(line)
            if map[step] == nil {
                order.append(step)
                map[step] = StepGroup(id: step)
            }
            map[step]?.lines.append(line)
            if Self.isError(line) { map[step]?.errors += 1 }
        }
        return order.compactMap { map[$0] }
    }

    /// 每一步的耗时（从 `⏱ op「x」耗时 Nms` 里解析）—— 栖阅就是这种「目录 2.32s」
    private var timings: [(step: String, ms: Int)] {
        var out: [(String, Int)] = []
        for line in logs {
            guard let r = line.range(of: "op「"),
                  let t = line.range(of: "」耗时 ") else { continue }
            let op = String(line[r.upperBound..<t.lowerBound])
            let rest = line[t.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let ms = Int(digits) {
                let step = RuleSandbox.stepNameForOp(op)
                out.append((step, ms))
            }
        }
        return out
    }

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

                    // ── 诊断时间线：分步 + 耗时（栖阅同款）──────────────────
                    if !timings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("分步耗时")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            let recent = Array(timings.reversed().prefix(8))
                            ForEach(recent.indices, id: \.self) { i in
                                HStack {
                                    Text(recent[i].step)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                        .frame(width: 52, alignment: .leading)
                                    Text(Self.fmtMS(recent[i].ms))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(recent[i].ms >= 3000 ? .orange : Theme.sub)
                                    Spacer()
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))
                    }

                    // ── 诊断时间线：按步骤分组 ──────────────────────────────
                    if !groups.isEmpty {
                        Text("诊断时间线（\(groups.count) 步 / \(logs.count) 条）")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        ForEach(groups) { g in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(g.id)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                    Text("\(g.lines.count) 条")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.sub)
                                    if g.errors > 0 {
                                        Text("⚠️ \(g.errors)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.red)
                                    }
                                    Spacer()
                                }
                                ForEach(Array(g.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(Self.isError(line) ? .red : Theme.ink)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))
                        }
                    }

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
                                    .foregroundStyle(Self.isError(line) ? .red : Theme.ink)
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

    /// 毫秒 → 人话（栖阅那种「2.32s」）
    private static func fmtMS(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.2fs", Double(ms) / 1000.0)
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
