import SwiftUI
import UIKit

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

/// ⭐⭐⭐ **阅读设置页** —— 柴阅把「细项」放这儿，面板只留高频项。
/// 这里是本轮从**被删掉的栖阅面板**里迁过来的全部细项。
struct ReadingSettingsScreen: View {
    @AppStorage("reader.paraAlign") private var paraAlign: String = "justify"
    @AppStorage("reader.verticalJustify") private var verticalJustify: Bool = false
    @AppStorage("reader.showBaseline") private var showBaseline: Bool = false
    @AppStorage("reader.baselineScope") private var baselineScope: String = "full"
    @AppStorage("reader.baselineColor") private var baselineColorHex: String = "#B8B8B8"
    @AppStorage("reader.tapAnywhere") private var tapAnywhere: Bool = true
    @AppStorage("reader.swipeUpExit") private var swipeUpExit: Bool = false
    @AppStorage("reader.twoPageSpread") private var twoPageSpread: Bool = false
    @AppStorage("reader.contentInHeaderFooter") private var contentInHeaderFooter: Bool = false
    @AppStorage("reader.pageTurn") private var pageTurn: Bool = true
    @AppStorage("reader.followSystem") private var followSystem: Bool = false

    private var baselineColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: baselineColorHex) },
            set: { baselineColorHex = $0.hexString }
        )
    }

    var body: some View {
        SettingsScreenScaffold(title: "阅读设置",
                               subtitle: "面板里放的是高频项；这些细项在这里改（柴阅也是这么分的）") {
            VStack(spacing: 0) {
                SettingsToggleRow(icon: "hand.tap", title: "点击页面任意位置翻页",
                                  subtitle: "关闭后：点中间出菜单，点两侧才翻页",
                                  isOn: $tapAnywhere, tint: Theme.tagBlue)
                divider
                SettingsToggleRow(icon: "arrow.up", title: "上滑退出阅读",
                                  isOn: $swipeUpExit, tint: Theme.tagBlue)
                divider
                SettingsToggleRow(icon: "book", title: "点两侧翻章",
                                  subtitle: "翻页方式在阅读页的「外观」面板里选",
                                  isOn: $pageTurn, tint: Theme.tagBlue)
                divider
                SettingsToggleRow(icon: "circle.lefthalf.filled", title: "跟随系统深浅色",
                                  isOn: $followSystem, tint: Theme.tagPurple)
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            VStack(spacing: 0) {
                sectionTitle("段落")
                SettingsToggleRow(icon: "arrow.up.and.down", title: "垂直两端对齐",
                                  subtitle: "每页文字自动调整行间距填满页面，底部对齐整齐",
                                  isOn: $verticalJustify, tint: Theme.tagGreen)
                divider
                alignRow
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            VStack(spacing: 0) {
                sectionTitle("行底线")
                SettingsToggleRow(icon: "line.3.horizontal", title: "显示行底线",
                                  isOn: $showBaseline, tint: Theme.tagGreen)
                if showBaseline {
                    divider
                    HStack(spacing: 10) {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.tagGreen)
                            .frame(width: 26)
                        Text("底线颜色")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        ColorPicker("", selection: baselineColorBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                    .padding(.vertical, 11)
                    divider
                    scopeRow
                }
            }
            .padding(.horizontal, 14)
            .glassCard(cornerRadius: 16, strong: true)

            VStack(spacing: 0) {
                sectionTitle("未实现")
                SettingsRow(icon: "rectangle.split.2x1", title: "宽屏同屏显示左右两页",
                            subtitle: "还没接", disabled: true)
                divider
                SettingsRow(icon: "rectangle.split.2x1.bottomhalf", title: "内容限制在页眉页脚之间",
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

    private var alignRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.justify")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagGreen)
                .frame(width: 26)
            Text("段落对齐")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: $paraAlign) {
                ForEach(ReaderParaAlign.all, id: \.raw) { a in
                    Text(a.name).tag(a.raw)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.accent)
        }
        .padding(.vertical, 11)
    }

    private var scopeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 17))
                .foregroundStyle(Theme.tagGreen)
                .frame(width: 26)
            Text("底线范围")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: $baselineScope) {
                ForEach(ReaderBaselineScope.all, id: \.raw) { s in
                    Text(s.name).tag(s.raw)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.accent)
        }
        .padding(.vertical, 11)
    }
}

// MARK: - ② 阅读主题（柴阅 ReaderThemesScreen）

/// 16 套配色 + 4 套皮肤（两层分开：配色 = 颜色，皮肤 = 版式与装饰）。
struct ReaderThemesScreen: View {
    @AppStorage("reader.theme") private var themeKey: String = "paper"

    var body: some View {
        SettingsScreenScaffold(title: "阅读主题",
                               subtitle: "配色管颜色，皮肤管字体与章节号装饰 —— 每套配色自带一个皮肤") {
            VStack(spacing: 0) {
                // ⚠️ 别用 `enumerated()`：元素类型变成元组 ⇒ `id:` 推不出 ID ⇒ 编译错 ⭐⭐⭐
                ForEach(ReaderTheme.all) { t in
                    if t.key != ReaderTheme.all.first?.key {
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

    private func themeRow(_ t: ReaderTheme) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.bg)
                    .frame(width: 34, height: 42)
                Text("文")
                    .font(.system(size: 14))
                    .foregroundStyle(t.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                Text("皮肤 · \(t.skin.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            if themeKey == t.key {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { themeKey = t.key }
    }
}

// MARK: - ③ 字体（柴阅 FontsScreen）

struct FontsScreen: View {
    @AppStorage("reader.fontKey") private var fontKey: String = "system"

    var body: some View {
        SettingsScreenScaffold(title: "字体") {
            VStack(spacing: 0) {
                ForEach(ReaderFont.all) { f in
                    if f.raw != ReaderFont.all.first?.raw {
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

    private func fontRow(_ f: ReaderFont) -> some View {
        HStack(spacing: 12) {
            Text("永")
                .font(ReaderFontPicker.fontFor(f, size: 20))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 42)
                .background(Theme.ink.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(f.name)
                .font(ReaderFontPicker.fontFor(f, size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            if fontKey == f.raw {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { fontKey = f.raw }
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
