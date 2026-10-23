import Foundation
import WebKit
import SwiftUI
import UIKit

// MARK: - 资源定位

/// 引擎资源定位。
///
/// Xcode 对「文件系统同步组」里的 .js/.html 落盘位置在不同版本上不一致：
/// 有的版本保留目录结构（engine/xxx.js），有的展平到 bundle 根。
/// 这里不猜 —— 挨个候选路径找，找不到再在 bundle 里递归搜一遍。
/// 找不到就明确报出缺哪个文件，而不是让首屏无声卡死。
enum ResourceLocator {
    /// 引擎脚本的**注入顺序有依赖**，别改
    static let scripts = [
        "jsoup-compat.js",   // 选择器层
        "sextant-filter.js", // 栖阅同款 Sextant 过滤表达式求值器（必须在 jsonpath.js 前）
        "jsonpath.js",       // JSONPath
        "org-jsoup.js",      // org.jsoup.* 兼容
        "sha1.js",           // 哈希
        "java-api.js",       // java.*
        "packages-native.js", // Packages.* 的原生函数实现（必须排在 packages_stub.js 前）
        "packages_stub.js",   // Packages / JavaImporter / importPackage 兼容层
        "source-api.js",      // Legado 的 source.* / cookie.* 兼容层（必须在 rule-analyzer 之前）
        "rule-analyzer.js",  // 规则解释器
        "engine.js",         // 调度层
    ]

    private static let subdirs = ["engine", "Resources/engine", "Engine", "reader", "Resources/reader", ""]

    private static var cache: [String: String] = [:]

    /// 宿主页：只用来给 JS 一个 document，位置必须和它同级可读
    static func engineHTML() -> (html: String, dir: URL)? {
        guard let url = locate("engine.html") else { return nil }
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (s, url.deletingLastPathComponent())
    }

    static func text(_ name: String) -> String? {
        if let hit = cache[name] { return hit }
        guard let url = locate(name),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        cache[name] = s
        return s
    }

    static func missingScripts() -> [String] {
        scripts.filter { text($0) == nil }
    }

    static func locate(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        // 1) 常见子目录
        for sub in subdirs {
            if let u = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: sub),
               FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // 2) bundle 根
        if let u = Bundle.main.url(forResource: base, withExtension: ext),
           FileManager.default.fileExists(atPath: u.path) { return u }
        // 3) 递归兜底：把 bundle 树里所有同名文件都找出来
        if let root = Bundle.main.resourceURL,
           let hit = firstMatch(in: root, base: base, ext: ext) { return hit }
        // 4) 用户覆盖目录：改引擎不用重新编译
        let custom = AppPaths.documents.appendingPathComponent("engine", isDirectory: true)
        let cu = custom.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cu.path) { return cu }
        return nil
    }

    private static func firstMatch(in dir: URL, base: String, ext: String) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        for item in items {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let hit = firstMatch(in: item, base: base, ext: ext) { return hit }
            } else if item.lastPathComponent == "\(base).\(ext)" {
                return item
            }
        }
        return nil
    }
}

// MARK: - 沙盒

/// 把 WKWebView 压成一台纯粹的 JS 虚拟机：
/// - 规则引擎全在这台虚拟机里跑（含 CSS/正则/JSONPath/XPath/`@js:`）
/// - 所有 UI（列表、目录、正文）都是原生 SwiftUI，WebView 一个像素都不显示
///
/// 调用方向：
///   原生 --callAsyncJavaScript--> JS  `window.__qrInvoke(op, payload)` 返回 Promise
///   JS ----postMessage-----------> 原生 `request/getString/cacheFile/...`
///   原生 --evaluateJavaScript----> JS  `window.__qrResolve(id, value)`
/// 调用方向：
///   原生 --callAsyncJavaScript--> JS  `window.__qrInvoke(op, payload)` 返回 Promise
///   JS ----postMessage-----------> 原生 `request/getString/cacheFile/...`
///   原生 --evaluateJavaScript----> JS  `window.__qrResolve(id, value)`
///
/// 注意 `WKScriptMessageHandler` 必须显式列在 conformance 里 —— 只写方法不写 conformance
/// 的话，编译器只在调用点报一句「does not conform」，很容易看漏。
@MainActor

