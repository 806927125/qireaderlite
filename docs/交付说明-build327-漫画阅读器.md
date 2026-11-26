# 轻阅 Lite build327 —— 把柴阅的【漫画阅读器】搬过来

日期：2026-11-26　｜　CFBundleVersion **327**　｜　包名 `com.qireaderlite.app`　｜　CI **45833353016**

> 用户原话：「**是不是还没搬完全，柴阅不是可以看漫画的吗，你把漫画阅读器也搬过来啊**」

---

## 0. 先说清一件事：这个功能对轻阅**不是鸡肋**

⭐⭐⭐ 柴阅的漫画阅读器 = `App/Sources/Media/Comic/`（**6 个文件 1941 行**）独立的一套翻页阅读器。

⭐⭐⭐ **关键在数据链**：柴阅的漫画**没有单独的「漫画接口」** —— 它的图**就是章节正文里的 `<img>`**：

```swift
// 柴阅 MediaSession.images(at:)
let raw = try await content(at: index)          // ← 正常拉章节正文
let paragraphs = processor.paragraphs(content: raw, ...)
let sources = ChapterText(...).imageSources    // ← 从正文里抽图片地址
```

⇒ **`MediaSession` + `ChapterText.imageSources` 我们包里早就有**（在 `ChaiyueReaderServices`）
⇒ **只差界面层** ⭐⭐⭐

⭐⭐⭐ 而且这正好是「老 WebView 阅读器时代能看、现在看不了」的根因：
老阅读器把章节正文塞进 WebView ⇒ 正文里的 `<img>` 直接渲染出来（虽然只是图片滚动，不是翻页）；
换成柴阅的原生排版后，那些图被当成**正文插图** ⇒ 站方漫画源**打不开** ⭐⭐⭐

---

## 1. 搬了什么（柴阅源码一字未改）

| 内容 | 上游出处 | 体量 |
|---|---|---|
| 漫画阅读器 6 文件 | `App/Sources/Media/Comic/` | 1941 行 |
| 形态角标/文案 | `App/Sources/Media/MediaKindStyle.swift` | 56 行 |
| 媒体启动对象 | `App/Sources/App/AppModel.swift`（`MediaLaunch` / `app.media` / `closeMedia()`） | ~15 行 |

与上游的 diff **只有三处**：
① `import ReaderModels/ReaderServices` → `ChaiyueModels/ChaiyueReaderServices`（模块改名）
② 整文件包进 `#if os(iOS)`（漫画用满 UIKit ⇒ macOS/Linux 编不到）
③ 需要跨模块用的成员升 public（`ComicReaderScreen` / `MediaLaunch` / `app.media` / `closeMedia()` / `MediaKindStyle` 的三个成员）

---

## 2. ⭐⭐⭐ 真正的断点：站方的 `book.type` 在宿主↔引擎往返里被丢了

柴阅靠 `book.type` 判形态（**iOS 约定 `2`=图片；Legado 安卓是位标记 `64`=图片**）
⇒ **这个字段丢了 ⇒ 柴阅永远以为是文字书 ⇒ 漫画永远打不开** ⭐⭐⭐

三处补齐：

| 位置 | 补什么 |
|---|---|
| 宿主 `Core/Book.swift` | **computed** `mediaType`（从站方原始字段 `raw` 现算）⭐⭐⭐ |
| `ChaiyueReaderAdapter.book()` | `book.type = b.mediaType`（搬进柴阅的 `Book`） |
| `LegadoEngineBackend.bookPayload()` | `"type": b.type`（柴阅的书 → 站方；站方脚本要读 `book.type`） |

⭐⭐⭐ **为什么 `mediaType` 是 computed 而不是存一个字段**：
`Book` 是 `Codable`（合成）⇒ **Swift 不会用属性默认值兜底** ⇒ 加一个 `var type: Int = 0`
⇒ **旧书架数据解码直接失败**（整库读不出来）⇒ 而站方的 `type` 本来就原样存在 `raw` 里 ⇒ **现算即可，零持久化风险** ⭐⭐⭐

⭐⭐⭐ **判定只用柴阅那一份真相**：宿主不自己判一遍，而是
`chaiyueBook.mediaKind(sourceType: source?.bookSourceType) == .comic` ⇒ **不会与柴阅的规则漂移** ⭐⭐⭐

---

## 3. 宿主怎么接的

