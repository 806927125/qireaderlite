// swift-tools-version:6.0
// ⭐⭐⭐ **tools 6.0 ⇒ 默认语言模式 = Swift 6**（与柴阅 `Packages/ReaderCore/Package.swift` 一致）⭐⭐⭐
//   柴阅的阅读器/会话层是按 **Swift 6** 写的（SwiftUI 的 `View` 在 Swift 6 才是 @MainActor）⭐⭐⭐
//   ⇒ 我们照搬的代码里大量「从 @MainActor 上下文调 @MainActor 方法」在 Swift 5 下是**硬错误**⭐⭐⭐
//   ⇒ ⇒ 三个阅读器 target 用 Swift 6；**引擎侧三个 target 仍钉在 Swift 5**（它们是按 Swift 5 写的，别动）⭐⭐⭐
import PackageDescription

// ⭐⭐⭐⭐⭐ **轻阅 Lite 的引擎包（2026-11-21 起 = 柴阅/Chaiyue 的引擎实现）**
//
// ⚠️⚠️⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）是 **GPL-3.0** ⭐⭐⭐
//   ⇒ 本包内的 `ChaiyueModels` / `ChaiyueEngine` 源码是柴阅的，**受 GPL-3.0 约束** ⭐⭐⭐
//   ⇒ 用户的选择：**自用、不分发** ⇒ GPL 的分发义务不触发 ⭐⭐⭐
//   ⚠️⚠️ **一旦把本 App 的二进制分发给他人 ⇒ 必须以 GPL-3.0 发布并提供完整源码** ⭐⭐⭐
//   ⇒ 详见 `docs/移植-柴阅引擎.md` 与仓库根的 `LICENSE-注意.md`
//
// ⭐ **本包分三个 target**：
//   · `ChaiyueModels` = 柴阅的 `ReaderModels`（13 文件）⇒ **Linux 可编** ✔
//   · `ChaiyueEngine` = 柴阅的 `RuleEngine`（34 文件）⇒ JS 部分 Apple only ⭐⭐⭐
//   · `LegadoEngine`  = **我们写的适配层**（宿主契约 + 状态搬运）⇒ **Linux 可编** ✔
//
// ⭐⭐⭐ **为什么 JS 部分要条件编译**（记忆老坑：「沙盒编不到 = 没有门禁」）：
//   柴阅用 **JavaScriptCore**（与轻阅一致）⇒ Linux 沙盒编不到 ⇒ 若整包编不过
//   ⇒ **沙盒门禁全部失效**（当天没被验过都不知道）⭐⭐⭐
//   ⇒ 解法：`#if canImport(JavaScriptCore) && !os(Linux)` 包裹 JS 层 ⭐⭐⭐
//     ⇒ Apple 上功能**完全不变**；Linux 上少了 JS 求值能力，但**规则解析/URL/编码/状态**都在 ⭐⭐⭐
//   ⇒ ⚠️ 这是**我们加的补丁**（与上游有 diff）⇒ 同步柴阅上游时需重新套用 ⇒ 已记录 ⭐⭐⭐
let package = Package(
    name: "LegadoEngine",
    // ⭐⭐⭐⭐⭐ **平台下限 = iOS 17 / macOS 14**（2026-11-25 柴阅阅读器 vendor 后抬高）⭐⭐⭐
    //   柴阅的阅读器/会话层用 **@Observable（Observation 框架）** ⇒ 需要 iOS 17 / macOS 14 ⭐⭐⭐
    //   （柴阅自己的 `Packages/ReaderCore/Package.swift` 声明的就是 iOS 17 / macOS 14 ⇒ 与上游一致）⭐⭐⭐
    //   ⚠️ 本 App 的 deployment target 是 **iOS 26** ⇒ 抬高包下限对 App 无影响 ⭐⭐⭐
    //   ⚠️ 之前是 .iOS(.v16)/.macOS(.v13) ⇒ 柴阅的 `SourceRepository.swift` 报
    //      「'Observable()' is only available in macOS 14.0 or newer」⭐⭐⭐
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LegadoEngine", targets: ["LegadoEngine"]),
        // ⭐⭐⭐⭐⭐ **柴阅的【阅读器】整包 vendor**（2026-11-25 用户要求：「阅读正文界面的老代码全部删掉，全部用柴阅的」）⭐⭐⭐
        //   · `ChaiyueReaderKit` = 柴阅 `Packages/ReaderCore/Sources/ReaderKit`（排版分页 / CSS / 主题脚本）⭐⭐⭐
        //   · `ChaiyueReaderServices` = 柴阅 `ReaderServices` 的阅读子集（ReaderSession / 内容服务 / 书架仓）⭐⭐⭐
        //   · `ChaiyueReader` = 柴阅 `App/Sources/Reader`（阅读界面本体）⭐⭐⭐
        //   ⇒ 宿主（App）只需要 import 柴阅的这些类型 ⇒ **我们手写的那套原生阅读器全部作废** ⭐⭐⭐
        .library(name: "ChaiyueReader", targets: ["ChaiyueReader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "6.1.0"),
        // ⭐⭐⭐ **Sextant**（柴阅用它做过滤表达式 ⇒ 比纯正则强 ⇒ 这是柴阅比轻阅强的地方）⭐⭐⭐
        .package(url: "https://github.com/KittyMac/Sextant.git", from: "0.4.41"),
        // ⭐⭐⭐⭐⭐ **swift-crypto**（2026-11-21 移植柴阅实证）
        //   `Crypto/Digests.swift` 用 `import Crypto` 取 MD5/SHA ⭐⭐⭐
        //   ⇒ **Apple 平台 = CryptoKit 的再导出**（符号一致）／**Linux = 纯 Swift 实现** ⇒ 一个模块名两边通用 ⭐⭐⭐
        //   ⚠️ **必须在 Package.swift 声明** ⇒ 否则 Apple 上报「Unable to find module dependency: 'Crypto'」⭐⭐⭐
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // ⭐⭐⭐ **ZIPFoundation**（柴阅的阅读服务用它解 EPUB/zip）⇒ 阅读器 vendor 需要 ⭐⭐⭐
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        // ① 柴阅的模型层（原样，target 名改成 ChaiyueModels）
        .target(
            name: "ChaiyueModels",
            path: "Sources/ChaiyueModels",
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
        // ② 柴阅的引擎层（原样 + 条件编译补丁）
        .target(
            name: "ChaiyueEngine",
            dependencies: [
                "ChaiyueModels",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Kanna", package: "Kanna"),
                .product(name: "Sextant", package: "Sextant"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ChaiyueEngine",
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
        // ⭐⭐⭐⭐⭐ **柴阅的【登录配套设施】（ReaderPlatform）已并入 `ChaiyueEngine`**（2026-11-21）⭐⭐⭐
        //   目录：`Sources/ChaiyueEngine/Platform/`（原样 vendor，文件整体 `#if canImport(WebKit)`）⭐⭐⭐
        //   · `PlatformSourceUI` = `SourceUIDelegate` 的完整实现（浏览器 / 验证码 / 后台渲染 / toast / 复制 / 外链）⭐⭐⭐
        //   · `WebViewRenderer` = 后台 WKWebView 渲染（正文 `useWebView`）⭐⭐⭐
        //   · `CookieSync` = WK cookie ⇒ URLSession cookie 的同步 ⭐⭐⭐
        //   ⇒ 站方登录要开浏览器/要验证码时，**柴阅原生支持**（此前静默失败）⭐⭐⭐
        //   ⚠️ **并入而非独立 target** ⇒ xcodeproj 不用改（宿主仍只 import LegadoEngine）⭐⭐⭐
        // ③ 我们的适配层（宿主契约 + 状态搬运；**纯逻辑 ⇒ Linux 沙盒可编 ⇒ 门禁活着**）
        .target(
            name: "LegadoEngine",
            // ⭐⭐⭐⭐⭐ **加 `ChaiyueReader` 依赖**（2026-11-27 · 段评浮层浏览器转发）⭐⭐⭐⭐⭐
            //   `ChaiyueBrowserOverlayBridge.swift` 要转发 `ChaiyueReader` 模块里的
            //   `ChaiyueBrowserOverlay`（它要用柴阅的 `SourcePresenter` + `CookieSync`）⭐⭐⭐
            //   ⇒ **不循环**：ChaiyueReader 只依赖 ChaiyueEngine/ChaiyueModels/…，不依赖 LegadoEngine ⭐⭐⭐
            //   ⚠️ 宿主**不能**直接 import ChaiyueReader（会带进柴阅的 `Book` 等 ⇒ 与宿主同名撞名）
            //     ⇒ 所以在**宿主门面模块**里转发一层 ⇒ 宿主只 import LegadoEngine ⇒ 不撞名 ⭐⭐⭐
            dependencies: ["ChaiyueEngine", "ChaiyueModels", "ChaiyueReader"],
            path: "Sources/LegadoEngine",
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
        // ⭐⭐⭐⭐⭐ ④ 柴阅的【排版与分页内核】（ReaderKit；只依赖 ChaiyueModels ⇒ 干净）⭐⭐⭐
        .target(
            name: "ChaiyueReaderKit",
            dependencies: ["ChaiyueModels"],
            path: "Sources/ChaiyueReaderKit",
            // ⭐⭐⭐⭐⭐ **照搬柴阅 App target 的编译设置**（`App/project.yml`）：
            //   SWIFT_VERSION 6.0 + SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
            //   + SWIFT_APPROACHABLE_CONCURRENCY: YES ⭐⭐⭐
            //   ⇒ DefaultActorIsolation：顶层默认 @MainActor（SwiftUI View 本来就是）⭐⭐⭐
            //   ⇒ ApproachableConcurrency：老代码的并发违规降级成警告（不报错）⭐⭐⭐
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        // ⭐⭐⭐⭐⭐ ⑤ 柴阅的【阅读服务子集】（ReaderServices 的 Reading/Content/Library/Sources/Speech/Support）⭐⭐⭐
        .target(
            name: "ChaiyueReaderServices",
            dependencies: [
                "ChaiyueModels",
                "ChaiyueEngine",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/ChaiyueReaderServices",
            // ⭐⭐⭐⭐⭐ **照搬柴阅 App target 的编译设置**（`App/project.yml`）：
            //   SWIFT_VERSION 6.0 + SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
            //   + SWIFT_APPROACHABLE_CONCURRENCY: YES ⭐⭐⭐
            //   ⇒ DefaultActorIsolation：顶层默认 @MainActor（SwiftUI View 本来就是）⭐⭐⭐
            //   ⇒ ApproachableConcurrency：老代码的并发违规降级成警告（不报错）⭐⭐⭐
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        // ⭐⭐⭐⭐⭐ ⑥ 柴阅的【阅读界面本体】（App/Sources/Reader）⭐⭐⭐
        .target(
            name: "ChaiyueReader",
            dependencies: [
                "ChaiyueModels",
                "ChaiyueEngine",
                "ChaiyueReaderKit",
                "ChaiyueReaderServices",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/ChaiyueReader",
            // ⭐⭐⭐⭐⭐ **照搬柴阅 App target 的编译设置**（`App/project.yml`）：
            //   SWIFT_VERSION 6.0 + SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
            //   + SWIFT_APPROACHABLE_CONCURRENCY: YES ⭐⭐⭐
            //   ⇒ DefaultActorIsolation：顶层默认 @MainActor（SwiftUI View 本来就是）⭐⭐⭐
            //   ⇒ ApproachableConcurrency：老代码的并发违规降级成警告（不报错）⭐⭐⭐
            swiftSettings: [.swiftLanguageMode(.v6),
                          // ⭐⭐⭐ **柴阅 `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` 的编译器等价物** ⭐⭐⭐
                          //   （不是 upcoming feature！upcoming feature 那个名字**不生效** ⇒ 表现为
                          //    「main actor-isolated property 'chapters' can not be referenced from a
                          //     nonisolated context」⇒ 顶层默认 @MainActor 才与柴阅一致）⭐⭐⭐
                          .unsafeFlags(["-default-isolation", "MainActor"]),
                          .enableUpcomingFeature("ApproachableConcurrency")],
        ),
        // ⚠️⚠️ **旧的 `LegadoEngineTests` 已删**（2026-11-21 移植柴阅）⭐⭐⭐
        //   它测的是**我们自己那套已被替换掉的引擎** ⇒ 符号全没了 ⇒ 测不了 ⭐⭐⭐
        //   ⇒ 能力覆盖改由**柴阅自带的权威测试**承担（下面两个 target）⭐⭐⭐
        // ⭐⭐⭐⭐⭐ **柴阅自带的权威测试**（2026-11-21 移植时 vendor 进来）⭐⭐⭐
        //   ⇒ 柴阅的 `RuleEngineTests` / `ReaderModelsTests` = **行为规格** ⭐⭐⭐
        //   ⇒ 移植后**在沙盒里直接跑权威测试** ⇒ 比我们自己的门禁更硬 ⭐⭐⭐
        //   ⚠️ 部分用例需要 JSC ⇒ Linux 上会失败（桩如实抛错）⇒ **平台差异，不是移植错** ⭐⭐⭐
        .testTarget(name: "ChaiyueRuleEngineTests",
                    dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                    path: "Tests/ChaiyueRuleEngineTests",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // ⭐⭐⭐⭐⭐ **登录表单探针**（2026-11-21 真机「登录界面没按钮」实证）⭐⭐⭐
        //   ⇒ 真跑柴阅的 `resolveLoginRows` ⇒ 证明「`@js:` 的 loginUi 能解析出按钮」⭐⭐⭐
        //   ⇒ Linux 没 JSC ⇒ **只能靠 CI（macOS）跑它** ⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe",
                          dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // ⭐⭐⭐⭐⭐ **「禁漫天堂」登录面板探针**（2026-11-21 真机「没有小说/漫画/视频这些按钮」实证）⭐⭐⭐
        //   ⇒ 真引擎 + 真源 ⇒ 验「viewName 能求出人话名」+「action 能真跑」⭐⭐⭐
        //   ⇒ Linux 没有 JSC ⇒ **只能靠 CI（macOS）跑** ⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe2",
                          dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe2",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // ⭐⭐⭐⭐⭐ **「书山聚合 v6」全链探针**（2026-11-23）⭐⭐⭐
        //   ⇒ 沙盒（Linux）**没有 JSC** ⇒ `@js:` / `<js>` 求值跑不了 ⇒
        //   ⇒ 「这个源在轻阅里能不能跑」**只能靠 macOS CI 真引擎真跑** ⇒ ⭐⭐⭐
        //   ⇒ 探针证明 5 件事：① exploreUrl 能求值出分类 ② ruleExplore 能解析出书单
        //   ⇒   ③ 详情/目录/正文三段通 ④ 登录面板 26 行能求出
        //   ⇒   ⑤ **改名后的 `ssh_*` 符号在全局可用**（证明隔离化没打断作用域）⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe3",
                          dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe3",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // ⭐⭐⭐⭐⭐ **token 管道探针**（2026-11-24 真机「Token 格式错误」实证）⭐⭐⭐
        //   ⇒ 真机症状：站方回「Token 格式错误」⇒ 实测 = **token 不是合法 base64** ⭐⭐⭐
        //   ⇒ 本探针用**真引擎 + 真源 + 真站方**逐环取证：JS 侧的 getLoginHeader 形态、
        //     站方 ssh_buildHeaders 的产物、**重启往返**、以及站方的真实判定 ⭐⭐⭐
        //   ⇒ ⚠️ 依赖 `LegadoEngine` target（要用宿主同款的 `ChaiyueKeyValueStore` 接线）⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe4",
                          dependencies: ["LegadoEngine", "ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe4",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // ⭐⭐⭐⭐⭐ **发现页筛选 action 真跑探针**（2026-11-24 真机「切平台无效」实证）⭐⭐⭐⭐⭐
        //   ⇒ 站方的筛选 action 是**字符串** ⇒ 「顶层符号隔离化」（改名）**按 AST 改** ⇒ 漏改 ⭐⭐⭐
        //   ⇒ 漏改 ⇒ 引擎里符号未定义 ⇒ **ReferenceError** ⇒ **筛选静默失效**（平台切不动）⭐⭐⭐
        //   ⇒ 本探针**真跑一次 action** ⇒ 断言「站方变量真的变了」⇒ 这类回归必红 ⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe5",
                          dependencies: ["LegadoEngine", "ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe5",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ChaiyueModelsTests",
                    dependencies: ["ChaiyueModels"],
                    path: "Tests/ChaiyueModelsTests",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
