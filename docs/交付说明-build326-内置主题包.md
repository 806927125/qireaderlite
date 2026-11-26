# 轻阅 Lite build326 —— 柴阅的 7 个内置主题包（连「一键装」那一栏）

日期：2026-11-26　｜　CFBundleVersion **326**　｜　包名 `com.qireaderlite.app`　｜　CI **45817272734**

> 用户拍板：「**要**」⇒ 把 build325 交付说明里列为「已知缺口 / 需你拍板」的那一项做掉：
> 柴阅自带的 **7 个内置主题包**（celadon / eink / galaxy / native-sakura / shiba / starter-web / sticker-journal，共 11 MB），
> 并**新增「一键装」那一栏**（柴阅上游自己没给这个界面）。

---

## 0. 为什么这算「新增功能」而不是「搬」

⭐⭐⭐ 柴阅的 `ReaderThemePreset` 里**列了 9 个预设**，但上游 `App/Resources/Themes/` 只放了 **7 个包**
（`onepiece` 海贼王 / `shinchan` 蜡笔小新 **仓库里没有包** ⇒ 轻阅显示「未内置」）⭐⭐⭐

⭐⭐⭐ 而且柴阅上游**根本没有「一键装」的界面** —— 它只在 App 启动时 `syncInstalled()` 同步**已经装过**的那几份
（用户得自己想办法拿到 `.chaiyuetheme` 文件）⇒ **这一栏是轻阅新增的**，数据与包全部来自柴阅 ⭐⭐⭐

---

## 1. 资源：为什么打 `.bundle` 而不是直接丢进 Resources

⚠️ `.chaiyuetheme` 是**自定义扩展名**（其实是 zip）⇒ **Xcode 对「未知类型文件」的处理不稳**
（可能展平目录、也可能干脆忽略）⇒ 不能赌。

⇒ 正解：把 7 个包放进 **`QiReaderLite/Resources/ChaiyueThemes.bundle/Themes/`**（`.bundle` 一定是资源）
⇒ 并给 `ReaderThemePreset.packageURL` 加**三级兜底**：

```swift
Bundle.main.url(forResource: id, withExtension: "chaiyuetheme", subdirectory: "Themes")
    ?? Bundle.main.url(forResource: id, withExtension: "chaiyuetheme")
    ?? Bundle.main.url(forResource: "ChaiyueThemes", withExtension: "bundle")
        .flatMap { Bundle(url: $0) }?
        .url(forResource: id, withExtension: "chaiyuetheme", subdirectory: "Themes")
```

⚠️ 轻阅的 Xcode 工程用**文件系统同步组**（`PBXFileSystemSynchronizedRootGroup`）⇒ 资源拷进去即自动进包，不用改工程 ⭐⭐⭐

---

## 2. 包内 public 出口（`PublicPresetThemes.swift`）

⚠️⚠️ **「装入」这一步必须在包内实现**，因为柴阅的
`ReaderThemeStore.importFile(_:)` / `save(_:)` / `reload(_:from:)` / `theme(_:)` **全是 internal** ⇒ 宿主 App 根本调不到。

⇒ 包内开一个 public 出口（**不动柴阅一行逻辑**）：

| 出口 | 作用 |
|---|---|
| `ChaiyuePresetTheme` | 一套内置包（id / 中文名 / 摘要 / 纸色 / 墨色 / 点缀色） |
| `.isAvailable` | 柴阅没放包的（onepiece / shinchan）⇒ false ⇒ 界面显示「未内置」 |
| `.isInstalled(in:)` | 装过没有 |
| `.install(into:)` | **首次** ⇒ `importFile`（柴阅生成随机 UUID ⇒ 我们把 id 记进 UserDefaults）<br>**再次** ⇒ `reload(existingID, from: url)`（**id 与名字不变**、原地更新） |
| `ChaiyuePresetThemes.all` | 照搬柴阅的预设清单 |
| `.syncInstalled(into:)` | App 更新带来新版主题包时同步（柴阅启动时也会做） |

⭐⭐⭐ **两个 Swift 隔离坑（本地用 swiftc 双模块小样复现并验证修法）**⭐⭐⭐：

1. **出口整体标 `@MainActor`** —— 本 target 是 `-default-isolation MainActor`
   ⇒ `ReaderThemeStore` / `ReaderThemePreset` 的成员**全是 MainActor 隔离**的
   ⇒ 出口不隔离 ⇒ 宿主访问报「call to main actor-isolated … in a nonisolated context」⭐⭐⭐
2. **`id` 标 `nonisolated`** —— SwiftUI 的 `ForEach` 用 `\.id` 取 KeyPath，那是非隔离求值
   ⇒ id 若是隔离的 ⇒ 报「main actor-isolated property 'id' can not be referenced from a nonisolated context」⭐⭐⭐

---

## 3. 宿主 UI：设置页「阅读主题」新增「内置主题包」一栏

- 位置：`QiReaderLite/Features/Settings/SettingsScreens.swift` 的 `ReaderThemesScreen`
- 形态：**横滑卡片**（纸色小样 + 柴阅中文名 + 摘要 + 「装入 / 已装入 / 未内置」）
- 装入后**直接选用**（写 `reader.customTheme`）⇒ 用户马上看到效果
- 主题落在柴阅的**「自定义主题」区**（CSS/JS 主题 ⇒ 柴阅的 `ThemeStore` 管）⇒ 与柴阅同一条链 ⭐⭐⭐
- ⚠️ `ReaderThemesScreen` 整体标 `@MainActor`（访问包内隔离成员必需）

---

## 4. 新门禁（19 项 / 4 条变异对照）

`test/reader-chaiyue-preset-themes.test.js` ⇒ 四条判据，缺一条这功能就是坏的：

| 判据 | 内容 |
|---|---|
| ① **包在** | 7 个 `.chaiyuetheme` 都在 bundle 里，且每个**是合法 zip**（不是 zip ⇒ 柴阅解不了） |
| ② **找得到** | `packageURL` 有 `.bundle` 兜底 |
| ③ **装得进** | 包内有 public 出口 + `install(into:)` + `@MainActor` |
| ④ **点得着** | 宿主有这一栏、列的是柴阅清单、真调 `install(into:)`、View 标了 `@MainActor` |

---

## 5. 验证

- CI **45817272734**（main，commit `3422c43`）：编译 + 5 个探针 + 柴阅引擎权威测试 全绿
- 门禁：新门禁 19/19；全量 JS 门禁无回归（`app-type-sanity` 16/0）
- 产物：`QingYue-build326.zip`（+ `-noprov`）⇒ 解包验 **CFBundleVersion = 326** ✔
- **二进制体检（实测）**：
  | 项 | 结果 |
  |---|---|
  | `CFBundleVersion` | **326** ✔（`com.qireaderlite.app` / `CFBundleName QingYue`） |
  | 内置主题包 | `ChaiyueThemes.bundle/Themes/` 里 **7 个 `.chaiyuetheme` 全在**，且每个都是**合法 zip**（`PK` 头）⭐⭐⭐ |
  | 图标资源没丢 | `cy.list.bullet` / `cy.headphones` / `cy.sun.max` / `cy.textformat` / `Theme-xuan` **全部命中** ✔ |
  | 外观切换 | 二进制里**查不到 `overrideUserInterfaceStyle`** ⇒ 仍不再用 UIKit 改窗口 ✔ |
  | 老阅读器符号 | 9 个**全部 0 命中** ✔（柴阅符号 + `ChaiyuePresetThemes` 全在） |
  | 体积 | IPA **7.6 MB → 19.2 MB**（差值 11.6 MB = 7 个主题包）⭐⭐⭐ |
