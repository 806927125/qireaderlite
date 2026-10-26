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

    /// ⭐⭐⭐⭐⭐ **启动就把内存档案的落盘位置交出去**（build263）
    ///
    /// ⚠️ jetsam 杀进程 ⇒ 内存里的峰值/采样**一起没了** ⇒ 崩了再看面板啥也看不到
    ///   ⇒ 所以采样必须**落盘** ⇒ 这里注入位置（App 起来就有）⇒ 面板立刻能回看上次会话 ⭐⭐⭐
    override init() {
        super.init()
        MemoryMeter.configure(storeURL: AppPaths.memMeterFile)
    }

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
        let beforeMB = MemoryMeter.currentMB
        LegadoEngineBackend.shared.dropAllSessions()
        let after = MemoryMeter.sample()
        appendLog("[宿主] 引擎已重置（新引擎会话已清空 · 内存 \(beforeMB) → \(after / (1024 * 1024)) MB）")
    }

    /// 给界面用的一行状态

    func diagnose() -> String {
        var lines: [String] = []
        lines.append("引擎版本：\(Self.engineVersion)")
        lines.append("App 版本：\(AppPaths.appVersionLine)")
        // ⭐⭐⭐⭐⭐ **写盘量**（2026-10-26 iOS「diskwrites」限额被杀 ⇒ 加自检）
        //   ⇒ iOS 限额 ≈ 12.43 KB/s × 24h ≈ **1.07 GB/天**
        //   ⇒ 自己卡在 2 MB/小时 ⇒ 超了就停落盘 ⇒ **再也不会被系统杀** ⭐⭐⭐
        //   ⇒ 这一行让「谁在写盘」一眼可见（不用再猜）⭐⭐⭐
        lines.append("本小时写盘：\(DiskWriteMeter.currentHourText)（限额 2.00 MB/小时 · iOS 约 1.07 GB/天）")
        // ⭐⭐⭐⭐⭐ **内存水位**（2026-10-26 jetsam 6.8GB 实证 ⇒ 之前面板没有这一项）
        //   ⇒ jetsam 记录：`QingYue` 单进程 425984 页 ×16KB = **6.8GB** ⇒ 被系统内存杀
        //   ⇒ 现象 =「闪退」+ **没有 .ips 崩溃日志** ⇒ 之前完全看不见内存水位 ⭐⭐⭐
        //   ⇒ 这一行 + 超限自动清（清引擎会话 = 重建 JS context）⇒ **抢在系统杀之前自救** ⭐⭐⭐
        _ = MemoryMeter.sample()
        lines.append(MemoryMeter.panelLine)
        // ⭐⭐⭐⭐⭐ **引擎会话数**（2026-10-26 jetsam 6.8GB 实证）
        //   ⇒ 一个源 = 一个会话 = 一个 JSC context ⇒ 以前**只增不减** ⇒ 内存随源数涨
        //   ⇒ 现在封顶（≤4）⇒ 这一行能一眼看出「会话有没有在涨」⭐⭐⭐
        lines.append("引擎会话：\(LegadoEngineBackend.shared.liveSessionCount) 个"
                     + "（上限 \(LegadoEngineBackend.maxLiveSessions) · 超了就淘汰最久未用的）")
        // ⭐⭐⭐⭐⭐ **上次会话的档案**（build263）
        //   ⇒ jetsam 杀进程 ⇒ **内存里的峰值/日志一起没了** ⇒ 崩了再看面板啥也看不到
        //   ⇒ 所以峰值 + 采样（带 op 名）**落盘** ⇒ 这一行能回看「被杀前涨到多少、最后一个 op 是啥」⭐⭐⭐
        lines.append(MemoryMeter.lastSessionText)
        let timeline = MemoryMeter.timelineText(6)
        if !timeline.isEmpty {
            lines.append("—— 内存采样（上次会话）——")
            lines.append(timeline)
        }
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


    /// ⭐⭐⭐⭐⭐ **加一行日志**（2026-10-26 iOS「diskwrites」限额被杀 ⇒ 重构）
    ///
    /// ⚠️⚠️⚠️ **原实现是真凶**（崩溃日志的 heaviest stack 实证）：
    ///   ① \`Task { @MainActor in appendLog(...) }\` ⇒ **每条日志一次 Task 调度**
    ///      ⇒ 栈顶正是 \`libswift_Concurrency\` ⭐⭐⭐
    ///   ② 落盘**在主线程发起** ⇒ **每条日志一次 IO 往返** ⭐⭐⭐
    ///   ⇒ 引擎诊断每条规则都来一行 ⇒ 一次 op 几十行 ⇒ 几千行就淹没主线程
    ///   ⇒ iOS 的 \`diskwrites\` 限额（12.43 KB/s × 24h ≈ 1.07 GB）被吃光 ⇒ **iOS 杀进程**
    ///   ⇒ 用户看到的现象是「闪退」⭐⭐⭐⭐⭐
    ///
    /// ⭐⭐⭐ **新实现（两路分开）**：
    ///   · **内存日志**（UI 面板要显示）⇒ 主线程 ⇒ 但**只在必要时**切 ⭐⭐⭐
    ///   · **磁盘日志**（崩溃前证据）⇒ **直接后台** ⇒ **完全不占主线程** ⭐⭐⭐
    /// ⭐⭐⭐⭐⭐ **单行日志的最大长度**（2KB）
    ///
    /// ⚠️⚠️⚠️ **为什么必须截断**（2026-10-26 iOS「diskwrites」限额被杀）：
    ///   站方可以调 \`java.log(任意内容)\` ⇒ **一行日志可能是几十 KB**
    ///   （整个响应 / 整本书 / base64 载荷）⭐⭐⭐
    ///   ⇒ 一次 op 打一行 50KB ⇒ **几十次就 1MB** ⇒ **几百次就 1GB** ⇒ iOS 杀进程 ⭐⭐⭐
    ///   ⇒ 截到 2KB ⇒ 就算站方疯狂打日志 ⇒ 写盘量也可控 ⭐⭐⭐
    private static let maxLineLength = 2_048

    func appendLog(_ line: String) {
        // ⭐⭐⭐ **先截断**（站方 `java.log` 可以打任意长 ⇒ 不截断 = 写盘炸弹）⭐⭐⭐
        let clipped = line.count > Self.maxLineLength
            ? String(line.prefix(Self.maxLineLength)) + "…（已截断，原长 \(line.count) 字）"
            : line
        let stamped = "[\(Self.logTimeFormatter.string(from: Date()))] "
            + "[\(Self.stepFor(clipped, fallback: currentStep))] " + clipped
        NSLog("%@", stamped)
        // ⭐⭐⭐ **落盘：直接进后台队列**（内部 \`diskQueue.async\` ⇒ 不占主线程）
        Self.persistToDisk(stamped)
        // ⭐⭐⭐ **内存日志：必须主线程**（\`recentLogs\` 是 \`@Published\`）
        //   ⇒ **已经在主线程就别再开 Task**（原来每次都开 ⇒ 白白一次调度）⭐⭐⭐
        if Thread.isMainThread {
            Self.applyMemoryLog(stamped)
        } else {
            Task { @MainActor in Self.applyMemoryLog(stamped) }
        }
    }

    /// ⭐⭐⭐ **写进内存日志**（主线程）
    private static func applyMemoryLog(_ stamped: String) {
        shared.recentLogs.append(stamped)
        if shared.recentLogs.count > 300 {
            shared.recentLogs.removeFirst(shared.recentLogs.count - 300)
        }
    }

    /// **日志落盘**（进程被杀也不丢）
    private static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("engine-log.txt")
    }()

    private nonisolated(unsafe) static let diskLogLock = NSLock()
    /// ⭐⭐⭐⭐⭐ **待落盘的缓冲**（批量写 ⇒ 不再每行一次 IO）
    ///
    /// ⚠️⚠️⚠️ **为什么标 `nonisolated(unsafe)`**（2026-10-26 类型检查门禁撞到）：
    ///   `RuleSandbox` 整体是 `@MainActor` ⇒ 它的 static 默认带**主 actor 隔离**
    ///   ⇒ 而这个缓冲**故意**在 `diskQueue.async`（后台队列）里读写
    ///   ⇒ Swift 6 的编译器会判「主 actor 隔离的量被 Sendable 闭包碰了」⇒ **报 error**
    ///   ⇒ 但它**本来就由 `diskLogLock` 保护**（锁 ⇒ 跨线程安全）⇒ 与主 actor 无关 ⭐⭐⭐
    ///   ⇒ ⇒ 标 `nonisolated(unsafe)`：**语义对**（锁才是保护者）+ **Swift 6 也能编** ⭐⭐⭐
    ///   ⇒ ⚠️ 只能标在**有锁保护**的量上 ⇒ 没锁的量不许这样标 ⭐⭐⭐
    private nonisolated(unsafe) static var diskBuffer: [String] = []
    /// ⭐⭐⭐ **落盘队列**（后台 ⇒ 不占主线程）
    private nonisolated(unsafe) static let diskQueue = DispatchQueue(label: "qr.disklog", qos: .utility)

    /// ⭐⭐⭐⭐⭐ **日志文件上限**（256KB ⇒ 足够读完一次崩溃现场）
    ///
    /// ⚠️ 以前是 1MB + **每次轮转都 `.atomic` 重写 600KB**
    ///   ⇒ 一次轮转 = 读 1MB + 写 600KB(临时) + rename ⇒ **写盘量放大好几倍** ⭐⭐⭐
    private nonisolated(unsafe) static let diskLogLimit = 256 * 1024

    /// ⭐⭐⭐⭐⭐ **批量落盘**
    ///
    /// ⭐⭐⭐ **三个修法一起**（2026-10-26 iOS「diskwrites」限额被杀）：
    ///   ① **批量**：攒够 32 行或 2 秒才写一次 ⇒ IO 次数降一个数量级 ⭐⭐⭐
    ///   ② **不用 `.atomic`**：`.atomic` = 写临时文件 + rename ⇒ **双倍写盘**
    ///      ⇒ 改用 FileHandle 追加（真 append）⭐⭐⭐
    ///   ③ **计量 + 限流**：`DiskWriteMeter` 记字节数 ⇒ 超上限就**停止落盘**
    ///      ⇒ 内存日志还在（不丢证据）⇒ 但不再被系统杀 ⭐⭐⭐
    private static func persistToDisk(_ line: String) {
        diskQueue.async {
            diskLogLock.lock()
            diskBuffer.append(line)
            let count = diskBuffer.count
            diskLogLock.unlock()
            if count >= 32 { flushDiskLog() }
            else if count == 1 {
                // ⭐ 首次进缓冲 ⇒ 排一个 2 秒后的兜底 flush（保证最后几行也落盘）
                diskQueue.asyncAfter(deadline: .now() + 2) { flushDiskLog() }
            }
        }
    }

    /// ⭐⭐⭐⭐⭐ **每小时最多落盘多少行**（防止再被刷爆）
    ///
    /// ⚠️ iOS 的 \`diskwrites\` 限额 ≈ 1.07 GB / 24h ⇒ 引擎诊断一多就吃光 ⭐⭐⭐
    /// ⇒ 我们自己卡在 **2000 行 / 小时**（≈ 每行 100 字节 ⇒ 200KB/小时
    ///   ⇒ 一天最多 4.8 MB ⇒ **远低于限额**）⭐⭐⭐
    /// ⇒ 超了之后**内存日志照常**（面板还能看）⇒ 只是不再落盘 ⭐⭐⭐
    private static let diskLinesPerHour = 2000
    /// ⭐⭐ 同上：写盘限流计数由 `diskLogLock` 保护 ⇒ 不该带主 actor 隔离
    private nonisolated(unsafe) static var diskLinesThisHour = 0
    private nonisolated(unsafe) static var diskHourStart = Date()

    /// ⭐⭐⭐ **把缓冲刷到磁盘**（后台队列内调用）
    /// ⭐⭐⭐⭐⭐ **把缓冲刷到磁盘**（锁保护的量 ⇒ 与主 actor 无关 ⇒ 标 `nonisolated`）
    ///
    /// ⚠️ 同上：它在**后台队列**里被调 ⇒ 不能带 `@MainActor` 隔离
    ///   ⇒ 数据由 `diskLogLock` 保护 ⇒ 语义上安全 ⭐⭐⭐
    private nonisolated static func flushDiskLog() {
        diskLogLock.lock()
        let lines = diskBuffer
        diskBuffer.removeAll()
        diskLogLock.unlock()
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }

        // ⭐⭐⭐⭐⭐ **行数限流**：超上限 ⇒ 停止落盘（内存日志还在）
        let now = Date()
        diskLogLock.lock()
        if now.timeIntervalSince(diskHourStart) > 3600 {
            diskHourStart = now
            diskLinesThisHour = 0
        }
        diskLinesThisHour += lines.count
        let overLines = diskLinesThisHour > diskLinesPerHour
        diskLogLock.unlock()
        if overLines { return }

        // ⭐⭐⭐ **计量 + 限流**：超上限 ⇒ **停止落盘**（内存日志还在）
        guard DiskWriteMeter.record(data.count) else { return }

        let url = logFileURL
        // ⭐⭐⭐ **轮转：超上限 ⇒ 只留尾部**（**不用 `.atomic`** ⇒ 不产生额外副本）
        var existing = Data()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size + data.count > diskLogLimit {
            if let d = try? Data(contentsOf: url) { existing = Data(d.suffix(diskLogLimit / 2)) }
        }
        do {
            let fh = try FileHandle(forWritingTo: url)
            if !existing.isEmpty {
                // ⭐⭐⭐ **截断 + 写尾部 + 追加新内容**（一次 truncate ⇒ 不留旧数据）
                try fh.truncate(atOffset: 0)
                try fh.write(contentsOf: existing)
            } else {
                try fh.seekToEndOfFile()
            }
            try fh.write(contentsOf: data)
            try fh.close()
        } catch {
            // ⭐⭐⭐ 首次写（文件还不存在）⇒ 建一个
            try? data.write(to: url)
            DiskWriteMeter.record(data.count)
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

