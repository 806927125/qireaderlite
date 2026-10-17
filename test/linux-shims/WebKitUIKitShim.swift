// WebKit / UIKit 的最小 shim，只为让 RuleSandbox.swift 能在 Linux 上类型检查。
//
// ⚠️ 重要局限：这些签名是我按记忆写的，**不等于真实 SDK**。
// 它能可靠抓的是「我自己代码里的错」——打错字、成员不存在、
// 我自己类型之间的参数不匹配、可选性用错。
// 它**抓不到**「我把 WebKit API 用错了」，那种只能靠真机/真 Xcode 编译。
// 所以这个门禁通过 ≠ 能编译过，只是把已知的坑清掉一大半。

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - WebKit

public class WKWebViewConfiguration: NSObject {
    public var userContentController = WKUserContentController()
    public var websiteDataStore = WKWebsiteDataStore.default()
    public var preferences = WKPreferences()
    public var defaultWebpagePreferences = WKPageConfiguration()
    public override init() { super.init() }
}

public class WKUserContentController: NSObject {
    public func add(_ scriptMessageHandler: WKScriptMessageHandler, name: String) {}
    public override init() { super.init() }
}

public class WKWebsiteDataStore: NSObject {
    public class func `default`() -> WKWebsiteDataStore { WKWebsiteDataStore() }
}

public class WKPreferences: NSObject {
    public var javaScriptCanOpenWindowsAutomatically: Bool = false
}

public class WKPageConfiguration: NSObject {
    public var allowsContentJavaScript: Bool = true
}

public class WKContentWorld: NSObject {
    public class var page: WKContentWorld { WKContentWorld() }
}

public class WKFrameInfo: NSObject {}

public class WKNavigation: NSObject {}

public class WKNavigationAction: NSObject {
    public var request: URLRequest { URLRequest(url: URL(string: "about:blank")!) }
}

public enum WKNavigationActionPolicy: Int { case cancel = 0; case allow = 1 }

public class WKWebView: NSObject {
    public var navigationDelegate: WKNavigationDelegate?
    public var isHidden: Bool = false
    public var isUserInteractionEnabled: Bool = true

    public init(frame: NSRect, configuration: WKWebViewConfiguration) { super.init() }

    public func loadHTMLString(_ string: String, baseURL: URL?) {}
    public func loadFileURL(_ url: URL, allowingReadAccessTo: URL?) {}
    public func evaluateJavaScript(_ script: String, completionHandler: ((Any?, (any Error)?) -> Void)? = nil) {}
    public func evaluateJavaScript(_ script: String) async throws -> Any { NSNull() }
    public func callAsyncJavaScript(_ functionBody: String,
                                    arguments: [String: Any] = [:],
                                    in frame: WKFrameInfo? = nil,
                                    contentWorld: WKContentWorld) async throws -> Any? { nil }
}

@MainActor
public protocol WKNavigationDelegate: NSObjectProtocol {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
}
public extension WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(.allow) }
}

public class WKScriptMessage: NSObject {
    public var name: String { "" }
    public var body: Any { NSNull() }
}

@MainActor
public protocol WKScriptMessageHandler: NSObjectProtocol {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
}

// MARK: - UIKit

public struct CGRectShim {
    public var width: Double = 0; public var height: Double = 0
    public static let zero = CGRectShim()
}
public typealias CGFloat = Double
public typealias NSRect = CGRectShim

public enum NSTextAlignment { case left, center, right }

public class UIColor: NSObject {
    public static let black = UIColor()
    public static let white = UIColor()
    public static let clear = UIColor()
    public func withAlphaComponent(_ a: CGFloat) -> UIColor { self }
}

public class UIFont: NSObject {
    public static func systemFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont { UIFont() }
    public enum Weight { case regular, medium }
}

public class CALayer: NSObject {
    public var cornerRadius: CGFloat = 0
    public var masksToBounds = false
}

public class NSLayoutConstraint: NSObject {
    public class func activate(_ c: [NSLayoutConstraint]) {}
}

