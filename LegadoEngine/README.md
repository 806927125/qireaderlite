# LegadoEngine —— 柴阅（Chaiyue）引擎 + 阅读器

> ⚠️⚠️ **本仓库现在只有【柴阅/Chaiyue】一套引擎** ⭐⭐⭐
> 老引擎（2026-10-25 退役的老 JS 引擎、以及从「六阅 LegadoR」二进制逆向重建的自研 Swift 引擎）
> **已物理删除**：代码、逆向产物（`Reference/`）、说明文档、老 API 说明，全部不再保留 ⭐⭐⭐
> ⇒ 只看这一份文档即可；文档里提到的东西都还在，文档**没**提到的东西就是没了 ⭐⭐⭐

---

## 1. 引擎 = 柴阅（GPL-3.0）

| 部分 | 来源 | 保真度 |
|---|---|---|
| 规则引擎 `ChaiyueEngine` | 柴阅 `Packages/ReaderCore/Sources/RuleEngine`（vendor 进本仓库） | **原版源码** |
| 模型 `ChaiyueModels` | 柴阅 `Packages/ReaderCore/Sources/ReaderModels` | **原版源码** |
| 阅读器 `ChaiyueReader` / `ReaderKit` / `ReaderServices` | 柴阅 `App/Sources/Reader` + `Packages/ReaderCore/Sources/{ReaderKit,ReaderServices}` | **原版源码** |
| 宿主门面 `LegadoEngine` | 我们写的适配层（类型别名 + 宿主入口） | 我们写的 |

⇒ **语义 = Legado 3.0**（兼容网上绝大多数 Legado 书源 JSON）
⇒ ⚠️ **模块名/类型名保留 `LegadoEngine`**（宿主 `import LegadoEngine` 一行不改 ⇒ UI 零改动）⭐⭐⭐
⇒ ⚠️ **许可**：柴阅 = **GPL-3.0** ⇒ 本仓库内 `Chaiyue*` 目录是柴阅源码
   ⇒ **自用、不分发** ⇒ 不触发 GPL 分发义务；**一旦分发/上架 ⇒ 必须整体 GPL-3.0 + 提供对应源码** ⭐⭐⭐

---

## 2. 目录（当前真实内容）

```
Sources/
  ChaiyueEngine/        柴阅规则引擎（43 文件）—— 规则求值 / JS 运行时 / 网络 / 登录
  ChaiyueModels/        柴阅模型（13 文件）—— 书源 / 书 / 章 / 规则模型（JSON 兼容）
  ChaiyueReader/        柴阅阅读界面（69 文件）—— 文字阅读器 + 漫画阅读器 + App 层 shim
  ChaiyueReaderKit/     柴阅排版内核（7 文件）—— 分页 / CSS / 主题脚本 / 偏移映射
  ChaiyueReaderServices/柴阅阅读服务（21 文件）—— 正文 / 内容处理 / 书架仓 / 书源仓 / 朗读 / 缓存
  ChaiyueProbe…5/       探针（5 个可执行）—— 真引擎 + 真源 + 真网络
  LegadoEngine/         宿主门面（2 文件）—— `LegadoEngineHost` 类型别名 + 键值仓
Tests/
  ChaiyueModelsTests/   柴阅模型的权威测试
  ChaiyueRuleEngineTests/ 柴阅规则引擎的权威测试（CI 上 `swift test` 跑）
```

⚠️ **没有** `Reference/`、**没有** `JS/Resources`、**没有** `Models/ Core/ Analyzers/ Net/` 这些老引擎目录
⇒ 那些是老引擎（`LegadoR`）的东西，**已删** ⭐⭐⭐

---

## 3. 编译设置（⭐⭐⭐ 分层照抄柴阅，别再混）

| 层 | 柴阅出处 | 本仓库 target | 设置 |
|---|---|---|---|
| 柴阅 SPM 包层 | `Packages/ReaderCore` | `ChaiyueEngine` / `ChaiyueModels` / `ChaiyueReaderKit` / `ChaiyueReaderServices` | tools 6.0 + `swiftLanguageMode(.v6)`，**无默认隔离** |
| 柴阅 App 层 | `App/project.yml` | `ChaiyueReader`（阅读界面 + shim） | `.v6` + `.unsafeFlags(["-default-isolation","MainActor"])` + `ApproachableConcurrency` |
| 引擎侧（按 Swift 5 写的） | — | `ChaiyueModels` / `ChaiyueEngine` / `LegadoEngine` | **钉死 `.v5`**（tools 6.0 会把它们默认拖进 v6 ⇒ 探针炸） |
| 探针 / 测试 | — | 5 个探针 + 2 个 testTarget | **钉死 `.v5`** |

⭐ 平台下限：**iOS 17 / macOS 14**（柴阅用 `@Observable`）

---

## 4. 宿主怎么用

```swift
import LegadoEngine

// 全部指向柴阅的模型 ⇒ 行为与柴阅逐字一致
let source: LegadoEngineHost.Source = …          // = ChaiyueModels.BookSource
let book:    LegadoEngineHost.BookModel = …      // = ChaiyueModels.Book
let chapter: LegadoEngineHost.ChapterModel = …   // = ChaiyueModels.BookChapter
```

⭐ **命名纪律**：宿主 App 侧还有自己的 `Book` / `Chapter` / `BookSource`
⇒ `import ChaiyueEngine` 会把柴阅的同名类型也带进来 ⇒ **裸写类型名会 ambiguous**
⇒ 一律用 `LegadoEngineHost.*` 别名（或宿主自己的 `QiBook` / `QiChapter`）⭐⭐⭐

---

## 5. 验证

| 手段 | 位置 |
|---|---|
| 柴阅模型的权威测试 | `Tests/ChaiyueModelsTests` |
| 柴阅规则引擎的权威测试 | `Tests/ChaiyueRuleEngineTests`（CI 上 `swift test` 跑）⭐⭐⭐ |
| 5 个真探针（真引擎 + 真源 + 真网络） | `Sources/ChaiyueProbe…5`（CI 上跑）⭐⭐⭐ |
| 静态门禁 | 仓库 `test/` 下：`engine-apple-api` / `engine-package-deps` / `chaiyue-port-contract` / `reader-*` 等 |

⭐ **沙盒 Linux 编不到 SwiftUI/UIKit** ⇒ iOS 界面层只能靠 CI 验编译
⇒ 改动 iOS 界面后**别指望本地 `swift build` 绿**，以 CI 为准 ⭐⭐⭐

---

## 6. 许可提示

- 柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本仓库内 `Sources/Chaiyue*` 是柴阅源码 ⭐⭐⭐
- 宿主门面 `Sources/LegadoEngine` 与宿主 App 是我们自己的代码
- **自用、不分发** ⇒ 不触发 GPL 分发义务
- ⚠️ **一旦把 App 的二进制分发给他人 / 上架 ⇒ 必须整体以 GPL-3.0 发布并提供对应源码** ⭐⭐⭐
