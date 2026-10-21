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
    /// 正在跑的动作（只有它在转圈，**其它按钮不禁用** —— 以前全禁 → 「登录都点不了了」）
    @State private var runningAction: String?
    @State private var message = ""
    @State private var failed = false
    /// 站方吐出来的原文（判断登录成没成的真话）
    @State private var stationMessages: [String] = []
    /// 登录状态检测报告
    @State private var report: LoginStatusReport?
    @State private var probing = false
    /// 番茄 sessionid（手动兜底）
    @State private var fqToken = ""
    @State private var fqTokenSaved = false

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
                                HStack(spacing: 6) {
                                    if runningAction == f.action {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(f.name)
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            // ⚠️ 只禁用**正在跑的那个**按钮。
                            //    以前是 `.disabled(busy)` → 全面板禁用 →
                            //    一旦某个 op 卡住，busy 永远 true → **登录都点不了了**
                            .disabled(runningAction != nil)
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

                    // ── 引擎急救（卡死时点这个，不用重装 App）──────────
                    HStack(spacing: 10) {
                        Button {
                            resetEngine()
                        } label: {
                            Label("重置引擎", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        Text("点不动/没反应 = 引擎卡住了 → 点这个换掉它")
                            .font(.caption2)
                            .foregroundStyle(Theme.sub)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))

                    // ── 番茄 sessionid（手动兜底）──────────
                    fqTokenBox

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

    // MARK: - 番茄 sessionid（手动兜底）

    /// 番茄 sessionid 手动输入框
    ///
    /// ⚠️ 为什么需要：发现页那句「您还未登陆番茄账号」是**大灰狼服务器**说的，
    ///    它靠请求头里的 `sessionid` 认人。那个 sessionid 来自**我们 App 自己的 cookie 罐**。
    ///    ⇒ **在 Safari 里登录番茄没用**（cookie 在 Safari 的罐里，App 读不到）
    ///    ⇒ 只有在 App 内置浏览器里登录才会进我们的罐
    ///    ⇒ 万一内置浏览器那条路不通，站方**本来就支持手动填**：
    ///       `source.getLoginInfoMap()['手动填写番茄token(可不填)']` → 这里给它入口 ✅
    private var fqTokenBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("番茄 sessionid（可选）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            TextField("从 fanqienovel.com 复制 sessionid", text: $fqToken)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            // App 自己 cookie 罐里有没有番茄 sessionid
            let jarCookie = CookieJar.cookieString(for: "https://fanqienovel.com")
            let hasJar = jarCookie.contains("sessionid")
            Text(hasJar
                 ? "✅ App 的 cookie 罐里已有番茄 sessionid（内置浏览器登录成功）"
                 : "⚠️ App 的 cookie 罐里**没有**番茄 sessionid（在 Safari 登录的读不到）")
                .font(.caption2)
                .foregroundStyle(hasJar ? Theme.sub : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    SourceVariables.setLoginInfoValue(
                        "手动填写番茄token(可不填)", fqToken.trimmingCharacters(in: .whitespacesAndNewlines),
                        for: source.bookSourceUrl)
                    fqTokenSaved = true
                } label: {
                    Label(fqTokenSaved ? "已保存" : "保存", systemImage: fqTokenSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                Text("App 读不到 Safari 的 cookie；在 App 内置浏览器登录番茄最省事，这个是兜底")
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        // 已存的番茄 token 回填
        fqToken = SourceVariables.loginInfo(for: source.bookSourceUrl)["手动填写番茄token(可不填)"] ?? ""
        fqTokenSaved = !fqToken.isEmpty
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

    /// 跑一个 loginUi 按钮的动作
    ///
    /// ⚠️⚠️ **`busy` 一定要用 defer 放开**：
    ///    以前 `busy = false` 写在 do/catch 里 → **op 永不返回时两个分支都不走**
    ///    → `busy` 永远 true → 面板里**所有按钮全被禁用** → 「登录都点不了了」。
    ///    这是用户真机报的原话。
    private func run(_ action: String) {
        guard !action.isEmpty else { return }
        busy = true
        runningAction = action
        message = ""
        stationMessages = []
        Task { @MainActor in
            // ⚠️ 一定会放开（哪怕 op 卡死/抛错/超时）
            defer {
                busy = false
                runningAction = nil
            }
            do {
                let r = try await withTimeout(seconds: Self.actionTimeout) {
                    try await SourceService.shared.login(
                        source: source, action: action, formValues: values)
                }
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
                message = error.localizedDescription
                failed = true
            }
        }
    }

    /// 一个登录动作最多等多久（秒）
    /// ⚠️ 不能太短：🍅番茄登录要等用户在浏览器里登录完（可能几分钟）
    static let actionTimeout: Double = 330

    /// 给 SwiftUI 的超时包装（`Task.sleep` + 竞速）
    private func withTimeout<T>(seconds: Double,
                                _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "qrlite", code: -1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "操作超时（\(Int(seconds)) 秒）—— 引擎可能卡住了，点「重置引擎」再试"
                ])
            }
            guard let first = try await group.next() else {
                throw NSError(domain: "qrlite", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "操作没有结果"
                ])
            }
            group.cancelAll()
            return first
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

    /// 引擎卡死时的急救：换掉那个卡死的 WKWebView
    private func resetEngine() {
        RuleSandbox.shared.resetEngine()
        message = "引擎已重置，可以再试一次了"
        failed = false
    }
}
