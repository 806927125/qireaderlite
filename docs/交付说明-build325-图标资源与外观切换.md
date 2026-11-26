# 轻阅 Lite build325 —— 修 build324 真机三条：图标全没了 / 日夜切不动 / 主题切不动

日期：2026-11-26　｜　CFBundleVersion **325**　｜　包名 `com.qireaderlite.app`　｜　CI **45800043404**

> 真机反馈（build324）：
> ① **日间夜间切换不了**　② **悬浮栏显示 bug，目录这些图标没了**　③ **主题切换也有 bug**
> ⇒ 三条症状，**两个根因**，都不是柴阅逻辑错，是**移植时漏了东西 / 两套机制打架**。

---

## 0. 结论先说

| 症状 | 真根因 | 修法 |
|---|---|---|
| ② 悬浮栏图标全没了、主题小页纸糊成一团 | **柴阅的图标不是系统 SF Symbols，而是自绘资源**（`Assets.xcassets/Icons/cy.*.symbolset` 144 个 + `Theme-*` 皮肤图 4 张）⇒ **上一版只搬了 Swift 源码、没搬资源** | 把资源搬进 `QiReaderLite/Resources/Assets.xcassets/` |
| ① 日/夜切不动 | 柴阅 `AppearanceStore.apply()` 改**整个窗口**的 `overrideUserInterfaceStyle`，而轻阅**根部强制 `.preferredColorScheme(.dark)`** ⇒ **两边打架** | `apply()` 不再改窗口；改由**阅读器这一层**用 SwiftUI 施加 |
| ③ 选浅色主题切不动 | **同一个根因**：柴阅 `select()` 把浅色主题写进 `lightTheme` 槽，而当前 scheme 恒为 `.dark` ⇒ `theme(for:)` 一直读 `darkTheme` ⇒ 纸面不变 | 同上（外观能切了，浅色主题自然生效） |

---

## 1. 根因一：柴阅的图标是**自绘资源**，我们只搬了代码

柴阅的 `Image(icon:)`（`App/Sources/Design/Icons.swift`）：

```swift
extension Image {
    nonisolated init(icon name: String) {
        if IconNames.all.contains(name) {
            self.init("cy." + name)      // ← 自绘资源，资源名带 cy. 前缀
        } else {
            self.init(systemName: name) // ← 系统 SF Symbol 兜底
        }
    }
}
```

⚠️ **`IconNames.all` 里的 144 个名字全部走 `cy.` 分支**（不走系统兜底）⇒
**资源没搬 ⇒ 这 144 个图标一个都显示不出来** ⇒ 悬浮栏（`list.bullet` / `headphones` / `sun.max` / `textformat`）全空 ✓ 与真机一致。

⭐⭐⭐ **我们上一版 vendor 时只搬了 Swift 源码、漏了 `Assets.xcassets`** ⇒ 这是这轮最大的教训：
**「源码搬过来了」≠「能跑」—— 资源、图标、字体、storyboard 都是「源码的一部分」** ⭐⭐⭐

**修**：把柴阅的 `Icons/`（144 个 `cy.*.symbolset`，SVG 矢量，1.6 MB）+ 4 张 `Theme-*.imageset` 皮肤图
搬进 `QiReaderLite/Resources/Assets.xcassets/`。
⭐ 轻阅的 Xcode 工程用的是**文件系统同步组**（`PBXFileSystemSynchronizedRootGroup`，`path = QiReaderLite`）
⇒ **资源拷进去即自动进包，不用改 pbxproj** ⭐⭐⭐

---

## 2. 根因二：轻阅的「全局强制深色」vs 柴阅的「外观切换」打架

| 一方 | 机制 |
|---|---|
| 轻阅 | 根部 `.preferredColorScheme(.dark)`（2026-11-24 真机反馈：玻璃按钮乳白）⇒ **SwiftUI 层**一直要 `.dark` |
| 柴阅 | `AppearanceStore.apply()` 遍历所有窗口写 `overrideUserInterfaceStyle` ⇒ **UIKit 层**要 `.light` |