final class RuleSandbox: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = RuleSandbox()

    @Published private(set) var ready = false
    @Published private(set) var lastError: String?
    /// 引擎启动过程中的每一步状态，界面上直接显示。
    /// 不然「搜不出东西」和「引擎根本没起来」在用户眼里长得一模一样。
    @Published private(set) var bootLog: [String] = []
    /// 最近 300 条引擎日志 —— 站方 JS 的报错以前只进 NSLog，用户**根本看不见**，
    /// 排查只能靠猜（「浏览器弹不出来」就是这么瞎查的）。自检面板里能看到。
    ///
    /// ⚠️ 之前是 60 条，自检面板只显示后 12 条 → 站方登录时打的那张会员卡片
    ///    会被后来的日志直接挤掉，用户什么都看不到。300 条够用。
    @Published private(set) var recentLogs: [String] = []

    private var webView: WKWebView!
    private var bootWaiters: [CheckedContinuation<Void, Never>] = []
    private var jsRequests: [Int: CheckedContinuation<Any?, Never>] = [:]
    private var jsSeq = 0
    /// 当前这次调用所属的书源，决定 header / jsLib / Cookie 策略
    var currentSource: BookSource?

    private override init() { super.init() }

    // MARK: 启动

    /// 引擎版本。改引擎时同步改这个，用户一眼能看出装的是新包还是旧包。
    static let engineVersion = "2026.10.22-r28（DTO 容错解码 / 目录 nextTocUrl 翻页队列）"

    /// 给界面用的一行状态
    var statusText: String {
        if ready { return "引擎就绪" }
        if let e = lastError { return "引擎未就绪：\(e)" }
        if bootLog.isEmpty { return "引擎启动中…" }
        return "引擎启动中：\(bootLog.last ?? "")"
    }

    /// 引擎自检：把缺什么、卡在哪一步一次列清
    func diagnose() -> String {
        var lines: [String] = []
        lines.append("引擎版本：\(Self.engineVersion)")
        lines.append("App 版本：\(AppPaths.appVersionLine)")
        if !recentLogs.isEmpty {
            lines.append("—— 最近引擎日志 ——")
            lines.append(contentsOf: recentLogs.suffix(12))
        }        // ATS 有没有放开：装旧包的话这里是 false，
        // 症状就是「分类能出来、一点书就报 App Transport Security」
        let ats = (Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]) ?? [:]
        let rawTrue = (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false
        // iOS 10+：plist 里只要出现这三个键之一，NSAllowsArbitraryLoads 的值就**被忽略、按 NO 算**。
        // 所以不能只看那个键写着什么 —— 得看旁边有没有"作废键"。曾经就因为这个白查了三轮。
        let killers = ["NSAllowsArbitraryLoadsInWebContent",
                       "NSAllowsArbitraryLoadsForMedia",
                       "NSAllowsLocalNetworking"].filter { ats[$0] != nil }
        if rawTrue && killers.isEmpty {
            lines.append("HTTP 明文站：已放开")
        } else if rawTrue {
            lines.append("HTTP 明文站：**实际没放开**（plist 写着 true，但被 \(killers.joined(separator: ",")) 作废了）")
        } else {
            lines.append("HTTP 明文站：**未放开**")
        }
        lines.append("就绪状态：\(ready ? "已就绪" : "未就绪")")
        if let e = lastError { lines.append("错误：\(e)") }
        let missing = ResourceLocator.missingScripts()
        if !missing.isEmpty { lines.append("缺少引擎文件：\(missing.joined(separator: ", "))") }
        else { lines.append("引擎文件：\(ResourceLocator.scripts.count) 个全部就位") }
        if let d = ResourceLocator.engineHTML() {
            lines.append("engine.html：已找到（\(d.html.count) 字符）")
        } else {
            lines.append("engine.html：**没找到**")
        }
        lines.append(contentsOf: bootLog.suffix(6).map { "· " + $0 })
        return lines.joined(separator: "\n")
    }

    /// **完整日志全文** —— 给「复制日志」按钮用。
    ///
    /// ⚠️ `diagnose()` 只带 12 条日志，那个窗口根本不够用：
    ///    站方登录时会打一张会员卡片（`java.log`），再跑几轮就把它挤出窗口了。
    ///    复制给别人的必须是**全量**，不然对方看到的日志跟现场对不上。
    func fullLogText() -> String {
        var lines: [String] = []
        lines.append("======== 轻阅 引擎日志 ========")
        lines.append("时间：\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("App 版本：\(AppPaths.appVersionLine)　引擎版本：\(Self.engineVersion)")
        lines.append("引擎状态：\(ready ? "已就绪" : "未就绪")")
        if let e = lastError { lines.append("错误：\(e)") }
        lines.append("")
        lines.append("======== 引擎日志（\(recentLogs.count) 条）========")
        if recentLogs.isEmpty {
            lines.append("（一条都没有）")
        } else {
            for (i, l) in recentLogs.enumerated() {
                lines.append(String(format: "%3d. %@", i + 1, l))
            }
        }
        lines.append("")
        lines.append("======== 启动过程 ========")
        if bootLog.isEmpty { lines.append("（空）") }
        else { lines.append(contentsOf: bootLog) }
        return lines.joined(separator: "\n")
    }

    /// 真发一次明文 HTTP 请求，看系统到底放不放行。
    ///
    /// Info.plist 里写着"已放开"不作数 —— 有些签名/安装工具会改写 Info.plist，
    /// 只有实际发一次请求才知道结果。这一条实测能区分两种情况：
    ///   - 放行 → http 站能用，之前那次报错另有原因
    ///   - -1022 → 这个包的 ATS 例外没生效，http 站全都不行
    func probePlainHTTP() async -> String {
        let ats = (Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]) ?? [:]
        let plistSays = (ats["NSAllowsArbitraryLoads"] as? Bool) == true
        var lines: [String] = []
        lines.append("Info.plist 写着：\(plistSays ? "已放开" : "未放开")")
        for url in ["http://neverssl.com/", "http://example.com/"] {
            guard let u = URL(string: url) else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 10
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            // 用跟书源请求**同一种** session（ephemeral），
            // 不然测出来放行、真发书源请求还是被拦，诊断就骗人了。
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: cfg)
            do {
                let (_, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                lines.append("✅ \(url) → HTTP \(code)")
                lines.append("")
                lines.append("结论：**明文 HTTP 能用**。之前那次报错是别的原因。")
                return lines.joined(separator: "\n")
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain,
                   ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                    lines.append("❌ \(url) → 被系统拦（ATS -1022）")
                } else {
                    lines.append("⚠️ \(url) → \(ns.localizedDescription)（不是 ATS 问题）")
                }
            }
        }
        lines.append("")
        lines.append("结论：**这个包的 ATS 例外没生效，http 明文站全都用不了。**")
        lines.append("多半是签名/安装工具改写了 Info.plist。")
        return lines.joined(separator: "\n")
    }

    func boot() {
        guard webView == nil else { return }
        bootLog.removeAll()
        bootLog.append("查找 engine.html…")
        guard let page = ResourceLocator.engineHTML() else {
            lastError = "找不到 engine.html —— 引擎资源没进 bundle"
            bootLog.append("失败：engine.html 不在 bundle 里")
            return
        }
        bootLog.append("engine.html 找到了（\(page.html.count) 字符）")
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "qr")
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 沙盒里跑站方书源的 JS，必须能跑 JS
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // 不要用 limitsNavigationsToAppBoundDomains：它可能连带拦掉 loadFileURL 自己，
        // 一拦就是「引擎永远不 ready」，首屏直接卡死。防外跳交给下面的 navigationDelegate。

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isHidden = true
        wv.isUserInteractionEnabled = false
        wv.navigationDelegate = self
        // 同步通道要用 window.prompt → 必须挂 uiDelegate（见下面的 WKUIDelegate 实现）
        wv.uiDelegate = self
        webView = wv

        wv.loadHTMLString(page.html, baseURL: page.dir)
    }

    /// **重置引擎** —— 引擎卡死时的救命按钮
    ///
    /// ⚠️ 为什么需要：站方 JS 一旦卡住（比如同步通道的 window.prompt 没人回调），
    ///    那个 WKWebView 的 **JS 线程就永远卡在那** → 引擎彻底死掉 →
    ///    后面所有 op 排队 → **App 点什么都没反应**。
    ///    换掉 WKWebView = 换掉那条卡死的 JS 线程 ✅
    ///    （不用重装 App）
    func resetEngine() {
        NSLog("[engine] 重置引擎")
        recentLogs.append("[engine] 手动重置引擎")
        if recentLogs.count > 300 { recentLogs.removeFirst(recentLogs.count - 300) }
        ready = false
        lastError = nil
        bootLog.removeAll()
        // 旧的那个还挂着 message handler → 先摘掉，免得回调打到新的
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "qr")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        // 队列里排队的 op 全部作废（它们等的是那个死掉的引擎）
        invokeTail = nil
        boot()
    }

    /// 按依赖顺序逐个注入引擎脚本，缺哪个直接报出来
    private func injectEngine() async {
        let missing = ResourceLocator.missingScripts()
        guard missing.isEmpty else {
            lastError = "引擎文件缺失: " + missing.joined(separator: ", ")
            bootLog.append("失败：缺 \(missing.count) 个文件")
            return
        }
        bootLog.append("开始注入 \(ResourceLocator.scripts.count) 个引擎脚本…")
        for name in ResourceLocator.scripts {
            guard let code = ResourceLocator.text(name) else {
                lastError = "引擎文件读不到: \(name)"
                return
            }
            do {
                // ⚠️ 末尾必须补 `void 0` ——
                // evaluateJavaScript 会把脚本的**完成值**桥接回 Swift，
                // 而 WebKit 桥接不了普通 JS 对象 / 函数 / Symbol
                // → 抛 WKError.resultTypeIsUnsupported（「返回结果的类型不受支持」）。
                // 引擎脚本本来就没返回值（IIFE 或语句堆），补一句 void 0 保证完成值是 undefined。
                // ⚠️ 前面那个 \n 不能省：万一脚本以 `// 注释` 结尾，void 0 会被注释掉。
                // 这类问题 jsdom 测不出来（jsdom 没有返回值桥接环节），
                // 所以另有门禁：test/engine-script-toplevel.test.js 断言每个脚本顶层完成值是 undefined。
                _ = try await webView.evaluateJavaScript(code + "\n;void 0;")
            } catch {
                lastError = "引擎脚本 \(name) 执行出错: \(error.localizedDescription)"
                return
            }
        }
        // 自检：调度层没起来就别装作 ready，否则上层只会看到一个没来由的 15s 超时
        // （写成 `(try? await …) as? Bool` 在 Any? 上不可靠，拆开写）
        var invoked = false
        if let r = try? await webView.evaluateJavaScript(
            "typeof window.__qrInvoke === 'function' && !!(window.QR && window.QR.rule)") {
            invoked = (r as? Bool) == true
        }
        guard invoked else {
            lastError = "引擎脚本注入完了但 __qrInvoke 不可用，顺序或内容有问题"
            bootLog.append("失败：__qrInvoke 不可用")
            return
        }
        // 同步通道（window.prompt）的开关 —— **默认关**
        // ⚠️ 它有把 JS 线程永久卡死的风险（原生那边不回调 → prompt 永不返回
        //    → 引擎死掉 → 后面所有 op 排队 → App 点什么都没反应）。
        //    默认走纯 JS 兜底（语义跟 Swift 一致），要用原生实现就在自检面板里开。
        let wantSync = UserDefaults.standard.bool(forKey: EngineSyncChannel.key)
        _ = try? await webView.evaluateJavaScript(
            "window.QR && (window.QR.__qrSyncEnabled = \(wantSync ? "true" : "false"));\n;void 0;")
        bootLog.append(wantSync
            ? "同步通道（window.prompt）已开启 —— 卡了就用「重置引擎」"
            : "同步通道默认关闭（用纯 JS 兜底，避免 JS 线程卡死）")
        bootLog.append("注入完成，__qrInvoke 可用")
        markReady()
    }

    /// 切换同步通道（不用重启引擎）
    func applySyncChannel(_ on: Bool) async throws {
        guard let wv = webView else { return }
        _ = try? await wv.evaluateJavaScript(
            "window.QR && (window.QR.__qrSyncEnabled = \(on ? "true" : "false"));\n;void 0;")
    }

    /// 往引擎日志里追加一条（宿主侧用，比如自动选线的结果）
    ///
    /// ⭐ **格式：`[时间戳] [步骤] 内容`**（2026-10-21 对齐栖阅的诊断体系）
    ///   栖阅的日志是**分步事件链**（`component=… event=…` + 一堆计数器），
    ///   轻阅原来只有一坨字符串流水 ⇒ 排查「时好时坏」时**看不出哪一步断的**。
    ///   ⇒ 现在每行都带：① 毫秒时间戳 ② 步骤归属 ③ 原始内容
    ///   ⇒ 面板再按步骤分组成「诊断时间线」，一眼看出断在哪。
    func appendLog(_ line: String) {
        let stamped = "[\(Self.logTimeFormatter.string(from: Date()))] "
            + "[\(Self.stepFor(line, fallback: currentStep))] " + line
        recentLogs.append(stamped)
        if recentLogs.count > 300 { recentLogs.removeFirst(recentLogs.count - 300) }
        NSLog("%@", stamped)
    }

    /// **清空引擎日志**
    ///
    /// ⭐ 用户要「测试完日志要清空」⇒ 手动按钮 + 测书源开始时自动清空，
    ///    这样报告里只有**本次**的日志，不会混着上一次的。
    func clearLogs() {
        recentLogs.removeAll()
    }

    /// 日志行的时间戳（`HH:mm:ss.SSS`）
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// **当前正在跑的 op 属于哪一步** —— 给日志归类用
    /// （`[两遍跑]…` 这种没有自己步骤名的日志，会归到当前 op 那一步）
    private var currentStep: String = ""

    /// op 名 → 步骤名（面板上分组的依据）
    ///
    /// ⚠️ 实现放在 `EngineLogTimeline`（nonisolated 静态）——
    ///    这个类是 `@MainActor`，方法放在这儿就只有 MainActor 上能调，
    ///    而日志解析在**同步**上下文里做 ⇒ 编译不过。
    static func stepNameForOp(_ op: String) -> String {
        EngineLogTimeline.stepNameForOp(op)
    }

    /// 日志行 → 步骤名
    static func stepFor(_ line: String, fallback: String) -> String {
        if line.hasPrefix("[目录]") { return "目录" }
        if line.hasPrefix("[详情]") { return "详情" }
        if line.hasPrefix("[正文]") { return "正文" }
        if line.hasPrefix("[发现]") { return "发现" }
        if line.hasPrefix("[搜索]") { return "搜索" }
        if line.hasPrefix("[登录]") { return "登录" }
        if line.hasPrefix("[ajax") { return "网络" }
        if line.hasPrefix("[Swift·") { return "宿主" }
        if line.hasPrefix("[选线]") { return "选线" }
        // ⚠️ 两遍跑 / 引擎内部消息 ⇒ 属于当前这一步
        return fallback.isEmpty ? "引擎" : fallback
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        // ⭐ 标记当前引擎后端（用户能在「测书源」面板看到）
        if !EngineBackend.useNewEngine { EngineBackend.current = .legacyJS }
        let ws = bootWaiters; bootWaiters = []
        ws.forEach { $0.resume() }
    }

    func waitReady() async {
        if ready { return }
        await withCheckedContinuation { bootWaiters.append($0) }
    }

    // MARK: 原生 → JS

    struct SandboxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 调一次引擎操作。`op` 对应 `engine.js` 里的 `OPS`。
    /// 串行链的尾巴：上一个 invoke 没跑完，下一个先等它。
    ///
    /// ⚠️ 为什么要串行：同一个 WKWebView 上**并发**跑多个
    ///    `callAsyncJavaScript` 时，只要有一个在执行期间页面被导航/重载，
    ///    其余的结果就会变成不支持的类型 → `WKError.javaScriptResultTypeIsUnsupported`
    ///    （code 5，「执行 JavaScript 返回结果的类型不受支持」）。
    ///    真机症状：发现页**退出重进**才报错 —— `.task` 重跑时上一轮的
    ///    `exploreKinds` 还没结束，两个调用叠在一起。
    ///
    /// ⚠️ 没用独立 actor：这个类整体是 `@MainActor`，同文件里声明的 actor
    ///    会被继承全局 actor → 编译报
    ///    "actor 'InvokeSerializer' cannot have a global actor"。
    ///    在 @MainActor 里用 Task 链串行就够。
    private var invokeTail: Task<Void, Never>?

    /// 单个 op 的最长等待（秒）
    ///
    /// ⚠️ 这条是**保命**的：op 队列是**串行**的 → 一个 op 永不返回，
    ///    后面所有 op 全排队 → **整个 App 点什么都没反应**（真机踩过：
    ///    内嵌浏览器 present 失败 → continuation 没人 resume → 引擎彻底卡死）。
    ///    有了这个超时，最坏情况是「这次操作失败」，不是「App 死了」。
    ///    （浏览器那个 op 自己有 5 分钟看门狗，这里给 6 分钟留余量）
    static let opTimeoutSeconds: Double = 360

    /// 把书源给的 URL 字符串解析成 `URL`
    ///
    /// ⚠️⚠️ **为什么要兜底重试**（2026-10-21 真机栽过）：
    ///   `URL(string:)` 遇到 `{` `}` `"` 裸中文这些字符**直接返回 nil**。
    ///   而站方的 POST 请求 query 里就有这些：
    ///   `…/detail?book_id=xxx&source=番茄&tab=小说&variable={"custom":""}`
    ///   → URL 解析失败 → **请求根本没发出去** → 引擎把失败吞成空串 →
    ///     站方 `JSON.parse('')` → 「JSON Parse error: Unable to parse JSON string」
    ///     → 详情数据为空 → 简介规则炸「abstract.split」。
    ///   ⇒ 沙盒用 Node fetch（自己会编码）所以全绿，**真机才炸**。
    ///   ⇒ 这里再兜一层：解析不了就百分号编码一遍再试。
    private static func parseURL(_ raw: String) -> URL? {
        let s = String(raw)
        if let u = URL(string: s), u.scheme != nil { return u }
        // 只保留 URL 合法字符（保留 : / ? # [ ] @ ! $ & ' ( ) * + , ; =）
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=")
        guard let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed),
              let u2 = URL(string: encoded), u2.scheme != nil else { return nil }
        return u2
    }

    func invoke(_ op: String, _ payload: [String: Any] = [:], source: BookSource? = nil) async throws -> Any {
        let prev = invokeTail
        let current = Task<Any, Error> {
            if let prev { await prev.value }
            return try await self.invokeLocked(op, payload, source: source)
        }
        invokeTail = Task { _ = try? await current.value }
        // ⚠️ 超时保护：current 永不返回时，**别把整个队列拖死**
        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask { try await current.value }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.opTimeoutSeconds * 1_000_000_000))
                throw SandboxError(message: "操作「\(op)」超时（\(Int(Self.opTimeoutSeconds)) 秒），引擎可能卡住了")
            }
            do {
                guard let first = try await group.next() else {
                    throw SandboxError(message: "操作「\(op)」没有结果")
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                // ⚠️⚠️ **超时就直接换掉引擎**：
                //    队列是串行的 → 卡死的 op 不死，后面全排队 → App 点什么都没反应。
                //    换掉 WKWebView = 换掉那条卡死的 JS 线程 → 队列立刻疏通 ✅
                //    （不清也行，但用户得多等 6 分钟 —— 这期间面板全是废的）
                if (error as? SandboxError) != nil {
                    NSLog("[engine] op「%@」超时 → 重置引擎", op)
                    self.resetEngine()
                }
                throw error
            }
        }
    }

    private func invokeLocked(_ op: String, _ payload: [String: Any],
                              source: BookSource?) async throws -> Any {
        boot()
        await waitReady()
        let prev = currentSource
        if let s = source { currentSource = s }
        defer { currentSource = prev }
        // ⭐ **步骤归属 + 耗时**（2026-10-21 对齐栖阅的诊断体系）
        //   栖阅的测试面板会给每一步单独计时（目录 2.32s / 正文 1.38s），
        //   轻阅原来完全没有 ⇒ 排查「时好时坏」时既不知道断在哪步，也不知道慢在哪步。
        // ⚠️ 必须设在**这里**（真正执行时），不能在 `invoke` 里 ——
        //    `invoke` 只是排队，前面还有 op 时 currentStep 就被改掉了 ⇒ 归类会串。
        let step = Self.stepNameForOp(op)
        let prevStep = currentStep
        currentStep = step
        let t0 = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            // ⚠️ 消息本身**不要**再写 `[步骤]` 前缀 —— appendLog 会自动加，
            //    否则会变成 `[目录] [目录] ⏱ …`。
            appendLog("⏱ op「\(op)」耗时 \(ms)ms")
            currentStep = prevStep
        }

        let argJSON = Self.jsonString(payload)
        // ⚠️⚠️ 必须 JSON.stringify 成字符串再返回，**不能**把 JS 对象直接过桥。
        //
        // callAsyncJavaScript 会把 Promise 的 resolved value 直接桥接成 Foundation 对象，
        // 而返回值里只要出现下面任意一个，就抛 WKError.resultTypeIsUnsupported
        // （中文本地化就是「执行 JavaScript 返回结果的类型不受支持」）：
        //     · 属性值是 undefined（哪怕对象本身有别的键）
        //     · 函数 / Symbol / BigInt / DOM 节点
        //
        // 引擎返回的 { books, total, nextUrl } / { kinds, error } 这类对象，
        // 只要哪个分支走了 `error: undefined` 或漏了某个键，真机就整页报错，
        // 而 **jsdom 沙盒完全测不出来**（jsdom 没有「返回值桥接回 Swift」这一步，
        // `vm.runInContext` 会直接把对象给你，看着一切正常）。
        //
        // 字符串永远桥接得过去，所以：JS 侧一律 JSON.stringify，Swift 侧再解析。
        // 顺带把 undefined 变成"字段缺失"，解码时行为可预期。
        let script = """
        try {
            var v = await window.__qrInvoke(\(Self.jsonString(op)), \(argJSON));
            var s = null;
            try {
                // ⚠️⚠️ JSON.stringify 对 **函数 / Symbol** 返回 **undefined**（不是字符串！），
                //    对循环引用会**抛异常**。
                //    脚本一旦返回 undefined，WebKit 就抛
                //    WKError.javaScriptResultTypeIsUnsupported (code 5)
                //    —— 中文本地化：「执行 JavaScript 返回结果的类型不受支持」。
                //
                //    所以这里必须**保证返回的一定是字符串**：
                //    · v 是 undefined → 换成 null
                //    · v 是函数/Symbol → stringify 得到 undefined → 兜底成错误 JSON
                //    · v 是循环引用   → stringify 抛异常 → 兜底成错误 JSON（并带上原因）
                s = JSON.stringify(v === undefined ? null : v);
            } catch (e2) {
                s = JSON.stringify({ error: 'JSON 序列化失败: ' + String((e2 && e2.message) || e2) });
            }
            if (typeof s !== 'string') {
                s = JSON.stringify({ error: '引擎返回了不可序列化的值（type=' + (typeof v) + '）' });
            }
            return s;
        } catch (e) {
            return JSON.stringify({ error: String((e && e.message) || e) });
        }
        """
        do {
            let r = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            // 结果是 JSON 文本；解析不了就把原文带出来，别只丢一句"返回结果的类型不受支持"
            if let text = r as? String {
                return Self.bridgeJSON(text) ?? (text as Any)
            }
            if let dict = r as? [String: Any] { return dict }
            return r ?? NSNull()
        } catch let e as WKError {
            // 把 code 带上：.resultTypeIsUnsupported 说的还是那句人话，
            // 带上 code + 原文才查得出是哪个 op 的哪个字段出的问题
            // ⚠️ 普通 String 插值**不支持** `\(v, privacy: .public)` ——
            //    那是 SwiftUI Text 的插值语法，在这里报
            //    "cannot infer contextual base in reference to member 'public'"
            //    + "extra argument 'privacy' in call"，两行且都跟真正原因不沾边
            throw SandboxError(message: "引擎调用 \(op) 失败 [\(e.code.rawValue)]: \(e.localizedDescription)")
        } catch {
            throw SandboxError(message: "引擎调用 \(op) 失败: \(error.localizedDescription)")
        }
    }

    /// JS 侧 JSON.stringify 的文本 → Foundation 对象。
    /// 解析失败返回 nil，交给调用方把原文带出来（比静默吞掉强）。
    static func bridgeJSON(_ text: String) -> Any? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "null" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])
    }

    static func jsonString(_ o: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed]),
           let s = String(data: d, encoding: .utf8) { return s }
        return "null"
    }

    // MARK: JS → 原生

    /// WKScriptMessageHandler
    ///
    /// 刻意**不**标 nonisolated：WebKit 在新 SDK 里整个模块是 @MainActor 标注的，
    /// 用 nonisolated 实现 @MainActor 协议要求会直接不满足 conformance。
    /// 类本身就是 @MainActor，方法直接继承，不需要额外标注。
    func userContentController(_ ucc: WKUserContentController,
                               didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any],
              let fn = body["fn"] as? String,
              let id = body["id"] as? Int else { return }
        let args = body["args"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let result = await self.dispatch(fn: fn, args: args)
            self.reply(id: id, result: result)
        }
    }

    /// **共享的 URLSession**（连接复用 ⇒ 连续请求不用重新握手）
    ///
    /// ⚠️ headers 是**每个请求自己设**的（URLRequest 上），这里只放 UA 兜底；
    ///    cookie 罐共用 `HTTPCookieStorage.shared` ✅（站方登录态靠它）。
    private static var sessionCache: [String: URLSession] = [:]

    private static func sharedSession(headers: [String: String], timeout: Double) -> URLSession {
        let key = "\(timeout)|\(headers["User-Agent"] ?? "")"
        if let s = sessionCache[key] { return s }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = headers
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        // 站方很多接口是 keep-alive ⇒ 别急着断
        cfg.requestCachePolicy = .useProtocolCachePolicy
        let s = URLSession(configuration: cfg)
        sessionCache[key] = s
        return s
    }

    private func reply(id: Int, result: [String: Any]) {
        let js = "window.__qrResolve(\(id), \(Self.jsonString(result)));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func dispatch(fn: String, args: [String: Any]) async -> [String: Any] {
        func err(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        func ok(_ payload: [String: Any] = [:]) -> [String: Any] { var d = payload; d["ok"] = true; return d }

        switch fn {
        case "ping":
            return ok()

        case "log":
            let m = args["msg"] as? String ?? ""
            appendLog(m)
            return ok()

        case "toast":
            let m = args["msg"] as? String ?? ""
            await MainActor.run { Toast.show(m) }
            return ok()

        case "request":
            return await nativeRequest(args)

        case "getString":
            // 站方规则常把「整份 HTML」当字符串塞给 java.getString/正则
            guard let s = args["str"] as? String else { return err("getString 缺参") }
            return ok(["value": Self.base64(s)])

        case "getStringArray":
            let arr = args["list"] as? [String] ?? []
            return ok(["value": arr.map { Self.base64($0) }])

        case "getCookie":
            let url = args["url"] as? String ?? ""
            return ok(["value": CookieJar.cookieString(for: url)])

        case "setCookie":
            let url = args["url"] as? String ?? ""
            let c = args["cookie"] as? String ?? ""
            CookieJar.set(c, for: url)
            return ok()

        case "removeCookie":
            // ⚠️ 站方的「退出登录」靠它清 cookie —— 以前原生侧没这个 op
            //    → 站方 logout() 里的 cookie.removeCookie 全是空操作
            //    → 退出后 cookie 还在 → 用户看着像没退出。
            let url = args["url"] as? String ?? ""
            CookieJar.remove(for: url)
            return ok()

        case "cachePut":
            // 能力在 Swift（Core/LegadoCompat.swift 的 Cache）→ 这里只转发
            let k = args["key"] as? String ?? ""
            let v = args["value"] as? String ?? ""
            LegadoCompat.Cache.put(k, v)
            return ok(["value": "1"])

        case "cacheGet":
            let k = args["key"] as? String ?? ""
            return ok(["value": LegadoCompat.Cache.get(k)])

        case "cacheRemove":
            let k = args["key"] as? String ?? ""
            LegadoCompat.Cache.remove(k)
            return ok(["value": "1"])

        case "cacheText":
            guard let p = args["path"] as? String, let t = args["text"] as? String else { return err("cacheText 缺参") }
            return ok(["value": CacheFiles.write(p, t) ? "1" : "0"])

        case "cacheFile":
            let p = args["path"] as? String ?? ""
            let t = args["text"] as? String ?? ""
            return ok(["value": CacheFiles.write(p, t) ? "1" : "0"])

        case "readCache":
            let p = args["path"] as? String ?? ""
            return ok(["value": CacheFiles.read(p) ?? ""])

        case "readFile":
            // 只允许读 Documents 下的文件，挡掉 ../ 穿越
            guard let p = args["path"] as? String, let safe = SandboxFS.sanitize(p),
                  let s = try? String(contentsOf: safe, encoding: .utf8) else { return ok(["value": ""]) }
            return ok(["value": s])

        case "importScript":
            guard let p = args["path"] as? String, let s = ResourceLocator.text(p) else { return err("importScript 找不到 " + (args["path"] as? String ?? "")) }
            // 明确用 completion-handler 版本：直接写 evaluateJavaScript(s) 会被解析到
            // async 重载，那边少个 await 就是编译错误
            // 补 \n;void 0; 同 injectEngine：别把脚本完成值交给 WebKit 去桥接
            webView.evaluateJavaScript(s + "\n;void 0;", completionHandler: nil)
            return ok()

        case "getWebViewUA":
            return ok(["value": Self.userAgent])

        case "sourceHeader":
            return ok(["value": currentSource?.header ?? ""])

        case "deviceID":
            return ok(["value": UIDevice.current.identifierForVendor?.uuidString ?? "qiReaderLite"])

        case "openBrowser":
            // 内嵌浏览器：弹出来 → 用户登录/扫码 → 关掉 → 把页面 HTML/URL/cookie 交回去。
            // 聚合源的「番茄登录 / 注册 / 用户后台 / 教程」全靠它。
            return await self.openBrowser(args)

        case "showBrowser":
            // 别名：有些书源直接调 java.showBrowser（引擎侧已经改成走两遍跑，
            // 但保底留一个）→ 当成 openBrowser 处理。
            return await self.openBrowser(args)

        default:
            return err("原生侧没有实现 fn=\(fn)")
        }
    }

    // MARK: 内嵌浏览器

    /// 弹内嵌浏览器，等用户关掉，把页面 HTML / URL / cookie 交回去。
    ///
    /// ⚠️ 必须**等用户关掉**才能返回 —— 站方是这么用的：
    ///    `let page = java.startBrowserAwait(url, '番茄登录'); let html = page.body();`
    ///    也就是「打开 → 用户扫码 → 关闭 → 读页面」。
    private func openBrowser(_ args: [String: Any]) async -> [String: Any] {
        guard let raw = args["url"] as? String,
              let u = URL(string: raw), u.scheme != nil else {
            return ["ok": false, "error": "URL 非法: \(args["url"] as? String ?? "nil")"]
        }
        let title = args["title"] as? String ?? ""
        NSLog("[browser] 打开 %@", raw)
        recentLogs.append("[browser] 打开 " + raw)
        if recentLogs.count > 300 { recentLogs.removeFirst(recentLogs.count - 300) }
        await MainActor.run { Toast.show("正在打开浏览器…（登录完把浏览器关掉）") }
        guard let host = Self.topViewController() else {
            // 兜底：弹不出来至少用系统浏览器打开（登录态拿不回来，但页面能看）
            if let u = URL(string: raw) {
                await MainActor.run { UIApplication.shared.open(u) }
            }
            return ["ok": false, "error": "找不到可显示的界面（已改用系统浏览器打开）"]
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            var done = false
            var watchdog: Timer?
            func finish(_ value: [String: Any]) {
                guard !done else { return }
                done = true
                watchdog?.invalidate()
                watchdog = nil
                cont.resume(returning: value)
            }
            let sheet = BrowserSheet(url: raw, title: title) { html, url, cookie in
                finish(["ok": true, "value": [
                    "html": html, "url": url, "cookie": cookie
                ]])
            }
            let vc = UIHostingController(rootView: sheet)
            vc.modalPresentationStyle = .fullScreen
            host.present(vc, animated: true)

            // ⚠️⚠️⚠️ **present 可能失败，而失败时没人 resume 这个 continuation**
            //   → 这个 op 永远不返回 → 引擎的 op 队列是**串行**的
            //   → 后面所有 op 全排队 → **整个 App 点什么都没反应**
            //   （症状：toast「正在打开浏览器…」闪一下，浏览器不出现，之后全卡）
            //
            // 常见原因：从 SwiftUI 的 .sheet 里面再 present 一个 UIKit 模态
            //   → 「whose view is not in the window hierarchy」/「already presenting」
            //
            // 所以：**① 验一下有没有真的弹出来  ② 加看门狗兜底**

            // ① 下一个 runloop 还没进窗口 → present 失败了 → 立刻报错，别挂着
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Task { @MainActor in
                    guard !done else { return }
                    if vc.view.window == nil {
                        self.recentLogs.append("[browser] 弹不出来（present 失败）：\(raw)")
                        if self.recentLogs.count > 300 {
                            self.recentLogs.removeFirst(self.recentLogs.count - 300)
                        }
                        finish(["ok": false, "error": "浏览器弹不出来（界面没接上），请把日志发出来"])
                    }
                }
            }
            // ② 看门狗：用户一直没关 → 自动收场（5 分钟）
            watchdog = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
                Task { @MainActor in
                    guard !done else { return }
                    self.recentLogs.append("[browser] 超时自动关闭：\(raw)")
                    if self.recentLogs.count > 300 {
                        self.recentLogs.removeFirst(self.recentLogs.count - 300)
                    }
                    finish(["ok": false, "error": "浏览器超时（5 分钟没关），已自动关闭"])
                    vc.dismiss(animated: true)
                }
            }
        }
    }

    /// 当前最顶层的 view controller（present 浏览器要用）
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // ⚠️ 排除隐藏窗口 —— 引擎自己的 WKWebView 之类的别被选中，
        //    present 到看不见的窗口上 =「浏览器弹不出来」
        let visible = (scene?.windows ?? []).filter { !$0.isHidden && $0.alpha > 0.01 }
        let win = visible.first(where: { $0.isKeyWindow })
            ?? visible.first { $0.rootViewController != nil }
            ?? scene?.windows.first
        var vc = win?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    // MARK: HTTP

    private func nativeRequest(_ args: [String: Any]) async -> [String: Any] {
        // ⚠️ 别写 URLRequest(url: URL(string: "")!) —— Apple 平台上 URL(string: "") 返回 nil，
        // 强解包会**每次发请求都崩**。Kotlin 的 URL("") 是合法空 URL，Swift 不是。
        guard let raw = args["url"] as? String else {
            return ["ok": false, "error": "URL 非法: \(args["url"] as? String ?? "nil")"]
        }
        // ⚠️⚠️⚠️ **`data:` 伪 URL 绝不能真去 fetch**（2026-10-22 真机栽在这）
        //   聚合源（🍅大灰狼）的 bookUrl / tocUrl / chapterUrl 全是：
        //       data:;base64,<载荷>,{"type":"qingtian2"}
        //   ⇒ URLSession 去 fetch 它 ⇒ Foundation 解 data: URL 的 base64
        //      ⇒ 载荷不是合法 base64 ⇒ 抛「**illegal base64 data at input byte 9**」
        //      ⇒ 还会冒成一个 toast ⇒ 规则整条挂掉 ⭐
        //   ⇒ 这里**直接把载荷当响应体返回**（跟引擎 fetchPage 的处理一致）。
        //      站方的语义就是「data: 伪 URL 的载荷 = 页面内容」✅
        if raw.lowercased().hasPrefix("data:") {
            var payload = ""
            if let comma = raw.firstIndex(of: ",") {
                payload = String(raw[raw.index(after: comma)...])
            }
            // 剥掉 Legado 的 URL 选项后缀 `,{"type":"x"}`（百分号编码过的也认）
            if let m = payload.range(of: #",\s*(\{|%7B)"#, options: [.regularExpression, .caseInsensitive]) {
                payload = String(payload[..<m.lowerBound])
            }
            return ["ok": true, "code": 200, "url": raw, "headers": [:],
                    "_body": payload, "body": payload, "_code": 200, "_url": raw]
        }
        // ⭐⭐⭐ **必须走 Core/AnalyzeUrl.swift**（2026-10-21 真机「目录 0 章」的根因之二）：
        //   以前这里只用 `parseURL`（纯 Foundation 的百分号编码）⇒
        //   **query 里的 `+` 原样保留** ⇒ 服务器按 form 解码时 `'+'` 变**空格**
        //   ⇒ 🍅大灰狼的 book_id 是 **base64**（base64 字母表里就有 `+` 和 `/`）
        //   ⇒ **book_id 被损坏** ⇒ 「有的书能开、有的书开不了」 ⇒ 目录 0 章 ❗
        //   （build166/167 写好的 `analyzeFields` —— `+`→`%2B`、`/`→`%2F`、中文/花括号
        //     百分号编码 —— **在 App 里一次都没被调用过**，是死代码 ⚠️）
        //   ⇒ 现在原生请求层跟沙盒（JS 的 analyzeUrl）**用同一套语义** ✅
        //   ⇒ 沙盒全绿、真机炸的那一类问题，从根上没了。
        //
        // ⚠️ method/body 的来源要分清：
        //   ① 引擎 URL 规则那条链：JS 已经解析过选项了（method/body 在参数里）⇒ 保留参数
        //   ② 站方 `java.ajax(url)` 那条链：**没**解析过 ⇒ 这里用 AnalyzeUrl 解析出来的
        let parsed = AnalyzeUrl.parse(raw, baseUrl: "")
        let hasOption = AnalyzeUrl.hasOptionSuffix(raw)
        let methodFromOptions = hasOption ? parsed.method : (args["method"] as? String ?? "GET")
        let bodyFromOptions = hasOption ? parsed.body : (args["body"] as? String ?? "")
        guard let u = Self.parseURL(parsed.url) else {
            return ["ok": false, "error": "URL 非法: \(args["url"] as? String ?? "nil")"]
        }
        var req = URLRequest(url: u)

        // 站方书源的 header 里有 UA / Referer / Cookie，很多站不加就 403
        var header: [String: String] = [:]
        // ⚠️ 站方 `url,{"headers":{…}}` 选项里的头（**替换**源级头）⇒ 先铺它
        if hasOption {
            for (k, v) in parsed.headers { header[k] = v }
        }
        if let h = args["headers"] as? [String: String] { header.merge(h) { _, new in new } }
        if let srcHeader = currentSource?.header, !srcHeader.isEmpty,
           let parsed = HeaderCodec.decode(srcHeader) {
            for (k, v) in parsed where header[k] == nil { header[k] = v }
        }
        let ua = Self.userAgent
        // 别在循环里 break：站方 header 常见顺序是 Referer 在前、User-Agent 在后，
        // 一 break 后面所有头全丢，表现是「Referer 没带上被站方 403」
        for (k, v) in header {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        // ── loginHeader：自动注入到**每次**请求头（栖阅机制，§9.2 🟢）──
        // 格式：`名称: 值`，一行一个（最常用的是 `Cookie: sessionid=xxx`）
        // 用途：番茄 sessionid 这类「不来自 cookie 罐、但每个请求都要带」的凭据
        //      （🍅大灰狼要 sessionid 才能同步番茄数据；
        //        而它只能从 cookie 罐里翻 → 在 Safari 登录的读不到 → 一直提示「未登录番茄」）
        //
        // ⚠️ 解析逻辑放在 LegadoCompat（纯 Foundation）→ 沙盒 swiftc 能真编 ✅
        if let src = currentSource {
            let lh = SourceVariables.loginHeader(for: src.bookSourceUrl)
            if !lh.isEmpty {
                for (name, value) in LegadoCompat.parseLoginHeader(lh) {
                    // 已有同名头就不覆盖（站方自己指定的优先）
                    if req.value(forHTTPHeaderField: name) == nil {
                        req.setValue(value, forHTTPHeaderField: name)
                    }
                }
            }
        }

        let method = methodFromOptions.uppercased()
        req.httpMethod = method
        if !bodyFromOptions.isEmpty {
            req.httpBody = bodyFromOptions.data(using: .utf8)
        } else if let body = args["body"] as? String, !body.isEmpty {
            req.httpBody = body.data(using: .utf8)
        } else if let b64 = args["bodyBase64"] as? String, let d = Data(base64Encoded: b64) {
            req.httpBody = d
        }

        // ⚠️ 超时从 20s 降到 12s：站方（🍅大灰狼）的详情流程有 **8 个 host 的失败兜底**，
        //    一个 host 卡住就等满超时 → 7 个兜底能把详情页拖到两分钟 ❗
        //    12s 足够正常响应，又不会让兜底链失控。
        let timeout = min(max(args["timeout"] as? Double ?? 12, 3), 90)

        // httpAdditionalHeaders 是**可选**属性，不能直接下标赋值
        // （`cfg.httpAdditionalHeaders["X"] = v` 编译不过），得先把字典拼好再赋
        var sessionHeaders = header
        sessionHeaders["User-Agent"] = req.value(forHTTPHeaderField: "User-Agent") ?? ua

        // ⚠️⚠️ **必须复用同一个 URLSession**（2026-10-21 真机「详情页很慢很慢」）：
        //   原来每次请求都 `URLSession(configuration: cfg)` 新建一个 ephemeral session
        //   ⇒ 每次都要**重新 TCP 连接 + TLS 握手**（弱网下 1~3 秒）
        //   ⇒ 而 🍅大灰狼的详情流程要发 3~8 次请求（还有 8 个 host 的失败兜底）
        //   ⇒ 详情页光握手就耗掉十几秒 ❗
        //   ⇒ 共享 session ⇒ 连接复用 ⇒ 后续请求只花 RTT ✅
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = sessionHeaders
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        let session = Self.sharedSession(headers: sessionHeaders, timeout: timeout)

        // ⚠️⚠️ **重试**（2026-10-21 真机定位，照抄栖阅的 HttpTransport）
        //
        //   栖阅（URLSession + 跳证书 + DNS覆写 + 代理 + **重试**）在用户手机上检测
        //   `v5.langge.uk` 是「**网络环境优良 / 延迟低 / 解析时间 0s**」⇒
        //   **那台服务器在用户网络里是通的**！
        //   而轻阅同一个 URL 报「请求超时」⇒ **不是网络问题，是轻阅一次不成就放弃** ❗
        //   （聚合源详情有 8 条线路逐条兜底 ⇒ 一次超时就把详情页拖成一两分钟的转圈）
        //
        //   ⇒ 现在：失败/超时**重试 2 次**（每次超时砍半 ⇒ 总耗时可控），并把每次尝试记进日志 ✅
        var result: [String: Any] = [:]
        let attempts = 3
        for i in 0..<attempts {
            let per = max(3.0, timeout / Double(attempts - i))   // 越重试越短，别把总时长吃光
            var r1 = req
            r1.timeoutInterval = per
            result = await Self.perform(req: r1, session: session)
            let code = result["code"] as? Int ?? 0
            let failed = (result["error"] != nil) || code == 0
            if !failed {
                if i > 0 {
                    NSLog("[request] 重试成功（第 %d 次）%@", i + 1, raw)
                    recentLogs.append("[request] 重试成功（第 \(i + 1) 次）" + raw)
                }
                break
            }
            NSLog("[request] 第 %d 次失败 %@：%@", i + 1, raw, String(describing: result["error"] ?? "无响应"))
            recentLogs.append("[request] 第 \(i + 1) 次失败：" + raw)
            if i < attempts - 1 { usleep(300_000) }   // 0.3s 退避
        }

        // ATS 兜底：明文被系统拦了，就改用 https 再试一次。
        // 有些站 http 挂在 CDN 后面，https 反而是通的。
        if result["atsBlocked"] as? Bool == true,
           u.scheme?.lowercased() == "http",
           var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            if let httpsURL = comps.url {
                var req2 = URLRequest(url: httpsURL)
                req2.httpMethod = method
                req2.httpBody = req.httpBody
                req2.allHTTPHeaderFields = req.allHTTPHeaderFields
                var r2 = await Self.perform(req: req2, session: session)
                if r2["ok"] as? Bool == true {
                    r2["httpsUpgraded"] = true
                    result = r2
                }
            }
        }
        return result
    }

    /// 真发一次请求。抽出来是为了能在 ATS 拦截时**换 https 再试一次**。
    private static func perform(req: URLRequest, session: URLSession) async -> [String: Any] {
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let charset = Self.charset(of: http?.textEncodingName)
            let text = String(data: data, encoding: charset)
                ?? String(data: data, encoding: .utf8)
                ?? ""
            var hs: [String: String] = [:]
            http?.allHeaderFields.forEach { k, v in hs["\(k)"] = "\(v)" }
            return [
                "ok": true,
                "code": http?.statusCode ?? 0,
                "url": http?.url?.absoluteString ?? req.url?.absoluteString ?? "",
                "redirectUrl": http?.url?.absoluteString ?? "",
                "headers": hs,
                "body": text,
                "bytes": data.count,
            ]
        } catch {
            var out: [String: Any] = ["ok": false, "error": error.localizedDescription]
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain,
               ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                // 系统安全策略(ATS)拦了明文 HTTP。
                // 绝大多数情况是装的是旧包（旧包没放开 ATS），给一句人话，
                // 别让用户对着英文报错猜。
                out["atsBlocked"] = true
                out["error"] = "系统安全策略(ATS)拦了明文 HTTP 地址。"
                    + "如果你装的是旧版 App，请到 GitHub 的 ipa-build 分支重新下载安装最新版；"
                    + "如果已经是最新版，说明这个站只支持 http，换一个书源试试。"
            }
            return out
        }
    }

    // MARK: 工具

    static var userAgent: String {
        let v = UIDevice.current.systemVersion
        let m = "iPhone CPU iPhone OS \(v) like Mac OS X"
        return "Mozilla/5.0 (\(m)) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 qireaderlite/1.0"
    }

    private static func charset(of name: String?) -> String.Encoding {
        guard let n = name?.lowercased() else { return .utf8 }
        if n.contains("gb") { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) }
        if n.contains("big5") { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))) }
        if n.contains("euc") { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_JP.rawValue))) }
        return .utf8
    }

    private static func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }
}

