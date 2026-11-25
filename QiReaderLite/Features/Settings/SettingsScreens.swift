import SwiftUI
import UIKit
import ChaiyueReader

// ══════════════════════════════════════════════════════════════════
//  ⭐⭐⭐⭐⭐ **App 设置区 = 柴阅的「一页一个独立子页」** ⭐⭐⭐⭐⭐
//
//  柴阅（GPL-3.0 ⇒ 只读当规格）的设置区结构：
//      Screens/Settings/AboutScreen        关于
//                   BackupScreen       备份
//                   CacheScreen        缓存
//                   FontsScreen        字体
//                   ReaderThemesScreen 阅读主题
//                   ReadingSettingsScreen 阅读设置
//                   SpeechSettingsScreen 朗读设置
//  ⇒ **每一项点进去是一个独立子页**，不是一个长列表。
//  ⇒ 轻阅这边照抄这个结构；**没有的能力做成灰态**（轻阅既有约定：
//    摆位不点，不弹「还没接」）。
//
//  ⭐⭐⭐ **被删掉的栖阅面板项都迁到「阅读设置」页**
//  （柴阅的位置：面板只放高频项，细项放 App 设置页）⭐⭐⭐
// ══════════════════════════════════════════════════════════════════

// MARK: - 柴阅的 SettingRow / ToggleRow（轻阅版，配色走轻阅的 Theme）

/// 一行「图标 + 标题 + 副标题 + 右侧值 + chevron」。
struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = Theme.tagBlue
    /// 灰态 = 能力还没接（摆位不点）
    var disabled: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(disabled ? Theme.sub.opacity(0.5) : tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(disabled ? Theme.sub : Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if let value {
                    Text(value)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.sub)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.sub.opacity(0.6))
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 一行开关（柴阅 `ToggleRow`）。
struct SettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var tint: Color = Theme.tagBlue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 11)
    }
}

