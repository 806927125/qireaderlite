#if canImport(JavaScriptCore) && !os(Linux)
import Foundation
import JavaScriptCore

/// `java.webSocket(config)`：JavaScriptCore 没有 WebSocket，由原生层完成连接与收发，协议细节交给书源的 onMessage。
/// 整个会话在 JS 线程上同步完成：网络操作在 Swift 并发线程池中执行，JS 线程以信号量等待并轮询超时与取消；
/// JSValue 只在 JS 线程上读写，异步闭包里只传递 Swift 值
final class JSWebSocketCall {
    struct Config {
        var url: String
        var headers: [String: String]
        var send: [WebSocketFrame]
        var onMessage: JSValue
        /// 毫秒
        var connectTimeout: Int
        /// 单帧等待，毫秒
        var receiveTimeout: Int
        var maxAudioBytes: Int
        var contentType: String
    }

    static let defaultConnectTimeout = 12_000
    static let defaultReceiveTimeout = 30_000
    static let defaultMaxAudioBytes = 16 << 20
    static let maxAudioBytesLimit = 64 << 20
    /// `java.webSocket` 的返回值。朗读流程从会话中取音频，不会把它当作地址请求
    static let resultMarker = "java.webSocket:audio"

    private unowned let runtime: JSRuntime
    private var session: RuleSession { runtime.session }
    private var context: JSContext { runtime.context }

    init(runtime: JSRuntime) {
        self.runtime = runtime
    }

    func run(_ argument: JSValue?) throws -> TTSAudio {
        let config = try parseConfig(argument)
        let session = session
        try session.checkCancelled()
        let source = session.source
        try RateLimiter.shared.acquire(key: source.key, rate: source.concurrentRate, isCancelled: { session.isCancelled })
        defer { RateLimiter.shared.release(key: source.key, rate: source.concurrentRate) }

        var headers = config.headers
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = session.env.userAgent
        }
        let request = WebSocketRequest(
            url: config.url, headers: headers, timeout: Double(config.connectTimeout) / 1000,
            maximumMessageSize: config.maxAudioBytes / 3 * 4 + (1 << 20)
        )
        let transport = session.env.webSocket
        let connection = try wait(config.connectTimeout, timeoutError: .connectTimeout(config.connectTimeout), connection: nil,
                                  discard: { $0.close() }) {
            try await transport.connect(request)
        }
        defer { connection.close() }

