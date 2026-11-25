import UIKit

// =============================================================================
// ⭐⭐⭐⭐⭐ **阅读皮肤**（照**柴阅** `App/Sources/Reader/ReaderSkin.swift` 的结构重写，2026-11-25）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **参照对象与许可边界** ⭐⭐⭐⚠️
//   柴阅（github.com/Lincb522/Chaiyue）是 **GPL-3.0** ⇒ **不能抄它的代码与背景图资源** ⭐⭐⭐
//   ⇒ 这里**只照它的「结构与观感」重写**：皮肤 = 字体 + 强调色 + **章节号装饰** + **进度装饰** ⭐⭐⭐
//   ⇒ 背景图我们没有 ⇒ 用**纯色底 + 渐变层次**代替（见 `ReaderSkinBackground`）⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **柴阅的四套皮肤**（读它的源码得出）⭐⭐⭐⭐⭐
//   | 皮肤 | 正文字体 | 章节号装饰 | 进度装饰 | 强调色 |
//   |---|---|---|---|---|
//   | **宣纸 xuan** | 宋体 | 右上角**朱印**「第N章」 | 毛笔进度 | 朱红 #B23A2C |
//   | **晴窗 qing** | 苹方 | 左上角**描边大号**章号 | 页点 | 墨 #1F2430 |
//   | **星夜 xing** | 宋体 | 居中**金色**大号章号 | 星光进度条 | 浅金 #E9D9A6 |
//   | **烛灯 zhu** | 楷体 | 居中大号章号 | 居中页码 | 暖橙 #E8A35C |
//
// ⭐⭐⭐ **轻阅的 16 套配色 × 柴阅的 4 套皮肤** ⇒ 每个配色归属一个皮肤（见 `ReaderTheme.skin`）⭐⭐⭐
//   ⇒ 皮肤决定**版式与装饰**，配色决定**颜色** ⇒ 两层分开（柴阅就是这么分的）⭐⭐⭐
// =============================================================================

enum ReaderSkin: String, CaseIterable, Identifiable, Sendable {
    case xuan   // 宣纸
    case qing   // 晴窗
    case xing   // 星夜
    case zhu    // 烛灯

    var id: String { rawValue }

    var name: String {
        switch self {
        case .xuan: return "宣纸"
        case .qing: return "晴窗"
        case .xing: return "星夜"
        case .zhu:  return "烛灯"
        }
    }

    /// ⭐⭐⭐ 正文字体（用轻阅的 `fontKey` 取值 ⇒ 复用现有字体机制）⭐⭐⭐
    var fontRaw: String {
        switch self {
        case .xuan, .xing: return "song"   // 宋体
        case .qing:        return "system" // 苹方（系统）
        case .zhu:         return "kai"    // 楷体
        }
    }

    /// ⭐⭐⭐ 强调色（柴阅原值）⭐⭐⭐
    var accent: UIColor {
        switch self {
        case .xuan: return UIColor(hex: 0xB23A2C)   // 朱红
        case .qing: return UIColor(hex: 0x1F2430)   // 墨
        case .xing: return UIColor(hex: 0xE9D9A6)   // 浅金
        case .zhu:  return UIColor(hex: 0xE8A35C)   // 暖橙
        }
    }

    /// ⭐⭐⭐ 章节号装饰的样式 ⭐⭐⭐
    enum ChapterNumberStyle {
        /// 宣纸：右上角**朱印**（40×40 实心朱红方块 + 内框 + 两行「第N章」+ 旋转 -4°）
        case seal
        /// 晴窗：左上角**描边大号**章号（64pt ultraLight 的「01」）
        case outlineBig
        /// 星夜：标题上方**居中小字**「第 N 章」（11pt medium，字距 5）
        case centeredSmall
        /// 烛灯：标题**下方**的装饰纹样（柴阅 zhu 的做法）
        case ornament
    }

    var chapterNumberStyle: ChapterNumberStyle {
        switch self {
        case .xuan: return .seal
        case .qing: return .outlineBig
        case .xing: return .centeredSmall
        case .zhu:  return .ornament
        }
    }

    /// ⭐⭐⭐ 章节号的颜色（宣纸=朱红；晴窗=正文色淡描；星夜=浅金；烛灯=暖橙）⭐⭐⭐
    var chapterNumberColor: UIColor {
        switch self {
        case .xuan: return accent
        case .qing: return UIColor(hex: 0x1F2430).withAlphaComponent(0.32)
        case .xing: return UIColor(hex: 0xE9D9A6)
        case .zhu:  return UIColor(hex: 0xE8A35C)
        }
    }

