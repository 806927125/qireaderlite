import SwiftUI

/// ⭐⭐⭐⭐⭐ **阅读配色（16 套）** ⭐⭐⭐⭐⭐
///
/// ⚠️ 这个文件原来住在 `ReaderView.swift` 里 —— 那个 `ReaderView` 是一套**没人用的旧阅读器**
///    （另一套简版实现，没有分页、没有页眉页脚、设置面板是栖阅的 Form）。
///    柴阅化时它被删了，但 `ReaderTheme` 全仓都在用 ⇒ 单独搬到这里。
///
/// ⭐⭐⭐ **两层分开**（build322 定案）：
///   · **配色**（本文件）= 底色 + 字色 ⇒ 16 套
///   · **皮肤**（`ReaderSkin`）= 字体 + 章节号装饰 + 进度装饰 ⇒ 4 套（宣纸/晴窗/星夜/烛灯）
///   ⇒ 每套配色**归属**一个皮肤 ⇒ 换配色会带上那套皮肤的版式。
struct ReaderTheme: Identifiable {
    let key: String
    let name: String
    let bg: Color
    let ink: Color
    /// ⭐⭐⭐⭐⭐ **皮肤**（柴阅的四套：宣纸/晴窗/星夜/烛灯）⭐⭐⭐⭐⭐
    ///   ⇒ 皮肤决定**版式与装饰**（字体 / 章节号装饰 / 进度装饰），配色决定**颜色** ⇒ 两层分开 ⭐⭐⭐
    var skin: ReaderSkin = .xuan
    var id: String { key }

    // 必须定义成静态成员：`all.first(where:) ?? .paper` 里的 .paper
    // 要能从 ReaderTheme 上解析到，只在 all 数组里写 .init 是不够的。
    static let paper = ReaderTheme(key: "paper", name: "纸白",
                                   bg: Color(red: 0.949, green: 0.941, blue: 0.914),
                                   ink: Color(red: 0.16, green: 0.15, blue: 0.13), skin: .xuan)
    static let green = ReaderTheme(key: "green", name: "护眼",
                                   bg: Color(red: 0.847, green: 0.906, blue: 0.816),
                                   ink: Color(red: 0.13, green: 0.18, blue: 0.12), skin: .xuan)
    static let gray = ReaderTheme(key: "gray", name: "米灰",
                                  bg: Color(red: 0.90, green: 0.90, blue: 0.90),
                                  ink: Color(red: 0.18, green: 0.18, blue: 0.18), skin: .qing)
    static let dark = ReaderTheme(key: "dark", name: "夜间",
                                  bg: Color(red: 0.10, green: 0.10, blue: 0.11),
                                  ink: Color(red: 0.82, green: 0.82, blue: 0.84), skin: .xing)

    // 浅色一排（对应设置面板第一行「文」格子）
    static let paper2 = ReaderTheme(key: "paper2", name: "米黄",
                                    bg: Color(red: 0.976, green: 0.961, blue: 0.925),
                                    ink: Color(red: 0.20, green: 0.18, blue: 0.14), skin: .xuan)
    static let wheat = ReaderTheme(key: "wheat", name: "麦黄",
                                   bg: Color(red: 0.949, green: 0.906, blue: 0.796),
                                   ink: Color(red: 0.22, green: 0.18, blue: 0.12), skin: .zhu)
    static let rose = ReaderTheme(key: "rose", name: "藕粉",
                                  bg: Color(red: 0.965, green: 0.914, blue: 0.918),
                                  ink: Color(red: 0.24, green: 0.16, blue: 0.17), skin: .zhu)
    static let sky = ReaderTheme(key: "sky", name: "天青",
                                 bg: Color(red: 0.898, green: 0.933, blue: 0.949),
                                 ink: Color(red: 0.14, green: 0.18, blue: 0.24), skin: .qing)
    static let blue = ReaderTheme(key: "blue", name: "湖蓝",
                                  bg: Color(red: 0.855, green: 0.906, blue: 0.941),
                                  ink: Color(red: 0.12, green: 0.17, blue: 0.24), skin: .qing)
    static let teal = ReaderTheme(key: "teal", name: "青碧",
                                  bg: Color(red: 0.855, green: 0.929, blue: 0.902),
                                  ink: Color(red: 0.12, green: 0.20, blue: 0.18), skin: .qing)
    static let green2 = ReaderTheme(key: "green2", name: "豆绿",
                                    bg: Color(red: 0.898, green: 0.933, blue: 0.859),
                                    ink: Color(red: 0.15, green: 0.21, blue: 0.13), skin: .xuan)