```
详情页「开始阅读」
   ├─ 不是漫画 ⇒ ChaiyueReaderScreen（柴阅的文字阅读器，build324 起）
   └─ 是漫画   ⇒ ChaiyueComicScreen → 柴阅的 ComicReaderScreen ⭐⭐⭐
```

- `ChaiyueReaderHost` 新增 `mode: .text / .comic`：**共用同一套镜像逻辑**（书源/目录预写/书架进度）
  ⇒ 目录已在详情页取过 ⇒ 漫画页**命中章节缓存 ⇒ 不重复请求站方**（站方目录 JS 很慢）⭐⭐⭐
- 新增 `ChaiyueComicScreen`：造 `AppModel` → 置 `app.media = MediaLaunch(...)` → 渲染 `ComicReaderScreen`
- **进度回写分模式**：漫画的进度由柴阅 `MediaSession.save()` 直接写进**柴阅的书架仓** ⇒ 宿主读它搬回轻阅书库
  ⚠️ **漫画的 `position` 是「图片序号」、不是章号** ⇒ 绝不能当章下标用 ⭐⭐⭐
- 按钮文案用柴阅的 `actionTitle(for:)` ⇒ 漫画书写「**开始看漫画 / 继续看漫画**」，图标 `photo`

---

## 4. 门禁（24 项 / 6 条变异对照）

`test/reader-chaiyue-comic.test.js` ⇒ 六条判据，缺一条这功能就是坏的：

| 判据 | 内容 |
|---|---|
| ① **文件在** | 6 个漫画文件都在，且都有 `#if os(iOS)` 守卫 |
| ② **宿主能开** | `ComicReaderScreen` 是 public 且有 `public init` |
| ③ **启动通道** | `MediaLaunch` / `app.media` / `closeMedia()` 都在（漫画走 media，不走 reader） |
| ④ **会话能造** | 协议有 `mediaSession(for:)` **且宿主实现了** |
| ⑤ **type 不丢** | `Book.mediaType` / 适配器搬 type / `bookPayload` 带 type |
| ⑥ **详情页分流** | 按 `mediaKind` 判 ⇒ 开漫画屏 |

---

## 5. 已知边界（说清楚，别踩）

⚠️ **本地漫画（CBZ / PDF 导入）没做** ⇒ 轻阅**没有本地书导入入口** ⇒ 柴阅那 7 个内置主题包之外
「导入本地漫画」这条路在轻阅里不存在 ⭐⭐⭐

⚠️ **漫画源要靠站方标 `book.type`** ⇒ 站方不给这个字段 ⇒ 这本书就还是走文字阅读器（不是 bug，是站方的事）

⚠️ **听书 / 短剧没搬** ⇒ 柴阅的 `MediaLayer` 里还有那两支（`AudioPlayerScreen` / `DramaPlayerScreen`）
⇒ 轻阅只搬了漫画 ⇒ `MediaLayer` 那一层轻阅**不引入** ⇒ 宿主自己按 `mode` 分流 ⭐⭐⭐

---

## 6. 验证

- CI **45833353016**（main，commit `6f545a9`）：编译 + 5 个探针 + 柴阅引擎权威测试 全绿
- 门禁：新门禁 24/24；全量 JS 门禁无回归
- 产物：`QingYue-build327.zip`（+ `-noprov`）⇒ 解包验 **CFBundleVersion = 327** ✔
- **二进制体检（实测）**：
  | 项 | 结果 |
  |---|---|
  | `CFBundleVersion` | **327** ✔（`com.qireaderlite.app` / `CFBundleName QingYue`） |
  | 漫画符号 | `ComicReaderScreen` / `ComicModel` / `ComicPagerController` / `ComicStripController` / `ComicChrome` / `ComicStage` **全部在包内** ⭐⭐⭐ |
  | 老阅读器符号 | 8 个**全部 0 命中** ✔ |
  | 图标资源 | `cy.list.bullet` / `cy.headphones` / `cy.sun.max` / `cy.textformat` / `Theme-xuan` **全部命中** ✔ |
  | 主题包 | `ChaiyueThemes.bundle/Themes/` **7 个 `.chaiyuetheme` 全在** ✔ |
  | 体积 | IPA 19.2 MB → **19.4 MB**（漫画阅读器本体） |


---

# 附：build328 —— 形态判据的第二条路（2026-11-26 追加）

