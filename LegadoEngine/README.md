# LegadoEngine

从「六阅 LegadoR」iOS app（`io.legado.reader.ios` v1.0.7）逆向重建的 **Legado 3.0 书源规则引擎**，
可直接集成进你自己的 iOS app。兼容网上绝大多数 Legado 书源 JSON（阅读 3.0）。

## 来源与保真度（务必了解）

| 部分 | 来源 | 保真度 |
|---|---|---|
| 全部类型/属性/方法签名 | 原 app 二进制未剥离符号表（30.5 万符号，精确 demangle） | 精确 |
| JS 扩展层（`Resources/*.js`，java/cookie/cache/jsoup/Rhino 兼容 shim） | 原 app 二进制内嵌明文 JS，1:1 提取 | 原样 |
| 书源 JSON 字段名 | 原二进制 CodingKeys 字符串提取 | 精确 |
| Swift 实现体 | 按符号签名 + 开源 gedoor/legado（Kotlin）引擎语义重建 | 高保真重建，非原始代码 |

原 app 本身是开源 Legado 的 iOS Swift 移植，规则语义与安卓版一致。
`Reference/` 目录保留了从二进制提取的完整引擎接口清单，可自行核对。

## 集成（Swift Package Manager）

把 `LegadoEngine` 目录放进你的仓库，Xcode → File → Add Package Dependencies → Add Local，
或在你的 `Package.swift` 中：

```swift
.package(path: "LegadoEngine")
// target 依赖: .product(name: "LegadoEngine", package: "LegadoEngine")
```

要求 iOS 16+。依赖 SwiftSoup（HTML 默认规则）与 Kanna（XPath），会自动拉取。

## 用法

```swift
import LegadoEngine

// 1. 导入书源（单个对象或数组都支持）
let sources = try BookSource.parse(jsonData)
let source = sources[0]

// 2. 搜索
let books = try await LegadoEngine.search(source: source, key: "斗破苍穹")

// 3. 详情 + 目录
let book = books[0].toBook()
let info = try await LegadoEngine.bookInfo(source: source, book: book)
let chapters = try await LegadoEngine.chapters(source: source, book: info)

// 4. 正文
let text = try await LegadoEngine.content(source: source, book: info, chapter: chapters[0])

// 发现页
let kinds = LegadoEngine.exploreKinds(source: source)
let list = try await LegadoEngine.explore(source: source, kind: kinds[0])
```

也可以单独用规则引擎解析任意内容：

```swift
let rule = AnalyzeRule(source: source)
rule.setContent(htmlString, baseUrl: "https://example.com/list/")
let title = try rule.getString("class.bookname.0@text")
let links = try rule.getStringList("class.list@tag.a@href", isUrl: true)
```

书源变量持久化：`BookSource.variable` / `Book.variable` 是 JSON 字符串，
引擎运行中 JS `source.putVariable` 等会写入内存对象，宿主 app 负责落盘。

## 能力范围

- 规则语法：默认(JSoup) / `@json:` / `@XPath:` / `:regex` / `@js:` / `<js>`，
  `{{...}}` 内嵌、`@put/@get`、`##正则##替换`、`||` `&&` `%%` 组合
- AnalyzeUrl：GET/POST、options JSON、header 合并、charset（含 GBK）、data: URI、
  webView 抓取（WKWebView + webJs + sourceRegex 嗅探）、loginCheckJs、并发限速
- JS 扩展：java.ajax/加解密(AES/DES/RSA/签名)/base64/hex/md5/sha/gzip/时间格式化/
  cookie/cache/文件/jsoup/编码转换，Rhino 语法兼容（原 app 同款 shim）

## 已知限制

- 图片解密（bitmap 原生）与 TTF 字体反爬：JS shim 已就位，原生侧为 stub（返回 null），
  需要时按 `JS/` 中注释补齐 CoreGraphics/CoreText 实现。
- 登录 UI（loginUi 表单）、书源调试 UI 不在引擎范围内，宿主 app 自行实现；
  `JSHost` 协议可接收 JS 的 log/toast。
- 引擎不做持久化、不做替换净化(ReplaceRule)管理；正文净化规则 `replaceRegex` 已支持。
- JS 层依赖 JavaScriptCore，仅 Apple 平台可用；Linux 分支仅供 CI 编译核心解析逻辑。

## 目录

```
Sources/LegadoEngine/
  Models/      书源/书籍/章节/规则模型（JSON 兼容）
  Core/        AnalyzeRule / AnalyzeUrl / RuleSplitter
  Analyzers/   ByDefault(SwiftSoup) / ByXPath(Kanna) / ByJSONPath / ByRegex
  Net/         HTTPClient / ConcurrentRateLimiter / WebFetcher
  JS/          JSBridge + 原生扩展 + Resources(原样提取的 JS shim)
  LegadoEngine.swift  门面 API
Reference/     原二进制提取的引擎符号清单与 JS 原始 blob
Tests/         解析/规则/JS 单元测试
```

## 验证状态

- 核心解析层（Models/Analyzers/Core/Net/门面）：Swift 6.0.3 Linux `swift build` 零警告通过，
  `swift test` 20/20 通过（书源解析、默认/JSON/正则规则、@put/@get、##替换、||/&&/%%、URL 构造等）。
- JS 契约：`Reference/node_bridge_test.js` 用 node 加载原样提取的 5 个 bootstrap，
  按 `JSNatives.swift` 相同的参数约定模拟原生分发，32/32 断言通过
  （base64/md5/AES-ECB/CBC/DES 往返、gzip/deflate 往返、cache、jsoup 包装、source/book 绑定、Rhino 改写）。
  运行：`node --openssl-legacy-provider Reference/node_bridge_test.js`（需修改文件内资源路径）。
- JS 原生实现（JSBridge/JSNatives 的 Apple 分支）：已通过语法检查与上述契约验证，
  但 JavaScriptCore/CommonCrypto/Security 无法在 Linux 沙箱编译，**首次请在 Xcode 里 Build 一次**；
  若有小的 API 出入，集中在 `JS/JSNatives.swift`，按编译提示微调即可。
- `Tests/RuleTests.swift` 的 `testJSBridge` 在 Apple 平台会自动跑真 JS 断言。

接收 JS 的 log/toast：

```swift
final class MyHost: JSHost {
    func jsLog(_ msg: String) { print("[书源JS]", msg) }
    func jsToast(_ msg: String) { /* 弹 toast */ }
}
let bridge = JSBridge(source: source, book: book, chapter: nil,
                      variables: RuleVariables(), host: MyHost())
let v = try bridge.eval("java.md5Encode('abc')")
```

## 许可提示

原 app 为开源 Legado（GPL-3.0）的衍生移植；本重建参考了其开源引擎语义。
若你的 app 闭源分发，请自行评估 GPL 合规风险（规则引擎语义本身来自 GPL 项目）。