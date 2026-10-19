import CoreText
import Foundation
import SwiftUI
import UIKit

/// 一页正文
struct ReaderPage: Identifiable {
    let index: Int
    /// 这一页在全文里的字符范围
    let range: NSRange
    var id: Int { index }
}

/// 正文分页器。
///
/// 抄的是栖阅 `ReaderPaginator.swift` 的路子：用 CoreText 的 CTFramesetter
/// 把整章排成 N 个页框，每页记一个字符范围，翻页就是切页号。
///
/// 不用 CSS 多列 —— 那个在 WKWebView 里没法验证，而且拿不到精确字范围，
/// 翻页位置对不齐。CoreText 这条路页边界是确定的。
final class ReaderPaginator {
    private var framesetter: CTFramesetter?
    private var frameCache: [Int: CTFrame] = [:]
    private var cacheKey: String = ""

    private(set) var pages: [ReaderPage] = []

    /// 排版 + 垂直两端对齐。
    ///
    /// 栖阅的说法：「开启后每页文字会自动调整行间距以填满页面，使底部对齐整齐」。
    /// 做法：先按基准行距排一遍，量出**满页**那页有几行，
    /// 再把行距调成「行高正好填满一页」，重排一次。
    /// 最后一行（不满的那页）不参与计算。
    @discardableResult
    func paginateJustified(_ attributed: NSAttributedString,
                            pageSize: CGSize,
                            config: ReaderLayoutConfig) -> [ReaderPage] {
        var pages = paginate(attributed, pageSize: pageSize)
        guard config.verticalJustify, pages.count > 1 else { return pages }

        // 找一页"排得比较满"的（取前几页里行数最多的那个）
        var bestLines = 0
        for i in 0..<min(pages.count, 3) {
            guard let f = frame(at: i, pageSize: pageSize) else { continue }
            let n = (CTFrameGetLines(f) as NSArray).count
            if n > bestLines { bestLines = n }
        }
        guard bestLines > 1 else { return pages }

        // 让 bestLines 行正好填满一页
        let fontLineHeight = config.resolvedFont.lineHeight
        let target = pageSize.height / CGFloat(bestLines)
        let wanted = max(0, target - fontLineHeight)
        guard abs(wanted - config.lineSpacing) > 0.5 else { return pages }

        var tuned = config
        tuned.lineSpacing = wanted
        // ⚠️ 不能拿 attributed.string 重新造 —— 那样标题的样式就丢了。
        //    直接改正文那段 attributed 的行距。
        let tunedAttr = NSMutableAttributedString(attributedString: attributed)
        let full = attributed.length
        if full > 0 {
            let ps = tuned.paragraphStyle()
            tunedAttr.addAttribute(.paragraphStyle,
                                   value: ps,
                                   range: NSRange(location: 0, length: full))
        }
        pages = paginate(tunedAttr, pageSize: pageSize)
        return pages
    }

    /// 排版。返回页列表。
    @discardableResult
    func paginate(_ attributed: NSAttributedString, pageSize: CGSize) -> [ReaderPage] {
        pages = []
        frameCache.removeAll()
        framesetter = CTFramesetterCreateWithAttributedString(attributed)

        guard let fs = framesetter, attributed.length > 0, pageSize.width > 1 else {
            pages = [ReaderPage(index: 0, range: NSRange(location: 0, length: 0))]
            return pages
        }

        var start = 0
        var index = 0
        // 每次问 framesetter："从这个位置开始，能装进这一页多少字？"
        // 它给的 visibleRange 就是这一页真正的边界。
        while start < attributed.length {
            let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            // 装不下一个字 = 到头了（可能是字太长/页太窄），必须 break，
            // 否则会死循环。
            guard visible.length > 0 else { break }
            pages.append(ReaderPage(index: index,
                                    range: NSRange(location: start, length: visible.length)))
            index += 1
            start += visible.length
            // 保险：最多 20000 页，异常文本不至于把内存吃穿
            if index > 20000 { break }
        }

        if pages.isEmpty {
            pages = [ReaderPage(index: 0, range: NSRange(location: 0, length: 0))]
        }
        return pages
    }

