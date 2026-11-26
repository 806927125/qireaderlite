import Foundation
import SwiftUI
import LegadoEngine

#if canImport(WebKit) && !os(Linux)
// ⭐⭐⭐⭐⭐ **轻阅的浏览器 / 验证码 呈现入口**（2026-11-21 移植柴阅的登录配套设施）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么需要它**：
//   柴阅的 `SourceUIDelegate` 要求宿主实现「浏览器 / 验证码 / toast / 复制 / 外链 / 视频」⭐⭐⭐
//   ⇒ 轻阅之前**没有实现** ⇒ 站方登录要开浏览器/要验证码时 ⇒ **静默失败** ⭐⭐⭐
//   ⇒ 聚合源的「🍅番茄登录 / 🔐注册书源 / 🏝用户后台」这些按钮**全是浏览器流程** ⭐⭐⭐
//     ⇒ 浏览器不工作 ⇒ 拿不到 token/cookie ⇒ **登录永远失败** ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **为什么用轻阅自己的 `BrowserSheet`（而不是柴阅的 WebViewRenderer）**：
//   · 轻阅的 `BrowserSheet` **已经写好**了（注释里就写着「书源的 java.startBrowser 用它」）⭐⭐⭐
//     但**一直没人调用** ⇒ 现在把它接上 ⭐⭐⭐
//   · 用户可见、可交互（地址栏/前进后退）⇒ 登录体验对 ⭐⭐⭐
//   · `html`/`js` 场景（站方直接给 HTML）⇒ 轻阅的 BrowserSheet 撑不住 ⇒ **交给柴阅的后台渲染** ⭐⭐⭐
//
// ⭐⭐⭐ **全局入口的必要性**：`SourceUIDelegate` 的方法在**引擎工作线程**上被调用
//   ⇒ 必须切到主线程 ⇒ 且 SwiftUI 的 `.sheet` 只能挂在 View 上 ⇒ ⇒ 需要一个**全局的 @MainActor 持有者** ⭐⭐⭐

// MARK: - 全局浏览器入口（App 根 View 用 `.sheet(item:)` 挂它）

/// ⭐⭐⭐⭐⭐ **全局浏览器入口**（引擎 → 主线程 → SwiftUI 的唯一桥梁）⭐⭐⭐
@MainActor
final class BrowserPresenter: ObservableObject {
    static let shared = BrowserPresenter()

    /// 当前要呈现的浏览器（`nil` = 没在呈现）
    @Published var item: BrowserItem?

    /// ⭐⭐⭐⭐⭐ **阅读器在场吗**（2026-11-27 真机「段评的浏览器要先回详情页才看得到」）⭐⭐⭐⭐⭐
    ///
    /// ⚠️⚠️⚠️ **为什么需要**（真机实证）⭐⭐⭐：
    ///   浏览器原本用 `.sheet(item:)` 挂在 **App 根 View** 上 ⇒ 而阅读器是 **`fullScreenCover`**
    ///   ⇒ ⇒ **fullScreenCover 的呈现层级高于根上的 sheet** ⇒ **浏览器被压在阅读器下面** ⭐⭐⭐
    ///   ⇒ ⇒ 用户看到的现象：「点段评 → 浏览器不见了 → 得先关掉阅读器回详情页才看得到」⭐⭐⭐
    ///   ⇒ 正解：**浏览器改挂在【阅读器那一层】**（柴阅原版就是「浏览器浮在阅读器之上」）⭐⭐⭐
    ///   ⇒ 本标志用来决定「这次浏览器由根 View 还是由阅读器承载」⭐⭐⭐
    @Published var readerPresented = false

    /// ⭐⭐⭐ 呈现一个浏览器页面；关闭时把 (html, url, cookie) 交回去 ⭐⭐⭐
    func present(url: String, title: String, onFinish: @escaping (String, String, String) -> Void) {
        // ⚠️ **阅读器在场 ⇒ 由阅读器承载**（否则会被阅读器盖住 ⇒ 看不见）⭐⭐⭐
        item = BrowserItem(url: url, title: title, onReader: readerPresented, onFinish: onFinish)
    }

    /// ⭐⭐⭐ **阅读器消失时**（用户直接关阅读器，浏览器还开着）⇒ 把浏览器收掉并**回调 nil** ⭐⭐⭐
    ///   ⚠️ 不回调 ⇒ 站方那边等的 `startBrowserAwait` 结果**永远不来** ⇒ 卡死 ⭐⭐⭐
    func dismissIfReading() {
        guard let item, item.onReader else { return }
        self.item = nil
        item.onFinish("", "", "")   // 空内容 ⇒ 调用方按「没有结果」处理 ⭐⭐⭐
    }
}

