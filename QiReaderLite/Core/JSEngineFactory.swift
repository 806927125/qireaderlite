import Foundation
import LegadoCore

/// ⭐⭐⭐⭐⭐ **JS 后端选择**（2026-10-26 · 闪退真凶的方向性修法）
///
/// ⭐⭐⭐ **为什么要有「后端」这一层**：
///   站方 JS 跑在哪儿，决定了**它能吃多少内存而不弄死 App**：
///   · `JSC`（App 进程内）⇒ 站方脚本一次吃几 GB ⇒ **jetsam 秒杀 App**（6.8GB 实证）⭐⭐⭐
///   · `WKWebView`（**WebContent 独立进程**）⇒ 炸的也是那个进程 ⇒ **App 不死**（老引擎一直免疫）⭐⭐⭐
///
/// ⭐ **Core 层不能 import WebKit**（沙盒 Linux 门禁要编它）⇒
///   ⇒ 这里只放**工厂 + 开关**；真正的实现由 UI 层注册进来 ⭐
public enum JSEngineFactory {

    /// 后端种类
    public enum Kind: String, CaseIterable, Sendable {
        /// ⭐ WKWebView（独立进程）—— 跟老引擎一样 ⇒ 站方 JS 再野也炸不到 App
        case webView = "WKWebView（独立进程·跟老引擎一样）"
        /// JSC（App 进程内）—— 快，但站方脚本的内存算 App 的
        case jsc = "JSC（App 进程内）"

        /// UserDefaults 里的键
        public static let storageKey = "qr.jsBackend"

        public var storageValue: String {
            switch self {
            case .webView: return "webview"
            case .jsc: return "jsc"
            }
        }

        public init?(storageValue: String) {
            switch storageValue {
            case "webview": self = .webView
            case "jsc": self = .jsc
            default: return nil
            }
        }
    }

    private static let lock = NSLock()
    private static var _maker: ((JSHostAPIProvider) -> JSExecutor?)?
    private static var _kind: Kind = .webView

    /// ⭐ 当前后端（默认 **WKWebView** ⇒ 跟老引擎一样 ⇒ 闪退免疫）
    public static var kind: Kind {
        lock.lock(); defer { lock.unlock() }
        return _kind
    }

    /// ⭐ 换后端（UI 层读开关后调）
    public static func setKind(_ k: Kind) {
        lock.lock(); _kind = k; lock.unlock()
    }

    /// ⭐ 注册实现（UI 层启动时调）
    public static func install(_ maker: @escaping (JSHostAPIProvider) -> JSExecutor?) {
        lock.lock(); _maker = maker; lock.unlock()
    }

    /// 建执行器（**没注册 ⇒ 返回 nil** ⇒ 引擎无 JS 后端 ⇒ 规则静默失效 ⇒ 必须显式报错）
    public static func make(_ api: JSHostAPIProvider) -> JSExecutor? {
        lock.lock(); let m = _maker; lock.unlock()
        return m?(api)
    }

    /// 后端是否可用（UI 层用它决定要不要 boot WebView）
    public static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _maker != nil
    }
}