⇒ 两个机制**互相覆盖** ⇒ 阅读器底部「日间/夜间」按钮点了没反应；
连带「选浅色主题」也切不动（`select()` 写 `lightTheme` 槽，但 `theme(for:)` 读的是 `darkTheme`）。

**修（只动我们自己的面，不动柴阅逻辑）**：

1. 包内 `AppearanceStore.apply()`：**不再遍历窗口**，只把状态写进 `UserDefaults["appearance"]`；
   写盘挪到 `apply()` 里（原来在 `set()` 开头就写 ⇒ CircularReveal 拍到的快照已是浅色 ⇒ **转场动画失效**）。
2. 宿主 `ChaiyueReaderScreen`：`@AppStorage("appearance")` 读该状态 ⇒ `.preferredColorScheme(...)` 施加
   （**叶子优先 ⇒ 盖过根部强制深色**）。

⇒ 结果：**只有阅读器变浅色，轻阅其它界面永远深色**（玻璃按钮不乳白）⇒ 两个目的都达到 ⭐⭐⭐

⚠️ 「自动（跟随系统）」档在轻阅里**按深色处理** —— 因为轻阅全局强制深色，跟随系统会被打回原形。
⇒ 这是有意的取舍，写在这里备查。

---

## 3. 顺手修的

- `DesignCompat.swift` 里那份 `SheetBackground` 与上游搬来的**同名不同实现**（上游只有一份 ⇒ 那份是我们自己补的）
  ⇒ 改名 `QSheetBackground` ⇒ `app-type-sanity` 由 **15/1 变 16/0**（基线红顺手修绿）⭐⭐⭐

---

## 4. 新门禁（防再犯）

`test/reader-chaiyue-assets-appearance.test.js`（**14 项，3 条变异对照**）：

1. `IconNames.all` 与 `Icons/cy.*.symbolset` **必须一一对应** + 四张皮肤图必须在
   （⇒ 再有人只搬代码不搬资源，门禁立刻红）⭐⭐⭐
2. `AppearanceStore.apply()` **不得**再出现 `overrideUserInterfaceStyle`（剥注释后判）
3. 宿主阅读器**必须**读 `appearance` 键并施加 `.preferredColorScheme`

⚠️ 门禁判据**必须剥注释** —— 否则「注释里解释了为什么去掉它」会被当成「代码里还在」⇒ 门禁永远红 ⇒ 变摆设 ⭐⭐⭐
⚠️ 变异对照**必须先剥注释再替换** —— 否则正则的 `[^)]*` 会跨行匹配，把注释尾巴和代码一起吃掉 ⇒ 变异失效 ⭐⭐⭐

---

## 5. 验证

- CI **45800043404**（main，commit `ddc1eac`）：编译 + 5 个探针 + 柴阅引擎权威测试 全绿
- 门禁：全量 JS 门禁无回归；新门禁 14/14；阅读器相关 42/34/39/54 全绿
- 产物：`QingYue-build325.zip`（+ `-noprov`）⇒ 解包验 **CFBundleVersion = 325** ✔
- **二进制体检（实测）**：
  | 项 | 结果 |
  |---|---|
  | `CFBundleVersion` | **325** ✔（`com.qireaderlite.app` / `CFBundleShortVersionString 3.6` / 最低 iOS 26.0） |
  | `Assets.car` | 2,156,888 B（build324 只有几百 KB ⇒ **图标与皮肤图真进包了**）⭐⭐⭐ |
  | 悬浮栏四个图标 | `cy.list.bullet` / `cy.headphones` / `cy.sun.max` / `cy.textformat` **全部命中** ✔ |
  | 四张皮肤图 | `Theme-xuan` / `Theme-qing` / `Theme-xing` / `Theme-zhu` **全部命中** ✔ |
  | 外观切换 | 二进制里**查不到 `overrideUserInterfaceStyle`** ⇒ 确实不再用 UIKit 改窗口 ✔ |
  | 老阅读器符号 | 9 个**全部 0 命中** ✔（柴阅符号 `ReaderContainer`/`ReaderChrome`/`ReaderSkin`/`StylePanel` 全在）|
  | 产物体积 | IPA 7.6 MB（build324 是 6.1 MB ⇒ 差值就是图标+皮肤图）⭐⭐⭐ |
