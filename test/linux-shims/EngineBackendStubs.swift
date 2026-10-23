// 只给「**新引擎适配层**的类型检查」用的最小替身。
//
// ⚠️ **为什么单独一份**：轻阅的 `RuleSandbox.swift` 依赖 WebKit / UIKit / SwiftUI
//    ⇒ 完整 Foundation 层门禁要靠一整套 shim（`WebKitUIKitShim.swift`），
//    而那份 shim **跟不上 RuleSandbox 的演进**（已知的既有缺口）。
//    ⇒ 适配层（模型转换 + 传输 + op 映射）**才是这轮最需要真类型检查的东西**
//    ⇒ 给它一条**独立、能跑**的通道 ⇒ 3 秒抓类型错 ⭐
//
// ⚠️ 这个文件**只在沙盒门禁里编译** ⇒ 不会进 App。

import Foundation

// MARK: - 适配层用到的宿主能力（最小替身）

enum Toast {
    static func show(_ message: String) {}
}

enum CookieJar {
    static func cookieString(for url: String) -> String { "" }
    static func snapshot() -> [String: String] { [:] }
}

enum CacheFiles {
    static func write(_ path: String, _ text: String) -> Bool { true }
    static func read(_ path: String) -> String? { nil }
}

// ⚠️⚠️ **必须标 `@MainActor`** —— 真机的 `RuleSandbox` 就是 `@MainActor`
//   ⇒ 适配层在后台线程调 `appendLog` 会被编译器拦下
//   ⇒ ⚠️ **沙盒 stub 之前没标 ⇒ 那类错误本地看不见（真机 CI 才炸）** ⭐
//   ⇒ 现在标上 ⇒ 沙盒就能抓「主线程隔离」这类错
@MainActor
final class RuleSandbox {
    static let shared = RuleSandbox()
    func appendLog(_ message: String) {}
    func invoke(_ op: String, _ payload: [String: Any] = [:],
                source: BookSource? = nil) async throws -> Any { [:] }
    func fullLogText() -> String { "" }
}

// MARK: - `SourceService` 需要的替身

enum AppEncoder {
    static func encode<T: Encodable>(_ v: T) throws -> Data { try JSONEncoder().encode(v) }
}

enum AppDecoder {
    static func decode<T: Decodable>(_ t: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(t, from: data)
    }
}

enum LegadoCompat {
    static func pingHosts(_ hosts: [String], timeout: Double = 6) async -> [[String: Any]] { [] }
}