    /// ⭐⭐⭐ 章节号字距（标题字号的倍数，柴阅原值）⭐⭐⭐
    var chapterNumberKern: CGFloat {
        switch self {
        case .xuan: return 0.28
        case .qing: return 0.04
        case .xing: return 0.22
        case .zhu:  return 0.34
        }
    }

    /// ⭐⭐⭐ 章节号对齐（柴阅：宣纸/晴窗靠左；星夜/烛灯居中）⭐⭐⭐
    var chapterNumberAlignment: ReaderParaAlign {
        switch self {
        case .xuan, .qing: return .left
        case .xing, .zhu:  return .center
        }
    }

    /// ⭐⭐⭐ 进度装饰的样式（柴阅每套皮肤不同）⭐⭐⭐
    enum ProgressStyle {
        /// 宣纸：一条细进度线（毛笔感）
        case brush
        /// 晴窗：页点（一排小圆点，当前页高亮）
        case dots
        /// 星夜：星光进度条（带辉光）
        case starlight
        /// 烛灯：居中页码（装饰在页脚）
        case pageNumber
    }

    var progressStyle: ProgressStyle {
        switch self {
        case .xuan: return .brush
        case .qing: return .dots
        case .xing: return .starlight
        case .zhu:  return .pageNumber
        }
    }

    /// ⭐⭐⭐ 页眉页脚里「次要文字」的颜色（柴阅 `uiSecondary`）⭐⭐⭐
    func secondaryColor(base: UIColor) -> UIColor {
        switch self {
        case .xuan: return base.withAlphaComponent(0.55)
        case .qing: return base.withAlphaComponent(0.55)
        case .xing: return UIColor(hex: 0xE9D9A6).withAlphaComponent(0.62)
        case .zhu:  return base.withAlphaComponent(0.55)
        }
    }
}

// MARK: - 颜色工具

extension UIColor {
    /// ⭐⭐⭐ `0xRRGGBB` 便捷构造（柴阅的配色都写成 hex）⭐⭐⭐
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - 一页的「页眉页脚 + 章节号装饰」

/// ⭐⭐⭐⭐⭐ **一页的 chrome 信息**（柴阅 `ReaderChromeText` + `ReaderSkin.Chrome` 的等价物）⭐⭐⭐⭐⭐
///
/// 柴阅一页的结构 = **纸色底 + 页眉 + 正文 + 页脚**（外加皮肤的章节号/进度装饰）⭐⭐⭐
struct ReaderPageChrome {
    /// 页眉：首屏是**书名**，之后是**章名**（柴阅同款）⭐⭐⭐
    var header: String = ""
    /// 页脚左：页码 / 总页（柴阅同款）⭐⭐⭐
    var footerLeft: String = ""
    /// 页脚右：全书进度（柴阅是「12.3%」）⭐⭐⭐
    var footerRight: String = ""
    /// 章节号（装饰用；柴阅优先取章名里的「第N章」）⭐⭐⭐
    var chapterNumber: Int? = nil
    /// 这一页是不是本章的**第一页**（柴阅只在章首页画装饰）⭐⭐⭐
    var isChapterFirstPage: Bool = false
    /// 皮肤（决定装饰样式）⭐⭐⭐
    var skin: ReaderSkin = .xuan
    /// 页眉页脚的次要文字颜色（柴阅 `uiSecondary`）⭐⭐⭐
    var secondary: UIColor = UIColor(white: 0.55, alpha: 1)
    /// 页眉带高度（正文要给它让位）⭐⭐⭐
    var headerHeight: CGFloat = 18
    /// 页脚带高度 ⭐⭐⭐
    var footerHeight: CGFloat = 16
    /// ⭐⭐⭐ **左右边距**（柴阅的页 = 左右各留 26 ⇒ 页眉页脚也跟着缩进来）
    ///   ⚠️ 以前**正文左边距根本没生效**：页容器宽度是对的（viewport-44），
    ///   但绘制原点 x=0 ⇒ 文字**顶到屏幕左边缘**、右边却空 44pt ⇒ 整块偏左 22pt ⭐⭐⭐
    var horizontalMargin: CGFloat = 22
}