public class NSLayoutAnchor: NSObject {
    public func constraint(equalTo a: NSLayoutAnchor) -> NSLayoutConstraint { NSLayoutConstraint() }
    public func constraint(equalTo a: NSLayoutAnchor, constant: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    public func constraint(lessThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
}

public class NSLayoutGuide: NSObject {
    public var bottomAnchor = NSLayoutAnchor()
}

/// 注意：iOS 上 UILabel / UIWindow 都是 UIView 的子类，anchor 挂在 UIView 上。
/// shim 写错继承关系会凭空造出一堆「真实 iOS 上不存在」的错误。
public class UIView: NSObject {
    public var alpha: CGFloat = 1
    public var layer: CALayer = CALayer()
    public var translatesAutoresizingMaskIntoConstraints = true
    public var centerXAnchor = NSLayoutAnchor()
    public var bottomAnchor = NSLayoutAnchor()
    public var widthAnchor = NSLayoutAnchor()
    public var safeAreaLayoutGuide = NSLayoutGuide()
    public func addSubview(_ v: UIView) {}
    public func removeFromSuperview() {}
    public class func animate(withDuration d: Double, animations: @escaping () -> Void) {}
    public class func animate(withDuration d: Double,
                             animations: @escaping () -> Void,
                             completion: ((Bool) -> Void)?) {}
}

public class UILabel: UIView {
    public var text: String?
    public var font: UIFont?
    public var textColor: UIColor?
    public var backgroundColor: UIColor?
    public var textAlignment: NSTextAlignment = .left
    public var numberOfLines: Int = 1
}

public class UIWindow: UIView {}

public class UIScene: NSObject {}
public class UIWindowScene: UIScene { public var keyWindow: UIWindow? { UIWindow() } }

public class UIApplication: NSObject {
    public static let shared = UIApplication()
    public var connectedScenes: Set<UIScene> = []
}

public class UIDevice: NSObject {
    public static let current = UIDevice()
    public var identifierForVendor: UUID? { nil }
    public var systemVersion: String { "17.0" }
}

// CoreFoundation 编码转换，RuleSandbox 的 charset() 用到。
// 真实类型是 struct 带 rawValue，shim 必须保持这个形状，否则会掩盖类型错误。
public struct CFStringEncoding: Equatable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public enum CFStringEncodings {
    public static let GB_18030_2000 = CFStringEncoding(0x0631)
    public static let big5 = CFStringEncoding(0x0A03)
    public static let EUC_JP = CFStringEncoding(0x0920)
}
public func CFStringConvertEncodingToNSStringEncoding(_ e: CFStringEncoding) -> UInt { UInt(e.rawValue) }


// MARK: - URLSession / HTTPCookie
//
// Linux corelibs-foundation 的签名和 Apple 不一样（比如 HTTPCookie 初始化器
// 多了个 mainDocumentURL），这里按 Apple 的签名覆盖，避免制造假错误。

public final class HTTPCookiePropertyKey: RawRepresentable, Hashable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let name = HTTPCookiePropertyKey("Name")
    public static let value = HTTPCookiePropertyKey("Value")
    public static let domain = HTTPCookiePropertyKey("Domain")
    public static let path = HTTPCookiePropertyKey("Path")
}

public class HTTPCookie: NSObject {
    public var name: String = ""
    public var value: String = ""
    public init?(properties: [HTTPCookiePropertyKey: Any]?) {}
}

public class HTTPCookieStorage: NSObject {
    public static let shared = HTTPCookieStorage()
    public func cookies(for url: URL) -> [HTTPCookie]? { nil }
    public func setCookies(_ cookies: [HTTPCookie], for url: URL) {}
    public func setCookies(_ cookies: [HTTPCookie], for url: URL, mainDocumentURL: URL?) {}
}

public class URLSessionConfiguration: NSObject {
    public static let ephemeral = URLSessionConfiguration()
    public var httpAdditionalHeaders: [AnyHashable: Any]?
    public var timeoutIntervalForRequest: TimeInterval = 60
    public var httpCookieStorage: HTTPCookieStorage?
    public var httpShouldSetCookies = true
}

public class URLSession: NSObject {
    public init(configuration: URLSessionConfiguration) { super.init() }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) { (Data(), URLResponse()) }
}


public class URLResponse: NSObject {
    public var url: URL? { nil }
}
public class HTTPURLResponse: URLResponse {
    public var statusCode: Int { 0 }
    public var allHeaderFields: [AnyHashable: Any] { [:] }
    public var textEncodingName: String? { nil }
}
