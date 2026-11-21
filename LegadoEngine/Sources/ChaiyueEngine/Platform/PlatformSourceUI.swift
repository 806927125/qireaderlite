#if canImport(WebKit) && !os(Linux)
import Foundation
import ChaiyueEngine
import WebKit

/// 打开浏览器页面的参数
public struct BrowserRequest: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// 全屏页面（`java.startBrowser`/`startBrowserAwait`：登录、人机验证）
        case page
        /// 浮层（`java.showBrowser`/`showReadingBrowser`：段评等），附带书源传入的配置 JSON
        case sheet(optionsJSON: String?)
    }

    public var url: String
    public var title: String
    public var html: String?
    public var js: String?
    public var sourceKey: String
    public var style: Style
    /// 书源在等待页面关闭后的结果（startBrowserAwait），界面需要提供明确的完成操作
    public var waitsForResult: Bool
    public var userAgent: String
}

/// 需要用户参与的交互，由界面层实现。回调必须且只调用一次
@MainActor
public protocol SourceInteractionPresenter: AnyObject {
    /// 打开浏览器页面；页面关闭时回调关闭时的地址与页面源码，取不到时传 nil
    func presentBrowser(_ request: BrowserRequest, completion: @escaping @MainActor (BrowserResult?) -> Void)
    /// 显示验证码图片并等待输入，取消时传 nil
    func presentVerificationCode(imageURL: String, sourceKey: String, completion: @escaping @MainActor (String?) -> Void)
    /// `java.copyText`
    func copyText(_ text: String)
    /// 非网页地址（如 `qdreader://`）交给系统打开，打不开时静默
    func openExternalURL(_ url: URL)
    /// 全屏播放视频，`url` 可带 `,{headers}` 选项
    func presentVideoPlayer(url: String, title: String?, sourceKey: String)
}

public extension SourceInteractionPresenter {
    func copyText(_ text: String) {}
    func openExternalURL(_ url: URL) {}
    func presentVideoPlayer(url: String, title: String?, sourceKey: String) {}
}

/// 规则引擎的界面能力实现。引擎在自己的工作线程上调用：
/// 渲染、等待浏览器关闭、验证码这三类在主线程执行并阻塞工作线程等待结果；打开浏览器、toast 不阻塞
public final class PlatformSourceUI: SourceUIDelegate, @unchecked Sendable {
    private let environment: SourceEnvironment
    private let lock = NSLock()
    private var toastHandler: (@Sendable (String, Bool) -> Void)?
    private var timeout: TimeInterval = 90

    @MainActor public weak var presenter: (any SourceInteractionPresenter)?
    /// WebView 数据存储，为空时使用 `WKWebsiteDataStore.default()`（与界面层的浏览器页共享登录态）
    @MainActor public var dataStore: WKWebsiteDataStore?

    public init(environment: SourceEnvironment) {
        self.environment = environment
    }

    public var onToast: (@Sendable (_ message: String, _ long: Bool) -> Void)? {
        get { lock.withLock { toastHandler } }
        set { lock.withLock { toastHandler = newValue } }
    }

    /// 后台渲染的最长等待时间（秒）
    public var renderTimeout: TimeInterval {
        get { lock.withLock { timeout } }
        set { lock.withLock { timeout = newValue } }
    }

    // MARK: - SourceUIDelegate

    public func toast(_ message: String, long: Bool) {
        onToast?(message, long)
    }

    public func renderWebView(_ request: WebViewRequest) throws -> String {
        let environment = environment
        let timeout = renderTimeout
        return try waitOnMain(timeout: timeout + 5) { [self] finish in
            WebViewRenderer.render(request, environment: environment, timeout: .seconds(timeout), dataStore: dataStore,
                                   completion: finish)
        }
    }

    public func startBrowser(url: String, title: String, html: String?, sourceKey: String) {
        let request = makeRequest(url: url, title: title, html: html, js: nil, sourceKey: sourceKey, style: .page, waits: false)
        Task { @MainActor in present(request) { _ in } }
    }

    public func showBrowser(_ sheet: BrowserSheet) {
        let request = makeRequest(url: sheet.url, title: sheet.title ?? "", html: sheet.html, js: sheet.js,
                                  sourceKey: sheet.sourceKey, style: .sheet(optionsJSON: sheet.optionsJSON), waits: false)
        Task { @MainActor in present(request) { _ in } }
    }

