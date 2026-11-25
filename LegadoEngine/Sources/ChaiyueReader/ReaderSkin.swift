// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if canImport(SwiftUI)
import ChaiyueReaderKit
import UIKit

/// 整套阅读皮肤：背景图、推荐字体、标题版式与装饰、页眉页脚与进度样式
enum ReaderSkin: String, Sendable {
    /// 宣纸：朱印章节号、毛笔进度
    case xuan
    /// 晴窗：描边大号章节号、毛玻璃页眉、页点
    case qing
    /// 星夜：居中金色章节号、星光进度条与睡着的小柴犬
    case xing
    /// 烛灯：楷体、花饰分隔、居中页码
    case zhu

    var imageName: String { "Theme-\(rawValue)" }

    var font: ReaderFontChoice {
        switch self {
        case .xuan, .xing: .song
        case .qing: .ping
        case .zhu: .kai
        }
    }

    var accent: UIColor {
        switch self {
        case .xuan: UIColor(hex: 0xB23A2C)
        case .qing: UIColor(hex: 0x1F2430)
        case .xing: UIColor(hex: 0xE9D9A6)
        case .zhu: UIColor(hex: 0xE8A35C)
        }
    }

    /// 朗读中句子的底色
    var mark: UIColor {
        switch self {
        case .xuan: UIColor(hex: 0xB23A2C, alpha: 0.14)
        case .qing: UIColor(hex: 0xFFD508, alpha: 0.42)
        case .xing: UIColor(hex: 0xE9D9A6, alpha: 0.16)
        case .zhu: UIColor(hex: 0xE8A35C, alpha: 0.2)
        }
    }

    /// 章首页标题上方留给装饰的高度
    func titleInset(fontSize: CGFloat) -> CGFloat {
        switch self {
        case .xuan, .zhu: 4
        case .qing: 70
        case .xing: 30
        }
    }

    var titleAlignment: NSTextAlignment {
        switch self {
        case .xuan, .qing: .natural
        case .xing, .zhu: .center
        }
    }

    /// 标题字距，按标题字号的倍数
    var titleKern: CGFloat {
        switch self {
        case .xuan: 0.28
        case .qing: 0.04
        case .xing: 0.22
        case .zhu: 0.34
        }
    }

    /// 标题右侧让出的宽度（宣纸的印章）
    var titleTrailing: CGFloat { self == .xuan ? 54 : 0 }

    // MARK: - 背景

    private static var backdrops: [String: UIImage] = [:]

