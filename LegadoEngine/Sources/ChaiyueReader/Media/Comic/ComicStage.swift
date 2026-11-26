#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/Comic/ComicStage.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/Comic/ComicStage.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import SwiftUI
import UIKit

extension UIColor {
    static let comicBg = UIColor.dynamic(light: UIColor(hex: 0xF7F4EF), dark: UIColor(hex: 0x0D0E18))
    static let comicHolder = UIColor.dynamic(light: UIColor(hex: 0x14142B, alpha: 0.05), dark: UIColor(white: 1, alpha: 0.04))
    static let comicInk = UIColor.dynamic(light: UIColor(hex: 0x14142B, alpha: 0.42), dark: UIColor(hex: 0xF5F2EC, alpha: 0.42))
}

/// 条漫与翻页的共同基类：左边缘右滑返回、轻点呼出菜单
class ComicStageController: UIViewController, UIGestureRecognizerDelegate {
    let model: ComicModel
    var onCenterTap: (() -> Void)?
    var onEdgeDrag: ((CGFloat) -> Void)?
    /// 结束时的位移与速度；取消时速度为负
    var onEdgeEnd: ((CGFloat, CGFloat) -> Void)?
    let edge = UIScreenEdgePanGestureRecognizer()

    init(model: ComicModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .comicBg
        view.clipsToBounds = true
        edge.edges = .left
        edge.delegate = self
        edge.addTarget(self, action: #selector(handleEdge(_:)))
        view.addGestureRecognizer(edge)
    }

    /// 放大后没贴着左边时左边缘拖动交给内容平移
    var edgeAllowed: Bool { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === edge { return edgeAllowed }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    func hideMenu() {
        guard model.menuVisible else { return }
        withAnimation(.easeIn(duration: 0.2)) { model.menuVisible = false }
    }

    @objc private func handleEdge(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        // 整个页面跟着手指移动，位移按窗口坐标算才不会抖
        let dx = max(0, recognizer.translation(in: nil).x)
        switch recognizer.state {
        case .began, .changed:
            onEdgeDrag?(dx)
        case .ended:
            onEdgeEnd?(dx, recognizer.velocity(in: nil).x)
        case .cancelled, .failed:
            onEdgeEnd?(dx, -1)
        default:
            break
        }
    }
}

struct ComicStage: UIViewControllerRepresentable {
    let model: ComicModel
    let mode: ComicMode
    let onCenterTap: () -> Void
    let onEdgeDrag: (CGFloat) -> Void
    let onEdgeEnd: (CGFloat, CGFloat) -> Void

    func makeUIViewController(context: Context) -> ComicStageController {
        let controller: ComicStageController = mode == .strip ? ComicStripController(model: model) : ComicPagerController(model: model)
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: ComicStageController, context: Context) {
        controller.onCenterTap = onCenterTap
        controller.onEdgeDrag = onEdgeDrag
        controller.onEdgeEnd = onEdgeEnd
    }
}

// MARK: - 格子

/// 一张图：未到时是同比例占位，失败时可点重试
final class ComicTileView: UIView {
    let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    var onRetry: (() -> Void)?
    private(set) var page: ComicPage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)
        spinner.color = .comicInk
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        retryButton.setImage(UIImage.icon("arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        retryButton.tintColor = .comicInk
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        addSubview(retryButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        // 很高的格子里指示放在首屏能看到的位置
        let y = min(bounds.midY, 180)
        spinner.center = CGPoint(x: bounds.midX, y: y)
        retryButton.frame = CGRect(x: bounds.midX - 30, y: y - 30, width: 60, height: 60)
    }

    func show(_ page: ComicPage, image: UIImage?, failed: Bool) {
        let fresh = self.page == page && imageView.image == nil && image != nil
        self.page = page
        if fresh {
            UIView.transition(with: imageView, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.imageView.image = image
            }
        } else {
            imageView.image = image
        }
        backgroundColor = image == nil ? .comicHolder : .clear
        retryButton.isHidden = image != nil || !failed
        if image == nil && !failed { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}

/// 相邻章节加载中或加载失败
final class ComicStatusView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let button = UIButton(type: .system)
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = .comicInk
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = .comicInk
        label.numberOfLines = 4
        label.textAlignment = .center
        addSubview(label)
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(Tok.accent)
        config.baseForegroundColor = UIColor(Tok.onAccent)
        config.attributedTitle = AttributedString("重试", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 28)
        button.configuration = config
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: ComicChapter?) {
        if case .failed(let message) = state {
            spinner.stopAnimating()
            label.text = message
            label.isHidden = false
            button.isHidden = false
        } else {
            spinner.startAnimating()
            label.isHidden = true
            button.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = label.sizeThatFits(CGSize(width: bounds.width - 80, height: 200))
        let buttonSize = button.sizeThatFits(.zero)
        let total = size.height + 16 + buttonSize.height
        var y = bounds.midY - total / 2
        label.frame = CGRect(x: 40, y: y, width: bounds.width - 80, height: size.height)
        y += size.height + 16
        button.frame = CGRect(x: bounds.midX - buttonSize.width / 2, y: y, width: buttonSize.width, height: buttonSize.height)
    }
}

#endif  // #if os(iOS)
