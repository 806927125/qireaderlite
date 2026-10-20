import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// 段落对齐方式（栖阅 ReadingSettings 里的 左对齐/居中/右对齐/两端对齐）
///
/// ⚠️ 做成 **struct**（不是 enum），跟能编译的 ReaderFont / PageTurnMode 保持一致。
///    enum 靠 raw value 隐式带来的 Hashable，会让 `Identifiable` 的
///    `where Self: Hashable` 扩展多出一个 `id` 候选 → `ID` 推导歧义 →
///    SwiftUI 的 `ForEach` 重载直接挑不中，只剩 `Binding<C>` 可选 → 一片红。
struct ReaderParaAlign: Identifiable, Hashable {
    let raw: String
    var id: String { raw }

    var name: String {
        switch raw {
        case "center":  return "居中"
        case "right":   return "右对齐"
        case "justify": return "两端对齐"
        default:        return "左对齐"
        }
    }
    var textAlignment: NSTextAlignment {
        switch raw {
        case "center":  return .center
        case "right":   return .right
        case "justify": return .justified
        default:        return .left
        }
    }

    static let left    = ReaderParaAlign(raw: "left")
    static let center  = ReaderParaAlign(raw: "center")
    static let right   = ReaderParaAlign(raw: "right")
    static let justify = ReaderParaAlign(raw: "justify")
    static let all: [ReaderParaAlign] = [.left, .center, .right, .justify]
}

/// 行底线的范围（栖阅：整行 / 按文字）
struct ReaderBaselineScope: Identifiable, Hashable {
    let raw: String
    var id: String { raw }

    var name: String { self == .full ? "整行" : "按文字" }

    static let full = ReaderBaselineScope(raw: "full")
    static let word = ReaderBaselineScope(raw: "word")
    static let all: [ReaderBaselineScope] = [.full, .word]
}

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

    // MARK: 栖阅 ReaderLayoutSettingsView 里的那几项

    /// 段落对齐
    var paraAlign: ReaderParaAlign = .left
    /// 垂直两端对齐：每页文字自动调整行间距填满页面，底部对齐整齐
    var verticalJustify: Bool = false
    /// 行底线：正文每一行底部画横线
    var showBaseline: Bool = false
    /// 独立底线颜色（不跟正文颜色走）
    var baselineColor: UIColor = UIColor(white: 0.72, alpha: 1)
    /// 底线范围：整行 / 按文字
    var baselineScope: ReaderBaselineScope = .full

    /// 排版**指纹** —— 用来判断「排版有没有真的变」。
    ///
    /// ⚠️ 不能给 ReaderLayoutConfig 加 Equatable：里面有 UIColor，
    ///    UIColor 的 == 只比颜色本身，不比「是不是同一个对象」，
    ///    用来判重不可靠。改成显式的指纹字符串。
    var layoutFingerprint: String {
        // ⚠️ 必须拆成几个短 let —— 一次拼太长 Swift 编译器会
        //    "unable to type-check this expression in reasonable time"（CI 报过）。
        let a = "\(fontSize)|\(lineSpacing)|\(paragraphSpacing)|\(horizontalMargin)"
        let b = "\(topMargin)|\(bottomMargin)|\(firstLineIndent)|\(fontFamily)|\(isBold)"
        // ⚠️ ReaderParaAlign / ReaderBaselineScope 是 **struct 不是 enum**，
        //    没有 rawValue（编译报 "has no member 'rawValue'"）→ 用 String(describing:)。
        let c = "\(textColor)|\(backgroundColor)|\(String(describing: paraAlign))|\(verticalJustify)"
        let d = "\(showBaseline)|\(baselineColor)|\(String(describing: baselineScope))"
        return a + b + c + d
    }

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

    /// 章标题 → 正文 → 带排版属性的字符串
    ///
    /// 标题样式照抄栖阅 reader.css 的 `.chapter-title`（那个文件跟栖阅逐字节一致）：
    ///   font-size: calc(var(--reader-font-size) * 1.18);
    ///   font-weight: 650;
    ///   line-height: 1.35;
    ///   margin: 0 0 28px;
    func attributed(title: String, body: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let head = NSMutableParagraphStyle()
            head.lineHeightMultiple = 1.35
            head.paragraphSpacing = 28
            head.alignment = .natural
            let headFont = UIFont.systemFont(ofSize: max(8, fontSize * 1.18), weight: .semibold)
            out.append(NSAttributedString(string: trimmed + "\n", attributes: [
                .font: headFont,
                .foregroundColor: textColor,
                .paragraphStyle: head
            ]))
        }
        out.append(attributed(body))
        return out
    }

    /// 正文段落样式
    func paragraphStyle() -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        para.paragraphSpacing = paragraphSpacing
        para.firstLineHeadIndent = firstLineIndent
        para.alignment = paraAlign.textAlignment
        return para
    }

    /// 正文 → 带排版属性的字符串
    func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: resolvedFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle()
        ])
    }
}


// MARK: - Color ↔ hex（设置项要持久化）

extension Color {
    /// "#RRGGBB" → Color
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    /// Color → "#RRGGBB"
    var hexString: String {
        let u = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
