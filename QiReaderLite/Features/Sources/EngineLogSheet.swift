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

    // MARK: - ⭐⭐ 当前引擎（主链路跑的是哪个）
    //
    // ⚠️ 键必须和 `EngineBackend` 里的一致 ⇒ 同一个 UserDefaults 键，两边同步
    @AppStorage("qr.useNewEngine") private var useNewEngine = true
    @AppStorage("qr.fallbackLegacy") private var fallbackLegacy = true
    @AppStorage("qr.engineBackend") private var backendKind = ""

    /// 当前后端（`EngineBackend.Kind` 的原文）
    private var currentBackendName: String {
        EngineBackend.Kind(rawValue: backendKind)?.rawValue ?? EngineBackend.Kind.swiftNew.rawValue
    }
    /// 主链路是不是走新引擎
    private var isNewEngine: Bool { useNewEngine }
    /// 当前是不是新引擎在服务
    private var servingIsNew: Bool { EngineBackend.current == .swiftNew }
    /// 一行「标签：值」
    private func engineRow(_ label: String, _ value: String, isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.sub)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(isError ? .red : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String { RuleSandbox.shared.diagnose() }
    private var logs: [String] { RuleSandbox.shared.recentLogs }

    // MARK: - 诊断时间线（对齐栖阅：分步 + 计时 + 出错一眼看见）
    //
    // ⚠️ 解析逻辑放在 `Core/EngineLogTimeline.swift`（纯 Foundation）
    //    ⇒ 沙盒 swiftc 能真编真跑，「测书源」页也共用同一份 ✅
    private var groups: [EngineLogTimeline.Group] { EngineLogTimeline.groups(logs) }
    /// 每一步的耗时 —— 栖阅就是这种「目录 2.32s」
    private var timings: [(step: String, ms: Int)] { EngineLogTimeline.timings(logs) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // ── ⭐⭐ 当前引擎（一眼看出主链路跑的是哪个）─────────
                    //
                    // ⚠️⚠️ **为什么必须放在这个面板的最上面**（2026-10-23 用户实测）：
                    //   下面那屏「引擎文件：11 个全部就位 / 注入完成」**全是老 JS 引擎的状态**
                    //   ⇒ 用户打开这个面板看到「引擎都就位」⇒ 以为**还在跑老引擎**
                    //   ⇒ 实际主链路（搜索/发现/详情/目录/正文）早就走新 Swift 引擎了 ⭐
                    //   ⇒ 所以「当前引擎」必须**在老引擎的信息之前**显示
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("当前引擎")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Text(EngineBackend.servingText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isNewEngine && servingIsNew ? Theme.accent : .orange)
                        }
                        // ⭐⭐⭐ **三件事分开显示**（用户实测踩出来的：只看一个状态会误判）
                        //   ① 开关开了没 ② 当前谁在服务 ③ 失败原因
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(EngineBackend.statusLines(), id: \.label) { line in
                                engineRow(line.label, line.value, isError: line.isError)
                            }
                        }
                        Text(isNewEngine
                             ? "主链路（搜索 / 发现 / 详情 / 目录 / 正文）走**新 Swift 引擎**（legado-engine）。\n下面这些是老 JS 引擎（兜底通道：登录 / 诊断）的状态。"
                             : "主链路当前走**老 JS 引擎**。新引擎被关掉了（开关在下面）。")
                            .font(.caption2)
                            .foregroundStyle(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(isOn: $useNewEngine) {
                            Text("用新 Swift 引擎（关掉 = 回到老引擎）")
                                .font(.system(size: 13))
                        }
                        Toggle(isOn: $fallbackLegacy) {
                            Text("新引擎失败时回退老引擎（关掉 = 纯新引擎）")
                                .font(.system(size: 13))
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))

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
                                    Text(EngineLogTimeline.fmtMS(recent[i].ms))
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
                                        .foregroundStyle(EngineLogTimeline.isError(line) ? .red : Theme.ink)
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
                                    .foregroundStyle(EngineLogTimeline.isError(line) ? .red : Theme.ink)
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
                // ⭐⭐⭐ **「诊断包」**：一键把**崩溃前**的日志 + 设备信息 + 引擎状态 复制出来
                //   ⇒ 不用手抄、不用导出 .ips ⇒ 直接粘给我就能定位 ⭐⭐⭐
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = Self.diagnosticBundle()
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "诊断包",
                              systemImage: copied ? "checkmark" : "stethoscope")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // ⭐ 「测试完日志要清空」—— 一键清掉，避免旧日志混着新日志看花眼
                    Button {
                        RuleSandbox.shared.clearLogs()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                    .disabled(logs.isEmpty)
                }
                // ⭐⭐⭐ **玻璃模式开关**：iOS 27 Beta 上系统玻璃会拖慢「弹出」⇒ 一键切轻量
                ToolbarItem(placement: .bottomBar) {
                    Toggle(isOn: Binding(
                        get: { GlassMode.isLight },
                        set: { GlassMode.setLight($0) })) {
                        Label("轻量玻璃", systemImage: GlassMode.isLight ? "leaf.fill" : "sparkles")
                            .font(.system(size: 13))
                    }
                    .padding(.bottom, 4)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
    }


    /// ⭐⭐⭐ **诊断包**（一键复制 ⇒ 直接发给我）
    ///
    /// ⇒ 包含：**崩溃前**的磁盘日志（进程被杀也不丢）+ 设备/系统 + 引擎状态 + 最近的开销
    @MainActor
    static func diagnosticBundle() -> String {
        var lines: [String] = []
        lines.append("======== 轻阅 诊断包 ========")
        lines.append("生成时间：\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("App：\(AppPaths.appVersionLine)")
        lines.append("设备：\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)")
        lines.append("引擎开关：新引擎=\(EngineBackend.useNewEngine ? "开" : "关")（关 = 走老引擎）")
        lines.append("引擎状态：\(EngineBackend.current.rawValue)")
        if let e = EngineBackend.lastError { lines.append("引擎错误：\(e)") }
        lines.append("")
        let disk = RuleSandbox.diskLogText()
        lines.append("======== 磁盘日志（\(disk.count) 字符 · 含崩溃前）========")
        lines.append(disk.isEmpty ? "（磁盘日志是空的）" : disk)
        lines.append("")
        lines.append("======== 当前内存日志 ========")
        lines.append(RuleSandbox.shared.fullLogText())
        return lines.joined(separator: "\n")
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
