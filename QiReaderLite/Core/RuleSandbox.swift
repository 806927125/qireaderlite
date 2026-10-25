import Foundation
import SwiftUI
import UIKit
// ⭐⭐⭐ 引擎的**真实 revision**（CI 用 -DLEGADO_REVISION=<sha> 注入 ⇒ 显示的永远是真在跑的）
import LegadoCore

// MARK: - ⭐⭐⭐ 引擎日志与宿主工具（老 JS 引擎已于 2026-10-25 **物理删除**）

/// ⭐⭐⭐⭐⭐ **引擎日志 + 宿主工具**（老 WKWebView 引擎已退役并**物理删除**）
///
/// ⚠️⚠️ **这个文件原来是什么**：
///   它是**老 JS 引擎（WKWebView）**的宿主壳（1559 行）⇒ 里面塞着 `engine.html`
///   + 11 个 JS 文件 + `window.prompt` 同步通道 + `__qrInvoke` 消息桥。
///   ⇒ 2026-10-25：老引擎退役 ⇒ **7 条调用路径切到新引擎** ⇒ **壳可以删了** ⭐⭐⭐
///
/// ⭐ **保留下来的是**（新引擎也要用）：
/// · `appendLog` / `fullLogText` / `diskLogText` / `clearLogs` ⇒ 引擎日志面板 + 崩溃前证据 ⭐⭐⭐
/// · `openExternal` ⇒ 站方 `java.startBrowser`（要碰 `UIApplication` ⇒ 只能住这个文件）⭐⭐⭐
/// · `cacheDeviceID` / `cachedDeviceID` ⇒ 设备 ID（`LegadoEngineBackend` **不能 import UIKit**）⭐⭐⭐
/// · `diagnose` / `probePlainHTTP` ⇒ 自检面板 ⭐
/// · `Toast` ⇒ 站方 `java.toast` / `longToast`（**必须切主线程**）⭐⭐⭐
///
/// ⚠️ **「阅读器」的 WKWebView 不是老引擎**（`ReaderWebView` / `BrowserSheet`）⇒ 别误删 ⭐⭐⭐
@MainActor
final class RuleSandbox: NSObject, ObservableObject {
    static let shared = RuleSandbox()

    /// ⭐⭐⭐ **用系统浏览器打开**（站方 `java.startBrowser` / `startBrowserAwait` / `showBrowser` …）
    ///
    /// ⚠️ **为什么放这里**：要碰 `UIApplication` ⇒ 只能住在 import 了 UIKit 的文件
    /// ⇒ 而 `LegadoEngineBackend` **不能 import UIKit**（沙盒 swift 门禁在 Linux 上编译 ⇒ 编不过）⭐⭐⭐
    /// ⇒ 分工：**能弹浏览器的逻辑住这里**，别的层只调它 ⭐
    ///
    /// ⚠️ **不等待用户关掉**（老引擎是「同步等」⇒ 靠两遍跑拿 cookie）
    /// ⇒ 新引擎没有两遍跑 ⇒ 先做到「能打开、不抛异常」⭐⭐⭐
    func openExternal(url: String, title: String) {
        guard let u = URL(string: url), u.scheme != nil else {
            appendLog("[宿主] 浏览器 URL 非法：\(url)")
            return
        }
        appendLog("[宿主] 打开浏览器：\(u.absoluteString) \(title)")
        UIApplication.shared.open(u)
    }

    /// ⭐⭐⭐ **把真设备 ID 写进 `UserDefaults`**（给**不能 import UIKit 的层**用）
    /// ⚠️ `LegadoEngineBackend` 在沙盒的 swift 门禁里**在 Linux 上编译** ⇒ **不许 import UIKit** ⭐⭐⭐
    /// ⇒ 凡是要 UIKit 的东西**留在本文件**，别的层通过 `UserDefaults` 拿 ⇒ 纯 Foundation ⇒ 两边都能编 ⭐
    static func cacheDeviceID() {
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "qiReaderLite"
        UserDefaults.standard.set(id, forKey: "qr.deviceID")
    }

