// ⭐⭐⭐⭐⭐ **Linux 编译门禁：让 `SourceService.swift` 在沙盒里被真编译**
//
// ⚠️⚠️⚠️ **为什么必须有这个**（2026-10-25 build253 CI 失败事故）：
//   我改了 `SourceService.swift`（新增 `withRealTimeout`）⇒ **沙盒门禁全绿**
//   ⇒ 但沙盒的 swift 门禁**根本没编这个文件**（只编 LegadoCompat / AnalyzeUrl / Book …）
//   ⇒ 于是**多了一个 `}`** 也没人发现 ⇒ 推到 CI ⇒ **BUILD FAILED**（白等一轮 CI）⭐⭐⭐
//   ⇒ 错误是 `extraneous '}' at top level` + 一串 `static methods may only be declared on a type`
//
// ⇒ 所以：**凡是 App 侧 Core/ 里的文件，都必须有 Linux 侧的编译覆盖** ⭐⭐⭐
//   ⇒ `SourceService.swift` 依赖 `RuleSandbox`（含 UIKit ⇒ Linux 编不到）
//   ⇒ 办法：**造 stub**（只提供签名，不含实现）⇒ 把 UIKit 依赖隔掉 ⇒ 真编译 ⭐
//
// ⚠️ **stub 原则**：只提供**签名**（类型 + 方法签名），**不许提供实现**
//   ⇒ 这样「多一个 `}`」「类型写错」「方法不存在」都会**真编译报错** ⭐⭐⭐
//   ⇒ 一旦给 stub 写了实现 ⇒ 就会变成「用假实现验真代码」⇒ 失去意义 ⇒ 禁止 ⭐
//
// ⇒ 本文件是**门禁夹具**（不是生产代码）⇒ 只在沙盒里被 swiftc 编 ⇒ 不进 App
import Foundation

// MARK: - ⭐⭐⭐ Stub：`RuleSandbox`（真身含 UIKit ⇒ Linux 编不到 ⇒ 这里只给签名）

/// ⭐ 只给签名 —— 真身有 UIKit ⇒ Linux 编不到
final class RuleSandbox {
    static let shared = RuleSandbox()
    /// ⭐ 真身：`func invoke(_ op: String, _ payload: [String: Any] = [:], source: BookSource? = nil) async throws -> Any`
    func invoke(_ op: String, _ payload: [String: Any] = [:], source: BookSource? = nil) async throws -> Any {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
    /// ⭐ 真身：`func appendLog(_ line: String)`
    func appendLog(_ line: String) {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - ⭐⭐⭐ Stub：`CookieJar`（真身在 RuleSandbox.swift 里）

enum CookieJar {
    /// ⭐ 真身：`CookieJar.snapshot()`
    static func snapshot() -> String {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - ⭐⭐⭐ Stub：`EngineBackend`（真身在 EngineBackend.swift，引用 UIKit？先 stub 掉）

enum EngineBackend {
    enum Kind: String { case swiftNew = "新 Swift 引擎（legado-engine）" }
    static var current: Kind { .swiftNew }
    static var lastError: String?
    static var description: String { "新 Swift 引擎（legado-engine）" }
}

// MARK: - ⭐⭐⭐ Stub：`LegadoEngineBackend`（真身 import LegadoCore ⇒ Linux 编不到）

final class LegadoEngineBackend: @unchecked Sendable {
    static let shared = LegadoEngineBackend()
    /// ⭐ 真身：`func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any?`
    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
    /// ⭐ 真身：`func dropSession(for sourceUrl: String)`
    func dropSession(for sourceUrl: String) {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - ⭐⭐⭐ Stub：`ObservableObject` / `@Published`（SwiftUI/Combine ⇒ Linux 没有）
// ⚠️ iOS 上 `SourceService.swift` 只 import Foundation 却能用它们
//   ⇒ 靠 Foundation 间接带入 ⇒ Linux 上编不到 ⇒ 这里给最小 stub ⭐

protocol ObservableObject: AnyObject {}

@propertyWrapper
struct Published<Value> {
    private var value: Value
    init(wrappedValue: Value) { self.value = wrappedValue }
    init(initialValue: Value) { self.value = initialValue }
    var wrappedValue: Value {
        get { value }
        set { value = newValue }
    }
    var projectedValue: Published<Value> { self }
}

// MARK: - ⭐⭐⭐ Stub：`Toast`（真身在 RuleSandbox.swift，含 UIKit）

enum Toast {
    static func show(_ text: String) {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - ⭐⭐⭐ Stub：`AppDecoder`（真身在 Store.swift，那个文件 import SwiftUI ⇒ Linux 编不到）

enum AppDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - ⭐⭐⭐⭐⭐ `RuleSandbox` 的**可编译片段**（2026-10-25 build254 CI 失败实证）
//
// ⚠️⚠️ **为什么单独抽出来**：
//   `RuleSandbox.swift` 整个文件 import UIKit/WebKit/SwiftUI ⇒ **Linux 编不到**
//   ⇒ 它的**类型错误**（如 `Self` 在存储属性初始化器里）**沙盒永远抓不到** ⭐⭐⭐
//   ⇒ 实测：build254 CI 报 `covariant 'Self' type cannot be referenced from
//     a stored property initializer` ⇒ 沙盒门禁全绿 ⇒ **白等一轮 CI** ⭐⭐⭐
//
// ⇒ 办法：把**与纯 Foundation 相关的部分**抽到这里 ⇒ Linux 真编真 typecheck ⭐⭐⭐
//   ⚠️ **stub 原则不变**：只给签名，不给实现 ⇒ 但这段是**真代码**（要验语义）⭐

/// ⭐⭐⭐ **引擎版本串的拼装 + revision 读取**（与 `RuleSandbox` 里的**真代码逐字一致**）
///
/// ⚠️⚠️ **这段必须与 `QiReaderLite/Core/RuleSandbox.swift` 保持一致**
///   ⇒ 门禁会**比对两边** ⇒ 改了一边忘了另一边 ⇒ 门禁红 ⭐⭐⭐
enum LegadoEngineInfo {
    static func version(revision: String) -> String {
        "legado-engine \(revision) · 老 JS 引擎已退役，只剩新引擎"
    }
}

/// ⭐⭐⭐ **revision 常量**（与 `RuleSandbox` 里的**真代码逐字一致**）
enum EngineRevision {
    static let generated: String = "unknown"
}

enum RuleSandboxVersionProbe {
    /// ⭐⭐⭐⭐⭐ **这里就是 CI 挂过的那一行**：
    ///   旧写法 `Self.engineRevision` ⇒ `covariant 'Self' type cannot be referenced
    ///   from a stored property initializer` ⇒ **CI 必挂** ⭐⭐⭐
    ///   ⇒ 修法：**显式类型名**（`RuleSandboxVersionProbe.engineRevision`）⭐⭐⭐
    static let engineRevision: String = EngineRevision.generated
    static let engineVersion = LegadoEngineInfo.version(revision: RuleSandboxVersionProbe.engineRevision)
}
