import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ **引擎日志 / 宿主诊断层**（2026-11-19 · 从老 `RuleSandbox` 抽出）
///
/// **为什么单独一个文件**：
/// · 老 `RuleSandbox` 是 **WKWebView 引擎壳**（`Resources/engine/*.js` 的宿主）
///   ⇒ 2026-11-19 老引擎（WebView JS 引擎 + 自研 Swift 引擎）**全部退役** ⇒ 壳子删掉
/// · 但 App 还要用它的**日志 / 诊断 / 浏览器 / 设备 ID** ⇒ 这几样搬到这里 ⭐⭐⭐
/// · 本文件**可以 import UIKit**（App 的 UI 层用）；引擎接线层**不许** import UIKit ⭐⭐⭐
///
/// ⚠️ `LegadoEngineBackend`（新引擎接线）在沙盒的 swift 门禁里**在 Linux 上编译**
///   ⇒ **不许 import UIKit** ⇒ 凡是要 UIKit 的东西**留在本文件**，别的层通过
///   `UserDefaults` / 本文件的静态方法拿 ⇒ 纯 Foundation ⇒ 两边都能编 ⭐⭐⭐
@MainActor
final class EngineLog: NSObject, ObservableObject {
    static let shared = EngineLog()

    // MARK: - 日志

    /// 最近 300 条引擎日志 —— 站方 JS 的报错以前只进 NSLog，用户**根本看不见**，
    /// 排查只能靠猜。自检面板里能看到。
    @Published private(set) var recentLogs: [String] = []

    /// 往引擎日志里追加一条（宿主侧用，比如自动选线的结果）
    ///
    /// ⭐ **格式：`[时间戳] [步骤] 内容`**（对齐栖阅的诊断体系）
    func appendLog(_ line: String) {
        let stamped = "[\(Self.logTimeFormatter.string(from: Date()))] "
            + "[\(Self.stepFor(line, fallback: currentStep))] " + line
        recentLogs.append(stamped)
        if recentLogs.count > 300 { recentLogs.removeFirst(recentLogs.count - 300) }
        NSLog("%@", stamped)
        // ⭐⭐⭐ **同时落盘**（App 被 watchdog 杀掉 ⇒ 内存里的日志全丢 ⇒ 拿不到任何证据）
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
    private var currentStep: String = ""

    /// op 名 → 步骤名（面板上分组的依据）
    static func stepNameForOp(_ op: String) -> String {
        EngineLogTimeline.stepNameForOp(op)
    }

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
        return fallback.isEmpty ? "引擎" : fallback
    }

    // MARK: - 状态与诊断

    /// 状态行（面板用）
    var statusText: String {
        EngineBackend.lastError.map { "引擎异常：\($0)" } ?? "引擎就绪"
    }

    /// 引擎自检：把缺什么、卡在哪一步一次列清
    func diagnose() -> String {
        var lines: [String] = []
        lines.append("引擎：LegadoEngine（Legado 3.0 语义）")
        lines.append("App 版本：\(AppPaths.appVersionLine)")
        if !recentLogs.isEmpty {
            lines.append("—— 最近引擎日志 ——")
            lines.append(contentsOf: recentLogs.suffix(12))
        }
        // ATS 有没有放开：装旧包的话这里是 false，
        // 症状就是「分类能出来、一点书就报 App Transport Security」
        let ats = (Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]) ?? [:]
        let rawTrue = (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false
        // iOS 10+：plist 里只要出现这三个键之一，NSAllowsArbitraryLoads 的值就**被忽略、按 NO 算**。
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
        if let e = EngineBackend.lastError { lines.append("错误：\(e)") }
        return lines.joined(separator: "\n")
    }

    /// **完整日志全文** —— 给「复制日志」按钮用
    func fullLogText() -> String {
        var lines: [String] = []
        lines.append("======== 轻阅 引擎日志 ========")
        lines.append("时间：\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("App 版本：\(AppPaths.appVersionLine)　引擎：LegadoEngine")
        if let e = EngineBackend.lastError { lines.append("错误：\(e)") }
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
        lines.append("======== 磁盘日志（崩溃前）========")
        let disk = Self.diskLogText()
        lines.append(disk.isEmpty ? "（空）" : disk)
        return lines.joined(separator: "\n")
    }

    // MARK: - 宿主能力（要 UIKit ⇒ 只能住这儿）

    /// ⭐⭐⭐ **用系统浏览器打开**（站方 `java.startBrowser` / `startBrowserAwait` / `showBrowser` …）
    func openExternal(url: String, title: String) {
        guard let u = URL(string: url), u.scheme != nil else {
            appendLog("[宿主] 浏览器 URL 非法：\(url)")
            return
        }
        appendLog("[宿主] 打开浏览器：\(u.absoluteString) \(title)")
        UIApplication.shared.open(u)
    }

    /// ⭐⭐⭐ **把真设备 ID 写进 `UserDefaults`**（给**不能 import UIKit 的层**用）
    static func cacheDeviceID() {
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "qiReaderLite"
        UserDefaults.standard.set(id, forKey: "qr.deviceID")
    }

    /// ⭐⭐⭐ **设备 ID（同步可取）** —— 给**不需要 UIKit 的层**用
    static let cachedDeviceID: String = UIDevice.current.identifierForVendor?.uuidString ?? "qiReaderLite"

    /// **明文 HTTP 探针**（ATS 有没有真的放开）
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

    /// 站方请求用的 UA（与引擎一致）
    static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS \(UIDevice.current.systemVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 qireaderlite/1.0"
    }
}