> 用户反馈可能：漫画源是**聚合站方按书标形态** ⇒ 327（只有「书源类型」那条路）判不出来。

## 形态其实有两条路（这轮才找齐）

| 路 | 来源 | 覆盖 | 出处 |
|---|---|---|---|
| **A** | **书源类型**（`BookSourceType`：0文字/1音频/**2图片**/3文件） | 「漫画源」这一类 | 柴阅 `BookParsers.swift`：`book.type = source.bookSourceType` |
| **B** | **站方目录脚本写的 `book.type`**（iOS `2`=图片） | **聚合站方按书标形态**（大灰狼这类） | 柴阅 `ChapterStore.saveBookType` 注释原文：「**目录脚本写入的 `book.type`（听书、漫画、短剧）**」 |

⇒ **B 路之前在引擎→宿主这一层被丢了** ⇒ 宿主判不出这类漫画 ⭐⭐⭐

## build328 做了什么

1. **引擎**：`toc` 的返回里带出 `bookType`（`result.book.type` 在目录解析后就是最终值）
2. **宿主 DTO**：`TocDTO` / `TocResult` 加 `bookType`（Optional ⇒ 合成 Codable 走 `decodeIfPresent` ⇒ 缺键不会炸）⭐⭐⭐
3. **详情页**：目录回来后把 `bookType` 收进**独立 `@State contentType`**
   ⚠️ 不能只改 `book.raw` ⇒ SwiftUI 只在 `@State` 变化时重算 body ⇒ 否则「目录回来了、按钮还没变成『开始看漫画』」⭐⭐⭐
   ⚠️ 时序上没问题：`resumeChapter` 依赖目录 ⇒ 目录没回来按钮点不动 ⇒ 能开时 `contentType` 必已到位 ⭐⭐⭐
4. **适配器**：形态**三路取一** ⇒ 目录脚本写的 `contentType` → 书源类型 `sourceType` → 书里已有的 `b.mediaType`
5. **门禁**：漫画门禁第⑤条同步改严（37 项绿）

## 验证

- CI **45843182667**（main，commit `22002ae`）✅ success
- 二进制体检：`CFBundleVersion = 328` ✔；漫画符号 3 个全在 ✔；老阅读器符号全 0 ✔；主题包 7 个 ✔
- 产物：`QingYue-build328.zip`（+ `-noprov`）


---

# 附：build329 —— 修「正文服务漏传 images:」（真机「图片出不来」）

> 真机（build328）：漫画页打开了、页码显示「1 / 2」（⇒ **目录/正文/抽地址这条链是通的**），
> 但**图一直转圈** ⇒ 卡在**取图**。

## 根因（只有一个）

柴阅的 `BookContentService.imageData(_:book:chapter:)`：
```swift
let url = imageURL(src, book: book, chapter: chapter)          // 相对地址拼接 ✔
if LocalBookStore.handles(url) { … }
guard let images else { throw URLError(.resourceUnavailable) } // ⭐⭐⭐ 就是这里
return try await images.data(for: url, source: source, isContent: true)
```

⇒ `images` 是 `ImageCache?`、**默认 nil** ⇒ **宿主不传就必然抛 `.resourceUnavailable`** ⭐⭐⭐
⇒ **为什么漏**：柴阅上游 `LibraryServices.contentService(for:)` 是**传了** `images: images` 的
⇒ 我们把 `LibraryServices` 拆成宿主门面协议（`ChaiyueReaderLibrary`）时**把这个依赖丢了** ⭐⭐⭐

## 影响面（已逐条核实，不是猜的）

| 路径 | 取图方式 | 329 前 |
|---|---|---|
| 漫画页的图 | `ComicModel` → `MediaSession.imageData` → **`service.imageData`** | ❌ 必抛错 |
| 文字阅读器的**正文插图** | `ReaderSession.downloadImages` → **`service.imageData`** | ❌ 必抛错 |
| 封面 / 缩略图 | `ImagePipeline` → **门面 `library.imageData`**（我们自己实现，带 images 实例） | ✅ 一直正常 |

## 修

① 宿主两处 `BookContentService(...)`（文字会话 + 漫画会话）**都传 `images: images`**（复用已有的 `ImageCache`）⭐⭐⭐
② 门禁第⑨条：钉住「每一处正文服务都必须传 `images:`」+ 变异对照 ⇒ 漫画门禁 **40/40 绿** ⭐⭐⭐
③ build 号 328 → 329