    // 深色一排（对应第二行「文」格子）
    static let dChar = ReaderTheme(key: "dChar", name: "炭黑",
                                   bg: Color(red: 0.13, green: 0.13, blue: 0.14),
                                   ink: Color(red: 0.80, green: 0.80, blue: 0.82), skin: .xing)
    static let dOlive = ReaderTheme(key: "dOlive", name: "橄榄",
                                    bg: Color(red: 0.16, green: 0.17, blue: 0.14),
                                    ink: Color(red: 0.78, green: 0.80, blue: 0.72), skin: .xing)
    static let dNavy = ReaderTheme(key: "dNavy", name: "藏青",
                                   bg: Color(red: 0.12, green: 0.14, blue: 0.20),
                                   ink: Color(red: 0.76, green: 0.80, blue: 0.88), skin: .xing)
    static let dPurple = ReaderTheme(key: "dPurple", name: "紫檀",
                                     bg: Color(red: 0.17, green: 0.13, blue: 0.19),
                                     ink: Color(red: 0.82, green: 0.78, blue: 0.86), skin: .xing)
    static let dBrown = ReaderTheme(key: "dBrown", name: "深棕",
                                    bg: Color(red: 0.19, green: 0.16, blue: 0.13),
                                    ink: Color(red: 0.84, green: 0.80, blue: 0.74), skin: .xing)
    static let dGreen = ReaderTheme(key: "dGreen", name: "墨绿",
                                    bg: Color(red: 0.12, green: 0.17, blue: 0.15),
                                    ink: Color(red: 0.76, green: 0.84, blue: 0.80), skin: .xing)
    static let dBlue = ReaderTheme(key: "dBlue", name: "深蓝",
                                   bg: Color(red: 0.12, green: 0.16, blue: 0.22),
                                   ink: Color(red: 0.78, green: 0.84, blue: 0.90), skin: .xing)

    /// 浅色一排
    static let light: [ReaderTheme] = [.paper, .paper2, .wheat, .rose, .sky, .blue, .green2, .gray]
    /// 深色一排
    static let darkRow: [ReaderTheme] = [.dChar, .dOlive, .dNavy, .dPurple, .dBrown, .dGreen, .dBlue, .dark]

    static let all: [ReaderTheme] = light + darkRow
    // ⚠️ 必须写 contains(where:)：`contains(t)` 在这里会被当成
    //    contains(where:) 的柯里化简写，Swift 5.9 编译不过
    //    （"missing argument label 'where:'"）。
    static func isDark(_ t: ReaderTheme) -> Bool { darkRow.contains(where: { $0.key == t.key }) }

    // ⭐⭐⭐⭐⭐ **深色适配**：控件/面板的底色必须**随主题反**（2026-11-25 真机）⭐⭐⭐⭐⭐
    //
    //   以前面板那层白纱是**写死的白色**（`Color.white.opacity(max(glassTint, 0.12))`）⭐⭐⭐
    //   ⇒ 浅色纸底上没问题 ⇒ **夜间底上就是一块乳白板**（白纱 + 玻璃 ⇒ 灰糊）⭐⭐⭐
    //   ⇒ 正解：**深色底用黑纱、浅色底才用白纱** ⇒ 两种底都通透可读 ⭐⭐⭐⭐⭐
    /// ⭐⭐⭐ **实例侧的深色判定**（名字叫 `isDarkTheme`，避免和静态的 `ReaderTheme.isDark(_:)` 同名）⭐⭐⭐
    var isDarkTheme: Bool { ReaderTheme.isDark(self) }

    /// ⭐⭐⭐ 面板的「压底纱」（栖阅的 dimming layer）
    ///   · 浅色底 ⇒ 白纱（压住后面的正文字）
    ///   · 深色底 ⇒ **黑纱**（白纱会把玻璃变成乳白板）
    func panelVeil(white: Double) -> Color {
        isDarkTheme ? Color.black.opacity(0.34) : Color.white.opacity(max(white, 0.12))
    }

    /// ⭐⭐⭐ 控件（旋钮/小按钮）的底色
    var controlFill: Color {
        isDarkTheme ? Color.white.opacity(0.12) : Color.black.opacity(0.05)
    }

    // ⭐⭐⭐⭐⭐ **阅读页 chrome 的配色**（照栖阅 `appThemeTint` 的思路：**跟着阅读主题走**）⭐⭐⭐⭐⭐
    //
    //   以前这些全是**写死的浅色版**（`Color(white: 0x22/0xff)` / `Color.black.opacity(0.05)` …）⭐⭐⭐
    //   ⇒ 浅色纸底上没问题 ⇒ **夜间底上：深灰字 + 黑色控件底 ⇒ 全部看不见** ⭐⭐⭐⭐⭐
    //   ⇒ 正解：每项都给**深/浅两档**，由 `isDark` 选 ⭐⭐⭐

    /// 面板里的正文色
    var chromeInk: Color { isDarkTheme ? Color.white.opacity(0.90) : Color(white: 0x22 / 0xff) }
    /// 面板里的次级文字
    var chromeSubInk: Color { isDarkTheme ? Color.white.opacity(0.62) : Color(white: 0x55 / 0xff) }
    /// 面板里的发丝线
    var hairLineColor: Color { isDarkTheme ? Color.white.opacity(0.16) : Color.black.opacity(0.07) }
    /// 面板内层（子分组）的底
    var panelInnerFill: Color { isDarkTheme ? Color.black.opacity(0.26) : Color.white.opacity(0.55) }
    /// 选中项的高亮色（跟 App 主色同族）
    var chromeAccent: Color { Terminal.cyan }
}
