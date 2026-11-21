import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 规则引擎运行所需的全局依赖，App 内共享一个实例
public final class SourceEnvironment: @unchecked Sendable {
    public let http: HTTPTransport
    /// `java.webSocket` 使用
    public let webSocket: WebSocketTransport
    public let store: KeyValueStore
    public let cookies: CookieStore
    public let cache: CacheStore
    /// 持久化的设备标识（书源通过 `java.deviceID()` 读取，部分书源据此限制设备数）
    public let deviceID: String
    /// 16 位十六进制，兼作登录信息的加密密钥（与 Legado 一致）
    public let androidID: String
    public var userAgent: String
    public var webViewUserAgent: String
    public var requestTimeout: TimeInterval = 30

    private let lock = NSLock()
    private weak var uiDelegate: SourceUIDelegate?
    private let headless = HeadlessSourceUI()
    private var logger: (@Sendable (String, String) -> Void)?
    private var eventHandler: (@Sendable (SourceEvent) -> Void)?
    private var loginHandler: (@Sendable (String) -> Void)?

    public static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    public convenience init(http: HTTPTransport = URLSessionTransport(), store: KeyValueStore,
                            deviceID: String? = nil, userAgent: String = SourceEnvironment.defaultUserAgent) {
        self.init(http: http, webSocket: URLSessionWebSocketTransport(), store: store, deviceID: deviceID, userAgent: userAgent)
    }

    /// ⭐⭐⭐⭐⭐ **androidID（登录信息加密密钥）可注入**（2026-11-21 移植补丁）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么加这个参数**：原实现用 `CryptoKit` 算 SHA256 ⇒ **Linux 沙盒编不到** ⭐⭐⭐
    ///   ⇒ 整个 `SourceEnvironment` 编不到 ⇒ **沙盒门禁全废**（当天没被验过都不知道）⭐⭐⭐
    ///   ⇒ 正解：**宿主（App 层，Apple 平台）自己算好传进来** ⇒ 引擎包不依赖 CryptoKit ⭐⭐⭐
    ///   ⇒ ⚠️ **必须与 Apple 端算法一致**（否则登录信息解不开）⇒ 由宿主保证 ⇒ 门禁另验 ⭐⭐⭐
    public init(http: HTTPTransport = URLSessionTransport(), webSocket: WebSocketTransport, store: KeyValueStore,
                deviceID: String? = nil, userAgent: String = SourceEnvironment.defaultUserAgent,
                androidID: String? = nil) {
        self.http = http
        self.webSocket = webSocket
        self.store = store
        cookies = CookieStore(store: store)
        cache = CacheStore(store: store)
        let id: String
        if let deviceID, !deviceID.isEmpty {
            id = deviceID
        } else if let saved = store.string(forKey: "__deviceID"), !saved.isEmpty {
            id = saved
        } else {
            id = UUID().uuidString
            store.set(id, forKey: "__deviceID")
        }
        self.deviceID = id
        #if canImport(CryptoKit)
        self.androidID = androidID ?? String(Hex.encode(Data(SHA256.hash(data: Data(id.utf8)))).prefix(16))
        #else
        // ⭐⭐⭐ **非 Apple 平台**：宿主若没注入就退化为 deviceID 本身 ⭐⭐⭐
        //   ⚠️ **仅供 Linux 沙盒编译/门禁**（真机永远是 Apple 端 ⇒ CryptoKit 路径）⭐⭐⭐
        self.androidID = androidID ?? String(id.prefix(16))
        #endif
        self.userAgent = userAgent
        webViewUserAgent = userAgent
    }

    public var ui: SourceUIDelegate {
        lock.withLock { uiDelegate } ?? headless
    }

    public func setUIDelegate(_ delegate: SourceUIDelegate?) {
        lock.withLock { uiDelegate = delegate }
    }

    /// 书源日志（`java.log`、解析错误）
    public func setLogger(_ logger: (@Sendable (_ sourceKey: String, _ message: String) -> Void)?) {
        lock.withLock { self.logger = logger }
    }

    public func setEventHandler(_ handler: (@Sendable (SourceEvent) -> Void)?) {
        lock.withLock { eventHandler = handler }
    }

    func log(_ sourceKey: String, _ message: String) {
        lock.withLock { logger }?(sourceKey, message)
    }

    func notify(_ event: SourceEvent) {
        lock.withLock { eventHandler }?(event)
    }

    // MARK: - 登录状态

    /// 书源登录状态（登录信息、登录头、登录时写入的 Cookie）变化时回调，参数为书源 key
    public func setLoginChangeHandler(_ handler: (@Sendable (_ sourceKey: String) -> Void)?) {
        lock.withLock { loginHandler = handler }
    }

    /// 书源登录状态的版本标记，每次变化都会换新；依赖登录状态的缓存（如 JS 生成的发现页分类）据此判断是否过期
    public func loginStamp(_ sourceKey: String) -> String {
        store.string(forKey: "loginStamp_" + sourceKey) ?? ""
    }

    /// 标记书源登录状态已变化：换新版本标记并通知各入口刷新
    public func sourceLoginDidChange(_ sourceKey: String) {
        store.set(UUID().uuidString, forKey: "loginStamp_" + sourceKey)
        lock.withLock { loginHandler }?(sourceKey)
    }
}
