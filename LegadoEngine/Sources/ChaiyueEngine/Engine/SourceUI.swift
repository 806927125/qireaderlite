import Foundation

/// 后台 WebView 渲染请求（`webView:true` 选项、`java.webView`）
public struct WebViewRequest: Sendable {
    public var html: String?
    public var url: String?
    public var js: String?
    public var sourceKey: String
    public var headers: [String: String]
    public var sourceRegex: String?
    /// 页面加载完成后额外等待的毫秒数
    public var delay: Int

    public init(html: String?, url: String?, js: String?, sourceKey: String, headers: [String: String] = [:],
                sourceRegex: String? = nil, delay: Int = 0) {
        self.html = html
        self.url = url
        self.js = js
        self.sourceKey = sourceKey
        self.headers = headers
        self.sourceRegex = sourceRegex
        self.delay = delay
    }
}

/// 浮层浏览器（`java.showBrowser`/`java.showReadingBrowser`），用于段评等页面
public struct BrowserSheet: Sendable {
    public var url: String
    public var title: String?
    public var html: String?
    public var js: String?
    /// 书源传入的浮层配置 JSON（高度比例、圆角等）
    public var optionsJSON: String?
    public var sourceKey: String

    public init(url: String, title: String?, html: String?, js: String?, optionsJSON: String?, sourceKey: String) {
        self.url = url
        self.title = title
        self.html = html
        self.js = js
        self.optionsJSON = optionsJSON
        self.sourceKey = sourceKey
    }
}

public struct BrowserResult: Sendable {
    public var url: String
    public var body: String

    public init(url: String, body: String) {
        self.url = url
        self.body = body
    }
}

/// 书源脚本需要界面配合的能力。调用发生在规则引擎工作线程上，实现方需自行切换到主线程并在需要时阻塞等待结果。
public protocol SourceUIDelegate: AnyObject, Sendable {
    func renderWebView(_ request: WebViewRequest) throws -> String
    func startBrowser(url: String, title: String, html: String?, sourceKey: String)
    func startBrowserAwait(url: String, title: String, html: String?, sourceKey: String) throws -> BrowserResult
    func showBrowser(_ sheet: BrowserSheet)
    func verificationCode(imageURL: String, sourceKey: String) throws -> String
    func toast(_ message: String, long: Bool)
    /// `java.copyText`
    func copyText(_ text: String)
    /// `java.openUrl`：网页用内置浏览器，其它 scheme 交给系统，打不开时静默
    func openURL(_ url: String, mimeType: String?, sourceKey: String)
    /// `java.openVideoPlayer`：`url` 可带 `,{headers}` 选项
    func openVideoPlayer(url: String, title: String?, floating: Bool, sourceKey: String)
}

public extension SourceUIDelegate {
    func copyText(_ text: String) {}
    func openURL(_ url: String, mimeType: String?, sourceKey: String) {}
    func openVideoPlayer(url: String, title: String?, floating: Bool, sourceKey: String) {}
}

/// 书源发出的通知（刷新发现页、跳转搜索、打开登录页等）
public enum SourceEvent: Sendable {
    case refreshExplore(sourceKey: String)
    case searchBook(key: String, sourceKey: String)
    case open(name: String, url: String?, title: String?, sourceKey: String)
    /// `java.addBook`：按地址取详情并加入书架
    case addBook(bookUrl: String, sourceKey: String)
    /// `java.reLoginView`：重新生成登录界面（未打开时打开）
    case reLoginView(sourceKey: String)
    /// `java.upLoginData`：登录界面输入框的新值（已写入登录信息）
    case upLoginData(data: [String: String], sourceKey: String)
    /// `java.refreshContent`：阅读器重新加载当前章节
    case refreshContent(sourceKey: String)
}

/// 无界面环境（单元测试、命令行）：交互能力直接报错，toast 记入日志
public final class HeadlessSourceUI: SourceUIDelegate, @unchecked Sendable {
    public var onToast: (@Sendable (String) -> Void)?

    public init(onToast: (@Sendable (String) -> Void)? = nil) {
        self.onToast = onToast
    }

    public func renderWebView(_ request: WebViewRequest) throws -> String {
        throw RuleError.message("当前环境不支持 WebView：\(request.url ?? "")")
    }

    public func startBrowser(url: String, title: String, html: String?, sourceKey: String) {
        onToast?("[浏览器] \(title) \(url)")
    }

    public func startBrowserAwait(url: String, title: String, html: String?, sourceKey: String) throws -> BrowserResult {
        throw RuleError.message("当前环境不支持打开浏览器：\(url)")
    }

    public func showBrowser(_ sheet: BrowserSheet) {
        onToast?("[浮层浏览器] \(sheet.url)")
    }

    public func verificationCode(imageURL: String, sourceKey: String) throws -> String {
        throw RuleError.message("当前环境不支持输入验证码")
    }

    public func toast(_ message: String, long: Bool) {
        onToast?(message)
    }
}