/// 子页外壳（柴阅每个设置页都是「大标题 + 若干组」）。
struct SettingsScreenScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            PageBackdrop()
            ScrollView {
                VStack(spacing: 14) {
                    BigTitle(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ① 阅读设置（柴阅 ReadingSettingsScreen）

/// ⭐⭐⭐⭐⭐ **阅读设置页 = 柴阅阅读器真正认的设置项**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
///
/// ⚠️⚠️⚠️ **键名必须与柴阅的 `ReaderSettings` 一模一样** ⭐⭐⭐：
///   柴阅的 `ReaderSettings` 直接读写 `UserDefaults.standard`
///   （包内 `ChaiyueReader/ReaderSettings.swift`，键如 `reader.fontSize` / `reader.spacing` / `reader.pageStyle`）
///   ⇒ 轻阅这边用 `@AppStorage` 写**同样的键** ⇒ **两边天然同步，零桥接代码** ⭐⭐⭐
///   ⇒ 而且柴阅的阅读器**立刻生效**（它读的就是这些键）⭐⭐⭐
///
/// ⚠️⚠️ **老阅读器那些细项（行底线 / 垂直两端对齐 / 宽屏双页 / 内容限制在页眉页脚之间…）清掉了** ⭐⭐⭐：
///   那些是**我们自己重写版阅读器**的功能 ⇒ 阅读器换成柴阅的 ⇒ **柴阅没有这些能力**
///   ⇒ 留在设置页里就是「摆着不点」的死设置 ⇒ 一并删掉（不做假开关）⭐⭐⭐
struct ReadingSettingsScreen: View {
    @AppStorage("reader.fontSize") private var fontSize: Double = 19
    @AppStorage("reader.spacing") private var spacing: Int = 1
    @AppStorage("reader.pageStyle") private var pageStyle: String = "slide"
    @AppStorage("reader.brightness") private var brightness: Double = -1
    @AppStorage("reader.keepScreenOn") private var keepScreenOn: Bool = true
    @AppStorage("reader.tapNext") private var tapNext: Bool = false
    @AppStorage("reader.paragraphComments") private var paragraphComments: Bool = true
    @AppStorage("reader.autoAddToShelf") private var autoAddToShelf: Bool = true
    @AppStorage("reader.conversion") private var conversion: Int = 0
    @AppStorage("reader.preload") private var preload: Int = 3

    /// 亮度：-1 = 跟随系统（柴阅的 `ReaderSettings.brightness` 是 `Double?`，落盘用 -1 表示 nil）⭐⭐⭐
    private var followSystemBrightness: Bool { brightness < 0 }
    private var clampedBrightness: Double { followSystemBrightness ? 0.5 : min(max(brightness, 0), 1) }

    var body: some View {
        SettingsScreenScaffold(title: "阅读设置",
                               subtitle: "这些就是柴阅阅读器真正认的项 —— 改完立刻生效") {
            VStack(spacing: 0) {
                sectionTitle("排版")
                fontSizeRow
                divider
                spacingRow
                divider
                pageStyleRow
                divider
                fontFamilyHint
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            VStack(spacing: 0) {
                sectionTitle("屏幕")
                brightnessRow
                divider
                SettingsToggleRow(icon: "sun.max", title: "阅读时保持屏幕常亮",
                                  isOn: $keepScreenOn, tint: Theme.tagBlue)
                divider
                SettingsToggleRow(icon: "hand.tap", title: "点击两侧都翻页",
                                  subtitle: "关闭后：点中间出菜单，点两侧才翻页",
                                  isOn: $tapNext, tint: Theme.tagBlue)
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            VStack(spacing: 0) {
                sectionTitle("正文")
                SettingsToggleRow(icon: "text.bubble", title: "显示段评气泡",
                                  subtitle: "书源在段落里给了段评时，段末冒一个小气泡",
                                  isOn: $paragraphComments, tint: Theme.tagGreen)
                divider
                conversionRow
                divider
                SettingsToggleRow(icon: "books.vertical", title: "读过的书自动加入书架",
                                  isOn: $autoAddToShelf, tint: Theme.tagGreen)
                divider
                preloadRow
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.ink.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 36)
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.sub)
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    // MARK: - 行

    private var fontSizeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat.size")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagBlue)
                .frame(width: 26)
            Text("字号")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text("\(Int(fontSize))")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, alignment: .trailing)
            Stepper("", value: $fontSize, in: 12...36, step: 1)
                .labelsHidden()
        }
        .padding(.vertical, 11)
    }

    private var spacingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagBlue)
                .frame(width: 26)
            Text("行距")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: $spacing) {
                ForEach(Self.spacingLevels, id: \.raw) { s in
                    Text(s.name).tag(s.raw)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .tint(Theme.accent)
        }
        .padding(.vertical, 11)
    }

    private var pageStyleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagBlue)
                .frame(width: 26)
            Text("翻页方式")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: $pageStyle) {
                ForEach(PageTurnStyle.allCases) { s in
                    Text(s.title).tag(s.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.accent)
        }
        .padding(.vertical, 11)
    }

    private var fontFamilyHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "character")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagBlue)
                .frame(width: 26)
            Text("正文字体")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text("在「字体」页选")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
        }
        .padding(.vertical, 11)
    }

    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.tagBlue)
                    .frame(width: 26)
                Text("亮度")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Toggle("跟随系统", isOn: Binding(
                    get: { followSystemBrightness },
                    set: { on in brightness = on ? -1 : clampedBrightness }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }
            if !followSystemBrightness {
                Slider(value: $brightness, in: 0...1)
                    .tint(Theme.accent)
            }
        }
        .padding(.vertical, 11)
    }

    private var conversionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagGreen)
                .frame(width: 26)
            Text("简繁转换")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: $conversion) {
                ForEach(ChineseConversion.allCases, id: \.rawValue) { c in
                    Text(c.title).tag(c.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.accent)
        }
        .padding(.vertical, 11)
    }

    private var preloadRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagGreen)
                .frame(width: 26)
            Text("预加载章节")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text("\(preload) 章")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
            Stepper("", value: $preload, in: 0...10, step: 1)
                .labelsHidden()
        }
        .padding(.vertical, 11)
    }

    /// ⭐⭐⭐ **行距三档**（柴阅的 `ReaderSettings.spacing` 是 0/1/2 三档，不是连续值）⭐⭐⭐
    private struct SpacingLevel: Identifiable {
        let raw: Int
        let name: String
        var id: Int { raw }
    }

    private static let spacingLevels: [SpacingLevel] = [
        SpacingLevel(raw: 0, name: "紧凑"),
        SpacingLevel(raw: 1, name: "标准"),
        SpacingLevel(raw: 2, name: "宽松"),
    ]
}

