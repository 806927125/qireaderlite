// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if canImport(SwiftUI)
import Observation
import ChaiyueReaderKit
import ChaiyueReaderServices
import SwiftUI

/// 阅读主题（原型 THEMES）：浅色四种、深色两种，每种外观各记一个当前主题
struct ReaderThemeSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UInt32
    let text: UInt32
    let secondaryAlpha: CGFloat
    let grain: Double
    let isDark: Bool
    var skin: ReaderSkin?
    /// 自定义主题解析后的样式（内置主题为 nil）
    var style: ReaderPageStyle?
    var customID: String?
    /// 网页渲染的自定义主题
    var web = false
    /// 自定义主题的修改时间，主题内容变了规格也跟着变
    var revision: Date?

    var bg: Color { Color(hex: background) }
    var fg: Color { Color(hex: text) }
    var fg2: Color { Color(hex: text, alpha: secondaryAlpha) }
    var uiText: UIColor { UIColor(hex: text) }
    var uiSecondary: UIColor { UIColor(hex: text, alpha: secondaryAlpha) }
    var uiBackground: UIColor { UIColor(hex: background) }

    var uiMark: UIColor { skin?.mark ?? UIColor(hex: 0xFFD508, alpha: 0.32) }

    static let all: [ReaderThemeSpec] = [
        .init(id: "xuan", name: "宣纸", background: 0xF3EDE1, text: 0x2A2622, secondaryAlpha: 0.45, grain: 0, isDark: false, skin: .xuan),
        .init(id: "qing", name: "晴窗", background: 0xF4F5F8, text: 0x1F2430, secondaryAlpha: 0.48, grain: 0, isDark: false, skin: .qing),
        .init(id: "xing", name: "星夜", background: 0x0E1120, text: 0xB9BDD0, secondaryAlpha: 0.42, grain: 0, isDark: true, skin: .xing),
        .init(id: "zhu", name: "烛灯", background: 0x17130F, text: 0xD3BE98, secondaryAlpha: 0.42, grain: 0, isDark: true, skin: .zhu),
        .init(id: "paper", name: "纸张", background: 0xF2EBDD, text: 0x2C2721, secondaryAlpha: 0.45, grain: 0.55, isDark: false),
        .init(id: "white", name: "素白", background: 0xFAF9F6, text: 0x1D1C1A, secondaryAlpha: 0.42, grain: 0, isDark: false),
        .init(id: "green", name: "豆绿", background: 0xDDE7D9, text: 0x25301F, secondaryAlpha: 0.45, grain: 0.45, isDark: false),
        .init(id: "mist", name: "雾灰", background: 0xE1E4E7, text: 0x20262C, secondaryAlpha: 0.45, grain: 0, isDark: false),
        .init(id: "dusk", name: "暮色", background: 0x2A2521, text: 0xCBBFAE, secondaryAlpha: 0.4, grain: 0.4, isDark: true),
        .init(id: "night", name: "夜间", background: 0x0E0E0F, text: 0x8E8A84, secondaryAlpha: 0.42, grain: 0, isDark: true),
    ]

    static func find(_ id: String) -> ReaderThemeSpec? { all.first { $0.id == id } }
}

enum ReaderFontChoice: Int, CaseIterable, Identifiable {
    case song, ping, kai

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .song: "宋体"
        case .ping: "苹方"
        case .kai: "楷体"
        }
    }

    var postScriptName: String? {
        switch self {
        case .song: FontLibrary.songti
        case .ping: nil
        case .kai: FontLibrary.kaitiName(bold: false)
        }
    }

    func preview(_ size: CGFloat) -> Font {
        switch self {
        case .song: .serif(size, bold: false)
        case .ping: .system(size: size)
        case .kai: .kai(size)
        }
    }
}

/// 翻页方式的界面名称（与原型一致）
extension PageTurnStyle {
    var label: String {
        switch self {
        case .curl: "仿真"
        case .slide: "覆盖"
        case .scroll: "平移"
        case .none: "无"
        case .vertical: "滚动"
        }
    }

    static let ordered: [PageTurnStyle] = [.curl, .slide, .scroll, .none, .vertical]
}

@Observable
final class ReaderSettings {
    private let defaults = UserDefaults.standard

