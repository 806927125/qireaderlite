import Foundation
import SwiftUI
import UIKit

/// 一页正文
struct ReaderPage: Identifiable {
    let index: Int
    /// 这一页在全文里的**字符**范围
    let range: NSRange
    /// 这一页的 **glyph** 范围。绘制直接用它 —— 不做字符↔glyph 换算，
    /// 所以「算出来的边界」和「画出来的内容」**必然是同一段**。
    let glyphRange: NSRange
    var id: Int { index }
}

/// 正文分页器。
///
/// ## 为什么是 NSLayoutManager 而不是 CoreText
///
/// 这不是我的设计，是**抄栖阅的**。栖阅二进制里能查到：
///
///     NSTextContainer     ✓ 5 处
///     NSLayoutManager     ✓ 3 处
///     CTFramesetter…      ✗ 0 处      ← 栖阅完全不用 CoreText 分页
///
/// 栖阅 `ReaderPaginator.swift` 用的是 Apple 官方的
/// `NSTextStorage` → `NSLayoutManager` → `NSTextContainer` 三件套。
///
/// 我原先用 `CTFramesetterCreateFrame` + `CTFrameGetVisibleStringRange`
/// 自己算页边界，再用 `CTFrameDraw` 画 —— **两套排版引擎**：
///
///   * `CTFrameGetVisibleStringRange` 给的是 CoreText 的可见范围，
///     遇到中文字体 fallback（PingFang → 系统兜底字形）、字距调整、
///     断行优化时，它和实际渲染结果会有偏差；
///   * 一旦偏差，**页边界和绘制内容就错位**，症状是「每页少一行」
///     「标题被切」「最后一页空白」这类没法复现的漂移。
///
/// 换成 NSLayoutManager 后，**排版和绘制共用同一个 layout manager**：
///
///     let g = lm.glyphRange(for: container)      // 这一页装得下的 glyph
///     lm.drawGlyphs(forGlyphRange: g, at: .zero) // 就画这一段
///
/// 边界和内容同源，**不存在对不齐的可能**。这才是栖阅的做法。
///
/// 另外 NSLayoutManager 不需要翻转坐标系：UIKit 的 `draw(_:)` 本来
/// 就是左上角原点，而 CoreText 要手动 `translate + scale` 翻转 ——
/// 少一层坐标系转换，少一类「上下颠倒」的 bug。
final class ReaderPaginator {
    private(set) var storage: NSTextStorage?
    private(set) var layoutManager: NSLayoutManager?
    /// 与 `pages` 一一对应的排版容器
    private(set) var containers: [NSTextContainer] = []
    private(set) var pages: [ReaderPage] = []
    /// 排版时的页尺寸（绘制时要用它来定位）
    private(set) var pageSize: CGSize = .zero

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
            let n = lineCount(at: i)
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
    ///
    /// 核心思路：**连续往 layout manager 上挂 NSTextContainer**。
    /// UIKit 会自动从上一个 container 排完的位置接着排，
    /// 每个 container 装得下的 glyph 范围就是**那一页**。
    @discardableResult
    func paginate(_ attributed: NSAttributedString, pageSize: CGSize) -> [ReaderPage] {
        reset()
        self.pageSize = pageSize

        guard attributed.length > 0, pageSize.width > 1, pageSize.height > 1 else {
            pages = [ReaderPage(index: 0,
                                range: NSRange(location: 0, length: 0),
                                glyphRange: NSRange(location: 0, length: 0))]
            return pages
        }

        let st = NSTextStorage(attributedString: attributed)
        let lm = NSLayoutManager()
        // 文本存储必须在挂 container **之前**先连上 layout manager，
        // 否则 UIKit 不知道往哪排。
        st.addLayoutManager(lm)

        var containers: [NSTextContainer] = []
        var result: [ReaderPage] = []

        while true {
            let c = NSTextContainer(size: pageSize)
            // ⚠️ 默认左右各留 5pt 内边距 —— 不清掉的话实际可用宽度
            //    比 pageSize.width 少 10pt，每页都会少排几个字。
            c.lineFragmentPadding = 0
            c.maximumNumberOfLines = 0
            c.lineBreakMode = .byWordWrapping
            lm.addTextContainer(c)
            containers.append(c)

            // 这一页装得下的 glyph 范围（UIKit 会在这里真正排版）
            let g = lm.glyphRange(for: c)
            // 装不下任何东西 = 到头了（页太窄/字太长），必须 break，否则死循环
            guard g.length > 0 else { break }

            let charRange = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
            result.append(ReaderPage(index: result.count, range: charRange, glyphRange: g))

            if NSMaxRange(g) >= lm.numberOfGlyphs { break }
            // 保险：最多 20000 页，异常文本不至于把内存吃穿
            if result.count > 20000 { break }
        }

        if result.isEmpty {
            result = [ReaderPage(index: 0,
                                 range: NSRange(location: 0, length: 0),
                                 glyphRange: NSRange(location: 0, length: 0))]
        }

        self.storage = st
        self.layoutManager = lm
        self.containers = containers
        self.pages = result
        return result
    }