## 顺带排除的三个怀疑（都不是问题）

- `imageDecode`（正文图解密脚本）⇒ 两边结构一致（都在 `ruleContent` 里）⇒ 适配器的整体 JSON 编解码能带过去 ✔
- 图片相对地址 ⇒ 柴阅 `imageURL(src:book:chapter:)` 用 `chapter.url` 作 base 拼接 ✔
- 站方 `url,{"headers":…}` 写法 ⇒ `InlineImageSource(src).requestURL` 处理 ✔

## 验证

- CI **45845998214**（main，commit `8b225e7`）✅ success
- 二进制体检：`CFBundleVersion = 329` ✔；漫画符号 3 个全在 ✔；老阅读器符号全 0 ✔；图标 ✔；主题包 7 个 ✔
- 产物：`QingYue-build329.zip`（+ `-noprov`）


---

# 附：build331 —— 引擎侧清理：老引擎的残留全删（只留柴阅）

> 用户：「**你看下引擎侧是不是除了柴阅的引擎的，还有老的引擎代码，有的话全给我删了，只留柴阅的**」

## 盘点结论：源码里已经没有老引擎了，但有**两处遗留物**

历史上有两条引擎，都已退役：
① **老 JS 引擎**（WKWebView + `Resources/engine/*.js`）⇒ 2026-10-25 物理删除
② **自研 Swift 引擎**（从「六阅 LegadoR」二进制逆向重建，模块前缀 `LegadoR`）⇒ 已物理删除

⭐⭐⭐ **全量盘点方法**（不是靠 grep 猜）：把 `LegadoEngine/Sources` 下**每一个 .swift**
与上游柴阅（`Packages/ReaderCore/Sources` + `App/Sources`）**逐文件按内容行集相似度比对** ⇒
「对不上」的 45 个文件逐一分类 ⇒ **全是**我们自己的 shim / 改造 / public 出口（合理、必须留）
⇒ ⇒ **源码层没有老引擎残留** ⭐⭐⭐

真正要删的是两处**遗留物**：

| 删什么 | 为什么 |
|---|---|
| `LegadoEngine/Reference/`（7 个文件） | ② 的**逆向产物**：5 个 blob JS + `engine_api.txt`（`LegadoR.AnalyzeRule.*` 接口清单）+ `engine_properties.txt` + `node_bridge_test.js`（引用早就不存在的 `Sources/LegadoEngine/JS/Resources`）⭐⭐⭐ |
| `LegadoEngine/README.md`（整份重写） | **整份是 ② 的说明书**：讲的目录（`Models/ Core/ Analyzers/ Net/ JS/`）、API（`JSBridge`/`JSHost`/`RuleVariables`/`JSNatives`）、测试（`Tests/RuleTests.swift`）**全都不存在了** ⇒ 留着会**误导**任何看它的人 ⭐⭐⭐ |

## 明确**不删**的（名字像老引擎，但其实是当前链路）

| 文件 | 为什么留 |
|---|---|
| `QiReaderLite/Core/LegadoCompat.swift` | **不是老引擎** ⇒ 是宿主给站方 JS 的原生能力实现（`java.timeFormat` 等）⇒ 当前链路的一部分 ⭐⭐⭐ |
| `QiReaderLite/Core/LegadoEngineProbe.swift` | 是**柴阅的接入探针**（不是老引擎的）⭐⭐⭐ |
| `Sources/LegadoEngine/`（模块名） | **宿主门面**（`LegadoEngineHost` 类型别名 + 键值仓）⇒ 宿主 App 全靠它 ⇒ 不能删 ⭐⭐⭐ |
| `ChaiyueEngine/JS/*` | 柴阅**自己的** JS 运行时（`JavaBridge`/`JSPrelude`/`JSRuntime`…）+ 我们的 Linux 桩 ⇒ 柴阅的 ⭐⭐⭐ |
| `ChaiyueEngine/Compat/LegadoPublicAPI.swift` | 我们自己的公开 API 层（宿主调它）⭐⭐⭐ |
| `LegadoEngine/Tests/*` | 柴阅的**权威测试**（`ChaiyueModelsTests` / `ChaiyueRuleEngineTests`）⭐⭐⭐ |
| `docs/` 下的历史交接文档 | **历史记录，不改** ⭐⭐⭐ |

