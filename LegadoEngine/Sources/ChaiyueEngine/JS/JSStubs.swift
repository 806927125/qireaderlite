#if !canImport(JavaScriptCore)
// ⭐⭐⭐⭐⭐ **Linux 沙盒桩**（2026-11-21 移植柴阅时加）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么要有这个文件**（记忆老坑：「沙盒编不到 = 没有门禁」）⭐⭐⭐
//   柴阅的 JS 层（`JS/*.swift`）整体在 `#if canImport(JavaScriptCore)` 里
//   ⇒ **Linux 沙盒没有 JSC** ⇒ `Engine/` `Rule/` `Network/` 里的非 JS 文件引用
//     `JSRuntime` / `JSResponse` / `JSSymmetricCrypto` / `JavaBridge` ⇒ **编不过** ⭐⭐⭐
//   ⇒ 编不过 ⇒ `swift build` 失败 ⇒ **沙盒门禁（linux-compile-gate）整条挂掉**
//     ⇒ 当天写的东西**一次都没被编译过**都不知道 ⭐⭐⭐
//
// ⭐⭐⭐ **为什么用「桩」而不是「逐处条件编译」**：
//   · 逐处条件编译要改柴阅 8 个文件的几十处 ⇒ **与上游的 diff 巨大** ⇒ 以后同步上游极痛 ⭐⭐⭐
//   · 桩是**独立新文件** ⇒ 柴阅的业务代码**一行不动** ⇒ diff 最小 ⭐⭐⭐
//   ⇒ 与上游的 diff 只有这个文件（删掉即可回到上游原样）⭐⭐⭐
//
// ⭐⭐⭐ **桩的行为必须「如实失败」，不能伪装成功**（否则门禁会假绿）⭐⭐⭐
//   ⇒ `JSRuntime.eval` **抛错**（"当前平台没有 JavaScriptCore"）
//     ⇒ 规则解析里「规则是 JS」的分支会**明确报错** ⇒ 门禁能测出「不该走 JS 路径」⭐⭐⭐
//   ⇒ ⚠️ 真实实现见 `JS/JSRuntime.swift`（Apple 平台走那条路 ⇒ 桩完全不参与）⭐⭐⭐
import Foundation

/// Linux 桩：JS 运行时（真实实现见 `JS/JSRuntime.swift`）
final class JSRuntime {
    unowned let session: RuleSession
    private(set) var bridge: JavaBridge!

    init(session: RuleSession) {
        self.session = session
        bridge = JavaBridge(runtime: self)
    }

    /// 当前执行中的解析器
    var currentHost: JSAnalyzerHost? { nil }

    /// ⭐⭐⭐ **如实抛错**（不伪装成功 ⇒ 门禁不会假绿）
    func eval(_ script: String, bindings: JSBindings) throws -> Any? {
        throw RuleError.js("当前平台没有 JavaScriptCore，无法求值 JavaScript（Linux 沙盒桩）")
    }

    func evalValue(_ script: String, bindings: JSBindings) throws -> Any? {
        try eval(script, bindings: bindings)
    }
}

/// Linux 桩：JS 原生桥（真实实现见 `JS/JavaBridge.swift`）
final class JavaBridge {
    private unowned let runtime: JSRuntime

    init(runtime: JSRuntime) {
        self.runtime = runtime
    }

    func enterLoginContext() {}
    func leaveLoginContext() {}
}

/// Linux 桩：响应对象（真实实现见 `JS/JSObjects.swift`）
final class JSResponse: NSObject {
    let responseURL: String
    let responseBody: String
    let status: Int
    let responseHeaders: [String: String]
    let bodyData: Data?

    init(url: String, body: String, status: Int = 200, headers: [String: String] = [:], bodyData: Data? = nil) {
        responseURL = url
        responseBody = body
        self.status = status
        responseHeaders = headers
        self.bodyData = bodyData
    }

    func body() -> String { responseBody }
    func url() -> String { responseURL }
    func code() -> Int { status }
    func statusCode() -> Int { status }
    func message() -> String { "HTTP \(status)" }
    func headers() -> NSDictionary { responseHeaders as NSDictionary }

    func header(_ name: String) -> String? {
        responseHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func cookies() -> NSDictionary {
        var map: [String: String] = [:]
        for (k, v) in responseHeaders where k.lowercased() == "set-cookie" {
            for part in v.components(separatedBy: "\n") {
                guard let pair = part.split(separator: ";").first, let eq = pair.firstIndex(of: "=") else { continue }
                map[String(pair[..<eq]).trimmedWhitespace] = String(pair[pair.index(after: eq)...]).trimmedWhitespace
            }
        }
        return map as NSDictionary
    }

    func raw() -> JSResponse { self }
    func toString() -> String { responseBody }
}

/// Linux 桩：对称加密（真实实现见 `JS/JavaBridge.swift`，依赖 CommonCrypto ⇒ Apple only）
final class JSSymmetricCrypto: NSObject {
    init(transformation: String, key: Data, iv: Data?) {
        super.init()
    }

    /// ⭐⭐⭐ **如实抛错**（Linux 上没有 CommonCrypto ⇒ 登录信息加解密不可用 ⇒ 明说）
    func encryptData(_ data: Data) throws -> Data {
        throw RuleError.js("当前平台没有 CommonCrypto，无法加密（Linux 沙盒桩）")
    }

    func decryptData(_ data: Data) throws -> Data {
        throw RuleError.js("当前平台没有 CommonCrypto，无法解密（Linux 沙盒桩）")
    }

    func decryptString(_ text: String) throws -> String {
        throw RuleError.js("当前平台没有 CommonCrypto，无法解密（Linux 沙盒桩）")
    }
}

#endif  // #if !canImport(JavaScriptCore)