    public func startBrowserAwait(url: String, title: String, html: String?, sourceKey: String) throws -> BrowserResult {
        let request = makeRequest(url: url, title: title, html: html, js: nil, sourceKey: sourceKey, style: .page, waits: true)
        return try waitOnMain(timeout: nil) { [self] finish in
            guard presenter != nil else {
                finish(.failure(RuleError.message("当前界面无法打开浏览器：\(url)")))
                return
            }
            present(request) { result in
                finish(.success(result ?? BrowserResult(url: url, body: "")))
            }
        }
    }

    public func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        Task { @MainActor in presenter?.copyText(text) }
    }

    /// 网页用内置浏览器；mimeType 为音视频时用播放器；其它 scheme 交给系统
    public func openURL(_ url: String, mimeType: String?, sourceKey: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mime = mimeType?.lowercased(), mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
            openVideoPlayer(url: trimmed, title: nil, floating: false, sourceKey: sourceKey)
            return
        }
        guard let link = URL(string: trimmed), let scheme = link.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            startBrowser(url: trimmed, title: "", html: nil, sourceKey: sourceKey)
        } else {
            Task { @MainActor in presenter?.openExternalURL(link) }
        }
    }

    public func openVideoPlayer(url: String, title: String?, floating: Bool, sourceKey: String) {
        guard !url.isEmpty else { return }
        Task { @MainActor in presenter?.presentVideoPlayer(url: url, title: title, sourceKey: sourceKey) }
    }

    public func verificationCode(imageURL: String, sourceKey: String) throws -> String {
        try waitOnMain(timeout: nil) { [self] finish in
            guard let presenter else {
                finish(.failure(RuleError.message("当前界面无法输入验证码")))
                return
            }
            presenter.presentVerificationCode(imageURL: imageURL, sourceKey: sourceKey) { code in
                if let code, !code.isEmpty {
                    finish(.success(code))
                } else {
                    finish(.failure(RuleError.message("已取消输入验证码")))
                }
            }
        }
    }

    // MARK: - 内部

    private func makeRequest(url: String, title: String, html: String?, js: String?, sourceKey: String,
                             style: BrowserRequest.Style, waits: Bool) -> BrowserRequest {
        BrowserRequest(url: url, title: title, html: html, js: js, sourceKey: sourceKey, style: style,
                       waitsForResult: waits, userAgent: environment.webViewUserAgent)
    }

    /// 打开前写入引擎 Cookie，关闭后把页面里的 Cookie（如登录态）合并回引擎
    @MainActor
    private func present(_ request: BrowserRequest, completion: @escaping @MainActor (BrowserResult?) -> Void) {
        guard let presenter else {
            completion(nil)
            return
        }
        let cookies = environment.cookies
        let sourceKey = request.sourceKey
        let notify = environment
        let store = (dataStore ?? .default()).httpCookieStore
        Task { @MainActor in
            await CookieSync.push(request.url, from: cookies, to: store)
            presenter.presentBrowser(request) { result in
                Task { @MainActor in
                    let before = cookies.digest()
                    await CookieSync.pull(result?.url ?? request.url, into: cookies, key: sourceKey, from: store)
                    await CookieSync.pullAll(into: cookies, from: store)
                    if cookies.digest() != before { notify.sourceLoginDidChange(sourceKey) }
                    completion(result)
                }
            }
        }
    }

    /// 在主线程启动界面流程，阻塞当前工作线程直到拿到结果
    private func waitOnMain<T: Sendable>(
        timeout: TimeInterval?,
        _ start: @escaping @MainActor (_ finish: @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) throws -> T {
        if Thread.isMainThread {
            throw RuleError.message("界面交互不能在主线程同步等待")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { @MainActor in
            start { result in
                if box.set(result) { semaphore.signal() }
            }
        }
        if let timeout {
            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                _ = box.set(.failure(RuleError.message("等待界面操作超时")))
            }
        } else {
            semaphore.wait()
        }
        guard let result = box.value else { throw RuleError.message("界面操作没有返回结果") }
        return try result.get()
    }
}

/// 只接受第一次写入的结果
final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    var value: Result<T, Error>? { lock.withLock { stored } }

    func set(_ result: Result<T, Error>) -> Bool {
        lock.withLock {
            guard stored == nil else { return false }
            stored = result
            return true
        }
    }
}

#endif  // #if canImport(WebKit) && !os(Linux)
