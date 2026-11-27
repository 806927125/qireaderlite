import Foundation
import ChaiyueModels
import ChaiyueEngine

// ⭐⭐⭐⭐⭐ **宿主适配入口（2026-11-21 起 = 柴阅引擎）**
//
// ⚠️⚠️⚠️ **为什么模块名要另起一个 enum**（沿用旧引擎的老规矩）：
//   模块名 `LegadoEngine` 与引擎里的门面 enum `LegadoEngine` **同名**
//   ⇒ 宿主侧写 `LegadoEngine.BookSource` 会被那个 enum 遮蔽（不是模块）⇒ 编译不过 ⭐⭐⭐
//   ⇒ 这里给一组**唯一命名**的类型别名 ⇒ 宿主侧用 `LegadoEngineHost.Source` 等 ⭐⭐⭐
//   ⇒ **宿主 UI 层一行都不用改**（它从不 import 引擎）⭐⭐⭐
public enum LegadoEngineHost {
    // MARK: - 模型（全部指向柴阅的模型 ⇒ 行为与柴阅逐字一致）
    /// ⭐⭐⭐ 书源模型 = 柴阅的 `BookSource`（强类型规则 struct ⇒ 宿主读 `ruleBookInfo?.intro` 不用改）⭐⭐⭐
    public typealias Source = ChaiyueModels.BookSource
    public typealias BookModel = ChaiyueModels.Book
    public typealias ChapterModel = ChaiyueModels.BookChapter
    public typealias SearchResult = ChaiyueModels.SearchBook
    public typealias Kind = ChaiyueModels.ExploreKind
    /// ⭐⭐⭐ **登录表单的行**（柴阅的 `LoginRow`）—— 宿主要造它 ⇒ 必须有别名 + public init ⭐⭐⭐
    ///   ⚠️ 宿主**不能** import `ChaiyueReader`（`@_exported` 柴阅模型 ⇒ 与宿主 `Book` 撞名）⇒ 走这里 ⭐⭐⭐
    public typealias LoginRow = ChaiyueEngine.LoginRow
    /// ⭐⭐⭐ **书籍变量**（`java.put/get` / `@put/@get` / `{{}}`）= 柴阅的 `[String: String]` ⭐⭐⭐
    ///   （旧引擎是自己写的 `RuleVariables` class ⇒ 现在换成柴阅的字典形态）⭐⭐⭐
    public typealias Vars = [String: String]
    // ⭐⭐⭐ **URL 构造器不再暴露** ⭐⭐⭐
    //   柴阅的 `AnalyzeUrl` 是 **internal** ⇒ 外部拿不到 ⇒ 而宿主**也不需要**它 ⭐⭐⭐
    //   ⇒ 宿主的每条主链（search/explore/exploreKinds/bookInfo/toc/content/login）
    //     都直接走柴阅的 **`WebBook`**（public 且完整）⇒ 不碰引擎内部 ⭐⭐⭐
    //   ⇒ 这比旧引擎（宿主自己搭 bridge + 自己解析）**更简单也更对** ⭐⭐⭐

    // ⭐⭐⭐⭐⭐ **引擎门面 = 柴阅的 `WebBook`**（2026-11-21 移植）⭐⭐⭐
    //   ⇒ 宿主的每条主链都走它 ⇒ 行为与柴阅**逐字一致**（权威实现）⭐⭐⭐
    public typealias WebBook = ChaiyueEngine.WebBook
    /// ⭐⭐⭐ 引擎环境（HTTP / Cookie / 缓存 / 变量存储 的持有者）⭐⭐⭐
    public typealias Environment = ChaiyueEngine.SourceEnvironment
    /// ⭐⭐⭐ **持久化后端**（宿主实现 ⇒ 柴阅的书源变量/登录信息都落在这儿）⭐⭐⭐
    public typealias Store = ChaiyueEngine.KeyValueStore
    /// ⭐⭐⭐ **诊断出口**（`explain` op 用 ⇒ 发一次请求看 URL/状态/字节）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么必须在这里暴露**：Swift 的 `import` **不 re-export** ⭐⭐⭐
    ///   ⇒ 宿主只 `import LegadoEngine` ⇒ 拿不到 `ChaiyueEngine` 模块里的符号 ⭐⭐⭐
    ///   ⇒ 所以凡宿主要用的柴阅符号，都得在这里开一个别名 ⭐⭐⭐
    public typealias Diagnostics = ChaiyueEngine.ChaiyueDiagnostics
    /// ⭐⭐⭐ **登录信息加解密**（柴阅存密文、UI 要明文 ⇒ 必须能互转）⭐⭐⭐
    public typealias LoginCrypto = ChaiyueEngine.ChaiyueLoginCrypto

    #if canImport(WebKit) && !os(Linux)
    // ⭐⭐⭐⭐⭐ **柴阅的【登录配套设施】（ReaderPlatform）的类型**（2026-11-21 移植）⭐⭐⭐
    //   ⇒ Swift 的 `import` **不 re-export** ⇒ 宿主只 `import LegadoEngine` ⇒ 必须在这里开别名 ⭐⭐⭐
    /// ⭐⭐⭐ 柴阅的界面委托实现（浏览器 / 验证码 / 后台渲染 / toast / 复制 / 外链 / 视频）⭐⭐⭐
    public typealias PlatformUI = ChaiyueEngine.PlatformSourceUI
    /// ⭐⭐⭐ 后台 WebView 渲染请求（正文 `useWebView` / `java.webView`）⭐⭐⭐
    public typealias WebViewRequest = ChaiyueEngine.WebViewRequest
    /// ⭐⭐⭐ 浏览器请求（`java.startBrowser` / `showBrowser`）⭐⭐⭐
    public typealias BrowserRequest = ChaiyueEngine.BrowserRequest
    /// ⭐⭐⭐ 浏览器结果（页面 URL + HTML）⭐⭐⭐
    public typealias BrowserResult = ChaiyueEngine.BrowserResult
    /// ⭐⭐⭐ 宿主要实现的交互协议（轻阅的实现见 `ChaiyueSourceUI.swift`）⭐⭐⭐
    public typealias InteractionPresenter = ChaiyueEngine.SourceInteractionPresenter
    #endif

    // ⭐⭐⭐⭐⭐ **登录面板的一行**（含 `viewName` ⇒ 人话显示名）⭐⭐⭐
    //   ⚠️⚠️ **必须在【无条件区】**（2026-11-21 实证）⭐⭐⭐
    //   ⇒ 之前放在 `#if canImport(WebKit)` 里 ⇒ **Linux 沙盒上不存在** ⇒ 宿主编不过 ⭐⭐⭐
    //   ⇒ 而 `LoginRow` 本身**不依赖 WebKit** ⇒ 无条件暴露才对 ⭐⭐⭐
    public typealias LoginRow = ChaiyueEngine.LoginRow
}