// MARK: - ② 阅读主题（柴阅 ReaderThemesScreen）

/// ⭐⭐⭐⭐⭐ **阅读主题页 = 柴阅的内置主题**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
///
/// ⚠️ **不再有「我们重写版的 16 套配色 + 4 套皮肤」** ⭐⭐⭐：
///   那是我们照着柴阅**观感重画**的产物（build322）⇒ 现在正文界面**整体换成柴阅原版**
///   ⇒ 主题也用柴阅的（`ReaderThemeSpec.all` = 宣纸 / 晴窗 / 星夜 / 烛灯 / 纸张 / 素白 / 豆绿 / 雾灰 / 暮色 / 夜间）⭐⭐⭐
///   ⇒ 自定义主题（CSS/JS）由柴阅自己的**外观面板**管理（`StylePanel` → 主题小页纸）⭐⭐⭐
struct ReaderThemesScreen: View {
    /// ⭐⭐⭐ 柴阅的浅色主题槽 ⭐⭐⭐
    @AppStorage("reader.lightTheme") private var lightTheme: String = "paper"
    /// ⭐⭐⭐ 柴阅的深色主题槽 ⭐⭐⭐
    @AppStorage("reader.darkTheme") private var darkTheme: String = "night"
    /// ⭐⭐⭐ 柴阅的自定义主题槽（选了自定义主题就盖过内置主题）⭐⭐⭐
    @AppStorage("reader.customTheme") private var customTheme: String = ""

    /// ⭐⭐⭐ **轻阅全局强制深色外观** ⇒ 阅读页里 `colorScheme` 恒为 `.dark`
    ///   ⇒ 柴阅的 `settings.theme(for: .dark)` 取的是 **`darkTheme`** ⇒ 用户在这里选的主题要写进 `darkTheme` ⭐⭐⭐
    ///   ⇒ 浅色主题同时写进 `lightTheme` ⇒ 万一以后不强制深色了，用户选的主题还在 ⭐⭐⭐
    private var currentId: String { customTheme.isEmpty ? darkTheme : customTheme }

