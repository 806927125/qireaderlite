# 阅读界面全量柴阅化 —— 设计规格

日期：2026-11-25　｜　目标产物：build323
用户原话：「阅读界面是不是有老代码保留，全给替换成柴阅的，设置那些也要替换」

---

## 0. 参照对象与许可边界

- 参照物 = **柴阅（Chaiyue, github.com/Lincb522/Chaiyue）**，**不是**栖阅。
- 柴阅是 **GPL-3.0** ⇒ **只读源码当规格，不抄代码、不拷背景图/图标资源**。
  落地方式：抽取「结构 + 参数 + 行为」，在轻阅里**同名不同实现**重画；
  皮肤底图用「纯色底 + 渐变层次」代替柴阅的图片资源。
- 用户已确认的设计决定：
  1. 栖阅的 8 个功能磁贴 ⇒ **全部去掉**，阅读页面板**跟柴阅一模一样**（只有「目录」「外观」两个 sheet）。
  2. App 设置区 ⇒ **全部分成柴阅式独立子页**（含备份 / 缓存 / 字体 / 关于）。

---

## 1. 老代码盘点（本轮的靶子）

| # | 老代码 | 位置 | 现状 | 处置 |
|---|---|---|---|---|
| 1 | **栖阅的 WebView 阅读器** | `Core/ReaderHost.swift`(235) + `Resources/reader/{reader.html,reader.js,reader.css,reader-scroll-core.js}`(48KB) | 轻阅渲染早已全原生，但**仍在每次开书时加载并执行这 48KB JS**，在后台自己跑章节逻辑并往回发「回声」消息（源码注释自述"WebView 只是个影子"） | **删除**（含 `ReaderSession` 里的接线） |
| 2 | **栖阅的阅读设置面板** | `Features/Reader/ReaderWebView.swift` ~550 行（注释：「严格按 ui.txt / 尺寸.txt 重做，一处不加不减」） | 栖阅 CSS 规格 1:1 复刻：底部 overlay 磨砂玻璃大卡 + 16 个配色格子 + 8 个功能磁贴（6 个灰置空壳） | **按柴阅 StylePanel 重写** |
| 3 | 另一套简易阅读器 | `Features/Reader/ReaderView.swift`(308，含自己的 settingsSheet) | 无引用 | **删除** |
| 4 | 栖阅分组式 App 设置列表 | `Features/Settings/SettingsView.swift` | 栖阅规格 | **拆成柴阅式独立子页** |

> 判据：轻阅有两条渲染路径 —— `PagedReaderUI`（原生分页）与 `SwiftScrollReaderView`（原生滚动），
> **都不是 WebView** ⇒ 删 WebView 阅读器是零功能损失。

---

## 2. 柴阅的阅读页结构（要照抄的对象）

来源：`App/Sources/Reader/ReaderChrome.swift`、`StylePanel.swift`、`ReaderContainer.swift`、`ReaderModel.swift`。

### 2.1 外壳
- 顶栏 / 底栏 = **overlay**（不是 sheet）。
- 底栏 = `[‹][章节滑杆][›]` + **4 个工具**：目录 / 朗读 / 日夜 / **Aa 外观**。
  - 「Aa」用**衬线体文字**绘制（系统 `textformat` 图标在中文环境会变「格式」字样）。
- 面板**一律 sheet**：
  - 「外观」= `StylePanel`，`.presentationDetents([.height(548)])` + `.presentationDragIndicator(.visible)`
  - 「目录」= `TocSheet`，`.qSheet([.fraction(0.76), .large])`

### 2.2 StylePanel 的 6 个组件（逐个重画）
| 组件 | 柴阅规格 |
|---|---|
| `GlassSlider` | 细轨：胶囊轨 6pt + 填充 + 圆钮（拖动时 22→26）+ 阴影；竖向拖动不改值（留给下拉面板） |
| `FontSizeStepper` | `A`(14) / 数字(17 semibold, 36 宽) / `A`(21)，高 46，圆角 16，按压态；14…30 |
| `SpacingPicker` | 三档行距**图标**（`SpacingGlyph` 画 4 条线，间距 3.2/4.6/6.2），选中项 `matchedGeometryEffect` |
| `FontPicker` | 字体**分段**：每项**用自己的字体**显示；内置 3 种（宋/苹/楷）+ 导入字体横向滚动 |
| `ThemeStrip` | 横向滚动的**主题小页纸**卡片（`ThemeSwatch`），选中态高亮，`.onAppear` 滚到当前（居中） |
| 翻页方式行 | 一排胶囊 |