    /// ⭐⭐⭐ **设备 ID（同步可取）** —— 给**不需要 UIKit 的层**用
    /// ⚠️ `LegadoEngineBackend` 里**不能 import UIKit**（沙盒的 swift 门禁在 Linux 上编译 ⇒ 编不过）⭐⭐⭐
    /// ⇒ 凡是要 UIKit 的东西，**留在本文件里**，别的文件只读这里 ⭐
    static let cachedDeviceID: String = UIDevice.current.identifierForVendor?.uuidString ?? "qiReaderLite"

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

    static let engineVersion = LegadoEngineInfo.version(revision: RuleSandbox.engineRevision)

    /// ⭐⭐⭐⭐⭐ **引擎的真实 revision**（**构建时生成的文件** ⇒ 绝不用手写的假值）
    ///
    /// ⚠️⚠️ **2026-10-25 真机教训**：之前这里是**手写**的 ⇒ build253 实际跑 `8d206b5`，
    ///   界面却显示 `c28de9b`（老值）⇒ **假证据** ⇒ 把排查带偏了 ⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么不能用 `-D` 宏**（实测踩过）：
    ///   Swift 的条件编译标志是**「有/无」**，**不带值**
    ///   （`-DLEGADO_REVISION=xxx` ⇒ 编译告警 `flags do not have values in Swift`）⭐⭐⭐
    ///   ⇒ 就算传进去也读不到值 ⇒ `#if` 分支里拿不到 revision ⭐⭐⭐
    ///   ⇒ 而且 `LegadoCore` 是 **SPM 依赖 target** ⇒ App target 的 `OTHER_SWIFT_FLAGS`
    ///   **根本传不进它**（实测：只出现在 App target 的 SwiftCompile 命令行里）⭐⭐⭐
    ///
    /// ⇒ 正解：**CI 生成一个 Swift 文件**（`EngineRevision.generated.swift`）
    ///   ⇒ 里面写 `static let generated = "89de55f67e3d"` ⇒ 编译进去 ⇒ **真值** ⭐⭐⭐
    ///   ⇒ 拿不到 ⇒ `"unknown"` ⇒ **明说不知道**（绝不含糊其辞）⭐⭐⭐
    static let engineRevision: String = EngineRevision.generated

    /// ⭐ **给界面用的一行状态**
    var statusText: String {
        if ready { return "引擎就绪" }
        if let e = lastError { return "引擎未就绪：\(e)" }
        return "引擎就绪"
    }

    /// ⭐⭐⭐ **User-Agent**（站方有的站会校验 UA ⇒ 不带会被拒）
    static var userAgent: String {
        let v = UIDevice.current.systemVersion
        let m = "iPhone CPU iPhone OS \(v) like Mac OS X"
        return "Mozilla/5.0 (\(m)) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 qireaderlite/1.0"
    }

    /// ⭐⭐⭐⭐⭐ **启动**（老引擎退役后**不再建 WKWebView** ⇒ 只准备日志与设备 ID）
    ///
    /// ⚠️ 之前这里会：找 `engine.html` + 注入 11 个 JS 脚本 + 起 WKWebView
    ///   ⇒ 那就是**老引擎** ⇒ 现在**没有了** ⇒ App 只有一个引擎（新引擎）⭐⭐⭐
    func boot() {
        Self.cacheDeviceID()
        ready = true
        lastError = nil
        bootLog.removeAll()
        bootLog.append("引擎：legado-engine（自研 Swift 引擎）· 老 JS 引擎已退役并物理删除")
        appendLog("[宿主] 引擎就绪（自研 Swift 引擎）")
    }

    /// ⭐⭐⭐⭐⭐ **重置引擎**（清掉新引擎的会话缓存 ⇒ 切书源/改 jsLib 后重来）
    ///
    /// ⚠️ 之前是「重建 WKWebView」⇒ 现在是「清新引擎的会话」⇒ 语义对等 ⭐⭐⭐
    func resetEngine() {
        LegadoEngineBackend.shared.dropAllSessions()
        appendLog("[宿主] 引擎已重置（新引擎会话已清空）")
    }

