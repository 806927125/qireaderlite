#if canImport(UIKit)
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

    func presentBrowser(_ request: BrowserRequest, completion: @escaping @MainActor (BrowserResult?) -> Void) {
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

    func presentVerificationCode(imageURL: String, sourceKey: String, completion: @escaping @MainActor (String?) -> Void) {
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
#endif
