# 轻阅 Lite build324 —— 阅读器「整包 vendor 柴阅源码」+ 大灰狼 0 本定责

日期：2026-11-26　｜　CFBundleVersion **324**　｜　包名 `com.qireaderlite.app`　｜　CI **45792653474 绿**

> 用户原话：「**把阅读正文界面的，老的代码全部删掉，全部用柴阅的**」
> 配套问题：「**你是不是柴阅没有移植完！**」（大灰狼聚合 5.9.30 发现页 0 本）

---

## 0. 一句话结论

build321~323 是「**照着柴阅重画**」（观感重写，代码还是我们自己的）；
**build324 才是「真搬柴阅源码」**：`App/Sources/Reader` 与 `Packages/ReaderCore` 三个模块**整包 vendor 进 SPM**，
宿主改走柴阅权威链，**我们手写的老阅读器整套删光**。

同时，**大灰狼「0 本」的定责也在这一版一起发**（用户要「一起」）⇒ **站方接口报错 ≠ 书源规则过时**。

---

## 1. 搬进来的是什么（柴阅原版源码，一字未改的部分）

| 模块 | 来源 | 体量 | 作用 |
|---|---|---|---|
| `ChaiyueReaderKit` | `Packages/ReaderCore/Sources/ReaderKit` | 1622 行 | 排版分页 / CSS / 主题脚本 / 偏移映射 |
| `ChaiyueReaderServices` | `Packages/ReaderCore/Sources/ReaderServices`（阅读子集） | 2749 行 | 正文服务 / 内容处理 / 书架仓 / 书源仓 / 朗读 / 章节缓存 |
| `ChaiyueReader` | `App/Sources/Reader` | ~9.6K 行 | **阅读界面本体**（`ReaderContainer` / `ReaderChrome` / `ReaderSkin` / `StylePanel` / `ReaderVoiceSheet` …） |

⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 这三个目录是柴阅源码。
用户此前已决定**自用、不分发** ⇒ 不触发 GPL 分发义务（见 `docs/移植-柴阅引擎.md`）；
**一旦把二进制分发给他人 / 上架 ⇒ 必须整体 GPL-3.0 + 提供对应源码**。

---

## 2. 删掉了什么（老阅读器整套清零）

| 删除项 | 位置 |
|---|---|
| 自研分页器 / 原生滚动核心 | `Features/Reader/Paging/*`（`ReaderPageVC` `PagedReaderUI` `PagedChapterPager` `ReaderPaginator` `ReaderLayoutConfig` `QRSlider` `SwiftScrollReaderView` `ReaderScrollCore`） |
| 栖阅那套 WebView 阅读器外壳 | `Features/Reader/ReaderWebView.swift` |
| 我们重写的皮肤 / 外观 | `Features/Reader/ReaderSkin.swift` `ReaderSkinBackground.swift` `ReaderStylePanel.swift` `ReaderTheme.swift` |
| 我们自己的阅读会话 | `Core/ReaderSession.swift`（换成柴阅的 `ReaderSession`） |

门禁 `test/reader-chaiyue-host.test.js` **双向盯着**：老符号必须 **0 命中**（连注释里都不许提），
柴阅阅读器必须在（`ReaderContainer(launch:)` + `.environment(app)`）⇒ 42 项绿，带变异对照。

---

## 3. 宿主怎么接上的

```
轻阅 App
 └─ Features/Reader/Chaiyue/
      ├─ ChaiyueReaderAdapter  轻阅 Book/Chapter/BookSource → 柴阅模型
      ├─ ChaiyueReaderHost     门面实现 + 书架/目录/书源镜像 + 进度回写
      └─ ChaiyueReaderScreen   开柴阅的 ReaderContainer
```

⭐ **只开「宿主可见性面」**（SwiftPM target 默认 internal ⇒ 宿主看不见）：
`ChaiyueReaderLibrary` `AppModel` `ReaderLaunch` `ReaderContainer`
`ReaderThemeSpec` `ReaderThemeMode` `CustomReaderTheme` `ReaderThemeStore` `ReaderFontChoice`
—— 其余 shim 仍是 internal（避免牵连 `AppearanceStore`/`IslandCenter` 一整串的公开面雪崩）。

⭐ **进度不分叉**：宿主先造柴阅的 `ReaderSession` 并缓存，柴阅的 `ReaderContainer` 随后调
`app.library.readerSession(for:)` 拿到的**就是同一份** ⇒ 正文只拉一次、进度只有一份。
退出时 `session.position.chapterIndex` 回写轻阅书库（轻阅口径 = 正章节下标，与柴阅的整表下标换算）。

