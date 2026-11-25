import Foundation

/// 主题库里的预设主题：点一下就从内置主题包复制一份进「我的主题」，之后可以随意改
struct ReaderThemePreset: Identifiable {
    let id: String
    let name: String
    let summary: String
    /// 卡片配色：纸色、字色、点缀色
    let paper: UInt32
    let ink: UInt32
    let accent: UInt32

    static let all: [ReaderThemePreset] = [
        shiba, stickerJournal, onePiece, shinchan, galaxy, celadon, eink, sakura, starter
    ]

    static let shiba = ReaderThemePreset(
        id: "shiba", name: "小柴 · 陪你读一会", summary: "章题居中，小柴停在页面下沿",
        paper: 0xFFFAE9, ink: 0x242334, accent: 0x8E6830
    )

    // MARK: - 主题包预设（与 docs/theme-dev/examples 同步，改完用 tools/pack.py 重新打包）

    static let stickerJournal = ReaderThemePreset(
        id: "sticker-journal", name: "贴纸手帐 · 奶油小日子", summary: "装订手帐，胶带纸卡和橘猫",
        paper: 0xFAF6F0, ink: 0x45413E, accent: 0xA55545
    )

    static let onePiece = ReaderThemePreset(
        id: "onepiece", name: "海贼王 · 草帽航海日志", summary: "航海日志，梅利号标记进度",
        paper: 0xFAF3E6, ink: 0x3A3028, accent: 0xA84534
    )

    static let shinchan = ReaderThemePreset(
        id: "shinchan", name: "蜡笔小新 · 春日部放学后", summary: "蜡笔画框，彩色蜡笔进度",
        paper: 0xFFF8E9, ink: 0x35323A, accent: 0xB84539
    )

    static let galaxy = ReaderThemePreset(
        id: "galaxy", name: "星河 · 星间漫游", summary: "星轨章头，火箭在航程仪表里",
        paper: 0xF4F3FA, ink: 0x37374E, accent: 0x635599
    )

    static let celadon = ReaderThemePreset(
        id: "celadon", name: "青瓷 · 一卷山水", summary: "竖向章签，锦鲤游过页底",
        paper: 0xF2F7F1, ink: 0x2C413C, accent: 0x426F61
    )

    static let eink = ReaderThemePreset(
        id: "eink", name: "墨水屏 · 黑白书房", summary: "黑白扉页，大章号居中",
        paper: 0xF7F7F3, ink: 0x292A28, accent: 0x363834
    )

    static let sakura = ReaderThemePreset(
        id: "native-sakura", name: "樱花信笺 · 花间来信", summary: "居中信笺，页角留给樱枝",
        paper: 0xFAF3F3, ink: 0x45383E, accent: 0xA4556F
    )

    static let starter = ReaderThemePreset(
        id: "starter-web", name: "我的主题 · 云边书签", summary: "星星书签，页底是云岸和月亮",
        paper: 0xF2F7F8, ink: 0x33434B, accent: 0x436E82
    )

    /// 内置主题包的文件地址（Resources/Themes/<id>.chaiyuetheme）
    var packageURL: URL? {
        Bundle.main.url(forResource: id, withExtension: "chaiyuetheme", subdirectory: "Themes")
            ?? Bundle.main.url(forResource: id, withExtension: "chaiyuetheme")
    }

    /// 从这个预设导入的那份主题的 id
    var installedKey: String { "readerThemes.preset.\(id)" }
    /// 导入（或上次同步）时那份主题的 updated；之后用户改过就不再自动覆盖
    private var stampKey: String { "readerThemes.preset.\(id).updated" }

    func markInstalled(_ theme: CustomReaderTheme) {
        UserDefaults.standard.set(theme.id, forKey: installedKey)
        UserDefaults.standard.set(theme.updated.timeIntervalSince1970, forKey: stampKey)
    }

    /// App 更新带来新版主题包时，同步到已导入、且用户没改过的那份
    @MainActor
    static func syncInstalled(_ store: ReaderThemeStore = .shared) {
        let defaults = UserDefaults.standard
        for preset in all {
            guard let theme = store.theme(defaults.string(forKey: preset.installedKey)), let url = preset.packageURL else { continue }
            let stamp = defaults.double(forKey: preset.stampKey)
            if stamp > 0, theme.updated.timeIntervalSince1970 > stamp + 1 { continue }
            guard (try? store.reload(theme.id, from: url)) == true, let updated = store.theme(theme.id) else { continue }
            preset.markInstalled(updated)
        }
    }
}
