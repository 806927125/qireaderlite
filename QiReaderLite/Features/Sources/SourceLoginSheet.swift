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

    /// ⭐ **栖阅登录页那种「浅色玻璃 + 蓝字」的按钮**（2026-10-22 用户截图对照）
    ///
    /// 栖阅那页：19 个站方按钮**全是玻璃块**，底下的插画直接透上来 ⇒ `.clear` 档
    /// ⚠️ 必须同时做两件事，少一个就露馅：
    ///   ① `buttonStyle(.plain)` —— `.bordered` 会画自己的边框+底色 ⇒ **玻璃套边框 = 一坨糊**
    ///   ② 文字显式 `foregroundStyle` —— `.plain` 下 `.tint()` 不生效 ⇒ 蓝字要自己给
    private struct GlassActionButtonStyle: ButtonStyle {
        var tint: Color = Theme.accent
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(tint)
                .glassCapsule()
                // 按压反馈（`.plain` 没有系统反馈 ⇒ 自己给一个轻微透明）
                .opacity(configuration.isPressed ? 0.55 : 1.0)
        }
    }

    /// 站方的文本/密码输入框（整行，玻璃通透）
    private var loginFields: some View {
        ForEach(fields.filter { $0.type != "button" }) { f in
            if f.type == "password" {
                SecureField(f.name, text: binding(f.name))
                    .glassField()
            } else {
                TextField(f.name, text: binding(f.name))
                    .glassField()
            }
        }
    }

    /// 站方那 19 个按钮（两列排，栖阅登录页同款）
    ///
    /// ⚠️ **必须独立成一个属性** —— 埋在 body 的四层嵌套里会让 Swift 类型推断超时
    private var actionButtonsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(fields.filter { $0.type == "button" }) { f in
                Button {
                    run(f.action)
                } label: {
                    HStack(spacing: 6) {
                        if runningAction == f.action {
                            ProgressView().controlSize(.small)
                        }
                        Text(f.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 10)
                }
                // ⚠️ 栖阅登录页的按钮是**浅色玻璃 + 蓝字**（不是实心蓝块）
                //    ⇒ 2026-10-22 改：`.bordered` → 玻璃按钮（`.plain` + `.glassCapsule()`）
                .buttonStyle(GlassActionButtonStyle())
                .disabled(runningAction != nil)
            }
        }
    }

    struct Field: Identifiable {
        let id = UUID()
        let name: String
        let type: String
        let action: String
    }

    var body: some View {
        // ⭐⭐ **接上 PageBackdrop**（2026-10-22 用户截图对照栖阅）
        //   栖阅那页的玻璃能透出**底下的插画** ⇒ 后面必须有高对比内容
        //   轻阅的 `PageBackdrop` 就是干这个的（渐变 + 彩色光斑 + GlassBackdrop）
        //   ⇒ 登录 sheet 之前**没有背景** ⇒ 玻璃后面只有系统材质 ⇒ 玻璃等于白做 ❗
        ZStack {
            PageBackdrop()
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                    // ── 按钮排成**两列**（栖阅登录页同款：站方那 19 个按钮两列排）──
                    //    文本/密码框仍整行 ✅
                    // ⚠️⚠️ **必须抽成独立属性**（2026-10-22 CI 报错）：
                    //   `LazyVGrid` 埋在 `ZStack>NavigationStack>ScrollView>VStack` 四层里
                    //   ⇒ Swift **类型推断超时**（the compiler is unable to type-check this expression）
                    //   ⇒ 抽出来一层就没事了 ⭐
                    actionButtonsGrid
                    // ⚠️ 同样抽出去（嵌套里 ForEach + switch + 输入框 ⇒ 推断负担大）
                    loginFields

                    if fields.isEmpty {
                        // ⭐⭐⭐ **说清「为什么空」+「怎么修」**（2026-10-24 真机）
                        //   原来只写一句「loginUi 是空的」⇒ 用户一脸懵 ⇒ 只能来问
                        //   ⚠️ 两种可能：
                        //     ① **导入时字段被丢了**（模型白名单解码 ⇒ 老版本存的源缺 `loginUi`）
                        //        ⇒ **重新导入一次源文件就能恢复** ⭐
                        //     ② 源文件里本来就没有 ⇒ 这个源确实没有站方登录
                        VStack(alignment: .leading, spacing: 4) {
                            Text("这个书源没有登录界面（loginUi 是空的）")
                                .font(.caption)
                                .foregroundStyle(Theme.sub)
                            Text("当前源：\(source.name)\n"
                                 + "① 多半是**导入时这个字段被丢掉了**（老版本存的源）⇒ **重新导入一次源文件**就能恢复\n"
                                 + "② 源文件里本来就没有 ⇒ 这个源确实没有站方登录界面")
                                .font(.caption2)
                                .foregroundStyle(Theme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(GlassActionButtonStyle())
                        .tint(Theme.accent)
                        Text("点不动/没反应 = 引擎卡住了 → 点这个换掉它")
                            .font(.caption2)
                            .foregroundStyle(Theme.sub)
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 12, variant: .regular)

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
            .task {
                load()
                // ⭐⭐⭐ **先挑一条最快的线路**（2026-10-24 真机「唯独大灰狼卡死」）
                //   大灰狼的站方 jsLib 里有 **8 条线路** ⇒ 站方 catch 循环会挨个试
                //   ⇒ 死线路每条等超时 ⇒ **每个 op 十几秒** ⇒ 面板一开就卡 ⭐⭐⭐
                //   ⇒ 挑一条通的写进 `server` ⇒ 之后所有 op 只打那一条 ⇒ 秒回
                await SourceService.shared.ensureFastLine(source: source)
                varsText = SourceVariables.effectiveVars(for: source.bookSourceUrl)
                // ⚠️⚠️ **别在这儿拉站方默认变量**（2026-10-24 真机「打开登录把 app 卡死」）
                //   那个调用要**跑站方 jsLib + 发网络请求**（大灰狼的服务器经常 502）
                //   ⇒ 卡在引擎队列里 ⇒ 面板一直转 ⇒ 用户以为 App 死了 ⭐⭐⭐
                //   ⇒ 现在：**打开面板只读本地缓存**（同步、秒开）
                //   ⇒ 想拉默认值/测速，点下面的「测速并选最快线路」⭐
                varsText = SourceVariables.effectiveVars(for: source.bookSourceUrl)
            }
            }
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
                .padding(.horizontal, 10)
            }
            .buttonStyle(GlassActionButtonStyle())
            .tint(Theme.accent)
            .disabled(probing || busy)

            Text("不看你填没填，直接问服务器：这个 cookie 认不认。")
                .font(.caption2)
                .foregroundStyle(Theme.sub)
        }
        .padding(12)
        .glassCard(cornerRadius: 12, variant: .regular)
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
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                }
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glassCard(cornerRadius: 12, variant: .regular)
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
    /// 「本地 / 云端」开关 —— 写进站方变量的 `proxy` 键
    private var proxyBinding: Binding<String> {
        Binding(
            get: {
                if let m = try? JSONSerialization.jsonObject(with: Data(varsText.utf8)) as? [String: Any],
                   let v = m["proxy"] as? String, !v.isEmpty { return v }
                return "云端"
            },
            set: { newValue in
                var m = (try? JSONSerialization.jsonObject(with: Data(varsText.utf8)) as? [String: Any]) ?? [:]
                m["proxy"] = newValue
                if let d = try? JSONSerialization.data(withJSONObject: m),
                   let t = String(data: d, encoding: .utf8) {
                    varsText = t
                }
                SourceVariables.setVars(
                    SourceVariables.mergeVars(
                        userJSON: varsText,
                        defaults: SourceVariables.defaultVars(for: source.bookSourceUrl)),
                    for: source.bookSourceUrl)
                varsSaved = true
            })
    }

    private var proxyHint: String {
        let hasSid = fqToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || CookieJar.cookieString(for: "https://fanqienovel.com").contains("sessionid")
        if proxyBinding.wrappedValue == "本地" {
            return hasSid
                ? "✅ 已填番茄 sessionid → 本地模式能自己抓番茄详情页，目录最稳"
                : "⚠️ 本地模式要我们自己抓番茄详情页 → **需要番茄 sessionid**（上面填一个）"
        }
        return "云端 = 交给大灰狼服务器抓（它有缓存 ⇒ 缓存里没有的书会 0 章）"
    }

    private var varsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("书源变量（线路 / 服务器）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("聚合源把服务器地址存在这里。默认线路不通时，详情页会逐条试 8 条（很慢）。把 server 改成一条通的线路即可。")
                .font(.caption2).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            // ⭐⭐⭐ **用 LimitedTextEditor**（不是 TextEditor）
            //   真机崩溃日志：TextEditor 粘贴/赋值巨量文本 ⇒ CoreText 排版 10 秒 ⇒ watchdog 杀进程
            //   ⇒ 这里给 8K 上限（站方默认表正常只有 170 字符 ⇒ 够用）⭐
            LimitedTextEditor(text: $varsText, limit: 8_000) { projected in
                message = "变量表 \(projected) 字符，太大了（上限 8000）⇒ 请只改 server 一项"
                failed = true
            }
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                // ⚠️ 这里用 `.regular` 磨砂档（等宽小字要看得清）；
                //    站方的邮箱/密码框用 `.clear` 通透档（栖阅同款）
                .glassCard(cornerRadius: 10, variant: .regular)
            // ⚠️ 空的时候**说清为什么空**（2026-10-24 真机：空框让人以为是 App 坏了）
            if varsText.isEmpty {
                Text("还没有变量。点下面的「**测速并选最快线路**」会跑一次站方 jsLib，把默认变量和线路一起拉回来。")
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    let raw = varsText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // ⚠️ 空 = 恢复默认（让站方用自己的兜底）
                    //    非空 = **合并站方默认变量**再存（只存一项会把
                    //    server/tab/sources/proxy 全丢掉 ⇒ 源被改坏）
                    if raw.isEmpty {
                        SourceVariables.setVars("", for: source.bookSourceUrl)
                    } else {
                        SourceVariables.setVars(
                            SourceVariables.mergeVars(
                                userJSON: raw,
                                defaults: SourceVariables.defaultVars(for: source.bookSourceUrl)),
                            for: source.bookSourceUrl)
                    }
                    varsText = SourceVariables.effectiveVars(for: source.bookSourceUrl)
                    varsSaved = true
                } label: {
                    Label(varsSaved ? "已保存" : "保存", systemImage: varsSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(GlassActionButtonStyle())
                if !varsText.isEmpty {
                    Button {
                        varsText = ""
                        SourceVariables.setVars("", for: source.bookSourceUrl)
                        varsSaved = true
                    } label: {
                        Text("清空（用默认线路）")
                            .font(.system(size: 13))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(GlassActionButtonStyle())
                }
            }
            // ── 本地 / 云端（站方的 proxy 变量）────────────────
            //  ⭐ 站方 JS 里 `if (url != "" && proxy == "本地")` 才会**自己去抓番茄详情页**，
            //    把 html 交给大灰狼服务器解析章节；
            //    「云端」= 让服务器自己抓（它有缓存 ⇒ 缓存没有的书就 0 章）。
            //  ⇒ 填了番茄 sessionid 就选「本地」，目录最稳 ✅
            HStack(spacing: 10) {
                Text("抓取方式").font(.system(size: 13))
                Picker("", selection: proxyBinding) {
                    Text("本地（我们自己抓番茄）").tag("本地")
                    Text("云端（服务器抓，有缓存）").tag("云端")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
            }
            Text(proxyHint)
                .font(.caption2).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            // ── 线路测速：并发试所有站方线路，挑最快的一条写进变量 ──
            Button {
                probingHosts = true
                probeResult = ""
                Task { await probeLines() }
            } label: {
                Label(probingHosts ? "测速中…" : "测速并选最快线路", systemImage: "speedometer")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(GlassActionButtonStyle())
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
        // ⭐ 顺便把站方默认变量拉回来（jsLib 的 getArguments 兜底表）
        //   ⇒ 「打开面板不再发网络请求」之后，这里是唯一的拉取入口
        //   ⇒ 拉不到就提示（引擎卡住 / 站方服务器不通）⇒ 用户一眼知道是哪边的问题 ⭐
        let defaults = await SourceService.shared.sourceDefaultVars(source: source)
        if !defaults.isEmpty {
            varsText = SourceVariables.effectiveVars(for: source.bookSourceUrl)
        }
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
        let results = await HostTools.pingHosts(hosts, timeout: 6)
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
        SourceVariables.setVars(
            SourceVariables.mergeVars(
                userJSON: varsText,
                defaults: SourceVariables.defaultVars(for: source.bookSourceUrl)),
            for: source.bookSourceUrl)
        varsText = SourceVariables.effectiveVars(for: source.bookSourceUrl)
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
                .glassField()
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
                    //    ⚠️ 站方取值用正则 `/sessionid=[^;]+/` ⇒ **必须带 `sessionid=` 前缀**
                    //    只填裸值的话正则匹配不上 ⇒ fqssionid 为空 ⇒ 白填 ❗
                    let stationSide = raw.isEmpty ? "" :
                        (raw.contains("sessionid=") ? raw : "sessionid=" + raw)
                    SourceVariables.setLoginInfoValue(
                        "手动填写番茄token(可不填)", stationSide,
                        for: source.bookSourceUrl)
                    fqTokenSaved = true
                } label: {
                    Label(fqTokenSaved ? "已保存" : "保存", systemImage: fqTokenSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(GlassActionButtonStyle())
                .tint(Theme.accent)
                Text("App 读不到 Safari 的 cookie；在 App 内置浏览器登录番茄最省事，这个是兜底")
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 12, variant: .regular)
    }

    // MARK: - 动作

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { newValue in
                values[key] = newValue
                // ⚠️ 落盘（按源）—— 重进面板/重启 App 都还在 ✅
                SourceVariables.setLoginFormValues(values, for: source.bookSourceUrl)
            }
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
        // ⭐⭐⭐ **先把模型缺的字段从「原始 JSON 存档」补上**（2026-10-24 真机）
        //   老版本存下来的源缺 `loginUi` ⇒ 登录界面整没了 ⇒ 这里补回来（不用重导）
        let src = SourceRawArchive.patch(source)
        // ⚠️ 已存的**表单值**回填（邮箱/密码等）—— 以前只在内存里，
        //    关掉面板就没了 ❗（2026-10-21 用户反馈）
        let saved = SourceVariables.loginFormValues(for: source.bookSourceUrl)
        if !saved.isEmpty {
            for (k, v) in saved { values[k] = v }
        }
        // 已存的番茄 token 回填
        fqToken = SourceVariables.loginInfo(for: source.bookSourceUrl)["手动填写番茄token(可不填)"] ?? ""
        fqTokenSaved = !fqToken.isEmpty
        // ⚠️ 存的没有 → 从 cookie 罐自动抓（内置浏览器登录过的就抓得到）
        if fqToken.isEmpty { autoFillFQSessionId() }
        // ⚠️ 显示**合并后**的变量（站方默认 + 你的改动）
        //    站方的 `getArguments` 只在变量串为空时才给默认表 ⇒ 只显示用户那几项
        //    会让人以为「只有 server 一项」，也不知道 proxy/tab 这些默认值去哪了。
        //
        // ⭐⭐⭐ **存量变量超长 ⇒ 自动清掉 + 告诉用户**（2026-10-24 真机崩溃日志）
        //   变量是**回流**的（引擎回传 ⇒ 存成用户变量 ⇒ 下次再喂回去）
        //   ⇒ 手滑存过一次大文本（158KB 那种）⇒ **永久**撑大
        //   ⇒ 登录面板一弹出来就排版巨量文本 ⇒ **10 秒排不完 ⇒ watchdog 杀进程** ⭐⭐⭐
        //   ⇒ 现在：**自动清掉**（`effectiveVars` 也会截断到 8K ⇒ 双保险）
        if SourceVariables.varsTooLong(for: source.bookSourceUrl) {
            SourceVariables.setVars("", for: source.bookSourceUrl)
            message = "你之前存了一份超大的书源变量（已被丢弃）⇒ 现在变量是干净的，可以重新填 server"
            failed = true
        }
        varsText = SourceVariables.effectiveVars(for: source.bookSourceUrl)
        guard let raw = src.loginUi, !raw.isEmpty,
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
    /// ⭐⭐⭐ **登录动作的 UI 级超时**：330 秒 → **90 秒**
    ///   原来 330 秒（5 分半）是为了「浏览器登录要用户手动操作」⇒
    ///   但**站方服务器不通**时也一起等 5 分半 ⇒ 用户看到的就是「**app 卡死了**」⭐⭐⭐
    ///   （用户原话：「打开登录还把 app 卡死了」）
    ///   ⇒ 现在：**90 秒**（浏览器那个 op 自己有 5 分钟看门狗，够用）
    ///   ⇒ 超时后按钮自动放开 + 提示，不会再把面板锁死 ⭐
    static let actionTimeout: Double = 90

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
            // ⚠️⚠️ **必须有 UI 级超时**（2026-10-24 真机「打开登录把 app 卡死」）
            //   `LoginStatus.probe` 里有多次引擎调用（loginProbe + 独立硬验证）
            //   ⇒ 引擎卡住时它**永远不返回** ⇒ `probing` 永远 true
            //   ⇒ 「检测登录状态」按钮**永远转圈** ⇒ 用户看到的又是「点不动 / 卡死」⭐⭐⭐
            //   ⇒ 现在：90 秒后自动收场（按钮放开 + 说清发生了什么）
            do {
                let r = try await withTimeout(seconds: 90) { await LoginStatus.probe(source) }
                report = r
            } catch {
                report = LoginStatusReport(
                    verdict: "不确定",
                    loggedIn: false,
                    lines: ["⏱ 检测超时（90 秒）⇒ 引擎/站方服务器没响应。",
                            "· 站方服务器不通时会这样（点上面的「测速并选最快线路」换一条线路）",
                            "· 引擎卡住的话点「重置引擎」换掉它"],
                    stationMessages: [],
                    baseUrl: "")
            }
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

// MARK: - 玻璃输入框

extension View {
    /// ⭐ **玻璃输入框**（栖阅登录页同款：通透，能看到底下的插画）
    ///
    /// ⚠️ 必须 `textFieldStyle(.plain)` —— `.roundedBorder` 会画自己的边框+底色
    ///    ⇒ 玻璃套边框 = 一坨糊（同「按钮那个 .bordered」的坑）
    ///
    /// ⚠️ 2026-10-22：原来把它定义在 `SourceLoginSheet` **struct 里面**
    ///    ⇒ 只有那个 struct 能用 ⇒ `TextField` 用不了（CI 报 no member 'glassField'）
    ///    ⇒ 必须是 **View 的扩展** ⭐
    func glassField() -> some View {
        self
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .glassCard(cornerRadius: 12, variant: .clear)
    }
}
