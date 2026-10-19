import CoreText
import SwiftUI
import UIKit

// MARK: - 一页正文

/// 一个 ViewController = 一页正文。
///
/// 跟老实现最大的区别：老的是「SwiftUI 里手写拖拽 + 手写 offset 动画 +
/// 手写章界判断」，三层各自出状态、互相打架。跨章卡死就是打出来的。
/// 现在容器交给 UIPageViewController —— 手势、边界、预取、动画全由系统负责，
/// 这里只管「这一页画什么」。
final class ReaderPageVC: UIViewController {

    enum Kind {
        case page          // 章内第 index 页
        case loading       // 章末/章首的加载占位
        case failed(String) // 换章失败
    }

    let kind: Kind
    private let canvas: ReaderPageCanvasView
    /// 失败页的两个出口：只报错不给路等于把用户堵死
    var onRetry: (() -> Void)?
    var onStepBack: (() -> Void)?
    /// 0 起。系统分页容器只认这个来定位。
    var slot: Int = 0 {
        didSet { view.tag = slot }
    }

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .page:
            canvas = ReaderPageCanvasView()
        case .loading:
            canvas = ReaderPageCanvasView()
        case .failed:
            canvas = ReaderPageCanvasView()
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(canvas)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        applyKind()
    }

    func applyKind() {
        switch kind {
        case .page:
            canvas.configure(kind: .text, message: nil)
            canvas.isHidden = false
        case .loading:
            canvas.configure(kind: .spinner, message: "正在加载下一章…")
            canvas.isHidden = false
        case .failed(let msg):
            canvas.configure(kind: .message, message: msg,
                            onRetry: { [weak self] in self?.onRetry?() },
                            onStepBack: { [weak self] in self?.onStepBack?() })
            canvas.isHidden = false
        }
    }

    /// 把一页的 CTFrame 装上去
    func setPage(frame: CTFrame?, pageSize: CGSize,
                 bg: UIColor, baseline: Bool, baselineColor: UIColor,
                 scope: ReaderBaselineScope) {
        guard case .page = kind else { return }
        canvas.configure(kind: .text, message: nil)
        canvas.setFrame(frame, pageSize: pageSize, background: bg,
                        showBaseline: baseline, baselineColor: baselineColor, scope: scope)
    }

    func setBackground(_ bg: UIColor) {
        canvas.backgroundColor = bg
    }
}

// MARK: - 页画布

/// 把一页 CTFrame 画到屏幕上。
///
/// 用 UIView 而不是 SwiftUI `Text` —— 分页要求**精确到字**，
/// Text 没法指定"这一页只显示这些字"。
final class ReaderPageCanvasView: UIView {

    enum Content {
        case text
        case spinner
        case message(String)
    }

    private var ctFrame: CTFrame?
    private var pageSize: CGSize = .zero
    private var baseline: Bool = false
    private var baselineColor: UIColor = .lightGray
    private var scope: ReaderBaselineScope = .full
    private var content: Content = .text

    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private let retryBtn = UIButton(type: .system)
    private let backBtn = UIButton(type: .system)
    private var retryAction: (() -> Void)?
    private var backAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.numberOfLines = 6
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        label.numberOfLines = 6
        retryBtn.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retryBtn.setTitle("重试", for: .normal)
        backBtn.titleLabel?.font = .preferredFont(forTextStyle: .body)
        backBtn.setTitle("回上一章", for: .normal)
        backBtn.setTitleColor(.secondaryLabel, for: .normal)
        for b in [retryBtn, backBtn] {
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
        }

        addSubview(spinner)
        addSubview(label)
        let stack = UIStackView(arrangedSubviews: [retryBtn, backBtn])
        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: centerYAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(kind: Content, message: String?,
                   onRetry: (() -> Void)? = nil,
                   onStepBack: (() -> Void)? = nil) {
        content = kind
        switch kind {
        case .text:
            spinner.stopAnimating()
            label.text = nil
            label.isHidden = true
            retryBtn.isHidden = true
            backBtn.isHidden = true
        case .spinner:
            spinner.startAnimating()
            label.text = message
            label.isHidden = false
            retryBtn.isHidden = true
            backBtn.isHidden = true
        case .message(let m):
            spinner.stopAnimating()
            label.text = m
            label.isHidden = false
            retryBtn.isHidden = false
            backBtn.isHidden = false
            retryBtn.removeTarget(nil, action: nil, for: .allEvents)
            backBtn.removeTarget(nil, action: nil, for: .allEvents)
            retryAction = onRetry
            backAction = onStepBack
            retryBtn.isEnabled = onRetry != nil
            backBtn.isEnabled = onStepBack != nil
            if onRetry != nil {
                retryBtn.addTarget(self, action: #selector(tapRetry), for: .touchUpInside)
            }
            if onStepBack != nil {
                backBtn.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
            }
        }
        setNeedsDisplay()
    }

    @objc private func tapRetry() { retryAction?() }
    @objc private func tapBack() { backAction?() }

    func setFrame(_ f: CTFrame?, pageSize: CGSize, background: UIColor,
                  showBaseline: Bool, baselineColor: UIColor, scope: ReaderBaselineScope) {
        ctFrame = f
        self.pageSize = pageSize
        self.baseline = showBaseline
        self.baselineColor = baselineColor
        self.scope = scope
        backgroundColor = background
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let frame = ctFrame, contentIsText else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        if baseline {
            drawBaselines(in: frame, ctx: ctx)
        }
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private var contentIsText: Bool {
        if case .text = content { return true }
        return false
    }

    /// 行底线：栖阅「开启后会在正文每一行底部绘制整行横线」
    /// 支持「整行 / 按文字」两种范围。
    private func drawBaselines(in frame: CTFrame, ctx: CGContext) {
        // ⚠️ 新 SDK 的 CTFrameGetPath 返回**非可选** CGPath，旧的 `!` 会报
        //    "cannot force unwrap value of non-optional type 'CGPath'"
        let path = CTFrameGetPath(frame)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setStrokeColor(baselineColor.cgColor)
        ctx.setLineWidth(max(1.0, 1.0 / (UIScreen.main.scale)))
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        guard count > 0 else { ctx.restoreGState(); return }
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
        for i in 0..<count {
            // CFArrayGetValueAtIndex 拿的是 UnsafeRawPointer，
            // 直接 let 会推成 Optional 再重名 —— 分两步写
            guard let raw = CFArrayGetValueAtIndex(lines, i) else { continue }
            let line = unsafeBitCast(raw, to: CTLine.self)
            let r = CTLineGetImageBounds(line, origins[i])
            // CTLineGetTypographicBounds 返回 Double，CGFloat 减 Double 要显式转
            let desc = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let baselineY = origins[i].y - desc
            var x0: CGFloat, x1: CGFloat
            switch scope {
            case .full:
                x0 = 0
                x1 = pageSize.width
            case .word:          // 栖阅叫「按文字」，枚举里是 .word 不是 .text
                x0 = CGFloat(r.origin.x)
                x1 = CGFloat(r.origin.x + r.width)
            }
            ctx.move(to: CGPoint(x: x0, y: baselineY))
            ctx.addLine(to: CGPoint(x: x1, y: baselineY))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
