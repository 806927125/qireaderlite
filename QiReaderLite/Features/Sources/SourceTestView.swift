import SwiftUI
import UIKit

/// **测书源** —— 单独挑一个书源，跑完整链路，看它能不能用、断在哪一步。
///
/// ⭐ 对齐栖阅的 `SourceFullTestView`（用户给的截图）：
///   · 顶部「开始测试」+ 源名 + 地址
///   · 「测试结果：通过 4 · 失败 0 · 耗时…」
///   · 四个阶段各带 ✅/❌ + 摘要 + **分步计时**（目录 2.32s / 正文 1.38s）
///   · 五份源码（搜索/发现/详情/目录/正文）—— 这里是**书源的规则原文**
///   · 诊断时间线（引擎日志按步骤分组）
///   · 「复制测试报告」
///
/// 编排逻辑在 `Core/SourceTestRunner.swift`（纯 Foundation ⇒ 沙盒能真编真跑）。
struct SourceTestView: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss

    @State private var report: SourceTestReport?
    @State private var running = false
    @State private var copied = false
    /// 展开的源码段
    @State private var showCode: String?

    private var logs: [String] { RuleSandbox.shared.recentLogs }
    private var groups: [EngineLogTimeline.Group] { EngineLogTimeline.groups(logs) }
    private var timings: [(step: String, ms: Int)] { EngineLogTimeline.timings(logs) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    headCard
                    if let r = report { resultCard(r) }
                    codeCard
                    if !groups.isEmpty { timelineCard }
                }
                .padding(14)
            }
            .navigationTitle("测书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = report?.reportText()
                            ?? RuleSandbox.shared.fullLogText()
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制报告",
                              systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                    .disabled(report == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // ⭐ 「测试完日志要清空」—— 手动一键清
                    Button {
                        RuleSandbox.shared.clearLogs()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
    }

    // MARK: - 头部

    private var headCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.name)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(source.bookSourceUrl)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.sub)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "测试中…" : (report == nil ? "开始测试" : "重新测试"),
                          systemImage: "play.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(running)
                if running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text("跑链路：发现 → 详情 → 目录 → 正文。每步单独计时，某步挂了也照样往下测 ⇒ 一次就知道哪些能用。")
                .font(.caption2)
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    // MARK: - 测试结果

    private func resultCard(_ r: SourceTestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("测试结果")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(r.headLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(r.failed == 0 ? .green : .orange)
                    .fontWeight(.semibold)
            }
            ForEach(r.stages) { s in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(s.ok ? .green : .red)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(s.kind.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text(EngineLogTimeline.fmtMS(s.ms))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(s.ms >= 3000 ? .orange : Theme.sub)
                        }
                        Text(s.ok ? s.summary : s.error)
                            .font(.caption2)
                            .foregroundStyle(s.ok ? Theme.sub : .red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    // MARK: - 五份源码（书源规则原文）

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("书源规则")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            ForEach(Self.codeKeys, id: \.key) { item in
                let text = sourceJSON(item.key)
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        showCode = (showCode == item.key) ? nil : item.key
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showCode == item.key ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text(item.title)
                                .font(.caption.weight(.medium))
                            if text.isEmpty {
                                Text("（空）").font(.caption2).foregroundStyle(Theme.sub)
                            }
                            Spacer()
                        }
                        .foregroundStyle(Theme.ink)
                    }
                    if showCode == item.key {
                        Text(text.isEmpty ? "（这条规则是空的）" : text)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.sub)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    /// 一个可展开的「源码」段
    ///
    /// ⚠️ **必须用 struct，不能用 tuple** —— Swift 的 key path（`\.key`）
    ///    **不能指向 tuple 元素** ⇒ 用 tuple 会编译失败。
    private struct CodeItem: Identifiable {
        let key: String
        let title: String
        var id: String { key }
    }

    private static let codeKeys: [CodeItem] = [
        CodeItem(key: "ruleSearch", title: "搜索页规则"),
        CodeItem(key: "ruleExplore", title: "发现页规则"),
        CodeItem(key: "ruleBookInfo", title: "详情页规则"),
        CodeItem(key: "ruleToc", title: "目录页规则"),
        CodeItem(key: "ruleContent", title: "正文页规则"),
    ]

    /// 从书源 JSON 里取出某个规则的原文
    private func sourceJSON(_ key: String) -> String {
        guard let d = try? AppEncoder.encode(source),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sub = obj[key],
              JSONSerialization.isValidJSONObject(sub),
              let data = try? JSONSerialization.data(withJSONObject: sub,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: - 诊断时间线

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("诊断时间线（\(groups.count) 步 / \(logs.count) 条）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            if !timings.isEmpty {
                // ⚠️ 同上：enumerated() 出来是 tuple ⇒ key path 用不了 ⇒ 走 indices
                let recent = Array(timings.reversed().prefix(6))
                ForEach(recent.indices, id: \.self) { i in
                    HStack {
                        Text(recent[i].step)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 48, alignment: .leading)
                        Text(EngineLogTimeline.fmtMS(recent[i].ms))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(recent[i].ms >= 3000 ? .orange : Theme.sub)
                        Spacer()
                    }
                }
                Divider()
            }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(g.id)
                            .font(.caption2.weight(.semibold))
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
                    ForEach(g.lines.suffix(8), id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(EngineLogTimeline.isError(line) ? .red : Theme.sub)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    // MARK: - 跑

    /// ⚠️ 标 `@MainActor`：`SourceService` 是 `@MainActor` class，
    ///    `SourceTestRunner.run` 的默认参数 `service: .shared` 要在
    ///    MainActor 上求值 ⇒ 显式标上更稳（CI 踩过 actor 隔离的坑）
    @MainActor
    private func run() async {
        running = true
        report = nil
        // ⚠️ **开始测试前先清空日志** ⇒ 报告里只有**本次**的日志，
        //    不会混着上一次跑剩下的（用户要「测试完日志要清空」）
        RuleSandbox.shared.clearLogs()
        let r = await SourceTestRunner.run(source)
        report = r
        running = false
    }
}