## 顺手修的门禁缺陷（基线红 ⇒ 全绿）

`test/engine-package-deps.test.js`：**37/7 → 44/0** ⭐⭐⭐
① `SYSTEM_MODULES` 白名单**缺** `AVKit`/`ImageIO`/`MediaPlayer`/`Observation`/`UniformTypeIdentifiers`
   （柴阅阅读器搬进来后暴露的）⭐⭐⭐
② `INTERNAL_TARGETS` 是**硬编码三个** ⇒ 新增的 `ChaiyueReaderKit`/`ChaiyueReaderServices`
   被**误报成「外部模块没声明」** ⇒ 改成**从 Package.swift 自动收集全部 target 名** ⇒ 以后加 target 也不会漏 ⭐⭐⭐

## 新门禁（让「删干净」可持续）

`test/engine-no-legacy.test.js`（**7 项**）⇒ 四条判据：
① `LegadoEngine/Reference/` **不许存在**
② README **不许教人用**老引擎的 API/路径（`JSNatives`/`node_bridge_test`/`RuleTests.swift`/`JSBridge`/`JSHost`/`RuleVariables`/老目录名）
   ⇒ ⚠️ 「六阅 / LegadoR **已物理删除**」这种**历史说明允许**（必要且有价值）⭐⭐⭐
③ 源码里**不许出现** `LegadoR.` 前缀
④ `Sources/LegadoEngine/`（门面模块）**只许有那两个门面文件** ⇒ 老引擎代码不许混进同名目录

## 验证

- CI：main（commit 见下）绿
- 门禁：新门禁 7/7；`engine-package-deps` **44/0**；`engine-apple-api` 645/0；阅读器相关 42/47/54/39 全绿


---

# 附：build332 —— 浏览器/验证码浮在【阅读器】之上（段评不必回详情页）

> 真机：「**段评打开，浏览器应该在阅读界面打开，现在是先回详情页再打开的**」

## 根因（两层，同一类「被 fullScreenCover 压住」）

| # | 谁 | 原来挂在哪 | 结果 |
|---|---|---|---|
| ① | **浏览器** | `@Published item` + **App 根 View 上的 `.sheet(item:)`** | 阅读器是 `fullScreenCover` ⇒ **层级高于根上的 sheet** ⇒ 浏览器被压在下面 ⇒ 「浏览器不见了」⭐⭐⭐ |
| ② | **验证码弹窗** | `ChaiyueRuntime.topPresenter` = **rootViewController** | 同上 ⇒ 弹窗被压住 ⇒ 「点了没反应」⭐⭐⭐ |

## 确认命中的是这条链（不是猜）
柴阅 `ParagraphComment.swift:60` ⇒ 段评气泡的 action 就是
`java.showReadingBrowser('...','段评')` ⇒ `PlatformSourceUI.showBrowser` ⇒ `presenter.presentBrowser`
⇒ 宿主 `ChaiyueInteractionPresenter.presentBrowser` ⇒ `BrowserPresenter.present` ⇒ **就是被压住的那一层** ⭐⭐⭐
（柴阅原版是**在阅读器之上浮一层 WebView**；轻阅换成宿主 `BrowserSheet` 后挂在根上 ⇒ 才被盖住）

## 改法
- `BrowserItem` 加 `onReader`（这次浏览器由根 View 还是阅读器承载）
- `BrowserPresenter` 加 `readerPresented` + `dismissIfReading()`
  （阅读器被关 ⇒ 收掉浏览器并**回调空结果** ⇒ 否则站方等的 `startBrowserAwait` 结果永远不来 ⇒ 卡死）⭐⭐⭐
- 根 View 的 sheet：**过滤掉** `onReader == true`（否则两层都 present）⭐⭐⭐
- **文字阅读器 + 漫画页**各挂一个只接 `onReader == true` 的 sheet；onAppear/onDisappear 置位/复位标志 ⭐⭐⭐
- `topPresenter` 改成**沿 `presentedViewController` 链找最顶层**（同柴阅 `topController()`）⭐⭐⭐

## 门禁
`test/browser-on-reader.test.js`（19 项）：根 View 过滤 / 两个阅读器都承载 / topPresenter 找顶层 /
BrowserPresenter 知道阅读器在场 ⇒ 29/29…（漫画门禁 47/47 + 本门禁 19/19）⭐⭐⭐