// Apple 文档：`@MainActor protocol WKNavigationDelegate : NSObjectProtocol`
// 所以这里**不能**标 nonisolated —— 用 nonisolated 实现 @MainActor 协议要求不满足 conformance。
// 类本身是 @MainActor，方法直接继承隔离，访问 webView / injectEngine 都不需要额外 await。
extension RuleSandbox: WKNavigationDelegate {
    /// 只允许本地引擎页；站方书源里的 JS 想把 WebView 导航到别处，一律拒绝
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let isLocal = url?.isFileURL == true
        decisionHandler(isLocal ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await self.injectEngine() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.lastError = "引擎加载失败: \(error.localizedDescription)"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.lastError = "引擎文件读取失败: \(error.localizedDescription)"
    }
}

// MARK: - 同步原生通道（window.prompt）

/// **同步**通道：JS → 原生 → JS，一个来回当场返回。
///
/// 为什么要它：Legado 的部分 `java.*` 是**同步**语义，站方在同一个表达式里就用了：
///     java.timeFormat(res.register_time*1000).padEnd(20, "\t")
/// `.padEnd` 必须立刻拿到那个**字符串** → 原生桥的 postMessage（异步）做不到
///（postMessage 回来时表达式早算完了）。
///
/// WKWebView 里能同步拿到原生返回值的口子只有一个：**`window.prompt`**。
/// `WKUIDelegate` 的 prompt 回调里**同步**调 completionHandler，
/// JS 侧的 `window.prompt(...)` 就会当场拿到返回值。
///
/// ⚠️ 只有**引擎那个** WebView 挂了本 delegate（内嵌浏览器那个没有），
///    所以不会影响站方网页自己的 prompt。
extension RuleSandbox: WKUIDelegate {
    /// 同步通道的报文前缀（JS 侧必须一模一样）
    static let syncPrefix = "__qrSync__"

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard prompt.hasPrefix(Self.syncPrefix) else {
            // 真实网页的 prompt：轻阅不弹窗，回默认值
            completionHandler(defaultText)
            return
        }
        let payload = String(prompt.dropFirst(Self.syncPrefix.count))
        completionHandler(Self.handleSync(payload))
    }

    /// 处理同步请求：{fn, args} → {ok, value|error}
    static func handleSync(_ payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fn = obj["fn"] as? String else {
            return "{\"ok\":false,\"error\":\"同步请求解析失败\"}"
        }
        let args = obj["args"] as? [String: Any] ?? [:]
        let result = LegadoCompat.handle(fn: fn, args: args)
        guard let out = try? JSONSerialization.data(withJSONObject: result),
              let s = String(data: out, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"同步结果序列化失败\"}"
        }
        return s
    }
}

