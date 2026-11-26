#if os(iOS)
// ⭐⭐⭐⭐⭐ **柴阅内置主题包的【对外出口】**（2026-11-26 · 内置主题包入 App）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么要有这个文件**（宿主 App 要做「装入内置主题包」按钮）⭐⭐⭐：
//   柴阅的 `ReaderThemePreset` / `ReaderThemeStore.reload(_:from:)` / `store.save(_:)`
//   **全是 internal**（它们是阅读器内部件）⇒ 宿主 App **调不到** ⭐⭐⭐
//   ⇒ 而「装入」这一步必须用到 `store.importFile` / `store.save` / `store.reload`
//     （主题 id 是随机 UUID、改名要落盘、重复装入要原地更新）⇒ **只能在包内实现** ⭐⭐⭐
//   ⇒ 这里开一个 **public 出口**（不动柴阅一行逻辑）⇒ 宿主只调 `install(into:)` ⭐⭐⭐
//
// ⚠️⚠️ **为什么整体标 `@MainActor`**（2026-11-26）⭐⭐⭐：
//   本 target 是 `-default-isolation MainActor` ⇒ `ReaderThemeStore` / `ReaderThemePreset`
//   的成员**全是 MainActor 隔离**的 ⇒ 我们的 public 出口若不隔离，宿主调用时会报
//   「call to main actor-isolated instance method … in a nonisolated context」⭐⭐⭐
//   ⇒ 出口与被代理的类型**保持同样的隔离** ⇒ 宿主在 View body（本来就是 @MainActor）里用 ⇒ 没问题 ⭐⭐⭐
//
// ⚠️ **柴阅上游自己也没有「一键装」的界面**（它只在启动时 `syncInstalled()` 同步**已装过**的）
//   ⇒ 这一栏是**新增功能**（数据与包全部来自柴阅）⭐⭐⭐
import Foundation

/// 一个内置主题包（照搬柴阅 `ReaderThemePreset` 的数据）
@MainActor
public struct ChaiyuePresetTheme: Identifiable {
    /// ⭐⭐⭐ **`id` 标 `nonisolated`**：SwiftUI 的 `ForEach` 用 `\.id` 取 KeyPath，
    ///   那是非隔离求值 ⇒ id 若是 MainActor 隔离的 ⇒ 编译报
    ///   「main actor-isolated property 'id' can not be referenced from a nonisolated context」⭐⭐⭐
    public nonisolated let id: String
    public let name: String
    public let summary: String
    /// 卡片配色：纸色、字色、点缀色
    public let paper: UInt32
    public let ink: UInt32
    public let accent: UInt32
    /// 柴阅原版预设（internal 类型 ⇒ 只能作为 **private** 存储 ⇒ 不污染对外面）⭐⭐⭐
    private let preset: ReaderThemePreset

    init(_ preset: ReaderThemePreset) {
        self.preset = preset
        id = preset.id
        name = preset.name
        summary = preset.summary
        paper = preset.paper
        ink = preset.ink
        accent = preset.accent
    }

    /// 主题包在 App 包里的位置（没有 ⇒ 这套主题柴阅没放包 ⇒ 不可用）
    public var packageURL: URL? { preset.packageURL }

    /// 这套主题**能不能装**（柴阅的 `onepiece` / `shinchan` 仓库里没有包 ⇒ 不可用）
    public var isAvailable: Bool { packageURL != nil }

    /// 已经装进来的那份主题的 id（装过时记在 UserDefaults）
    public var installedThemeID: String? {
        UserDefaults.standard.string(forKey: "readerThemes.preset.\(id)")
    }

    /// 已经装进来了吗
    public func isInstalled(in store: ReaderThemeStore) -> Bool {
        guard let installedThemeID else { return false }
        return store.theme(installedThemeID) != nil
    }

    /// 装进「我的主题」
    ///
    /// ⚠️ **首次装入 vs 再次装入**（两种路径不一样）：
    ///   · 首次 ⇒ `store.importFile(url)` ⇒ 柴阅会生成**随机 UUID** 当主题 id ⇒ 我们把 id 记到
    ///     UserDefaults（`readerThemes.preset.<presetId>`）⇒ 下次能找到它 ⭐⭐⭐
    ///   · 再次 ⇒ `store.reload(existingID, from: url)` ⇒ **id 与名字不变**、原地更新内容
    ///     （柴阅 `reload` 的语义就是这样：只更新已存在的主题）⭐⭐⭐
    ///   ⇒ 返回装好后的那份主题（宿主用它把「自定义主题」区刷新出来、并直接选用）
    @discardableResult
    public func install(into store: ReaderThemeStore) -> CustomReaderTheme? {
        guard let url = packageURL else { return nil }
        // 再次装入 ⇒ 原地更新（id 不变 ⇒ 用户已选中的主题不用重选）
        if let installedThemeID, let existing = store.theme(installedThemeID) {
            try? store.reload(existing.id, from: url)
            return store.theme(existing.id)
        }
        // 首次 ⇒ 导入并改成中文名
        guard var theme = try? store.importFile(url) else { return nil }
        theme.name = name
        store.save(theme)
        UserDefaults.standard.set(theme.id, forKey: "readerThemes.preset.\(id)")
        UserDefaults.standard.set(theme.updated.timeIntervalSince1970,
                                  forKey: "readerThemes.preset.\(id).updated")
        return theme
    }
}

/// 柴阅的全部内置主题包
@MainActor
public enum ChaiyuePresetThemes {
    /// 照搬柴阅的预设清单（`ReaderThemePreset.all`）
    public static let all: [ChaiyuePresetTheme] = ReaderThemePreset.all.map { ChaiyuePresetTheme($0) }

    /// App 更新带来新版主题包时，同步到已装入、且用户没改过的那份（柴阅启动时也会做）
    @MainActor
    public static func syncInstalled(into store: ReaderThemeStore = .shared) {
        ReaderThemePreset.syncInstalled(store)
    }
}
#endif  // #if os(iOS)
