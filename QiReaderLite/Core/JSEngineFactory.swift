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

    /// ⭐⭐⭐ **后端只有一种**：WKWebView（独立进程）
    ///
    /// ⚠️⚠️⚠️ **JSC 已彻底删除**（2026-10-26 用户明确：「JSC 给我彻底删掉哈」）
    ///   ⇒ JSC 跑在 **App 进程内** ⇒ 站方脚本的每次分配都算我们的 ⇒ 一次 op 就能顶到 GB 级
    ///   ⇒ jetsam 秒杀（闪退 + 没有 .ips）⇒ **老引擎一直免疫**（它的 JS 在 WebContent 独立进程）⭐⭐⭐
    /// ⇒ 这里**不再有第二种后端** ⇒ 新引擎的 JS 也只能走 WKWebView ⭐⭐⭐
    public enum Kind: String, CaseIterable, Sendable {
        /// WKWebView（独立进程·跟老引擎一样）⇒ 站方 JS 再野也炸不到 App
        case webView = "WKWebView（独立进程·跟老引擎一样）"

        /// UserDefaults 里的键
        public static let storageKey = "qr.jsBackend"

        public var storageValue: String { "webview" }

        public init?(storageValue: String) {
            if storageValue == "webview" { self = .webView } else { return nil }
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
