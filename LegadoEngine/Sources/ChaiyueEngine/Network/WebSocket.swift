import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WebSocketRequest: Sendable {
    public var url: String
    /// 握手请求头
    public var headers: [String: String]
    /// 握手超时。调用方另有计时，实现只需把它用作底层请求的超时
    public var timeout: TimeInterval
    /// 单条消息的最大字节数
    public var maximumMessageSize: Int

    public init(url: String, headers: [String: String] = [:], timeout: TimeInterval = 12, maximumMessageSize: Int = 1 << 20) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.maximumMessageSize = maximumMessageSize
    }
}

public enum WebSocketFrame: Sendable, Hashable {
    case text(String)
    case binary(Data)
}

/// WebSocket 传输层。规则引擎在工作线程上等待这些异步方法，超时与取消由调用方负责。测试时可注入模拟实现
public protocol WebSocketTransport: Sendable {
    /// 建立连接并完成握手
    func connect(_ request: WebSocketRequest) async throws -> any WebSocketConnection
}

public protocol WebSocketConnection: Sendable {
    func send(_ frame: WebSocketFrame) async throws
    /// 下一帧；对端以正常关闭码（1000）关闭时返回 nil，其它关闭码抛出 `WebSocketError.closed`
    func receive() async throws -> WebSocketFrame?
    /// 断开连接。可在任意线程重复调用，挂起中的 send/receive 必须随之结束
    func close()
}

public enum WebSocketError: LocalizedError, Equatable, Sendable {
    /// `java.webSocket` 参数错误，附带完整说明
    case invalidConfig(String)
    case connectFailed(String)
    /// 握手被拒绝（非 101 响应）
    case handshake(status: Int)
    /// 毫秒
    case connectTimeout(Int)
    /// 单帧等待超时，毫秒
    case timeout(Int)
    /// 单段音频超过上限，字节
    case audioTooLarge(Int)
    case closed(code: Int, reason: String)
    case connectionLost(String)
    /// onMessage 执行出错
    case script(String)
    /// onMessage 返回的 audio 不是 Base64
    case invalidAudio

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let message): message
        case .connectFailed(let message): "朗读服务连接失败：\(message)"
        case .handshake(let status): "朗读服务拒绝了连接（HTTP \(status)）"
        case .connectTimeout(let ms): "连接朗读服务超时（\(Self.seconds(ms))）"
        case .timeout(let ms): "朗读服务 \(Self.seconds(ms))内没有响应"
        case .audioTooLarge(let limit): "朗读音频超过上限（\(Self.size(limit))）"
        case .closed(let code, let reason): "朗读服务断开了连接（代码 \(code)）" + (reason.isEmpty ? "" : "：\(reason)")
        case .connectionLost(let message): "与朗读服务的连接中断：\(message)"
        case .script(let message): "朗读源 onMessage 执行出错：\(message)"
        case .invalidAudio: "朗读源 onMessage 返回的 audio 不是有效的 Base64"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .connectFailed, .connectTimeout, .timeout, .closed, .connectionLost: true
        case .handshake(let status): status >= 500 || status == 429 || status == 408
        case .invalidConfig, .audioTooLarge, .script, .invalidAudio: false
        }
    }

    private static func seconds(_ ms: Int) -> String {
        ms % 1000 == 0 ? "\(ms / 1000) 秒" : String(format: "%.1f 秒", Double(ms) / 1000)
    }

    private static func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 && bytes % (1 << 20) == 0 ? "\(bytes >> 20) MB" : "\(bytes) 字节"
    }
}

/// 基于 URLSessionWebSocketTask 的实现，不使用系统 Cookie
// ⭐⭐⭐ **移植补丁（2026-11-21）**：整个 class 在 `#if canImport(Darwin)` 里 ⭐⭐⭐
//   ⇒ Linux 的 swift-corelibs-foundation **没有 WebSocket 支持**（`URLSessionWebSocketTask` 不存在）⭐⭐⭐
//   ⇒ 不包 ⇒ Linux 编不到 ⇒ 沙盒门禁全废 ⭐⭐⭐
//   ⇒ Linux 版同名最小实现见 `Network/WebSocketLinux.swift`（`connect` 如实抛错）⭐⭐⭐
#if canImport(Darwin)
public final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var urlSession: URLSession?
    private var openers: [Int: CheckedContinuation<Void, Error>] = [:]
    private let trustsAllCertificates: Bool

    /// `trustsAllCertificates`：与 `URLSessionTransport` 一致，书源服务常用自签名证书
    public init(trustsAllCertificates: Bool = true) {
        self.trustsAllCertificates = trustsAllCertificates
        super.init()
    }

    private var session: URLSession {
        lock.withLock {
            if let urlSession { return urlSession }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            let queue = OperationQueue()
            queue.name = "RuleEngine.URLSessionWebSocketTransport"
            let created = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            urlSession = created
            return created
        }
    }

    public func connect(_ request: WebSocketRequest) async throws -> any WebSocketConnection {
        guard let url = URLSessionTransport.makeURL(request.url), let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw WebSocketError.invalidConfig("java.webSocket 的 url 必须以 ws:// 或 wss:// 开头：\(request.url)")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        req.httpShouldHandleCookies = false
        for (key, value) in request.headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = request.maximumMessageSize
        let id = task.taskIdentifier
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { openers[id] = continuation }
                if Task.isCancelled {
                    takeOpener(id)?.resume(throwing: CancellationError())
                    task.cancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
            takeOpener(id)?.resume(throwing: CancellationError())
        }
        return Connection(task: task)
    }

    private func takeOpener(_ id: Int) -> CheckedContinuation<Void, Error>? {
        lock.withLock { openers.removeValue(forKey: id) }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        takeOpener(webSocketTask.taskIdentifier)?.resume()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let opener = takeOpener(task.taskIdentifier) else { return }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            opener.resume(throwing: WebSocketError.handshake(status: http.statusCode))
        } else if let error = error as? URLError, error.code == .cancelled {
            opener.resume(throwing: CancellationError())
        } else {
            opener.resume(throwing: WebSocketError.connectFailed(error?.localizedDescription ?? "连接已关闭"))
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Darwin)
        // ⭐⭐⭐ **Darwin 专属**（Linux 的 swift-corelibs-foundation 不支持 server trust）⭐⭐⭐
        if trustsAllCertificates, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    private final class Connection: WebSocketConnection, @unchecked Sendable {
        let task: URLSessionWebSocketTask

        init(task: URLSessionWebSocketTask) { self.task = task }

        func send(_ frame: WebSocketFrame) async throws {
            let message: URLSessionWebSocketTask.Message
            switch frame {
            case .text(let text): message = .string(text)
            case .binary(let data): message = .data(data)
            }
            do {
                try await task.send(message)
            } catch {
                throw closedError() ?? WebSocketError.connectionLost(error.localizedDescription)
            }
        }

        func receive() async throws -> WebSocketFrame? {
            do {
                switch try await task.receive() {
                case .string(let text): return .text(text)
                case .data(let data): return .binary(data)
                @unknown default: return .binary(Data())
                }
            } catch {
                if task.closeCode == .normalClosure { return nil }
                throw closedError() ?? WebSocketError.connectionLost(error.localizedDescription)
            }
        }

        private func closedError() -> WebSocketError? {
            guard task.closeCode != .invalid else { return nil }
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .closed(code: task.closeCode.rawValue, reason: reason)
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
}

#endif  // #if canImport(Darwin)（Linux 无 WebSocket ⇒ 见 WebSocketLinux.swift）
