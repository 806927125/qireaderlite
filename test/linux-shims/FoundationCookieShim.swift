#if canImport(FoundationNetworking)
// ⭐⭐⭐ **Linux 专属 shim**：`HTTPCookieStorage` / `HTTPCookie` 的几个 Apple 专有成员
//
// ⚠️⚠️ **为什么需要**（2026-10-26 类型检查门禁撞到）：
//   Apple 平台：`HTTPCookieStorage.shared.cookies` 是**属性**、`HTTPCookie.domain`、
//     `HTTPCookieStorage.deleteCookie(_:)` 都有
//   Linux（corelibs-foundation + FoundationNetworking）：**一个都没有**
//   ⇒ 源码里 `HTTPCookieStorage.shared.cookies ?? []` 在 Linux 上被解析成
//     **未调用的方法引用** `(URL) -> [HTTPCookie]` ⇒ `??` 报类型错 ⭐⭐⭐
//   ⇒ 于是 `HostTools.swift` 编不过 ⇒ swiftc 在前面的文件就中断了
//     ⇒ **后面改过的文件根本没被类型检查过**（假绿）⭐⭐⭐
//
// ⭐ **本 shim 只为让类型检查跑过去**（沙盒 Linux 上 cookie 快照是空的 ⇒ 不影响真机）
//   ⇒ 真机走 Darwin 分支 ⇒ 用的是系统真实实现 ⭐⭐⭐
import Foundation
import FoundationNetworking

extension HTTPCookieStorage {
    /// ⭐ Linux 没有 `cookies` 属性（真机有）
    var cookies: [HTTPCookie] { [] }
    /// ⭐ Linux 没有 `deleteCookie`（真机有 ⇒ 换 cookie 时会删旧的）
    func deleteCookie(_ cookie: HTTPCookie) {}
}

extension HTTPCookie {
    /// ⭐ Linux 连 `properties` 都没有 ⇒ 沙盒里给空串（只够类型检查）
    var domain: String { "" }
}
#endif
