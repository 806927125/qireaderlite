import CoreGraphics
import Foundation
import UIKit

/// 排版参数。
///
/// 对应栖阅的 `ReaderLayoutConfig.swift`：字号、行距、段距、边距、首行缩进
/// 决定一页能装多少字，也就决定了分页结果。
///
/// ⚠️ 这些值跟 `settingsPayload` 里喂给 webview 的是同一套语义
///    （fontSize / lineSpacing / leftMargin / rightMargin），
///    改一处要记得改另一处，不然上下滚动和分页两种模式字会不一样大。
struct ReaderLayoutConfig {
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 8
    var paragraphSpacing: CGFloat = 10
    var horizontalMargin: CGFloat = 20
    var topMargin: CGFloat = 20
    var bottomMargin: CGFloat = 28
    /// 首行缩进，默认 2 个字（中文排版惯例）
    var firstLineIndent: CGFloat = 36
    var fontFamily: String = "System"
    var isBold: Bool = false
    var textColor: UIColor = UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1)
    var backgroundColor: UIColor = UIColor(red: 0.949, green: 0.941, blue: 0.914, alpha: 1)

    /// 一页的内容区尺寸（视口扣掉四周边距）
    func pageSize(in viewport: CGSize) -> CGSize {
        CGSize(width: max(80, viewport.width - horizontalMargin * 2),
               height: max(80, viewport.height - topMargin - bottomMargin))
    }

    /// 字体。系统字体以外的族名取不到就退回系统字体，绝不返回 nil。
    var resolvedFont: UIFont {
        let size = max(8, fontSize)
        let base: UIFont
        switch fontFamily {
        case "song":  base = UIFont(name: "Songti SC", size: size) ?? UIFont.systemFont(ofSize: size)
        case "hei":   base = UIFont(name: "Heiti SC", size: size) ?? UIFont.systemFont(ofSize: size)
        case "kai":   base = UIFont(name: "Kaiti SC", size: size) ?? UIFont.systemFont(ofSize: size)
        case "serif": base = UIFont(name: "Georgia", size: size) ?? UIFont.systemFont(ofSize: size)
        default:      base = UIFont.systemFont(ofSize: size)
        }
        return isBold ? UIFont.boldSystemFont(ofSize: size) : base
    }

    /// 正文 → 带排版属性的字符串
    func attributed(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        para.paragraphSpacing = paragraphSpacing
        para.firstLineHeadIndent = firstLineIndent
        para.alignment = .natural
        // 中英混排用 .natural 跟随系统语言方向，别写死 .left
        return NSAttributedString(string: text, attributes: [
            .font: resolvedFont,
            .foregroundColor: textColor,
            .paragraphStyle: para
        ])
    }
}
