#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/SourcePresenter.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/SourcePresenter.swift

import AVKit
import Observation
import ChaiyueEngine
import ChaiyueEngine
import SwiftUI
import WebKit

final class SourcePresenter: SourceInteractionPresenter {
    /// 验证码图片加载（图片地址、书源标识），需带书源的请求头与 Cookie 且不能走缓存
    var loadImage: ((String, String) async -> UIImage?)?
    /// 播放地址解析（地址、书源标识）：去掉 `,{选项}` 并带上书源请求头
    var resolvePlayback: ((String, String) async -> (url: URL, headers: [String: String])?)?
    weak var island: IslandCenter?

    func copyText(_ text: String) {
        UIPasteboard.general.string = text
        island?.show("doc.on.doc", "已复制")
    }

    func openExternalURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func presentVideoPlayer(url: String, title: String?, sourceKey: String) {
        let resolve = resolvePlayback
        Task {
            guard let playback = await resolve?(url, sourceKey) ?? URL(string: url).map({ ($0, [:]) }),
                  let top = Self.topController() else { return }
            let options: [String: Any]? = playback.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": playback.headers]
            let item = AVPlayerItem(asset: AVURLAsset(url: playback.url, options: options))
            if let title, !title.isEmpty {
                let meta = AVMutableMetadataItem()
                meta.identifier = .commonIdentifierTitle
                meta.value = title as NSString
                item.externalMetadata = [meta]
            }
            let controller = AVPlayerViewController()
            controller.player = AVPlayer(playerItem: item)
            controller.modalPresentationStyle = .fullScreen
            top.present(controller, animated: true) { controller.player?.play() }
        }
    }

    /// 以半屏/全屏浮层显示 SwiftUI 页面（书源脚本触发的登录界面等，可能盖在阅读器之上）
    func presentSheet(_ view: some View) {
        guard let top = Self.topController() else { return }
        // 与 qSheet 一致：iOS 26 用系统玻璃，更早的系统用材质底
        let legacy: Bool
        if #available(iOS 26, *) { legacy = false } else { legacy = true }
        let controller = UIHostingController(rootView: legacy ? AnyView(view.background(.regularMaterial)) : AnyView(view))
        if legacy { controller.view.backgroundColor = .clear }
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if legacy { sheet.preferredCornerRadius = 38 }
        }
        top.present(controller, animated: true)
    }

    func presentBrowser(_ request: BrowserRequest, completion: @escaping @MainActor @Sendable (BrowserResult?) -> Void) {
        guard let top = Self.topController() else {
            completion(nil)
            return
        }
        weak var host: UIViewController?
        let finish = BrowserCompletion(completion)
        let view = BrowserScreen(request: request) { result in
            host?.dismiss(animated: true)
            finish.call(result)
        }
        let controller = UIHostingController(rootView: view)
        if case .sheet(let options) = request.style {
            // 段评等浮层：默认 0.8 屏高，可下拉关闭（书源配置的 heightPercentage 优先）
            let fraction = Self.heightFraction(options)
            controller.sheetPresentationController?.detents = [.custom(identifier: .init("browser")) { $0.maximumDetentValue * fraction },
                                                               .large()]
            controller.sheetPresentationController?.prefersGrabberVisible = true
            controller.sheetPresentationController?.preferredCornerRadius = 20
        } else {
            controller.modalPresentationStyle = .pageSheet
        }
        controller.isModalInPresentation = request.waitsForResult
        // 下拉关闭时也回调，书源与 Cookie 同步不会一直等着
        controller.presentationController?.delegate = finish
        objc_setAssociatedObject(controller, &BrowserCompletion.key, finish, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        host = controller
        top.present(controller, animated: true)
    }

    private static func heightFraction(_ optionsJSON: String?) -> CGFloat {
        guard let data = optionsJSON?.data(using: .utf8),
              let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (options["heightPercentage"] as? NSNumber)?.doubleValue, value > 0.2, value <= 1 else { return 0.8 }
        return CGFloat(value)
    }

    func presentVerificationCode(imageURL: String, sourceKey: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let top = Self.topController() else {
            completion(nil)
            return
        }
        weak var host: UIViewController?
        let loader = loadImage
        let view = CaptchaScreen(imageURL: imageURL, loadImage: { await loader?($0, sourceKey) }) { code in
            host?.dismiss(animated: true)
            completion(code)
        }
        let controller = UIHostingController(rootView: view)
        controller.sheetPresentationController?.detents = [.custom { _ in 300 }]
        controller.isModalInPresentation = true
        host = controller
        top.present(controller, animated: true)
    }

    static func topController() -> UIViewController? {
        var top = AppearanceStore.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

private final class BrowserCompletion: NSObject, UIAdaptivePresentationControllerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private var completion: (@MainActor @Sendable (BrowserResult?) -> Void)?

    init(_ completion: @escaping @MainActor @Sendable (BrowserResult?) -> Void) {
        self.completion = completion
    }

    func call(_ result: BrowserResult?) {
        let pending = completion
        completion = nil
        pending?(result)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        call(nil)
    }
}

private struct BrowserScreen: View {
    let request: BrowserRequest
    let onClose: (BrowserResult?) -> Void
    @State private var page = WebPageModel()
    @State private var closing = false

    var body: some View {
        NavigationStack {
            WebViewContainer(webView: page.webView)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if page.progress < 1 {
                        ProgressView(value: page.progress)
                            .progressViewStyle(.linear)
                            .tint(Tok.accent)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle(page.title.isEmpty ? request.title : page.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { close() }.disabled(closing)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("刷新", icon: "arrow.clockwise") { page.webView.reload() }
                            Button("后退", icon: "chevron.backward") { page.webView.goBack() }
                            if let current = page.webView.url {
                                Button("复制链接", icon: "link") { UIPasteboard.general.url = current }
                                Button("在 Safari 中打开", icon: "safari") { UIApplication.shared.open(current) }
                            }
                        } label: {
                            Image(icon: "ellipsis")
                        }
                    }
                }
        }
        .task { page.load(request) }
    }

    private func close() {
        closing = true
        Task {
            let body = (try? await page.webView.evaluateJavaScript("document.documentElement.outerHTML")) as? String ?? ""
            onClose(BrowserResult(url: page.webView.url?.absoluteString ?? request.url, body: body))
        }
    }
}

// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/SourcePresenter.swift 搬运**（浏览器页的 WebView 封装）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件位置：App/Sources/App/SourcePresenter.swift（`WebPageModel` / `WebViewContainer` /
//              `WebHostView` / `WebSheetTouches` 四块，**一字未改**）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么必须搬**（不是「顺手补的」）：⭐⭐⭐
//   上游的 `BrowserScreen` 直接用这四个类型（`page.webView` / `page.progress` / `page.title` /
//   `page.load(request)`）⇒ 我们照搬 `BrowserScreen` 时**它们就是编译依赖** ⇒
//   不搬 ⇒ `cannot find 'WebPageModel' in scope` ⇒ **浏览器页与验证码页都编不出来** ⭐⭐⭐
//   ⇒ 与「换源面板」「TXT 分章」那类**功能面板**不同：这四个是**阅读器浏览器的实现件** ⇒ 必须搬 ⭐⭐⭐
@Observable
private final class WebPageModel: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    var title = ""
    var progress: Double = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pendingJS: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // 立刻把触摸交给网页，否则按钮要点得很稳才有反应
        webView.scrollView.delaysContentTouches = false
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in self?.progress = value }
            },
            webView.observe(\.title) { [weak self] view, _ in
                let value = view.title ?? ""
                Task { @MainActor in self?.title = value }
            },
        ]
    }

    func load(_ request: BrowserRequest) {
        webView.customUserAgent = request.userAgent
        pendingJS = request.js
        if let html = request.html, !html.isEmpty {
            webView.loadHTMLString(html, baseURL: URL(string: request.url))
        } else if let url = URL(string: request.url) {
            webView.load(URLRequest(url: url))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let js = pendingJS, !js.isEmpty else { return }
            pendingJS = nil
            _ = try? await webView.evaluateJavaScript(js)
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WebHostView { WebHostView(webView: webView) }
    func updateUIView(_ uiView: WebHostView, context: Context) {}
}

/// 把 WKWebView 铺满容器，并放开外层抽屉的拖动手势。
/// 抽屉默认会取消触摸，网页里的「获取验证码」因此收不到点击
final class WebHostView: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        WebSheetTouches.release(from: self, except: webView)
    }
}

enum WebSheetTouches {
    static func release(from root: UIView, except webView: WKWebView) {
        let scroll = webView.scrollView
        var view: UIView? = root
        var depth = 0
        while let current = view, depth < 8 {
            for gesture in current.gestureRecognizers ?? [] {
                let owner = gesture.view
                if owner === webView || owner === scroll || owner?.isDescendant(of: webView) == true { continue }
                gesture.cancelsTouchesInView = false
            }
            view = current.superview
            depth += 1
        }
    }
}

private struct CaptchaScreen: View {
    let imageURL: String
    let loadImage: (String) async -> UIImage?
    let onFinish: (String?) -> Void
    @State private var code = ""
    @State private var image: UIImage?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Text("输入验证码").font(.serif(22)).padding(.top, 24)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 220, maxHeight: 80)
            .onTapGesture { Task { await reload() } }
            TextField("验证码", text: $code)
                .font(.ui(18))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .frame(height: 48)
                .background(Tok.fill, in: Capsule())
                .padding(.horizontal, 40)
                .onSubmit { onFinish(code) }
            HStack(spacing: 12) {
                Button("取消") { onFinish(nil) }
                    .font(.ui(16, .medium))
                    .foregroundStyle(Tok.fg2)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Tok.fill, in: Capsule())
                AccentButton(title: "确定", icon: nil, wide: true) { onFinish(code) }
                    .disabled(code.isEmpty)
            }
            .padding(.horizontal, 24)
            Spacer()
        }
        .task {
            focused = true
            await reload()
        }
    }

    private func reload() async {
        image = await loadImage(imageURL)
    }
}
#endif
