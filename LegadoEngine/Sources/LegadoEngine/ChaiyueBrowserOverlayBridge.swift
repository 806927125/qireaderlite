// ⭐⭐⭐⭐⭐ **整个文件包进 `#if os(iOS)`**（2026-11-27）⭐⭐⭐⭐⭐
//   ⚠️ **为什么**：`ChaiyueReader` 模块的内容全是 iOS 守卫（阅读界面用满 UIKit/SwiftUI 的 iOS 侧）
//   ⇒ **macOS / Linux 上 `ChaiyueBrowserOverlay` 根本不存在** ⇒ 不加守卫 ⇒
//   ⇒ **Linux 编译门禁直接挂**（`cannot find 'ChaiyueBrowserOverlay' in scope`）⭐⭐⭐
#if os(iOS)
import Foundation
import ChaiyueEngine
import ChaiyueReader

// ⭐⭐⭐⭐⭐ **浮层浏览器的【宿主门面转发】**（2026-11-27 · 段评「反应很慢」）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么要在宿主门面模块里转发**（CI333 实锤）⭐⭐⭐：
//   宿主文件（`QiReaderLite/Core/ChaiyueSourceUI.swift`）只 `import LegadoEngine`
//   ⇒ **看不到 `ChaiyueReader` 模块的 public 类型** ⇒ 报
//     「cannot find 'ChaiyueBrowserOverlay' in scope」⭐⭐⭐
//   ⇒ 而**不能**让宿主直接 `import ChaiyueReader`
//     （它 `@_exported import ChaiyueModels` ⇒ 会把柴阅的 `Book`/`BookSource` 带进宿主命名空间
//       ⇒ 与宿主自己的 `Book` **撞名** ⇒ ambiguous）⭐⭐⭐
//   ⇒ 正解：**在宿主门面模块（`LegadoEngine`）里转发一层** ⇒
//     · 宿主只 `import LegadoEngine` ⇒ **不撞名**（`LegadoEngine` 没有 @_exported 柴阅模型）⭐⭐⭐
//     · 而 `LegadoEngine` 可以 import `ChaiyueReader`（**不循环**：ChaiyueReader 不依赖 LegadoEngine）⭐⭐⭐
//
// ⚠️ 类型一致性：`LegadoEngineHost.BrowserRequest` 就是 `ChaiyueEngine.BrowserRequest`（typealias）⭐⭐⭐
//   ⇒ 转发时**不需要任何转换** ⇒ 直接透传 ⭐⭐⭐

/// 宿主可见的浮层浏览器入口（段评等）
public enum ChaiyueBrowserOverlayBridge {
    /// 呈现段评等浮层浏览器（柴阅的轻量浮层 + cookie 同步）
    @MainActor
    public static func present(request: ChaiyueEngine.BrowserRequest,
                                environment: ChaiyueEngine.SourceEnvironment,
                                completion: @escaping @MainActor @Sendable (ChaiyueEngine.BrowserResult?) -> Void) {
        ChaiyueBrowserOverlay.present(request: request, environment: environment, completion: completion)
    }

    /// 呈现前把引擎 cookie 推进共享的 WK cookie 罐（宿主自己的完整浏览器用）
    @MainActor
    public static func prepareCookies(url: String, environment: ChaiyueEngine.SourceEnvironment) async {
        await ChaiyueBrowserOverlay.prepareCookies(url: url, environment: environment)
    }

    /// 关闭后把 cookie 拉回引擎
    @MainActor
    public static func collectCookies(url: String,
                                      environment: ChaiyueEngine.SourceEnvironment,
                                      sourceKey: String?) async {
        await ChaiyueBrowserOverlay.collectCookies(url: url, environment: environment, sourceKey: sourceKey)
    }
}
#endif  // #if os(iOS)
