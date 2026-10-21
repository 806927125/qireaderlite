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
    /// 书源变量（JSON）—— 聚合源把「服务器地址 / 线路」存在这儿
    @State private var varsText = ""
    @State private var varsSaved = false
    @State private var probingHosts = false
    @State private var probeResult: String = ""
    @State private var bestHost: String = ""
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
                    varsBox

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

    // MARK: - 书源变量（线路/服务器）

    /// **书源变量**编辑（JSON）
    ///
    /// ⚠️ 为什么需要：🍅大灰狼把**服务器地址（线路）**存在书源变量里
    ///    （`source.getVariable()` → `getArguments(..., "server")`）。
    ///    它的 jsLib 里列了 **8 条线路**，不通就**逐条兜底**（每条等满请求超时）
    ///    ⇒ 设备上如果默认那条不通，详情页会**一直转圈一两分钟** ❗
    /// ⇒ 轻阅以前**没有变量编辑入口** ⇒ 用户没法手动换一条通的路。
    ///    现在给了：把 JSON 里的 `"server"` 改成线路地址即可 ✅
    private var varsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("书源变量（线路 / 服务器）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("聚合源把服务器地址存在这里。默认线路不通时，详情页会逐条试 8 条（很慢）。把 server 改成一条通的线路即可。")
                .font(.caption2).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $varsText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90)
                .padding(8)
                .background(Theme.sub.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button {
                    let raw = varsText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 空 = 恢复默认（让站方用自己的兜底）
                    SourceVariables.setVars(raw, for: source.bookSourceUrl)
                    varsSaved = true
                } label: {
                    Label(varsSaved ? "已保存" : "保存", systemImage: varsSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                if !varsText.isEmpty {
                    Button {
                        varsText = ""
                        SourceVariables.setVars("", for: source.bookSourceUrl)
                        varsSaved = true
                    } label: {
                        Text("清空（用默认线路）").font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)
                }
            }
            // ── 线路测速：并发试所有站方线路，挑最快的一条写进变量 ──
            Button {
                probingHosts = true
                probeResult = ""
                Task { await probeLines() }
            } label: {
                Label(probingHosts ? "测速中…" : "测速并选最快线路", systemImage: "speedometer")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(probingHosts)
            if !probeResult.isEmpty {
                Text(probeResult)
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 并发测速站方的所有线路 → 把最快的一条写进书源变量的 `server`
    ///
    /// ⚠️ 为什么需要（2026-10-21 真机）：`v5.langge.uk` 在用户网络里**直接超时**
    ///    ⇒ 站方详情页会**逐条试 8 条线路** ⇒ 详情页转圈一两分钟 ❗
    ///    ⇒ 一次并发测速（6 秒超时）→ 挑通的写进去 ⇒ 立刻恢复 ✅
    private func probeLines() async {
        defer { probingHosts = false }
        var hosts: [String] = (try? await SourceService.shared.sourceHosts(source: source)) ?? []
        // 兜底：当前变量里的 server 也一起测
        if let m = try? JSONSerialization.jsonObject(with: Data(varsText.utf8)) as? [String: Any],
           let sv = m["server"] as? String, !sv.isEmpty, !hosts.contains(sv) {
            hosts.insert(sv, at: 0)
        }
        guard !hosts.isEmpty else {
            probeResult = "没拿到站方的线路列表（jsLib 里没有 host 数组？）"
            return
        }
        let results = LegadoCompat.pingHosts(hosts, timeout: 6)
        let ok = results.filter { ($0["ok"] as? Bool) == true }
        guard let best = ok.first, let host = best["host"] as? String else {
            // ⚠️ 不用嵌套引号的字符串插值（Swift 里 `\(r["host"])` 这种写法很容易被转义搞坏）
            let detail = results.map { r -> String in
                let h = r["host"] as? String ?? ""
                let good = (r["ok"] as? Bool) == true
                return h + (good ? " 通" : " 不通")
            }.joined(separator: "、")
            probeResult = "全部线路都不通：\(detail)"
            return
        }
        let ms = (best["ms"] as? Int) ?? -1
        // 写进书源变量的 server
        var m = (try? JSONSerialization.jsonObject(with: Data(varsText.utf8)) as? [String: Any]) ?? [:]
        m["server"] = host
        if let d = try? JSONSerialization.data(withJSONObject: m),
           let t = String(data: d, encoding: .utf8) {
            varsText = t
        }
        SourceVariables.setVars(varsText, for: source.bookSourceUrl)
        varsSaved = true
        bestHost = host
        // ⚠️ 文案照抄栖阅的「检测当前服务器」卡片（用户点名喜欢这个 UX ✅）
        //   栖阅原文：【网络环境优良】<服务器> 解析时间：0s / 延迟低，推荐使用此接口
        let grade = ms <= 1500 ? "网络环境优良" : (ms <= 4000 ? "网络环境一般" : "网络环境较差")
        let tip = ms <= 1500 ? "延迟低，推荐使用此接口" : "延迟偏高，可点「测速」换一条"
        probeResult = "💗【\(grade)】\n\(host)\n解析时间：\(max(ms, 0))ms\n\(tip)"
        Toast.show("✅ 正在检测：\(host) 请稍等~")
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
                    let raw = fqToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    // ① 栖阅机制：loginHeader → **自动注入到每次请求头**
                    //    （聚合源要 sessionid 才能同步番茄数据）
                    if raw.isEmpty {
                        SourceVariables.setLoginHeader("", for: source.bookSourceUrl)
                    } else {
                        let v = raw.hasPrefix("sessionid=") ? raw : "sessionid=" + raw
                        SourceVariables.setLoginHeader("Cookie: " + v, for: source.bookSourceUrl)
                    }
                    // ② 站方自己也读这个键（双保险，两边都能用）
                    SourceVariables.setLoginInfoValue(
                        "手动填写番茄token(可不填)", raw,
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

    /// **从 App 的 cookie 罐里自动抓番茄 sessionid** → 填进输入框 + 直接写进站方读的两个地方
    ///
    /// ⚠️ 为什么必须自动（2026-10-21 用户反馈「登录了的，那个输入框里啥也没有」）：
    ///    用户在**内置浏览器**里登录番茄后，sessionid 其实**已经在 App 的 cookie 罐里**了，
    ///    但那个输入框是「手动兜底」→ 不会自动填 → 用户以为没登录成功。
    /// ⇒ 现在：内置浏览器登录完（loginUi 的动作跑完）→ 自动抓 → 自动填 → **自动写进**
    ///   ① `source.getLoginInfoMap()['手动填写番茄token(可不填)']`（站方 jsLib 直接读这个键 ✅）
    ///   ② `loginHeader`（栖阅机制 → 自动注入到每次请求头 ✅）
    ///   ⇒ 站方不用 cookie 也能认出番茄 sessionid ⇒ 发现页/正文/翻页全通 ✅
    private func autoFillFQSessionId() {
        let jar = CookieJar.cookieString(for: "https://fanqienovel.com")
        guard let sid = Self.extractSessionId(jar), !sid.isEmpty else { return }
        if fqToken != sid { fqToken = sid }
        SourceVariables.setLoginInfoValue("手动填写番茄token(可不填)", sid, for: source.bookSourceUrl)
        SourceVariables.setLoginHeader("Cookie: sessionid=" + sid, for: source.bookSourceUrl)
        // ③ **再写一份成真 cookie**（站方主路径就是 cookie.getCookie('fanqienovel.com')）
        //    ⇒ 拿不到 cookie 时还能靠 loginInfo / loginHeader 兜底（三条路都通）
        if let c = HTTPCookie(properties: [
            .domain: "fanqienovel.com", .path: "/",
            .name: "sessionid", .value: sid,
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30)
        ]) {
            HTTPCookieStorage.shared.setCookie(c)
        }
        fqTokenSaved = true
    }

    /// 从 cookie 串里抠出 sessionid 的值
    private static func extractSessionId(_ cookieString: String) -> String? {
        for part in cookieString.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("sessionid=") {
                let v = String(kv.dropFirst("sessionid=".count)).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// 解析 loginUi（字段名 / 类型 / 按钮动作）
    private func load() {
        // 已存的番茄 token 回填
        fqToken = SourceVariables.loginInfo(for: source.bookSourceUrl)["手动填写番茄token(可不填)"] ?? ""
        fqTokenSaved = !fqToken.isEmpty
        // ⚠️ 存的没有 → 从 cookie 罐自动抓（内置浏览器登录过的就抓得到）
        if fqToken.isEmpty { autoFillFQSessionId() }
        varsText = SourceVariables.vars(for: source.bookSourceUrl)
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
                // ⚠️ 登录动作跑完 = 内置浏览器已经关了 → cookie 罐里该有 sessionid 了
                //    → 自动抓 + 自动写进站方读的那个键（用户不用手抄）
                autoFillFQSessionId()
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