---

## 4. 大灰狼「发现页 0 本」的定责（同一版一起发）

**结论：不是书源规则过时，也不是移植没完 ⇒ 是站方后端连不上七猫上游。**

沙盒直连站方实测（`/sources/🍅大灰狼聚合5.9.30-轻阅适配版v2.json`）：

| 平台 | 结果 |
|---|---|
| 七猫 `/discovedata` | **293 B** `{"code":-1,"msg":"Get \"https://api-bc.wtzw.com/api/v4/category/get-list?...\": EOF","data":null}` ⇒ **8 条线路 × 10 次全断，报文一字不差** |
| 番茄 `/get_discover` | HTTP 200 / **25,894 B** / code=0 / **23 本书** ⇒ 正常 |
| 换 UA / 加 Referer / 加 Cookie | **无影响** ⇒ 与我们无关 |

⇒ 官方「没问题」是因为它停在**默认平台番茄** ⇒ 是**平台维度差异**。
⇒ 落地：站方 JSON 里 `code != 0` ⇒ 判定写成「**站方接口报错 code=…：… ⇒ 站方/上游挂了，不是书源规则问题**」，
`data == null` 绝不再报「规则没匹配」（`LegadoPublicAPI.swift` + `SourceService.swift` + 门禁 34 项 + 2 条变异对照）。

---

## 5. 已知缺口（这一版**没有**的功能，交付时一并说明）

| 项 | 状态 | 影响 |
|---|---|---|
| 应用内**换源面板**（`ChangeSourceSheet`） | 空实现 | 阅读器里不能一键换源 ⇒ 换源走站方自己的登录/书源界面 |
| **TXT 分章/重排**（`TxtSplitSheet`） | 空实现 | 轻阅当前没有本地书入口 ⇒ 用不到 |
| 阅读器内**直接登录**（`SourceLoginSheet`） | 兜底提示 | 真登录面板在 App 侧「书源 → 登录」（走柴阅的 `resolveLoginRows` 求值按钮） |
| **本地书**（`LocalBookStore`） | 桩（`handles()` 恒 false） | EPUB/TXT 本地书未接 ⇒ 一旦走到会**明确报错**，不静默空目录 |
| **语音包**（`LocalVoice`） | 降级为系统 TTS | 朗读可用，音色只有系统音色 |
| 媒体层（听书/漫画/短剧） | 不在阅读器范围 | 柴阅的 `AudioBookPlayer` 等没搬 |

---

## 6. 这一轮踩的编译坑（都写进 `docs/柴阅阅读器移植-分工与地图.md` 了）

1. ⭐⭐⭐ **SwiftPM target 默认 internal ⇒ 宿主看不见** ⇒ CI 报一屏 `cannot find type`；
   ⇒ **只开宿主要用的面**，别全 public 化（会雪崩）；**凡宿主要 new 的类型必须显式 `public init`**
   （`public struct` 的默认 memberwise init 是 internal）。
2. ⭐⭐⭐ **条件编译要把 import 一起圈进去**，且**别用 `canImport(SwiftUI)` 当 iOS 守卫**
   （macOS 有 SwiftUI 没 UIKit ⇒ 等于没守）⇒ 用 `#if os(iOS)`。
3. ⭐⭐⭐ **跨模块协议实现要注意 sendability**：`ChaiyueEngine`（v5）与 `ChaiyueReader`（v6）
   对 `@MainActor (…) -> Void` 的推断不同 ⇒ **两侧都显式写 `@Sendable`**（本地已复现并验证三套修法）。
4. ⭐⭐ **柴阅的 `Book` 没有无参 init**（designated init 首参是 `bookUrl`）；轻阅的 `Book` 模型**没有 `totalChapterNum`**。
5. ⭐⭐ **柴阅上游两个 target 编译设置不同**：包层纯 Swift 6，app 层 `+ -default-isolation MainActor + ApproachableConcurrency`
   ⇒ 分层照抄，探针/测试 target 钉 `.v5`。

---

## 7. 验证

- CI **45792653474（分支）/ 45794615057（main）**：编译 + 5 个探针 + 柴阅引擎权威测试 **全绿**
- 门禁：阅读器相关 **42 项**、大灰狼定责 **34 项**、语法 parse **57 项** …… 均带变异对照
- 产物：`QingYue-build324.zip`（内含 `QingYue.ipa`）⇒ 解包验 **CFBundleVersion = 324** ✔