    /// 给界面用的一行状态

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
        // ⭐⭐⭐⭐⭐ **老引擎的「引擎文件清单」这段退休了**（2026-10-26 物理删除老引擎）
        //   ⇒ 以前这里报「11 个引擎 JS 全部就位 / engine.html 找到没找到」
        //   ⇒ 那 12 个 JS **已物理删除** ⇒ 报「全部就位」是**假的** ⇒ 整段删掉 ⭐⭐⭐
        //   ⇒ 引擎健康度改看**新引擎**（引擎 revision + 自检）⭐⭐⭐
        lines.append("引擎：Swift 新引擎（老 JS 引擎已退役）")
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


    func appendLog(_ line: String) {
        let stamped = "[\(Self.logTimeFormatter.string(from: Date()))] "
            + "[\(Self.stepFor(line, fallback: currentStep))] " + line
        recentLogs.append(stamped)
        if recentLogs.count > 300 { recentLogs.removeFirst(recentLogs.count - 300) }
        NSLog("%@", stamped)
        // ⭐⭐⭐ **同时落盘**（2026-10-24 真机：App 被 watchdog 杀掉 ⇒ 内存里的日志全丢
        //   ⇒ 用户重启后什么都看不到 ⇒ 我拿不到任何证据 ⇒ 只能猜）
        //   ⇒ 现在每行都写进 Documents/engine-log.txt（超过 1MB 就从头轮转）
        //   ⇒ 崩溃后重启 ⇒ 「引擎日志」面板里照样能复制到**崩溃前**的日志 ⭐⭐⭐
        Self.persistToDisk(stamped)
    }

    /// **日志落盘**（进程被杀也不丢）
    private static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("engine-log.txt")
    }()

    private static let diskLogLock = NSLock()

    private static func persistToDisk(_ line: String) {
        diskLogLock.lock(); defer { diskLogLock.unlock() }
        let url = logFileURL
        // 超过 1MB ⇒ 只留后半段（免得无限涨）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            if let data = try? Data(contentsOf: url) {
                let keep = data.suffix(600_000)
                try? keep.write(to: url, options: .atomic)
            }
        }
        if let data = (line + "\n").data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// **磁盘上的日志全文**（崩溃后也能拿）
    static func diskLogText() -> String {
        diskLogLock.lock(); defer { diskLogLock.unlock() }
        guard let d = try? Data(contentsOf: logFileURL),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
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


}

enum Toast {
    // ⭐⭐⭐⭐⭐ **必须切主线程**（2026-10-25 真机闪退实证）
    //
    // **事故**：build248 加了 `java.longToast` 的宿主实现 ⇒ 站方第一次真的调到宿主
    // ⇒ 引擎在**后台线程**跑 ⇒ `Toast.show` 在后台线程建 `UILabel` / 碰 `UIApplication`
    // ⇒ **UIKit 主线程违规 ⇒ 闪退**（点「发现」就退）⭐⭐⭐
    //
    // ⚠️ **为什么以前没事**：`java.toast` 走引擎自己那条路（不落宿主）⇒ 这个函数一直没人从后台调
    // ⇒ 一旦新增走宿主的 API（如 longToast）⇒ **立刻踩雷** ⇒ 所以要**根治**，不是在这一个调用点打补丁 ⭐
    //
    // ⇒ 修法：① 渲染部分标 `@MainActor`（**编译器从此强制所有调用点处理隔离**）
    //        ② 入口自己切主线程（谁调都安全）
    static func show(_ text: String) {
        // ⭐ 永远切主线程（哪怕已经在主线程也无妨 ⇒ 少一帧无所谓 ⇒ 绝不多一个崩溃点）
        DispatchQueue.main.async { MainActor.assumeIsolated { render(text) } }
    }

    /// ⭐ **UIKit 渲染**（只能在主线程）
    @MainActor
    private static func render(_ text: String) {
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

