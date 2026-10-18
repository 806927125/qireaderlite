import Foundation
import WebKit
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
        "jsonpath.js",       // JSONPath
        "org-jsoup.js",      // org.jsoup.* 兼容
        "sha1.js",           // 哈希
        "java-api.js",       // java.*
        "packages-native.js", // Packages.* 的原生函数实现（必须排在 packages_stub.js 前）
        "packages_stub.js",   // Packages / JavaImporter / importPackage 兼容层
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

    private var webView: WKWebView!
    private var bootWaiters: [CheckedContinuation<Void, Never>] = []
    private var jsRequests: [Int: CheckedContinuation<Any?, Never>] = [:]
    private var jsSeq = 0
    /// 当前这次调用所属的书源，决定 header / jsLib / Cookie 策略
    var currentSource: BookSource?

    private override init() { super.init() }

    // MARK: 启动

    /// 引擎版本。改引擎时同步改这个，用户一眼能看出装的是新包还是旧包。
    static let engineVersion = "2026.10.18-r11（UI：卡片接系统液态玻璃）"

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
        lines.append("App 版本：\(AppPaths.appVersion)")
        // ATS 有没有放开：装旧包的话这里是 false，
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
        webView = wv

        wv.loadHTMLString(page.html, baseURL: page.dir)
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
        bootLog.append("注入完成，__qrInvoke 可用")
        markReady()
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
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
    func invoke(_ op: String, _ payload: [String: Any] = [:], source: BookSource? = nil) async throws -> Any {
        boot()
        await waitReady()
        let prev = currentSource
        if let s = source { currentSource = s }
        defer { currentSource = prev }

        let argJSON = Self.jsonString(payload)
        // 引擎那边 __qrInvoke 返回 Promise；callAsyncJavaScript 会自动 await 并把结果送回来
        let script = "return window.__qrInvoke(\(Self.jsonString(op)), \(argJSON));"
        do {
            let r = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            return r ?? NSNull()
        } catch {
            throw SandboxError(message: "引擎调用 \(op) 失败: \(error.localizedDescription)")
        }
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
            NSLog("[engine] %@", m)
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

        case "showBrowser":
            // MVP 不实现交互式浏览器，明确回绝而不是假装成功
            return err("当前版本未实现交互式浏览器")

        default:
            return err("原生侧没有实现 fn=\(fn)")
        }
    }

    // MARK: HTTP

    private func nativeRequest(_ args: [String: Any]) async -> [String: Any] {
        // ⚠️ 别写 URLRequest(url: URL(string: "")!) —— Apple 平台上 URL(string: "") 返回 nil，
        // 强解包会**每次发请求都崩**。Kotlin 的 URL("") 是合法空 URL，Swift 不是。
        guard let raw = args["url"] as? String,
              let u = URL(string: raw), u.scheme != nil else {
            return ["ok": false, "error": "URL 非法: \(args["url"] as? String ?? "nil")"]
        }
        var req = URLRequest(url: u)

        // 站方书源的 header 里有 UA / Referer / Cookie，很多站不加就 403
        var header: [String: String] = [:]
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

        let method = (args["method"] as? String ?? "GET").uppercased()
        req.httpMethod = method
        if let body = args["body"] as? String, !body.isEmpty {
            req.httpBody = body.data(using: .utf8)
        } else if let b64 = args["bodyBase64"] as? String, let d = Data(base64Encoded: b64) {
            req.httpBody = d
        }

        let timeout = min(max(args["timeout"] as? Double ?? 20, 3), 90)

        // httpAdditionalHeaders 是**可选**属性，不能直接下标赋值
        // （`cfg.httpAdditionalHeaders["X"] = v` 编译不过），得先把字典拼好再赋
        var sessionHeaders = header
        sessionHeaders["User-Agent"] = req.value(forHTTPHeaderField: "User-Agent") ?? ua

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = sessionHeaders
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        let session = URLSession(configuration: cfg)

        var result = await Self.perform(req: req, session: session)

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
    static func set(_ cookie: String, for url: String) {
        guard let u = URL(string: url) else { return }
        // 新 SDK 的 setCookies 多了第三个参数 mainDocumentURL，不给编译不过
        HTTPCookieStorage.shared.setCookies(cookies(from: cookie, host: u.host ?? ""),
                                            for: u, mainDocumentURL: nil)
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
