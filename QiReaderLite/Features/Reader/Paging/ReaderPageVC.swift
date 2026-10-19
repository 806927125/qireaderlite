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
    var background: UIColor = .systemBackground { didSet { canvas.backgroundColor = background } }
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
            canvas.configure(kind: .failure(msg), message: msg,
                            onRetry: { [weak self] in self?.onRetry?() },
                            onStepBack: { [weak self] in self?.onStepBack?() })
            canvas.isHidden = false
        }
    }

    /// 把一页装上去。
    ///
    /// 传 **paginator + 页号**，不是传一个画好的 frame ——
    /// 分页和绘制必须共用同一个 layout manager（见 ReaderPaginator 顶部说明），
    /// 否则边界和内容会漂。paginator 可以是 nil（页装不下），那是空页。
    func setPage(paginator: ReaderPaginator?, page: Int,
                 bg: UIColor, baseline: Bool, baselineColor: UIColor,
                 scope: ReaderBaselineScope) {
        guard case .page = kind else { return }
        canvas.configure(kind: .text, message: nil)
        canvas.setPage(paginator: paginator, page: page, background: bg,
                       showBaseline: baseline, baselineColor: baselineColor, scope: scope)
    }

    func setBackground(_ bg: UIColor) {
        background = bg
    }

    /// 加载完事后改成失败（重试 / 回上一章）
    func showFailure(_ msg: String, retry: @escaping () -> Void, stepBack: @escaping () -> Void) {
        canvas.configure(kind: .failure(msg), message: msg,
                         onRetry: { [weak self] in self?.onRetry = retry; retry() },
                         onStepBack: { [weak self] in self?.onStepBack = stepBack; stepBack() })
    }
}

// MARK: - 页画布

/// 把一页画到屏幕上。
///
/// 用 UIView 而不是 SwiftUI `Text` —— 分页要求**精确到字**，
/// Text 没法指定"这一页只显示这些字"。
final class ReaderPageCanvasView: UIView {

    enum Content {
        case text
        case spinner
        /// 命名参数也叫 message 时，`kind: .message` 会推不出类型
        /// （报 "member 'message' expects argument of type 'String'"）→ 改名
        case failure(String)
    }

    /// 分页 + 绘制共用它（不要拆成两个对象）
    private var paginator: ReaderPaginator?
    private var pageIndex: Int = 0
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
        case .failure(let m):
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

    func setPage(paginator: ReaderPaginator?, page: Int, background: UIColor,
                 showBaseline: Bool, baselineColor: UIColor, scope: ReaderBaselineScope) {
        self.paginator = paginator
        self.pageIndex = page
        self.pageSize = paginator?.pageSize ?? .zero
        self.baseline = showBaseline
        self.baselineColor = baselineColor
        self.scope = scope
        backgroundColor = background
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let p = paginator, contentIsText else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        // NSLayoutManager 用 UIKit 坐标（左上角原点）→ **不要翻转**。
        // CoreText 那套 translate+scale 在这里是反的，会上下颠倒。
        if baseline { drawBaselines(p, ctx) }
        p.drawPage(pageIndex, in: ctx, origin: .zero)
        ctx.restoreGState()
    }

    private var contentIsText: Bool {
        if case .text = content { return true }
        return false
    }

    /// 行底线：栖阅「开启后会在正文每一行底部绘制整行横线」
    /// 支持「整行 / 按文字」两种范围。
    ///
    /// 用 `NSLayoutManager.numberOfLineFragments(forGlyphRange:)` 数行、
    /// `usedRect(for:)` 量实际排版高度，两者都取自**同一个** layout manager，
    /// 所以线一定贴在真正的行下面（CoreText 时代要手动算基线偏移，
    /// 字体 fallback 一换就错位）。
    private func drawBaselines(_ p: ReaderPaginator, _ ctx: CGContext) {
        guard let lm = p.layoutManager else { return }
        let g = p.glyphRange(at: pageIndex)
        guard g.length > 0 else { return }
        let n = lm.numberOfLineFragments(forGlyphRange: g)
        guard n > 0 else { return }
        // ⚠️ `textContainer(forGlyphAt:)` 返回**可选** NSTextContainer，
        //    而 `usedRect(for:)` 要非可选 → 直接内传会编译报
        //    "value of optional type 'NSTextContainer?' must be unwrapped"。
        //    拿到的是页面**第一个** container，用它的 usedRect 量整页排版高度。
        guard let pageContainer = lm.textContainer(forGlyphAt: g.location, effectiveRange: nil)
        else { return }
        let used = lm.usedRect(for: pageContainer)
        guard used.height > 0 else { return }
        let lineH = used.height / CGFloat(n)
        ctx.saveGState()
        ctx.setFillColor(baselineColor.cgColor)
        for i in 0..<n {
            let y = lineH * CGFloat(i + 1) - 1
            var x0: CGFloat = 0
            var x1: CGFloat = (pageSize.width > 1 ? pageSize.width : bounds.width)
            // ⚠️ ReaderBaselineScope 是 **struct** 不是 enum，
            //    对它 switch 要求穷尽 → 编译报 "switch must be exhaustive"。
            //    改用 == 比较（它本来就 Hashable/Equatable）。
            if scope != .full {          // 栖阅叫「按文字」，枚举里是 .word 不是 .text
                var eff = NSRange()
                let r = lm.lineFragmentRect(forGlyphAt: g.location + i, effectiveRange: &eff)
                if r.width > 0 {
                    x0 = r.minX
                    x1 = r.maxX
                }
            }
            guard x1 > x0 else { continue }
            ctx.fill(CGRect(x: x0, y: y, width: x1 - x0, height: 1))
        }
        ctx.restoreGState()
    }
}