/// ⭐⭐⭐ **一次浏览器呈现**（`Identifiable` ⇒ `.sheet(item:)` 要用）
struct BrowserItem: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    /// ⭐⭐⭐⭐⭐ **这次浏览器该由【阅读器】承载吗**（2026-11-27）⭐⭐⭐⭐⭐
    ///   · `true`  ⇒ 阅读器在场 ⇒ 由**阅读器那层**的 `.sheet` 呈现（浮在阅读器之上）⭐⭐⭐
    ///   · `false` ⇒ 没有阅读器 ⇒ 由 **App 根 View** 的 `.sheet` 呈现（详情页/书架等场景）⭐⭐⭐
    let onReader: Bool
    /// 关闭时回传：页面 HTML / 当前 URL / cookie 串
    let onFinish: (String, String, String) -> Void
}

// MARK: - 柴阅的 `SourceInteractionPresenter` 实现

/// ⭐⭐⭐⭐⭐ **轻阅实现柴阅的 `SourceInteractionPresenter`**（2026-11-21 移植柴阅）⭐⭐⭐
///
/// ⇒ 柴阅的 `PlatformSourceUI`（= `SourceUIDelegate` 的完整实现）通过它把
///   「开浏览器 / 要验证码 / 复制 / 外链 / 视频」交给轻阅的 UI ⭐⭐⭐
@MainActor
final class ChaiyueInteractionPresenter: NSObject, LegadoEngineHost.InteractionPresenter {
    static let shared = ChaiyueInteractionPresenter()

    /// ⭐⭐⭐ **浏览器**（`java.startBrowser` / `startBrowserAwait` / `showBrowser`）⭐⭐⭐
    func presentBrowser(_ request: LegadoEngineHost.BrowserRequest,
                        completion: @escaping @MainActor @Sendable (LegadoEngineHost.BrowserResult?) -> Void) {
        // ⚠️⚠️ **html/js 场景 ⇒ 轻阅的 BrowserSheet 撑不住** ⇒ 交给**柴阅的后台渲染** ⭐⭐⭐
        //   （柴阅的 `WebViewRenderer` 支持 html/js ⇒ 返回渲染后的 HTML）⭐⭐⭐
        if let html = request.html, !html.isEmpty {
            Task { @MainActor in
                let rendered = ChaiyueRuntime.renderWebView(
                    html: html, url: request.url, js: request.js, sourceKey: request.sourceKey)
                completion(rendered.map { LegadoEngineHost.BrowserResult(url: request.url, body: $0) })
            }
            return
        }
        // ⭐⭐⭐ **URL 场景 ⇒ 弹轻阅自己的 `BrowserSheet`**（用户可见可交互）⭐⭐⭐
        BrowserPresenter.shared.present(url: request.url, title: request.title) { html, url, _ in
            // ⚠️⚠️ **`waitsForResult` ⇒ 站方在等结果 ⇒ 必须回 URL 与 HTML** ⭐⭐⭐
            //   （不等待时也给 URL，站方能用它做后续）⭐⭐⭐
            if request.waitsForResult {
                completion(LegadoEngineHost.BrowserResult(url: url, body: html))
            } else {
                completion(nil)
            }
        }
    }

    /// ⭐⭐⭐ **验证码**（`java.getVerificationCode`）⭐⭐⭐
    func presentVerificationCode(imageURL: String, sourceKey: String,
                                 completion: @escaping @MainActor @Sendable (String?) -> Void) {
        // ⚠️ 用系统弹窗（不新增 UI 页面 ⇒ 改动最小）⭐⭐⭐
        guard let url = URL(string: imageURL) else { completion(nil); return }
        let alert = UIAlertController(title: "请输入验证码", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "验证码"
            tf.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completion(alert.textFields?.first?.text ?? "")
        })
        // ⚠️⚠️ **要能显示验证码图片** ⇒ 提示里带上图片 URL（站方常见做法）⭐⭐⭐
        alert.message = imageURL
        ChaiyueRuntime.topPresenter?.present(alert, animated: true)
        _ = url
    }

    /// ⭐⭐⭐ **复制文本**（`java.copyText`）⭐⭐⭐
    func copyText(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// ⭐⭐⭐ **外部链接**（`java.openUrl` 的非网页 scheme）⭐⭐⭐
    func openExternalURL(_ url: URL) {
        UIApplication.shared.open(url)
    }

    /// ⭐⭐⭐ **视频播放器**（`java.openVideoPlayer`）⭐⭐⭐
    func presentVideoPlayer(url: String, title: String?, sourceKey: String) {
        guard let u = URL(string: url) else { return }
        UIApplication.shared.open(u)
    }
}
#endif