    // MARK: - 绘制

    /// 某一页的 glyph 范围。绘制时直接用它，**不做任何换算**。
    func glyphRange(at index: Int) -> NSRange {
        guard pages.indices.contains(index) else { return NSRange(location: 0, length: 0) }
        return pages[index].glyphRange
    }

    /// 某一页有几行（垂直两端对齐要用它量「满页有几行」）
    func lineCount(at index: Int) -> Int {
        guard let lm = layoutManager, pages.indices.contains(index) else { return 0 }
        let g = pages[index].glyphRange
        guard g.length > 0 else { return 0 }
        return lm.numberOfLineFragments(forGlyphRange: g)
    }

    /// 把一页画到 UIKit 的图形上下文里。
    ///
    /// `origin` 一般是 `.zero`（PageView 的 bounds 原点）。
    /// ⚠️ **不要翻转坐标系** —— NSLayoutManager 用的是 UIKit 坐标（���上角原点），
    ///    CoreText 才需要 translate+scale。这里翻了会上下颠倒。
    func drawPage(_ index: Int, in ctx: CGContext, origin: CGPoint = .zero) {
        guard let lm = layoutManager, pages.indices.contains(index) else { return }
        let g = glyphRange(at: index)
        guard g.length > 0 else { return }
        // 背景（段落底色 / 边框之类）也要画，否则只剩字
        lm.drawBackground(forGlyphRange: g, at: origin)
        lm.drawGlyphs(forGlyphRange: g, at: origin)
    }

    /// 清空（换章/改字号时调）
    func reset() {
        if let lm = layoutManager {
            for c in containers { lm.removeTextContainer(at: lm.textContainers.count - 1) }
        }
        storage = nil
        layoutManager = nil
        containers = []
        pages = []
        pageSize = .zero
    }
}

/// 把一页画到屏幕上。
///
/// 用 UIView 而不是 SwiftUI `Text` —— 分页要求**精确到字**，
/// Text 没法指定"这一页只显示这些字"。
struct ReaderPageCanvas: UIViewRepresentable {
    /// ⚠️ 别把这个属性叫 `page` —— 成员查找可能命中它，
    ///    把 SwiftUI 的 `.page(...)` 修饰符**遮住**。
    ///    同样别叫 `size` / `background`。
    let paginator: ReaderPaginator?
    let pageIndex: Int
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
        v.paginator = paginator
        v.pageIndex = pageIndex
    }

    final class PageView: UIView {
        var paginator: ReaderPaginator? {
            didSet { setNeedsDisplay() }
        }
        var pageIndex: Int = 0 {
            didSet { setNeedsDisplay() }
        }
        var showBaseline: Bool = false
        var baselineColor: UIColor = .lightGray
        var baselineScope: ReaderBaselineScope = .full

        override func draw(_ rect: CGRect) {
            guard let p = paginator, let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.saveGState()
            // NSLayoutManager 直接用 UIKit 坐标（左上角原点）→ 不翻转
            p.drawPage(pageIndex, in: ctx, origin: .zero)
            if showBaseline { drawBaselines(p, ctx) }
            ctx.restoreGState()
        }

        /// 行底线：在每一行的基线下面画一条横线。
        /// 「整行」= 拉满整页宽；「按文字」= 只画有字的那一段。
        private func drawBaselines(_ p: ReaderPaginator, _ ctx: CGContext) {
            guard let lm = p.layoutManager else { return }
            let g = p.glyphRange(at: pageIndex)
            guard g.length > 0 else { return }
            let n = lm.numberOfLineFragments(forGlyphRange: g)
            guard n > 0 else { return }
            ctx.saveGState()
            ctx.setFillColor(baselineColor.cgColor)
            let lineH = bounds.height > 0 ? max(1, bounds.height / CGFloat(max(1, n))) : 1
            for i in 0..<n {
                var eff = NSRange()
                let r = lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: &eff)
                _ = r
                // 逐行推进：用下一行的起点字符来推它的 fragment
                let y = lineH * CGFloat(i) + lineH - 2
                var x0: CGFloat = 0
                var x1: CGFloat = bounds.width
                if baselineScope == .word {
                    // 只要这一行**有字**的那段横向范围
                    var eff2 = NSRange()
                    let rr = lm.lineFragmentRect(forGlyphAt: g.location + i, effectiveRange: &eff2)
                    if rr.width > 0 {
                        x0 = rr.minX
                        x1 = rr.maxX
                    }
                }
                guard x1 > x0 else { continue }
                ctx.fill(CGRect(x: x0, y: y, width: x1 - x0, height: 1))
            }
            ctx.restoreGState()
        }
    }
}