    var lightTheme: String { didSet { defaults.set(lightTheme, forKey: "reader.lightTheme") } }
    var darkTheme: String { didSet { defaults.set(darkTheme, forKey: "reader.darkTheme") } }
    var font: ReaderFontChoice { didSet { defaults.set(font.rawValue, forKey: "reader.font") } }
    /// 选中的导入字体（PostScript 名），优先于 `font`；字体被删后自动回到 `font`
    var customFont: String? { didSet { defaults.set(customFont, forKey: "reader.customFont") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "reader.fontSize") } }
    var spacing: Int { didSet { defaults.set(spacing, forKey: "reader.spacing") } }
    var pageStyle: PageTurnStyle { didSet { defaults.set(pageStyle.rawValue, forKey: "reader.pageStyle") } }
    /// 正在用的自定义主题；设了就盖过内置主题（深浅两套由主题自己的 @media 决定）
    var customTheme: String? { didSet { defaults.set(customTheme, forKey: "reader.customTheme") } }
    /// nil 表示跟随系统亮度
    var brightness: Double? { didSet { defaults.set(brightness ?? -1, forKey: "reader.brightness") } }
    var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "reader.keepScreenOn") } }
    var tapToTurnBothSides: Bool { didSet { defaults.set(tapToTurnBothSides, forKey: "reader.tapNext") } }
    /// 段末显示书源提供的段评气泡（全局开关）
    var paragraphComments: Bool { didSet { defaults.set(paragraphComments, forKey: "reader.paragraphComments") } }
    /// 读过的书自动放进书架。关闭后仍记住读到的章节
    var autoAddToShelf: Bool { didSet { defaults.set(autoAddToShelf, forKey: "reader.autoAddToShelf") } }
    var conversion: ChineseConversion { didSet { defaults.set(conversion.rawValue, forKey: "reader.conversion") } }
    var preloadCount: Int { didSet { defaults.set(preloadCount, forKey: "reader.preload") } }
    var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speech.rate") } }
    var speechVoice: String? { didSet { defaults.set(speechVoice, forKey: "speech.voice") } }
    /// 在线朗读源的 id；nil 时看本地神经语音，再看系统语音
    var speechEngine: Int64? { didSet { defaults.set(speechEngine.map(String.init), forKey: "speech.engine") } }
    /// 本地神经语音的音色编号，-1 表示改用系统语音；默认开启
    var localVoice: Int { didSet { defaults.set(localVoice, forKey: "speech.local") } }

    /// 行间额外空白（字号倍数）。正文固定行高约 1.42 字号，三档行距分别约为原型的 1.65、1.9、2.2 倍字号
    static let lineSpacings: [Double] = [0.24, 0.48, 0.78]

    init() {
        lightTheme = defaults.string(forKey: "reader.lightTheme") ?? "paper"
        darkTheme = defaults.string(forKey: "reader.darkTheme") ?? "night"
        font = ReaderFontChoice(rawValue: defaults.integer(forKey: "reader.font")) ?? .song
        customFont = defaults.string(forKey: "reader.customFont")
        let size = defaults.double(forKey: "reader.fontSize")
        fontSize = size > 0 ? size : 19
        spacing = defaults.object(forKey: "reader.spacing") == nil ? 1 : defaults.integer(forKey: "reader.spacing")
        pageStyle = PageTurnStyle(rawValue: defaults.string(forKey: "reader.pageStyle") ?? "") ?? .slide
        customTheme = defaults.string(forKey: "reader.customTheme")
        let bright = defaults.object(forKey: "reader.brightness") as? Double ?? -1
        brightness = bright < 0 ? nil : bright
        keepScreenOn = defaults.object(forKey: "reader.keepScreenOn") as? Bool ?? true
        tapToTurnBothSides = defaults.object(forKey: "reader.tapNext") as? Bool ?? false
        paragraphComments = defaults.object(forKey: "reader.paragraphComments") as? Bool ?? true
        autoAddToShelf = defaults.object(forKey: "reader.autoAddToShelf") as? Bool ?? true
        conversion = ChineseConversion(rawValue: defaults.integer(forKey: "reader.conversion")) ?? .none
        preloadCount = defaults.object(forKey: "reader.preload") as? Int ?? 3
        let rate = defaults.double(forKey: "speech.rate")
        speechRate = rate > 0 ? rate : 0.5
        speechVoice = defaults.string(forKey: "speech.voice")
        speechEngine = defaults.string(forKey: "speech.engine").flatMap(Int64.init)
        localVoice = defaults.object(forKey: "speech.local") as? Int ?? LocalVoice.defaultSpeaker
    }

    /// 参与备份的设置键
    static let backupKeys = [
        "reader.lightTheme", "reader.darkTheme", "reader.customTheme", "reader.font", "reader.customFont", "reader.fontSize", "reader.spacing", "reader.pageStyle",
        "reader.brightness", "reader.keepScreenOn", "reader.tapNext", "reader.paragraphComments", "reader.autoAddToShelf", "reader.conversion", "reader.preload",
        "speech.rate", "speech.voice", "speech.engine", "speech.local",
    ]

    /// 恢复备份后重新读取
    func reload() {
        let fresh = ReaderSettings()
        lightTheme = fresh.lightTheme
        darkTheme = fresh.darkTheme
        font = fresh.font
        customFont = fresh.customFont
        fontSize = fresh.fontSize
        spacing = fresh.spacing
        pageStyle = fresh.pageStyle
        customTheme = fresh.customTheme
        brightness = fresh.brightness
        keepScreenOn = fresh.keepScreenOn
        tapToTurnBothSides = fresh.tapToTurnBothSides
        paragraphComments = fresh.paragraphComments
        autoAddToShelf = fresh.autoAddToShelf
        conversion = fresh.conversion
        preloadCount = fresh.preloadCount
        speechRate = fresh.speechRate
        speechVoice = fresh.speechVoice
        speechEngine = fresh.speechEngine
        localVoice = fresh.localVoice
    }

    func theme(for scheme: ColorScheme) -> ReaderThemeSpec {
        let store = ReaderThemeStore.shared
        if let custom = store.theme(customTheme) {
            return store.spec(for: custom, dark: scheme == .dark)
        }
        let id = scheme == .dark ? darkTheme : lightTheme
        return ReaderThemeSpec.find(id) ?? ReaderThemeSpec.find(scheme == .dark ? "night" : "paper")!
    }

    /// 选中主题记入对应外观的槽位；皮肤主题顺带换成它的字体
    func select(_ theme: ReaderThemeSpec) {
        if let id = theme.customID, let custom = ReaderThemeStore.shared.theme(id) {
            use(custom)
            return
        }
        customTheme = nil
        if theme.isDark { darkTheme = theme.id } else { lightTheme = theme.id }
        if let skin = theme.skin {
            customFont = nil
            font = skin.font
        }
    }

    /// 当前生效的导入字体
    var importedFont: ImportedFont? { FontStore.shared.font(customFont) }

    /// 用自定义主题；样式表写了正文字号时把字号调过去（之后仍可用字号按钮调）
    func use(_ custom: CustomReaderTheme) {
        customTheme = custom.id
        let style = ReaderThemeStore.shared.sheet(for: custom).resolve(dark: false)
        if case .px(let size)? = style.body.fontSize {
            fontSize = min(30, max(14, size.rounded()))
        }
    }

    var typography: ReaderTypography {
        var t = ReaderTypography()
        t.fontSize = fontSize
        t.fontName = importedFont?.id ?? font.postScriptName
        t.lineSpacing = Self.lineSpacings[min(max(0, spacing), 2)]
        t.paragraphSpacing = 0.5
        t.titleScale = 1.4
        t.horizontalPadding = 26
        return t
    }

    /// 自定义主题的样式表补上字距、缩进、对齐、段距与章名字号；字号、字体、行距始终以排版面板为准
    func typography(for theme: ReaderThemeSpec) -> ReaderTypography {
        var t = typography
        guard let style = theme.style else { return t }
        let size = fontSize
        let body = style.body
        if let margin = body.marginBottom { t.paragraphSpacing = margin.points(fontSize: size) / size }
        if let spacing = body.letterSpacing { t.letterSpacing = spacing.points(fontSize: size) / size }
        if let indent = body.textIndent { t.indent = indent.points(fontSize: size) / (size * (1 + t.letterSpacing)) }
        if let align = body.textAlign { t.justified = align == .justify }
        if let title = style.chapterTitle.fontSize { t.titleScale = title.points(fontSize: size) / size }
        return t
    }
}
#endif  // #if canImport(UIKit)
