#if !canImport(Darwin)
// ⭐⭐⭐ **Linux 沙盒的 WebSocket 桩**（2026-11-21 移植柴阅时加）⭐⭐⭐
//
// ⚠️⚠️ **为什么需要**：Linux 的 swift-corelibs-foundation **没有 WebSocket 支持**
//   （`URLSessionWebSocketTask` 整个类型都不存在）⇒ 柴阅的 `URLSessionWebSocketTransport`
//   只能在 Apple 平台编译 ⇒ Linux 上必须有个**同名**的替代品，
//   否则 `SourceEnvironment`（默认参数 `webSocket: URLSessionWebSocketTransport()`）编不过 ⭐⭐⭐
//   ⇒ 整条编译链断 ⇒ **沙盒门禁全废** ⭐⭐⭐
//
// ⭐⭐⭐ **桩的行为必须「如实失败」**（不伪装成功 ⇒ 门禁不会假绿）⭐⭐⭐
import Foundation

/// Linux 桩：`java.webSocket` / 朗读 TTS 在沙盒里不可用 ⇒ 如实抛错
public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    public init() {}

    public func connect(_ request: WebSocketRequest) async throws -> any WebSocketConnection {
        throw WebSocketError.connectFailed("当前平台没有 WebSocket 支持（Linux 沙盒桩）")
    }
}
#endif  // #if !canImport(Darwin)