    var body: some View {
        SettingsScreenScaffold(title: "阅读主题",
                               subtitle: "柴阅的内置主题 —— 皮肤与配色都在这里") {
            VStack(spacing: 0) {
                ForEach(Array(ReaderThemeSpec.all.enumerated()), id: \.element.id) { index, t in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.ink.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 36)
                    }
                    themeRow(t)
                }
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)
        }
    }

    private func themeRow(_ t: ReaderThemeSpec) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.bg)
                    .frame(width: 34, height: 42)
                Text("文")
                    .font(.system(size: 14))
                    .foregroundStyle(t.fg)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                Text(t.skin.map { "皮肤 · \($0.name)" } ?? (t.isDark ? "深色" : "浅色"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            if currentId == t.id {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { select(t) }
    }

    private func select(_ t: ReaderThemeSpec) {
        customTheme = ""
        darkTheme = t.id
        if !t.isDark { lightTheme = t.id }
    }
}

// MARK: - ③ 字体（柴阅 FontsScreen）

/// ⭐⭐⭐⭐⭐ **字体页 = 柴阅的字体选择**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
///
/// ⚠️ 柴阅的 `ReaderSettings.font` 是 **`ReaderFontChoice`（Int 原始值）** ⭐⭐⭐
///   ⇒ 键 `reader.font`；`reader.customFont` 是导入字体的 PostScript 名（优先级更高）⭐⭐⭐
struct FontsScreen: View {
    @AppStorage("reader.font") private var font: Int = ReaderFontChoice.song.rawValue

    var body: some View {
        SettingsScreenScaffold(title: "字体") {
            VStack(spacing: 0) {
                ForEach(Array(ReaderFontChoice.allCases.enumerated()), id: \.element.id) { index, f in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.ink.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 36)
                    }
                    fontRow(f)
                }
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)
        }
    }

    private func fontRow(_ f: ReaderFontChoice) -> some View {
        HStack(spacing: 12) {
            Text("永")
                .font(Self.previewFont(f, size: 20))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 42)
                .background(Theme.ink.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(f.name)
                .font(Self.previewFont(f, size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            if font == f.rawValue {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { font = f.rawValue }
    }

    /// 每项用它自己的字体渲染（柴阅同款）
    private static func previewFont(_ f: ReaderFontChoice, size: CGFloat) -> Font {
        switch f {
        case .song: return .custom("Songti SC", size: size)
        case .kai:  return .custom("Kaiti SC", size: size)
        case .ping: return .system(size: size)
        }
    }
}

// MARK: - ④ 缓存（柴阅 CacheScreen）

struct CacheScreen: View {
    @State private var sizeText: String = "计算中…"
    @State private var cleared = false

    var body: some View {
        SettingsScreenScaffold(title: "缓存") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.tagBlue)
                        .frame(width: 26)
                    Text("已下载的章节")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(sizeText)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.sub)
                }
                .padding(.vertical, 13)
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            Button {
                ContentCache.shared.clearAll()
                cleared = true
                sizeText = "已清空"
            } label: {
                Text(cleared ? "已清空" : "清除全部缓存")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("已下载的章节与封面都会删除，书架不受影响")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .task { sizeText = cacheSizeText() }
    }

    private func cacheSizeText() -> String {
        let dir = AppPaths.cacheDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                 includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for f in files {
            let sz = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(sz)
        }
        let mb = Double(total) / 1024 / 1024
        return mb < 0.1 ? "不到 0.1 MB" : String(format: "%.1f MB", mb)
    }
}

// MARK: - ⑤ 关于（柴阅 AboutScreen）

struct AboutScreen: View {
    var body: some View {
        SettingsScreenScaffold(title: "关于") {
            VStack(spacing: 0) {
                aboutRow("App", "轻阅 Lite", "qireaderlite")
                divider
                aboutRow("版本", "build \(AppBuildInfo.number)", "iOS 26+")
                divider
                aboutRow("规则引擎", EngineInfo.version, nil)
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            VStack(spacing: 0) {
                aboutRow("开源许可", "阅读界面参考柴阅（GPL-3.0）", "只读当规格，未拷贝其代码与资源")
                divider
                aboutRow("书源", "兼容 Legado 书源 JSON", nil)
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.ink.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 36)
    }

    private func aboutRow(_ title: String, _ value: String, _ note: String?) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.trailing)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub.opacity(0.8))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - ⑥ 备份（柴阅 BackupScreen）

/// 柴阅的备份是 WebDAV；轻阅**还没接** ⇒ 灰态摆位（不假装能点）。
struct BackupScreen: View {
    var body: some View {
        SettingsScreenScaffold(title: "备份",
                               subtitle: "轻阅还没接云备份 —— 这里先占位") {
            VStack(spacing: 0) {
                SettingsRow(icon: "icloud", title: "WebDAV 备份",
                            subtitle: "还没接", disabled: true)
                divider
                SettingsRow(icon: "square.and.arrow.up", title: "导出书源",
                            subtitle: "还没接", disabled: true)
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.ink.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 36)
    }
}
