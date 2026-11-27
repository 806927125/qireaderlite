#if os(iOS)
// ⭐⭐⭐⭐⭐ **柴阅的【浮层浏览器】对外出口 + cookie 同步**（2026-11-27 · 段评「反应很慢」）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **真因（不是渲染慢，是【缺登录态】）** ⭐⭐⭐：
//   柴阅的 cookie 同步写在 **`PlatformSourceUI.present`** 里（`CookieSync.push` / `pull`）
//   ⇒ 而宿主**自己实现了 `presentBrowser`** ⇒ **完全绕过了那一层** ⭐⭐⭐
//   ⇒ ⇒ 段评页面**没有站方的登录态** ⇒ 页面要等站方接口 / 跳登录 ⇒ 用户感知 =「点了反应很慢」⭐⭐⭐
//
// ⭐⭐⭐ **柴阅原版的段评浏览器长什么样**（`Shims/SourcePresenter.swift` 的 `presentBrowser`）⭐⭐⭐：
//   · **UIKit 直接 `present` 在「最顶层 VC」上** ⇒ 阅读器是 `presented` ⇒ **天然浮在阅读器之上** ⭐⭐⭐
//   · 段评走 `.sheet` 样式 ⇒ **0.8 屏高浮层 + 可下拉关闭 + 顶部进度条**（不是完整浏览器）⭐⭐⭐
//   · `BrowserScreen` 里只有 `WebViewContainer` ⇒ **无地址栏、无 NavigationStack** ⇒ 轻得多 ⭐⭐⭐
//
// ⭐⭐⭐ **为什么宿主不能自己 import `CookieSync`** ⭐⭐⭐：
//   宿主（Xcode 工程）只链 **`LegadoEngine` + `ChaiyueReader`** 两个 product
//   ⇒ `import ChaiyueEngine` 会报 **no such module** ⇒ ⇒ 所以**必须在这里包一层 public 出口** ⭐⭐⭐
import UIKit
import SwiftUI
import ChaiyueEngine

/// 柴阅的浮层浏览器（段评 / 书源脚本触发的浮层页）+ cookie 同步
public enum ChaiyueBrowserOverlay {
    /// ⭐⭐⭐⭐⭐ **呈现段评等【浮层】浏览器**（0.8 屏高 + 顶层 present + **cookie 同步**）⭐⭐⭐⭐⭐
    ///
    /// - Parameters:
    ///   - request: 柴阅的浏览器请求（段评是 `.sheet` 样式）
    ///   - environment: 引擎环境（带站方 cookie ⇒ 段评页有登录态 ⇒ 打开即用，不跳登录）⭐⭐⭐
    ///   - completion: 关闭时回调（站方要结果时给 `BrowserResult`）
    @MainActor
    public static func present(request: BrowserRequest,
                                environment: SourceEnvironment,
                                completion: @escaping @MainActor @Sendable (BrowserResult?) -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        Task { @MainActor in
            // ⭐⭐⭐ **先把引擎的 cookie 推进共享的 WK cookie 罐**（照搬柴阅 `PlatformSourceUI.present`）⭐⭐⭐
            //   不做这步 ⇒ 段评页没有登录态 ⇒ 页面在等站方 ⇒ **用户感知就是「反应很慢」** ⭐⭐⭐
            await CookieSync.push(request.url, from: environment.cookies, to: store)
            let presenter = SourcePresenter()
            presenter.presentBrowser(request) { result in
                Task { @MainActor in
                    // ⭐ 关闭后把浏览器里的 cookie **拉回引擎**（登录态要留住）⭐⭐⭐
                    await CookieSync.pull(result?.url ?? request.url, into: environment.cookies,
                                         key: request.sourceKey, from: store)
                    await CookieSync.pullAll(into: environment.cookies, from: store)
                    completion(result)
                }
            }
        }
    }

    /// ⭐⭐⭐ **给宿主自己的浏览器用**：呈现前把引擎 cookie 推进共享罐 ⭐⭐⭐
    /// （宿主自己的 `BrowserSheet` 用的是 `WKWebsiteDataStore.default()` ⇒ 与这里是**同一个罐**）⭐⭐⭐
    @MainActor
    public static func prepareCookies(url: String, environment: SourceEnvironment) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        await CookieSync.push(url, from: environment.cookies, to: store)
    }

    /// ⭐⭐⭐ **给宿主自己的浏览器用**：关闭后把 cookie 拉回引擎 ⭐⭐⭐
    @MainActor
    public static func collectCookies(url: String, environment: SourceEnvironment, sourceKey: String?) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        await CookieSync.pull(url, into: environment.cookies, key: sourceKey, from: store)
        await CookieSync.pullAll(into: environment.cookies, from: store)
    }
}
#endif  // #if os(iOS)
