import CoreText
import Foundation
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
    let frame: CTFrame?
    let size: CGSize
    let background: UIColor

    func makeUIView(context: Context) -> PageView {
        let v = PageView()
        v.backgroundColor = background
        v.isOpaque = true
        v.contentMode = .redraw
        return v
    }

    func updateUIView(_ v: PageView, context: Context) {
        v.backgroundColor = background
        v.ctFrame = frame
    }

    final class PageView: UIView {
        var ctFrame: CTFrame? {
            didSet { setNeedsDisplay() }
        }

        override func draw(_ rect: CGRect) {
            guard let cf = ctFrame, let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.saveGState()
            // CoreText 用左下角原点，UIKit 的图形上下文是左上角原点 → 翻转
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            CTFrameDraw(cf, ctx)
            ctx.restoreGState()
        }
    }
}