// MARK: - 辅助

enum HeaderCodec {
    /// 解析书源 header 字符串：`key:value` 换行分隔，或 JSON。
    static func decode(_ s: String) -> [String: String]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.hasPrefix("{") {
            if let d = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] {
                return d.reduce(into: [:]) { acc, kv in
                    if let v = kv.value as? String { acc[kv.key] = v }
                    else if let v = kv.value as? NSNumber { acc[kv.key] = v.stringValue }
                }
            }
        }
        var out: [String: String] = [:]
        for line in t.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = String(l[l.startIndex..<c]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out.isEmpty ? nil : out
    }
}

enum CookieJar {
    static func cookieString(for url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 全量 cookie 快照：**host → "k=v; k2=v2"**
    ///
    /// ⚠️ 为什么需要快照：Legado 的 `cookie.getCookie(url)` 是**同步** API，
    ///    而原生桥只能 postMessage（异步）→ JS 里没法 await 一次同步调用。
    ///    所以原生侧先把 cookie 罐拍成快照塞进 payload，引擎侧同步读。
    static func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for c in HTTPCookieStorage.shared.cookies ?? [] {
            var host = c.domain
            if host.hasPrefix(".") { host.removeFirst() }
            guard !host.isEmpty else { continue }
            let pair = "\(c.name)=\(c.value)"
            if let prev = out[host], !prev.isEmpty {
                out[host] = prev + "; " + pair
            } else {
                out[host] = pair
            }
        }
        // ⚠️⚠️ **番茄 sessionid 别名**（2026-10-21 真机「番茄登了还是说过期」）：
        //   番茄新版登录的 cookie 键是 `sessionid_ss`，
        //   而站方（🍅大灰狼）有一行老正则 `rawCookie.match(/sessionid=[^;]+/)` **只认 `sessionid=`**
        //   ⇒ 站方抠不到 sessionid ⇒ 发现页一直 toast「您还未登陆番茄账号」
        //   ⇒ `ssionid` 参数空 ⇒ 大灰狼服务器回「番茄登录过期」
        //   ⇒ 这里补一条 `sessionid=<同值>` 别名（不覆盖已有的）⇒ 站方立刻能用 ✅
        //   （逻辑在 LegadoCompat（纯 Foundation）→ 沙盒 swiftc 能真编真跑）
        // ⚠️⚠️ **不能一边遍历一边改字典** ⇒ Swift 会崩
        //   （Fatal error: Collection was mutated while being enumerated）
        //   ⇒ 先收集要改的，再统一改
        var updates: [String: String] = [:]
        for (host, value) in out {
            if LegadoCompat.isFanqieHost(host) {
                let fixed = LegadoCompat.fanqieSessionAlias(value)
                if fixed != value { updates[host] = fixed }
            }
        }
        for (host, value) in updates { out[host] = value }
        return out
    }
    static func set(_ cookie: String, for url: String) {
        guard let u = URL(string: url) else { return }
        // 新 SDK 的 setCookies 多了第三个参数 mainDocumentURL，不给编译不过
        HTTPCookieStorage.shared.setCookies(cookies(from: cookie, host: u.host ?? ""),
                                            for: u, mainDocumentURL: nil)
    }