### 2.3 柴阅的 App「阅读设置」页（`ReadingSettingsScreen`）
字体 / 屏幕常亮 / 两侧都翻下一页 / 段评 / 自动加入书架 / 简繁转换 / 预加载 / TXT 目录规则
⇒ **轻阅多出来的排版细项放这里**（柴阅的位置）：段距、左右边距、首行缩进、行底线、垂直两端对齐、基线范围、双页、点击翻页。

---

## 3. 实施项

### A. 拆掉栖阅 WebView 阅读器
- 删 `QiReaderLite/Core/ReaderHost.swift`
- 删 `QiReaderLite/Resources/reader/` 4 个文件
- `Core/ReaderSession.swift`：删 `let host = ReaderHost()` 与 `wire()` 里全部 `host.on*` 接线；
  `start()` 不再等 `hostReady`、不再 `host.setSettings/apply`；
  `hostReady` 属性删除（若无其它引用）。
- ⚠️ `host.onRequestChapter` 原本负责「站方请求换章」⇒ 原生路径已有 `load(index:)`，确认不丢功能。
- 门禁：**扫不到任何 `ReaderHost` / `reader.html` / `reader.js` 引用**。

### B. 柴阅式「外观」面板
- 新增 `Features/Reader/ReaderStylePanel.swift`：
  - `ReaderStylePanel`（sheet 主体，6 行）
  - `GlassSlider` / `FontSizeStepper` / `SpacingPicker` / `FontPicker` / `ThemeStrip` / `ThemeSwatch`
- 主题条承载**轻阅 16 套配色**（`ReaderTheme`），每张卡片 = 一页纸预览（底色 + 文字色 + 三条示意行）；
  4 套**皮肤**（宣纸/晴窗/星夜/烛灯）仍决定字体 / 章节号装饰 / 进度装饰（build322 的「两层分开」决策不变）。
- **行距三档** ⇒ 预设组合（紧凑 / 标准 / 宽松），同时改 `lineSpacing` + `paragraphSpacing`。
- 面板从「底部 overlay」改成 **sheet**（与柴阅一致）。

### C. 面板收口
- 删栖阅 overlay 面板容器 + 8 个磁贴 + 其子页。
- 「目录」面板改成 sheet（`.fraction(0.76)` + `.large`）。
- 底栏第 2 个工具改名「外观」（柴阅用词），仍用衬线 `Aa`。

### D. App 设置区 ⇒ 柴阅式独立子页
- 入口页保留分组列表（柴阅的 Me/Settings 入口也是列表），但每一项点进去是**独立子页**：
  阅读设置 / 外观主题 / 缓存 / 备份 / 关于（+ 轻阅已有的替换净化、目录规则等归入对应子页）。
- 子页样式照柴阅 `SettingRow(icon:title:)` + `ToggleRow(icon:title:isOn:)`。

### E. 修章节号装饰的位置
- 现象（用户截图）：「第1章」朱印**贴在屏幕最顶、压在状态栏上**。
- 真因：画布铺满全屏，`drawChapterNumber` 用了画布坐标 `y≈2`，没扣安全区/正文区。
- 修法：装饰画在**正文区**内（页眉带之下），柴阅的位置 = **章标题那一行右侧**。

---

## 4. 验收

1. `bash test/run-all-gates.sh` **exit=0**，且汇总行齐全（不许「崩了」/「无汇总」）。
2. 新增门禁 `test/reader-chaiyue-clean.test.js`：
   - 源码里 **搜不到** `ReaderHost` / `reader.html` / `reader.js` / `reader.css`；
   - **搜不到** 栖阅面板的旧标记（`严格按 ui.txt`、`featureGrid`、`tiles`、`磁贴`）；
   - 柴阅面板 6 个组件**都在**（`GlassSlider`/`FontSizeStepper`/`SpacingPicker`/`FontPicker`/`ThemeStrip`）；
   - 「外观」是 **sheet**（`presentationDetents`）不是 overlay；
   - 发现页筛选键仍在（既有门禁）。
3. `test/syntax-parse-gate.sh` 全绿（语法错沙盒就能抓）。
4. CI（Xcode 真编译 + 真引擎测试）绿 ⇒ 出 `QingYue-build323.zip`，验 `CFBundleVersion=323`。
5. 交付说明写清「已做 / 未做 / 柴阅对应关系」。

## 5. 已知不做（本轮）
- 柴阅的**主题编辑器**（`ReaderThemeEditorScreen`，CSS 子集）—— 轻阅不做网页主题。
- 柴阅的**字体导入**（`FontsScreen`）—— 轻阅内置字体即可，导入留后。
- 柴阅的**朗读**完整实现（`SpeechController`/`LocalVoice`）—— 轻阅现有朗读能力维持。
- 柴阅的**段评/简繁转换/预加载**等功能项 —— 不属于阅读界面外壳，按需另做。