        for frame in config.send {
            try send(frame, over: connection, timeout: config.receiveTimeout)
        }
        var audio = Data()
        var state: JSValue = JSValue(newObjectIn: context)
        while true {
            let next = try wait(config.receiveTimeout, timeoutError: .timeout(config.receiveTimeout), connection: connection) {
                try await connection.receive()
            }
            // 对端正常关闭视为结束
            guard let frame = next else { break }
            let message = JSWebSocketMessage(frame)
            let returned: JSValue?
            do {
                returned = try runtime.call(config.onMessage, [message, state])
            } catch RuleError.js(let text) {
                throw WebSocketError.script(text)
            }
            try session.checkCancelled()
            guard let result = returned, result.isObject, !result.isArray else { continue }

            if let error = Self.property(result, "error"), error.toBool() {
                throw TTSError.server(JSRuntime.stringArgument(error) ?? "")
            }
            if let value = Self.property(result, "audio") {
                guard value.isString, let data = Self.decodeBase64(value.toString()) else { throw WebSocketError.invalidAudio }
                guard audio.count + data.count <= config.maxAudioBytes else {
                    throw WebSocketError.audioTooLarge(config.maxAudioBytes)
                }
                audio.append(data)
            }
            if result.hasProperty("state") {
                state = result.objectForKeyedSubscript("state")
            }
            if let more = Self.property(result, "send") {
                for frame in try parseFrames(more, field: "onMessage 返回的 send") {
                    try send(frame, over: connection, timeout: config.receiveTimeout)
                }
            }
            if Self.property(result, "done")?.toBool() == true { break }
        }
        guard !audio.isEmpty else { throw TTSError.emptyAudio }
        return TTSAudio(data: audio, contentType: config.contentType)
    }

    private func send(_ frame: WebSocketFrame, over connection: any WebSocketConnection, timeout: Int) throws {
        try wait(timeout, timeoutError: .timeout(timeout), connection: connection) {
            try await connection.send(frame)
        }
    }

    // MARK: - 同步等待

    private final class Pending<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var abandoned = false
        let semaphore = DispatchSemaphore(value: 0)

        /// 返回 true 表示等待方已放弃
        func finish(_ result: Result<T, Error>) -> Bool {
            let abandoned = lock.withLock {
                self.result = result
                return self.abandoned
            }
            semaphore.signal()
            return abandoned
        }

        /// 放弃等待；结果已经到达时返回成功值，交给调用方清理
        func abandon() -> T? {
            lock.withLock {
                abandoned = true
                return try? result?.get()
            }
        }

        func get() throws -> T {
            try lock.withLock { result! }.get()
        }
    }

    /// 阻塞 JS 线程直到异步操作完成。超时或取消时断开连接；放弃等待后才到达的结果交给 `discard` 清理
    private func wait<T: Sendable>(_ timeoutMs: Int, timeoutError: WebSocketError, connection: (any WebSocketConnection)?,
                                   discard: (@Sendable (T) -> Void)? = nil,
                                   _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let pending = Pending<T>()
        let task = Task {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            if pending.finish(result), case .success(let value) = result { discard?(value) }
        }
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        while pending.semaphore.wait(timeout: min(.now() + .milliseconds(50), deadline)) == .timedOut {
            let failure: Error
            if session.isCancelled {
                failure = RuleError.cancelled
            } else if DispatchTime.now() >= deadline {
                failure = timeoutError
            } else {
                continue
            }
            task.cancel()
            connection?.close()
            if let late = pending.abandon() { discard?(late) }
            throw failure
        }
        do {
            return try pending.get()
        } catch is CancellationError {
            throw RuleError.cancelled
        }
    }

    // MARK: - 参数

    private func parseConfig(_ value: JSValue?) throws -> Config {
        guard let value, value.isObject, !value.isArray, !isFunction(value) else {
            throw WebSocketError.invalidConfig("java.webSocket 参数必须是对象")
        }
        guard let url = Self.property(value, "url").flatMap(JSRuntime.stringArgument)?.trimmedWhitespace, !url.isEmpty else {
            throw WebSocketError.invalidConfig("java.webSocket 缺少 url")
        }
        let lower = url.lowercased()
        guard lower.hasPrefix("ws://") || lower.hasPrefix("wss://") else {
            throw WebSocketError.invalidConfig("java.webSocket 的 url 必须以 ws:// 或 wss:// 开头：\(url)")
        }
        guard let sendValue = Self.property(value, "send") else {
            throw WebSocketError.invalidConfig("java.webSocket 缺少 send")
        }
        let frames = try parseFrames(sendValue, field: "send")
        guard let handler = Self.property(value, "onMessage") else {
            throw WebSocketError.invalidConfig("java.webSocket 缺少 onMessage")
        }
        let maxAudio = Self.positiveInt(Self.property(value, "maxAudioBytes")) ?? Self.defaultMaxAudioBytes
        let contentType = Self.property(value, "contentType").flatMap(JSRuntime.stringArgument)?.trimmedWhitespace
        return Config(
            url: url,
            headers: Self.headers(Self.property(value, "headers")),
            send: frames,
            onMessage: try messageHandler(handler),
            connectTimeout: Self.positiveInt(Self.property(value, "connectTimeout")) ?? Self.defaultConnectTimeout,
            receiveTimeout: Self.positiveInt(Self.property(value, "receiveTimeout")) ?? Self.defaultReceiveTimeout,
            maxAudioBytes: min(maxAudio, Self.maxAudioBytesLimit),
            contentType: contentType.flatMap { $0.isEmpty ? nil : $0 } ?? "audio/mpeg"
        )
    }

    /// 函数直接使用；字符串先按表达式求值（可以引用 message、state，结果为函数时再以 (message, state) 调用），
    /// 不是合法表达式时按函数体处理
    private func messageHandler(_ value: JSValue) throws -> JSValue {
        if isFunction(value) { return value }
        guard value.isString, let code = value.toString(), !code.isBlank else {
            throw WebSocketError.invalidConfig("java.webSocket 的 onMessage 必须是函数或 JS 表达式")
        }
        let expression = "(function (message, state) { var __r = (\(code)\n); "
            + "return typeof __r === 'function' ? __r(message, state) : __r; })"
        do {
            if let fn = try runtime.evaluateNested(expression), isFunction(fn) { return fn }
        } catch {
            if let fn = try? runtime.evaluateNested("(function (message, state) {\n\(code)\n})"), isFunction(fn) { return fn }
            throw WebSocketError.invalidConfig("java.webSocket 的 onMessage 无效：\(error)")
        }
        throw WebSocketError.invalidConfig("java.webSocket 的 onMessage 无效")
    }

    /// 字符串为文本帧，`{type:"binary", data:"Base64"}` 为二进制帧；可以是单个帧或数组
    private func parseFrames(_ value: JSValue, field: String) throws -> [WebSocketFrame] {
        guard value.isArray else { return [try parseFrame(value, field: field)] }
        let length = Int(value.objectForKeyedSubscript("length")?.toInt32() ?? 0)
        return try (0..<length).map { try parseFrame(value.atIndex($0), field: field) }
    }

    private func parseFrame(_ value: JSValue, field: String) throws -> WebSocketFrame {
        if value.isString { return .text(value.toString()) }
        if value.isObject, !value.isArray {
            let type = Self.property(value, "type").flatMap(JSRuntime.stringArgument)?.lowercased() ?? ""
            let data = Self.property(value, "data").flatMap(JSRuntime.stringArgument)
            if type == "binary" {
                guard let data, let bytes = Self.decodeBase64(data) else {
                    throw WebSocketError.invalidConfig("java.webSocket 的 \(field) 中二进制帧的 data 不是有效的 Base64")
                }
                return .binary(bytes)
            }
            if type == "text", let text = data ?? Self.property(value, "text").flatMap(JSRuntime.stringArgument) {
                return .text(text)
            }
        }
        let shown = JSRuntime.stringArgument(value) ?? "null"
        throw WebSocketError.invalidConfig("java.webSocket 的 \(field) 中有无效的帧：\(shown.prefix(200))")
    }

    private func isFunction(_ value: JSValue) -> Bool {
        value.isObject && JSObjectIsFunction(context.jsGlobalContextRef, value.jsValueRef)
    }

    private static func property(_ object: JSValue, _ name: String) -> JSValue? {
        guard let value = object.objectForKeyedSubscript(name), !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    private static func positiveInt(_ value: JSValue?) -> Int? {
        guard let value else { return nil }
        let number = value.isNumber ? value.toDouble() : Double(value.toString().trimmedWhitespace) ?? .nan
        guard number.isFinite, number >= 1 else { return nil }
        return Int(min(number, Double(Int32.max)))
    }

    private static func headers(_ value: JSValue?) -> [String: String] {
        guard let value else { return [:] }
        if value.isString { return LenientJSON.stringMap(value.toString()) ?? [:] }
        guard let dict = JSRuntime.fromJS(value) as? [String: Any] else { return [:] }
        return dict.mapValues { RuleValue.jsString($0) ?? "" }
    }

    /// 音频可能有数 MB，先走系统解码，失败再兼容 URL 安全字符与换行
    static func decodeBase64(_ text: String) -> Data? {
        Data(base64Encoded: text) ?? Base64Codec.decode(text)
    }
}

