import SwiftUI
import UIKit

/// 书源登录界面（Legado 的 `loginUi`）
///
/// `loginUi` 是一个 JSON 数组：
/// ```json
/// [{ "name": "邮箱", "type": "text" },
///  { "name": "密码", "type": "password" },
///  { "name": "♥登录书源", "type": "button", "action": "login(true)" }]
/// ```
///
/// 点按钮 → 把**表单值**（字段名 → 值）交给引擎跑 `action` 里的 JS。
/// 引擎把它挂在 `result` 上 —— Legado 就是这么给的，
/// 站方 `login()` 里读的就是 `result['邮箱']` / `result['密码']`。
///
/// ⚠️ 站方报结果**只**用 `java.toast`（"✅️登录成功" / "💔登录失败"），
///    以前这个 toast 弹一下就没了 → 用户只看得到我们自己编的
///    「执行完成（登录信息已存到本地）」，那跟服务器认不认你毫无关系。
///    现在引擎把原文收回来（`messages`），这里原样显示。
struct SourceLoginSheet: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss

    @State private var fields: [Field] = []
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false
    /// 站方吐出来的原文（判断登录成没成的真话）
    @State private var stationMessages: [String] = []
    /// 登录状态检测报告
    @State private var report: LoginStatusReport?
    @State private var probing = false

    struct Field: Identifiable {
        let id = UUID()
        let name: String
        let type: String
        let action: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(fields) { f in
                        switch f.type {
                        case "password":
                            SecureField(f.name, text: binding(f.name))
                                .textFieldStyle(.roundedBorder)
                        case "button":
                            Button {
                                run(f.action)
                            } label: {
                                Text(f.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(busy)
                        default:
                            TextField(f.name, text: binding(f.name))
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if fields.isEmpty {
                        Text("这个书源没有登录界面（loginUi 是空的）")
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                    }

                    // ── 站方原文 ──────────────────────────────
                    if !stationMessages.isEmpty {
                        outputBox(title: "站方返回", text: stationMessages.joined(separator: "\n"))
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(failed ? Color.red : Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // ── 登录状态检测 ──────────────────────────
                    detectBox

                    if let r = report {
                        outputBox(title: "检测结果：\(r.verdict)", text: r.text)
                    }
                }
                .padding(14)
            }
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
            .task { load() }
        }
    }

    // MARK: - 登录状态检测

    private var detectBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                probe()
            } label: {
                HStack(spacing: 6) {
                    if probing {
                        ProgressView().controlSize(.small)
                        Text("检测中…")
                    } else {
                        Image(systemName: "checkmark.shield")
                        Text("检测登录状态")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .disabled(probing || busy)

            Text("不看你填没填，直接问服务器：这个 cookie 认不认。")
                .font(.caption2)
                .foregroundStyle(Theme.sub)
        }
        .padding(12)
        .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))
    }

    private func outputBox(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("复制", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))
    }

    // MARK: - 动作

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    /// 解析 loginUi（字段名 / 类型 / 按钮动作）
    private func load() {
        guard let raw = source.loginUi, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        fields = arr.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return Field(name: name,
                         type: (item["type"] as? String) ?? "text",
                         action: (item["action"] as? String) ?? "")
        }
    }

    private func run(_ action: String) {
        guard !action.isEmpty else { return }
        busy = true
        message = ""
        stationMessages = []
        Task { @MainActor in
            do {
                let r = try await SourceService.shared.login(
                    source: source, action: action, formValues: values)
                busy = false
                stationMessages = r.messages
                if r.ok {
                    // ⚠️ 「执行完成」不代表登录成功 —— 站方说啥才算啥
                    message = r.messages.isEmpty
                        ? "执行完成（站方没回话，自己点「检测登录状态」确认）"
                        : ""
                    failed = false
                } else {
                    message = r.message.isEmpty ? "执行失败" : r.message
                    failed = true
                }
            } catch {
                busy = false
                message = error.localizedDescription
                failed = true
            }
        }
    }

    /// 跑一次登录状态检测
    private func probe() {
        probing = true
        report = nil
        Task { @MainActor in
            let r = await LoginStatus.probe(source)
            report = r
            probing = false
        }
    }
}
