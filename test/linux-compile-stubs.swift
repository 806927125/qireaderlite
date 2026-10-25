import Foundation
// ⭐⭐⭐⭐⭐ **链【真引擎】**（`legado-engine` 的 SPM 产物）⇒ 能编 `LegadoEngineBackend.swift`
//   ⇒ 那个文件 import LegadoCore ⇒ 光靠 stub 隔不掉 ⇒ 必须链真模块 ⭐⭐⭐
//   ⚠️ 门禁在「找不到 LegadoCore 模块」时**显式 SKIP**（不许假绿）⭐
#if canImport(LegadoCore)
import LegadoCore
#endif

// MARK: - ⭐⭐⭐⭐⭐ **本文件是「Linux 编译门禁」的夹具**（不是生产代码）
//
// ⚠️⚠️⚠️ **stub 原则：只给签名，绝对不给实现**
//   ⇒ 否则就是「用假实现验真代码」⇒ 失去意义 ⭐⭐⭐
//   ⇒ 一旦给了实现，「多一个 `}`」「类型写错」「方法不存在」就抓不到了 ⭐⭐⭐
//
// ⚠️⚠️ **本文件里的每个符号，都必须对应 App 侧真实文件里的一个符号**
//   ⇒ 重复定义会报 `invalid redeclaration` ⇒ 门禁自己就红 ⇒ 逼你同步 ⭐⭐⭐

// MARK: - Stub：`RuleSandbox`（真身在 RuleSandbox.swift，import UIKit ⇒ Linux 编不到）

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

// MARK: - Stub：`CookieJar`（真身在 RuleSandbox.swift）


// MARK: - Stub：`CacheFiles`（真身在 RuleSandbox.swift）


// MARK: - Stub：`EngineBackend`（真身在 EngineBackend.swift）

public enum EngineBackend {
    public enum Kind: String { case swiftNew = "新 Swift 引擎（legado-engine）" }
    public static var current: Kind { .swiftNew }
    public static var lastError: String?
    public static var description: String { "新 Swift 引擎（legado-engine）" }
}

// MARK: - Stub：`ObservableObject` / `@Published`（SwiftUI/Combine ⇒ Linux 没有）
// ⚠️ iOS 上 `SourceService.swift` 只 import Foundation 却能用它们 ⇒ 靠 Foundation 间接带入 ⭐⭐⭐

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

// MARK: - Stub：`Toast`（真身在 RuleSandbox.swift，含 UIKit）

enum Toast {
    static func show(_ text: String) {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - Stub：`AppDecoder`（真身在 Store.swift，那个文件 import SwiftUI ⇒ Linux 编不到）

enum AppDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        fatalError("stub：门禁只做编译检查，不许真跑")
    }
}

// MARK: - ⭐⭐⭐⭐⭐ 引擎版本片段（与 `RuleSandbox.swift` 的**真代码逐字一致**）
//
// ⚠️⚠️ **这段必须与 `QiReaderLite/Core/RuleSandbox.swift` 保持一致**
//   ⇒ 门禁会**比对两边** ⇒ 改了一边忘了另一边 ⇒ 门禁红 ⭐⭐⭐
//   ⚠️ 2026-10-25 build254 CI 实证：真实代码里写的是 `Self.engineRevision`
//   ⇒ Swift 报 `covariant 'Self' type cannot be referenced from a stored property initializer`
//   ⇒ **CI 必挂** ⇒ 这里也必须用**显式类型名** ⭐⭐⭐

/// ⭐⭐⭐ **引擎版本串的拼装**（与 `RuleSandbox.swift` 里的**真代码逐字一致**）
enum LegadoEngineInfo {
    static func version(revision: String) -> String {
        "legado-engine \(revision) · 老 JS 引擎已退役，只剩新引擎"
    }
}

/// ⭐⭐⭐ **revision 常量**（与 `RuleSandbox.swift` 里的**真代码逐字一致**）
enum EngineRevision {
    static let generated: String = "unknown"
}

enum RuleSandboxVersionProbe {
    /// ⭐⭐⭐⭐⭐ **这里就是 CI 挂过的那一行**（`Self.` ⇒ Swift 编译错误 ⇒ CI 必挂）
    static let engineRevision: String = EngineRevision.generated
    static let engineVersion = LegadoEngineInfo.version(revision: RuleSandboxVersionProbe.engineRevision)
}

// ⭐⭐⭐⭐⭐ **别在这里 stub `CookieJar` / `CacheFiles`**（2026-10-26 真 bug）
//
// ⚠️⚠️⚠️ **为什么**：这两个类型**真实存在**（在 `QiReaderLite/Core/HostTools.swift`）
//   ⇒ stub 里再定义一份 ⇒ **重名** ⇒ 真类型被遮住 ⇒ 门禁**假绿** ⭐⭐⭐
//   ⇒ 后果：App 侧真代码里的类型错（`CookieJar` 没有 `cookieString`）**沙盒看不见**
//   ⇒ 一路漏到 iOS CI ⇒ BUILD FAILED（2026-10-26 实证）⭐⭐⭐
//
// ⭐⭐⭐ **通用判据**：
//   **stub 只许给「App 侧确实没有、但被 import 的模块提供」的类型**
//   ⇒ App 侧自己有的类型**绝不能 stub** ⇒ 否则真身被遮住 ⇒ 门禁失明 ⭐⭐⭐
//   ⇒ 变异测试能自证：把真类型改名 ⇒ 门禁必须报「重名/找不到」而不是绿 ⭐⭐⭐