    /// 删某个站点下的 cookie（站方的「退出登录」用）
    ///
    /// ⚠️ `HTTPCookieStorage.shared.setCookies([])` **不一定**会清掉已有的
    ///    （实测不可靠）→ 这里显式遍历 deleteCookie。
    ///    域匹配：cookie.domain 是 "v5.langge.uk" 或 ".langge.uk"，
    ///    要把 **父域** 的 cookie 也删掉（站方 logout 会逐个清 host + langge.uk）。
    static func remove(for url: String) {
        guard let u = URL(string: url) else { return }
        let host = (u.host ?? "").lowercased()
        guard !host.isEmpty else { return }
        for c in HTTPCookieStorage.shared.cookies ?? [] {
            var d = c.domain.lowercased()
            if d.hasPrefix(".") { d.removeFirst() }
            if d.isEmpty { continue }
            if d == host || host.hasSuffix("." + d) || d.hasSuffix("." + host) {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
    }
    static func cookies(from header: String, host: String) -> [HTTPCookie] {
        var out: [HTTPCookie] = []
        for part in header.components(separatedBy: ";;") {
            let p = part.trimmingCharacters(in: .whitespaces)
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let c = HTTPCookie(properties: [
                .name: kv[0], .value: kv[1], .domain: host, .path: "/",
            ]) else { continue }
            out.append(c)
        }
        return out
    }
}

enum CacheFiles {
    private static let root = AppPaths.cacheDir

    /// Legado 的 `java.cacheFile(path, content)`，路径是书源自定的 key，不是真实路径
    static func write(_ path: String, _ text: String) -> Bool {
        let safe = safeName(path)
        guard let d = text.data(using: .utf8) else { return false }
        let p = root.appendingPathComponent(safe)
        do { try d.write(to: p, options: .atomic); return true } catch { return false }
    }
    static func read(_ path: String) -> String? {
        let p = root.appendingPathComponent(safeName(path))
        return try? String(contentsOf: p, encoding: .utf8)
    }
    private static func safeName(_ s: String) -> String {
        let h = abs(s.hashValue)
        return "cf_\(h).cache"
    }
}

enum SandboxFS {
    /// 允许 Documents 下的任意路径，挡掉目录穿越
    static func sanitize(_ p: String) -> URL? {
        let base = AppPaths.documents.standardizedFileURL
        let u = URL(fileURLWithPath: p).standardizedFileURL
        let path = u.path
        guard path.hasPrefix(base.path + "/") || path == base.path else { return nil }
        return u
    }
}

@MainActor
/// 同步通道（window.prompt）开关的 UserDefaults key
///
/// ⚠️ 放**顶层**、不放 @MainActor 类里 —— @AppStorage 的初始化不在 MainActor 上，
///    放类里会出 actor 隔离告警。
enum EngineSyncChannel {
    static let key = "engine.syncChannelEnabled"
}

enum Toast {
    static func show(_ text: String) {
        let lbl = UILabel()
        lbl.text = text
        lbl.font = .systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = .white
        lbl.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        lbl.textAlignment = .center
        lbl.numberOfLines = 0
        lbl.alpha = 0
        lbl.layer.cornerRadius = 12
        lbl.layer.masksToBounds = true
        lbl.translatesAutoresizingMaskIntoConstraints = false
        let host = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow ?? UIWindow()
        host.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            lbl.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            lbl.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        UIView.animate(withDuration: 0.2) { lbl.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            UIView.animate(withDuration: 0.3, animations: { lbl.alpha = 0 }) { _ in lbl.removeFromSuperview() }
        }
    }
}
