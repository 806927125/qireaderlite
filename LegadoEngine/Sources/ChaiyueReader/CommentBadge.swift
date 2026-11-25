#if os(iOS)
// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
import ChaiyueModels
import UIKit

/// 段末评论气泡（参考 Legado / 番茄）：小圆角气泡带左下角小尾巴，数字与描边用次要文字色，底色随主题深浅微微着色
enum CommentBadge {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for comment: ParagraphComment, fontSize: CGFloat, color: UIColor, isDark: Bool) -> UIImage {
        let label = comment.label
        let key = "\(label)|\(fontSize)|\(color.hashValue)|\(isDark)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let font = UIFont.monospacedDigitSystemFont(ofSize: max(9, round(fontSize * 0.5)), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        let height = max(14, round(fontSize * 0.8))
        let tail = round(height * 0.24)
        let width = max(height * 1.3, ceil(textSize.width) + height * 0.7)
        let margin: CGFloat = 4
        let line: CGFloat = 1
        let size = CGSize(width: margin + width + line, height: height + tail + line)

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let body = CGRect(x: margin + line / 2, y: line / 2, width: width, height: height)
            let path = outline(body, radius: height * 0.36, tail: tail)
            path.lineWidth = line
            path.lineJoinStyle = .round
            color.withAlphaComponent(isDark ? 0.14 : 0.08).setFill()
            path.fill()
            color.withAlphaComponent(0.55).setStroke()
            path.stroke()
            text.draw(at: CGPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2), withAttributes: attributes)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 圆角矩形，底边靠左伸出一个小尾巴，一笔画成
    private static func outline(_ rect: CGRect, radius r: CGFloat, tail: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: CGPoint(x: x0 + r, y: y0))
        path.addLine(to: CGPoint(x: x1 - r, y: y0))
        path.addArc(withCenter: CGPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: x1, y: y1 - r))
        path.addArc(withCenter: CGPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: x0 + r + tail * 1.2, y: y1))
        path.addLine(to: CGPoint(x: x0 + r * 0.6, y: y1 + tail))
        path.addLine(to: CGPoint(x: x0 + r, y: y1))
        path.addArc(withCenter: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: x0, y: y0 + r))
        path.addArc(withCenter: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.close()
        return path
    }
}
#endif  // #if os(iOS)