    /// 按页面尺寸裁好的背景图，同一尺寸只生成一次
    func backdrop(size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let key = "\(rawValue)|\(Int(size.width))x\(Int(size.height))"
        if let cached = Self.backdrops[key] { return cached }
        guard let source = UIImage(named: imageName) else { return nil }
        let scale = max(size.width / source.size.width, size.height / source.size.height)
        let drawn = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            source.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                   width: drawn.width, height: drawn.height))
            if self == .zhu {
                UIColor(hex: 0x0A0704, alpha: 0.38).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        Self.backdrops = Self.backdrops.filter { $0.key.hasPrefix(rawValue) == false || $0.key == key }
        Self.backdrops[key] = image
        return image
    }

    // MARK: - 标题装饰

    /// 在章首页画标题装饰；`origin` 为文字区域左上角，`number` 为章节序号
    func drawTitleDecor(layout: ChapterLayout, origin: CGPoint, width: CGFloat, number: Int, theme: ReaderThemeSpec,
                        fontSize: CGFloat) {
        guard let title = layout.titleRect, let context = UIGraphicsGetCurrentContext() else { return }
        let rect = title.offsetBy(dx: origin.x, dy: origin.y)
        let gap = fontSize * 1.4
        switch self {
        case .xuan:
            drawSeal(text: "第\(ChineseNumeral.string(number))\n章", center: CGPoint(x: origin.x + width - 22, y: rect.minY + 20),
                     context: context)
            theme.uiText.withAlphaComponent(0.4).setFill()
            context.fill(CGRect(x: origin.x, y: rect.maxY + gap * 0.5, width: 44, height: 1))
        case .qing:
            let text = String(format: "%02d", number) as NSString
            text.draw(at: CGPoint(x: origin.x - 3, y: origin.y - 6), withAttributes: [
                .font: UIFont.systemFont(ofSize: 64, weight: .ultraLight),
                .strokeColor: theme.uiText.withAlphaComponent(0.32),
                .strokeWidth: 2.4,
                .kern: -2,
            ])
        case .xing:
            let text = "第 \(ChineseNumeral.string(number)) 章" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: accent.withAlphaComponent(0.8),
                .kern: 5,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: origin.x + (width - size.width) / 2 + 2.5, y: origin.y + 6), withAttributes: attributes)
        case .zhu:
            drawOrnament(center: CGPoint(x: origin.x + width / 2, y: rect.maxY + gap * 0.5), theme: theme, context: context)
        }
    }

    private func drawSeal(text: String, center: CGPoint, context: CGContext) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: -4 * .pi / 180)
        let box = CGRect(x: -20, y: -20, width: 40, height: 40)
        UIColor(hex: 0xB23A2C, alpha: 0.92).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 5).fill()
        UIColor(hex: 0xF6E6DA, alpha: 0.35).setStroke()
        let inner = UIBezierPath(roundedRect: box.insetBy(dx: 2, dy: 2), cornerRadius: 3.5)
        inner.lineWidth = 1
        inner.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.maximumLineHeight = 15
        style.minimumLineHeight = 15
        let font = UIFont(name: FontLibrary.kaitiName(bold: true), size: 13) ?? .boldSystemFont(ofSize: 12)
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor(hex: 0xF6E6DA), .paragraphStyle: style,
        ])
        let height = string.boundingRect(with: CGSize(width: 40, height: 60), options: .usesLineFragmentOrigin, context: nil).height
        string.draw(with: CGRect(x: -20, y: -height / 2, width: 40, height: height), options: .usesLineFragmentOrigin, context: nil)
        context.restoreGState()
    }

    private func drawOrnament(center: CGPoint, theme: ReaderThemeSpec, context: CGContext) {
        let line = theme.uiText.withAlphaComponent(0.35)
        line.setFill()
        context.fill(CGRect(x: center.x - 71, y: center.y - 0.4, width: 54, height: 0.8))
        context.fill(CGRect(x: center.x + 17, y: center.y - 0.4, width: 54, height: 0.8))
        theme.uiText.withAlphaComponent(0.5).setFill()
        context.fillEllipse(in: CGRect(x: center.x - 13.2, y: center.y - 1.2, width: 2.4, height: 2.4))
        context.fillEllipse(in: CGRect(x: center.x + 10.8, y: center.y - 1.2, width: 2.4, height: 2.4))
        let diamond = UIBezierPath()
        diamond.move(to: CGPoint(x: center.x, y: center.y - 5.5))
        diamond.addLine(to: CGPoint(x: center.x + 5, y: center.y))
        diamond.addLine(to: CGPoint(x: center.x, y: center.y + 5.5))
        diamond.addLine(to: CGPoint(x: center.x - 5, y: center.y))
        diamond.close()
        diamond.lineWidth = 1
        accent.withAlphaComponent(0.8).setStroke()
        diamond.stroke()
    }

    // MARK: - 页眉页脚

    struct Chrome {
        var header: String
        var page: Int
        var pageCount: Int
        /// 全书进度 0...1
        var progress: Double
        var percent: String
    }

    func drawChrome(_ chrome: Chrome, metrics: PageMetrics, theme: ReaderThemeSpec, bounds: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let left = metrics.textFrame.minX
        let width = metrics.textFrame.width
        let secondary = theme.uiSecondary
        func attributes(_ size: CGFloat, kern: CGFloat = 0.5, digits: Bool = false) -> [NSAttributedString.Key: Any] {
            [.font: digits ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size),
             .foregroundColor: secondary, .kern: kern]
        }
        func centered(_ text: String, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
            let string = text as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(at: CGPoint(x: bounds.midX - min(size.width, width) / 2, y: y), withAttributes: attributes)
        }
        let footerMid = metrics.footerY + 7

        switch self {
        case .xuan:
            truncated(chrome.header, in: CGRect(x: left, y: metrics.headerY, width: width, height: 14), attributes: attributes(10, kern: 3))
            ("\(ChineseNumeral.string(chrome.page + 1)) / \(ChineseNumeral.string(chrome.pageCount))" as NSString)
                .draw(at: CGPoint(x: left, y: metrics.footerY), withAttributes: attributes(10.5, kern: 2))
            drawBrush(progress: chrome.progress, from: CGPoint(x: metrics.textFrame.maxX - 110, y: footerMid), length: 110,
                      color: theme.uiText, context: context)
        case .qing:
            let pill = attributes(10.5)
            let text = chrome.header as NSString
            let size = text.size(withAttributes: pill)
            let pillWidth = min(width, size.width + 28)
            let box = CGRect(x: bounds.midX - pillWidth / 2, y: metrics.headerY - 5, width: pillWidth, height: 24)
            UIColor.white.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 12).fill()
            theme.uiText.withAlphaComponent(0.08).setStroke()
            let outline = UIBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 12)
            outline.lineWidth = 0.5
            outline.stroke()
            truncated(chrome.header, in: box.insetBy(dx: 14, dy: 5), attributes: pill, center: true)
            drawDots(page: chrome.page, count: chrome.pageCount, center: CGPoint(x: bounds.midX, y: footerMid), theme: theme,
                     context: context)
            let percent = chrome.percent as NSString
            let digits = attributes(10.5, digits: true)
            let w = percent.size(withAttributes: digits).width
            percent.draw(at: CGPoint(x: metrics.textFrame.maxX - w, y: metrics.footerY), withAttributes: digits)
        case .xing:
            truncated(chrome.header, in: CGRect(x: left, y: metrics.headerY, width: width, height: 14), attributes: attributes(11))
            drawSleepingShiba(at: CGPoint(x: left, y: footerMid - 6), context: context)
            let digits = attributes(10.5, digits: true)
            let percent = chrome.percent as NSString
            let w = percent.size(withAttributes: digits).width
            percent.draw(at: CGPoint(x: metrics.textFrame.maxX - w, y: metrics.footerY), withAttributes: digits)
            drawStarLine(progress: chrome.progress, from: left + 32, to: metrics.textFrame.maxX - w - 10, y: footerMid,
                         theme: theme, context: context)
        case .zhu:
            var header = attributes(11, kern: 4)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            header[.paragraphStyle] = style
            (chrome.header as NSString).draw(in: CGRect(x: left, y: metrics.headerY, width: width, height: 14), withAttributes: header)
            centered("— \(ChineseNumeral.string(chrome.page + 1)) —", y: metrics.footerY, attributes: attributes(11, kern: 3))
        }
    }

    private func truncated(_ text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any], center: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = center ? .center : .natural
        var attributes = attributes
        attributes[.paragraphStyle] = style
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    /// 一笔墨迹：已读部分是起笔重、收笔轻的笔触，未读部分是一道淡线
    private func drawBrush(progress: Double, from start: CGPoint, length: CGFloat, color: UIColor, context: CGContext) {
        color.withAlphaComponent(0.12).setFill()
        context.fill(CGRect(x: start.x, y: start.y - 0.5, width: length, height: 1))
        let done = length * CGFloat(min(max(progress, 0), 1))
        guard done > 2 else { return }
        let path = UIBezierPath()
        let steps = max(8, Int(done / 3))
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start.x + done * t
            let wave = sin(t * .pi * 2.2) * 0.6
            // 起笔略粗，收笔渐细
            let half = 1.6 * (1 - t * 0.55) + (t < 0.08 ? (0.08 - t) * 10 : 0)
            top.append(CGPoint(x: x, y: start.y + wave - half))
            bottom.append(CGPoint(x: x, y: start.y + wave + half))
        }
        path.move(to: top[0])
        top.dropFirst().forEach { path.addLine(to: $0) }
        bottom.reversed().forEach { path.addLine(to: $0) }
        path.close()
        color.withAlphaComponent(0.7).setFill()
        path.fill()
    }

    /// 页点：最多 7 个，当前页拉长
    private func drawDots(page: Int, count: Int, center: CGPoint, theme: ReaderThemeSpec, context: CGContext) {
        guard count > 1 else { return }
        let visible = min(count, 7)
        let first = min(max(0, page - visible / 2), count - visible)
        let gap: CGFloat = 6
        let total = CGFloat(visible - 1) * (5 + gap) + 18
        var x = center.x - total / 2
        for index in first..<(first + visible) {
            let current = index == page
            let w: CGFloat = current ? 18 : 5
            (current ? theme.uiText : theme.uiText.withAlphaComponent(0.18)).setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: center.y - 2.5, width: w, height: 5), cornerRadius: 2.5).fill()
            x += w + gap
        }
    }

    /// 细线 + 读到处一颗发光的星
    private func drawStarLine(progress: Double, from x0: CGFloat, to x1: CGFloat, y: CGFloat, theme: ReaderThemeSpec,
                              context: CGContext) {
        guard x1 > x0 else { return }
        theme.uiText.withAlphaComponent(0.15).setFill()
        context.fill(CGRect(x: x0, y: y - 0.5, width: x1 - x0, height: 1))
        let x = x0 + (x1 - x0) * CGFloat(min(max(progress, 0), 1))
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.8).cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.saveGState()
            context.clip(to: CGRect(x: x0, y: y - 0.5, width: x - x0, height: 1))
            context.drawLinearGradient(gradient, start: CGPoint(x: x0, y: y), end: CGPoint(x: x, y: y), options: [])
            context.restoreGState()
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6, color: accent.withAlphaComponent(0.7).cgColor)
        accent.setFill()
        context.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
        context.restoreGState()
    }

    /// 趴着睡觉的小柴犬（22×12）
    private func drawSleepingShiba(at origin: CGPoint, context: CGContext) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        let body = UIBezierPath()
        body.move(to: CGPoint(x: 2, y: 10))
        body.addQuadCurve(to: CGPoint(x: 7, y: 5), controlPoint: CGPoint(x: 2, y: 5))
        body.addQuadCurve(to: CGPoint(x: 10, y: 3.5), controlPoint: CGPoint(x: 8, y: 1.5))
        body.addQuadCurve(to: CGPoint(x: 13, y: 5), controlPoint: CGPoint(x: 12, y: 1.5))
        body.addQuadCurve(to: CGPoint(x: 20, y: 10), controlPoint: CGPoint(x: 19, y: 5))
        body.close()
        accent.withAlphaComponent(0.55).setFill()
        body.fill()
        let eyes = UIBezierPath()
        eyes.move(to: CGPoint(x: 8.5, y: 7.6))
        eyes.addQuadCurve(to: CGPoint(x: 10.5, y: 7.6), controlPoint: CGPoint(x: 9.5, y: 8.4))
        eyes.move(to: CGPoint(x: 11.6, y: 7.6))
        eyes.addQuadCurve(to: CGPoint(x: 13.6, y: 7.6), controlPoint: CGPoint(x: 12.6, y: 8.4))
        eyes.lineWidth = 0.8
        UIColor(hex: 0x10121D).setStroke()
        eyes.stroke()
        context.restoreGState()
    }
}

/// 阿拉伯数字转中文：7 → 七，32 → 三十二，102 → 一百零二
enum ChineseNumeral {
    private static let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    static func string(_ value: Int) -> String {
        guard value > 0 else { return "零" }
        guard value < 10000 else { return String(value) }
        let units = ["", "十", "百", "千"]
        let chars = Array(String(value)).map { Int(String($0))! }
        var result = ""
        var zero = false
        for (index, digit) in chars.enumerated() {
            let unit = units[chars.count - 1 - index]
            if digit == 0 {
                zero = true
                continue
            }
            if zero, !result.isEmpty { result += "零" }
            zero = false
            result += digits[digit] + unit
        }
        if result.hasPrefix("一十") { result.removeFirst() }
        return result
    }
}
#endif  // #if canImport(UIKit)