// MARK: - onMessage 的 message 参数

@objc protocol JSWebSocketMessageExports: JSExport {
    /// "text" 或 "binary"
    var type: String { get }
    /// 只有文本帧有值
    var text: String? { get }
    /// 字节数（文本帧按 UTF-8）
    var count: Int { get }
    func byteAt(_ offset: JSValue) -> JSValue
    func uint16BE(_ offset: JSValue) -> JSValue
    func utf8(_ offset: JSValue, _ length: JSValue) -> JSValue
    func base64(_ offset: JSValue, _ length: JSValue) -> JSValue
}

final class JSWebSocketMessage: NSObject, JSWebSocketMessageExports {
    let type: String
    let text: String?
    private let bytes: Data

    init(_ frame: WebSocketFrame) {
        switch frame {
        case .text(let text):
            type = "text"
            self.text = text
            bytes = Data(text.utf8)
        case .binary(let data):
            type = "binary"
            text = nil
            bytes = data
        }
    }

    var count: Int { bytes.count }

    /// length 为 -1 或省略时读到末尾；越界时抛出 JS 异常
    private func range(_ name: String, _ offset: JSValue, _ length: JSValue?) -> Range<Int>? {
        let start = offset.isNumber ? Int(offset.toInt32()) : 0
        var end = bytes.count
        if let length, length.isNumber, length.toInt32() != -1 {
            end = start + Int(length.toInt32())
        }
        guard start >= 0, start <= end, end <= bytes.count else {
            JSRuntime.throwError(RuleError.message("message.\(name) 越界：offset=\(start)，长度=\(bytes.count)"))
            return nil
        }
        return (bytes.startIndex + start)..<(bytes.startIndex + end)
    }

    private func undefined() -> JSValue { JSValue(undefinedIn: JSContext.current()) }

    func byteAt(_ offset: JSValue) -> JSValue {
        guard let r = range("byteAt", offset, JSValue(int32: 1, in: JSContext.current())) else { return undefined() }
        return JSValue(int32: Int32(bytes[r.lowerBound]), in: JSContext.current())
    }

    func uint16BE(_ offset: JSValue) -> JSValue {
        guard let r = range("uint16BE", offset, JSValue(int32: 2, in: JSContext.current())) else { return undefined() }
        let value = Int32(bytes[r.lowerBound]) << 8 | Int32(bytes[r.lowerBound + 1])
        return JSValue(int32: value, in: JSContext.current())
    }

    func utf8(_ offset: JSValue, _ length: JSValue) -> JSValue {
        guard let r = range("utf8", offset, length) else { return undefined() }
        return JSValue(object: String(decoding: bytes[r], as: UTF8.self), in: JSContext.current())
    }

    func base64(_ offset: JSValue, _ length: JSValue) -> JSValue {
        guard let r = range("base64", offset, length) else { return undefined() }
        return JSValue(object: Data(bytes[r]).base64EncodedString(), in: JSContext.current())
    }
}

#endif  // #if canImport(JavaScriptCore) && !os(Linux)