    /// 某一页的页框（用来画）。带缓存，重复取不会重新排。
    func frame(at index: Int, pageSize: CGSize) -> CTFrame? {
        guard let fs = framesetter, pages.indices.contains(index) else { return nil }
        let key = "\(Int(pageSize.width))x\(Int(pageSize.height))"
        if cacheKey != key {
            frameCache.removeAll()
            cacheKey = key
        }
        if let cached = frameCache[index] { return cached }
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        let range = pages[index].range
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: range.location, length: range.length),
                                             path, nil)
        frameCache[index] = frame
        return frame
    }

    /// 一次性工具：给一段 attributed，直接拿到第 index 页的帧。
    ///
    /// 供「全书页平铺」的分页器用 —— 那边每翻一页就要渲染一页，
    /// 用这个比"建 paginator → 排整章 → 取帧"干净，也不会把状态留在实例里。
    static func oneOffFrame(at index: Int, pageSize: CGSize,
                            attributed: NSAttributedString) -> CTFrame? {
        guard pageSize.width > 1, pageSize.height > 1 else { return nil }
        let fs = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        var start = 0
        let len = attributed.length
        for _ in 0..<max(1, index) {
            let frame = CTFramesetterCreateFrame(fs, CFRangeMake(start, 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { return nil }
            start += visible.length
            if start >= len { return nil }
        }
        let frame = CTFramesetterCreateFrame(fs, CFRangeMake(start, 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        return visible.length > 0 ? frame : nil
    }

    /// 清缓存（换章/改字号时调）
    func reset() {
        framesetter = nil
        frameCache.removeAll()
        cacheKey = ""
        pages = []
    }
}

/// 把一页 CTFrame 画到屏幕上。
///
/// 用 UIView 而不是 SwiftUI `Text` —— 分页要求**精确到字**，
/// Text 没法指定"这一页只显示这些字"。
struct ReaderPageCanvas: UIViewRepresentable {
    /// ⚠️ 别把这个属性叫 `frame` —— 成员查找会先命中它，
    ///    把 SwiftUI 的 `.frame(width:height:)` 修饰符**遮住**，
    ///    编译报 "cannot call value of non-function type 'CTFrame?'"。
    let ctFrame: CTFrame?
    /// ⚠️ 别叫 `size` / `background` —— 那是 View 的修饰符名，
    ///    成员查找会先命中属性，把 `.size()` / `.background()` 遮住。
    let pageSize: CGSize
    let bgColor: UIColor
    /// 行底线（栖阅：开启后会在正文每一行底部绘制整行横线）
    var showBaseline: Bool = false
    var baselineColor: UIColor = .lightGray
    var baselineScope: ReaderBaselineScope = .full

    func makeUIView(context: Context) -> PageView {
        let v = PageView()
        v.backgroundColor = bgColor
        v.isOpaque = true
        v.contentMode = .redraw
        return v
    }

    func updateUIView(_ v: PageView, context: Context) {
        v.backgroundColor = bgColor
        v.showBaseline = showBaseline
        v.baselineColor = baselineColor
        v.baselineScope = baselineScope
        v.ctFrame = ctFrame
    }

    final class PageView: UIView {
        var ctFrame: CTFrame? {
            didSet { setNeedsDisplay() }
        }
        var showBaseline: Bool = false
        var baselineColor: UIColor = .lightGray
        var baselineScope: ReaderBaselineScope = .full

        override func draw(_ rect: CGRect) {
            guard let cf = ctFrame, let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.saveGState()
            // CoreText 用左下角原点，UIKit 的图形上下文是左上角原点 → 翻转
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            CTFrameDraw(cf, ctx)
            if showBaseline { drawBaselines(cf, ctx) }
            ctx.restoreGState()
        }

        /// 行底线：在每一行的基线下面画一条横线。
        /// 「整行」= 拉满整页宽；「按文字」= 只画有字的那一段。
        private func drawBaselines(_ cf: CTFrame, _ ctx: CGContext) {
            let lines = CTFrameGetLines(cf)
            let count = CFArrayGetCount(lines)
            guard count > 0 else { return }
            var origins = [CGPoint](repeating: .zero, count: count)
            CTFrameGetLineOrigins(cf, CFRange(location: 0, length: 0), &origins)
            ctx.saveGState()
            ctx.setFillColor(baselineColor.cgColor)
            for i in 0..<count {
                // ⚠️ 别写 `obj as? CTLine` —— 对 CoreFoundation 类型做条件转换
                //    编译期就报 "conditional downcast ... will always succeed"。
                //    用 CFArray 取裸指针再 unsafeBitCast。
                guard let raw = CFArrayGetValueAtIndex(lines, i) else { continue }
                let line = unsafeBitCast(raw, to: CTLine.self)
                let y = origins[i].y
                var x0: CGFloat = 0
                var x1: CGFloat = bounds.width
                if baselineScope == .word {
                    // 只要这一行**有字**的那段横向范围。
                    // ⚠️ 别用 CTLineGetOffsetForIndex —— iOS SDK 里没这个符号，编译不过。
                    let b = CTLineGetImageBounds(line, nil)
                    if b.width > 0 {
                        x0 = b.minX
                        x1 = b.maxX
                    }
                }
                guard x1 > x0 else { continue }
                // 压在基线下面一点（翻转后的坐标系 y 向上，所以要减）
                ctx.fill(CGRect(x: x0, y: y - 2, width: x1 - x0, height: 1))
            }
            ctx.restoreGState()
        }
    }
}
