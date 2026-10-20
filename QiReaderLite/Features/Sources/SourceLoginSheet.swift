import SwiftUI

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
struct SourceLoginSheet: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss

    @State private var fields: [Field] = []
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false

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

                    if !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(failed ? Color.red : Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if fields.isEmpty {
                        Text("这个书源没有登录界面（loginUi 是空的）")
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
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
        Task { @MainActor in
            do {
                let r = try await SourceService.shared.login(
                    source: source, action: action, formValues: values)
                busy = false
                if r.ok {
                    message = "执行完成（登录信息已存到本地）"
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
}
