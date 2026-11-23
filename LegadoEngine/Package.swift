// swift-tools-version:5.9
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
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LegadoEngine", targets: ["LegadoEngine"]),
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
    ],
    targets: [
        // ① 柴阅的模型层（原样，target 名改成 ChaiyueModels）
        .target(
            name: "ChaiyueModels",
            path: "Sources/ChaiyueModels"
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
            path: "Sources/ChaiyueEngine"
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
            dependencies: ["ChaiyueEngine", "ChaiyueModels"],
            path: "Sources/LegadoEngine"
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
                    path: "Tests/ChaiyueRuleEngineTests"),
        // ⭐⭐⭐⭐⭐ **登录表单探针**（2026-11-21 真机「登录界面没按钮」实证）⭐⭐⭐
        //   ⇒ 真跑柴阅的 `resolveLoginRows` ⇒ 证明「`@js:` 的 loginUi 能解析出按钮」⭐⭐⭐
        //   ⇒ Linux 没 JSC ⇒ **只能靠 CI（macOS）跑它** ⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe",
                          dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe"),
        // ⭐⭐⭐⭐⭐ **「禁漫天堂」登录面板探针**（2026-11-21 真机「没有小说/漫画/视频这些按钮」实证）⭐⭐⭐
        //   ⇒ 真引擎 + 真源 ⇒ 验「viewName 能求出人话名」+「action 能真跑」⭐⭐⭐
        //   ⇒ Linux 没有 JSC ⇒ **只能靠 CI（macOS）跑** ⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe2",
                          dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe2"),
        // ⭐⭐⭐⭐⭐ **「书山聚合 v6」全链探针**（2026-11-23）⭐⭐⭐
        //   ⇒ 沙盒（Linux）**没有 JSC** ⇒ `@js:` / `<js>` 求值跑不了 ⇒
        //   ⇒ 「这个源在轻阅里能不能跑」**只能靠 macOS CI 真引擎真跑** ⇒ ⭐⭐⭐
        //   ⇒ 探针证明 5 件事：① exploreUrl 能求值出分类 ② ruleExplore 能解析出书单
        //   ⇒   ③ 详情/目录/正文三段通 ④ 登录面板 26 行能求出
        //   ⇒   ⑤ **改名后的 `ssh_*` 符号在全局可用**（证明隔离化没打断作用域）⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe3",
                          dependencies: ["ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe3"),
        // ⭐⭐⭐⭐⭐ **token 管道探针**（2026-11-24 真机「Token 格式错误」实证）⭐⭐⭐
        //   ⇒ 真机症状：站方回「Token 格式错误」⇒ 实测 = **token 不是合法 base64** ⭐⭐⭐
        //   ⇒ 本探针用**真引擎 + 真源 + 真站方**逐环取证：JS 侧的 getLoginHeader 形态、
        //     站方 ssh_buildHeaders 的产物、**重启往返**、以及站方的真实判定 ⭐⭐⭐
        //   ⇒ ⚠️ 依赖 `LegadoEngine` target（要用宿主同款的 `ChaiyueKeyValueStore` 接线）⭐⭐⭐
        .executableTarget(name: "ChaiyueProbe4",
                          dependencies: ["LegadoEngine", "ChaiyueEngine", "ChaiyueModels"],
                          path: "Sources/ChaiyueProbe4"),
        .testTarget(name: "ChaiyueModelsTests",
                    dependencies: ["ChaiyueModels"],
                    path: "Tests/ChaiyueModelsTests"),
    ]
)
