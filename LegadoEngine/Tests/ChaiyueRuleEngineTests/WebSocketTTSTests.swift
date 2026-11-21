import Foundation
import ChaiyueModels
@testable import ChaiyueEngine
import Testing

/// 脚本化的模拟服务端：每收到客户端一帧调用 `reply`，返回要推送给客户端的事件
final class MockWebSocket: WebSocketTransport, @unchecked Sendable {
    enum Event: Sendable {
        case frame(WebSocketFrame)
        /// 以正常关闭码关闭
        case close
    }

    typealias Reply = @Sendable (WebSocketFrame) -> [Event]

    private let lock = NSLock()
    private let reply: Reply
    private let connectError: Error?
    private let connectHangs: Bool
    private var _requests: [WebSocketRequest] = []
    private var _connections: [MockWebSocketConnection] = []
    private var _connectTimes: [Date] = []

    init(connectError: Error? = nil, connectHangs: Bool = false, reply: @escaping Reply = { _ in [] }) {
        self.connectError = connectError
        self.connectHangs = connectHangs
        self.reply = reply
    }

    var requests: [WebSocketRequest] { lock.withLock { _requests } }
    var connections: [MockWebSocketConnection] { lock.withLock { _connections } }
    var connectTimes: [Date] { lock.withLock { _connectTimes } }

    func connect(_ request: WebSocketRequest) async throws -> any WebSocketConnection {
        lock.withLock {
            _requests.append(request)
            _connectTimes.append(Date())
        }
        if let connectError { throw connectError }
        if connectHangs { try await Task.sleep(for: .seconds(3600)) }
        let connection = MockWebSocketConnection(reply: reply)
        lock.withLock { _connections.append(connection) }
        return connection
    }
}

final class MockWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: MockWebSocket.Reply
    private var inbox: [MockWebSocket.Event] = []
    private var waiter: CheckedContinuation<WebSocketFrame?, Error>?
    private var closed = false
    private var _sent: [WebSocketFrame] = []

    init(reply: @escaping MockWebSocket.Reply) { self.reply = reply }

    var sent: [WebSocketFrame] { lock.withLock { _sent } }
    var isClosed: Bool { lock.withLock { closed } }

    func send(_ frame: WebSocketFrame) async throws {
        try lock.withLock {
            if closed { throw WebSocketError.connectionLost("已关闭") }
            _sent.append(frame)
        }
        let events = reply(frame)
        lock.withLock { inbox.append(contentsOf: events) }
        drain()
    }

    func receive() async throws -> WebSocketFrame? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSocketFrame?, Error>) in
                let isClosed = lock.withLock {
                    if !closed { waiter = continuation }
                    return closed
                }
                if isClosed {
                    continuation.resume(throwing: WebSocketError.connectionLost("已关闭"))
                } else {
                    drain()
                }
            }
        } onCancel: {
            close()
        }
    }

    private func drain() {
        let next: (CheckedContinuation<WebSocketFrame?, Error>, MockWebSocket.Event)? = lock.withLock {
            guard let waiter, !inbox.isEmpty else { return nil }
            self.waiter = nil
            return (waiter, inbox.removeFirst())
        }
        guard let next else { return }
        let (continuation, event) = next
        switch event {
        case .frame(let frame): continuation.resume(returning: frame)
        case .close: continuation.resume(returning: nil)
        }
    }

    func close() {
        let pending = lock.withLock {
            closed = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(throwing: WebSocketError.connectionLost("已关闭"))
    }
}

private let mp3Head = Data([0xFF, 0xFB, 0x90])

/// 规格文档中的示例
private let specLib = """
function makeSession(text, speed) {
  return { url: "wss://speech.example.com/tts", headers: {"Authorization": "Bearer token"},
    send: [JSON.stringify({text: text, speed: speed})], onMessage: handleFrame,
    connectTimeout: 12000, receiveTimeout: 30000, maxAudioBytes: 16777216, contentType: "audio/mpeg" };
}
function handleFrame(message, state) {
  if (message.type === "text") { var v = JSON.parse(message.text); if (v.error) return {error: v.error}; if (v.done) return {done: true}; return v.audio ? {audio: v.audio} : null; }
  var headerLength = message.uint16BE(0);
  return {audio: message.base64(2 + headerLength, -1)};
}
"""

private func text(_ s: String) -> MockWebSocket.Event { .frame(.text(s)) }
private func binary(_ d: Data) -> MockWebSocket.Event { .frame(.binary(d)) }

@Suite("朗读源 java.webSocket")
struct WebSocketTTSTests {
    let http = MockTransport()

    func engine(_ id: Int64, _ ws: MockWebSocket, url: String = "@js:java.webSocket(makeSession(speakText, speakSpeed))",
                lib: String = specLib, retryCount: Int = 0, configure: (inout HttpTTS) -> Void = { _ in }) -> HttpTTSEngine {
        var tts = HttpTTS(id: id, name: "WebSocket 朗读", url: url)
        tts.jsLib = lib
        configure(&tts)
        let env = SourceEnvironment(http: http, webSocket: ws, store: MemoryKeyValueStore(), deviceID: "test-device")
        return HttpTTSEngine(tts: tts, environment: env, retryCount: retryCount, retryDelay: 0.01)
    }

    /// 只改示例会话的部分字段
    func session(_ overrides: String, handler: String = "handleFrame") -> String {
        specLib + "\nfunction custom(text, speed) { var c = makeSession(text, speed); c.onMessage = \(handler); "
            + "var o = \(overrides); for (var k in o) c[k] = o[k]; return c; }"
    }

    let customURL = "@js:java.webSocket(custom(speakText, speakSpeed))"

    @Test func 文本帧与带长度头的二进制帧拼接() async throws {
        let ws = MockWebSocket { frame in
            guard case .text = frame else { return [] }
            var framed = Data([0x00, 0x04])
            framed.append(Data("meta".utf8))
            framed.append(mp3Head)
            return [text(#"{"audio":"SUQz"}"#), text(#"{"status":"ok"}"#), binary(framed), text(#"{"done":true}"#),
                    text(#"{"audio":"AAAA"}"#)]
        }
        let audio = try await engine(301, ws).synthesize("你好", speed: 12)
        #expect(audio.data == Data("ID3".utf8) + mp3Head)
        #expect(audio.format == .mp3 && audio.contentType == "audio/mpeg")

        let request = try #require(ws.requests.first)
        #expect(request.url == "wss://speech.example.com/tts")
        #expect(request.headers["Authorization"] == "Bearer token" && request.headers["User-Agent"] != nil)
        #expect(request.timeout == 12)
        let connection = try #require(ws.connections.first)
        guard case .text(let first)? = connection.sent.first, connection.sent.count == 1 else {
            Issue.record("初始帧不对：\(connection.sent)")
            return
        }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(json["text"] as? String == "你好" && (json["speed"] as? NSNumber)?.intValue == 12)
        #expect(connection.isClosed)
        #expect(http.requests.isEmpty)
    }

    @Test func 后续帧_state传递与message读取() async throws {
        let lib = #"""
        function open(text) {
          return { url: "ws://local.test/s", send: ["hello", {type: "binary", data: "AQID"}], onMessage: step, contentType: "audio/wav" };
        }
        function step(message, state) {
          if (message.text === "ready") {
            if (typeof state !== "object" || state === null || Object.keys(state).length !== 0) return {error: "初始 state 应为空对象"};
            return {send: "next", state: {n: 1}};
          }
          if (message.text === "ping") {
            return {send: ["pong", {type: "binary", data: java.base64Encode("hi")}], state: {n: state.n + 1}};
          }
          if (message.type === "binary") {
            if (message.count !== 10 || message.text != null || message.byteAt(0) !== 0 || message.uint16BE(0) !== 5
                || message.utf8(2, 5) !== "hello" || message.base64(2, 2) !== "aGU=") return {error: "二进制读取错误"};
            return {audio: message.base64(7, -1)};
          }
          if (message.text === "end") return state.n === 2 ? {done: true} : {error: "state 未传递：" + JSON.stringify(state)};
          return {error: "未知帧：" + message.text};
        }
        """#
        let ws = MockWebSocket { frame in
            switch frame {
            case .binary(let data) where data == Data([1, 2, 3]): return [text("ready")]
            case .text("next"): return [text("ping")]
            case .binary(let data) where data == Data("hi".utf8):
                return [binary(Data([0x00, 0x05]) + Data("hello".utf8) + Data("RIF".utf8)), text("end")]
            default: return []
            }
        }
        let audio = try await engine(302, ws, url: "@js:java.webSocket(open(speakText))", lib: lib).synthesize("一")
        #expect(audio.data == Data("RIF".utf8) && audio.contentType == "audio/wav" && audio.format == .wav)
        let sent = try #require(ws.connections.first).sent
        #expect(sent == [.text("hello"), .binary(Data([1, 2, 3])), .text("next"), .text("pong"), .binary(Data("hi".utf8))])
    }

    @Test func onMessage返回error时报错且不重试() async throws {
        let ws = MockWebSocket { _ in [text(#"{"error":"额度已用完"}"#)] }
        await #expect(throws: TTSError.server("额度已用完")) {
            try await engine(303, ws, retryCount: 2).synthesize("一")
        }
        #expect(ws.requests.count == 1)
        #expect(ws.connections.allSatisfy { $0.isClosed })
        #expect(TTSError.server("额度已用完").localizedDescription == "朗读服务返回错误：额度已用完")
    }

    @Test func 单帧超时与连接超时() async throws {
        let silent = MockWebSocket()
        let started = Date()
        await #expect(throws: WebSocketError.timeout(200)) {
            try await engine(304, silent, url: customURL, lib: session("{receiveTimeout: 200}")).synthesize("一")
        }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(silent.connections.allSatisfy { $0.isClosed })
        #expect(WebSocketError.timeout(200).localizedDescription == "朗读服务 0.2 秒内没有响应")

        let hanging = MockWebSocket(connectHangs: true)
        await #expect(throws: WebSocketError.connectTimeout(300)) {
            try await engine(305, hanging, url: customURL, lib: session("{connectTimeout: 300}")).synthesize("一")
        }
        #expect(WebSocketError.connectTimeout(12000).localizedDescription == "连接朗读服务超时（12 秒）")
    }

    @Test func 超出maxAudioBytes() async throws {
        let ws = MockWebSocket { _ in [text(#"{"audio":"SUQz"}"#), text(#"{"audio":"SUQz"}"#), text(#"{"done":true}"#)] }
        await #expect(throws: WebSocketError.audioTooLarge(4)) {
            try await engine(306, ws, url: customURL, lib: session("{maxAudioBytes: 4}")).synthesize("一")
        }
        #expect(WebSocketError.audioTooLarge(16 << 20).localizedDescription == "朗读音频超过上限（16 MB）")

        let capped = MockWebSocket { _ in [text(#"{"audio":"SUQz"}"#), text(#"{"done":true}"#)] }
        _ = try await engine(307, capped, url: customURL, lib: session("{maxAudioBytes: 1e12}")).synthesize("一")
        #expect(capped.requests.first?.maximumMessageSize == (64 << 20) / 3 * 4 + (1 << 20))
    }

    @Test func 参数错误() async throws {
        let ws = MockWebSocket()
        let cases: [(String, String)] = [
            (#"@js:java.webSocket("wss://a.test")"#, "java.webSocket 参数必须是对象"),
            ("@js:java.webSocket()", "java.webSocket 参数必须是对象"),
            ("@js:java.webSocket([1])", "java.webSocket 参数必须是对象"),
            ("@js:java.webSocket(function(){})", "java.webSocket 参数必须是对象"),
            (#"@js:java.webSocket({send: [], onMessage: handleFrame})"#, "java.webSocket 缺少 url"),
            (#"@js:java.webSocket({url: "https://a.test", send: [], onMessage: handleFrame})"#,
             "java.webSocket 的 url 必须以 ws:// 或 wss:// 开头：https://a.test"),
            (#"@js:java.webSocket({url: "wss://a.test", onMessage: handleFrame})"#, "java.webSocket 缺少 send"),
            (#"@js:java.webSocket({url: "wss://a.test", send: []})"#, "java.webSocket 缺少 onMessage"),
            (#"@js:java.webSocket({url: "wss://a.test", send: [{type: "binary", data: "**"}], onMessage: handleFrame})"#,
             "java.webSocket 的 send 中二进制帧的 data 不是有效的 Base64"),
            (#"@js:java.webSocket({url: "wss://a.test", send: [3], onMessage: handleFrame})"#, "java.webSocket 的 send 中有无效的帧：3"),
        ]
        for (index, (url, message)) in cases.enumerated() {
            await #expect(throws: WebSocketError.invalidConfig(message)) {
                try await engine(310 + Int64(index), ws, url: url).synthesize("一")
            }
        }
        #expect(ws.requests.isEmpty && http.requests.isEmpty)

        // 书源中调用时以 JS 异常抛出，可被脚本捕获
        let env = SourceEnvironment(http: http, webSocket: ws, store: MemoryKeyValueStore(), deviceID: "test-device")
        let caught = try makeSession(makeSource(minimalSourceJSON), env: env)
            .evalSourceJS("try { java.webSocket(1); 'no' } catch (e) { String(e) }")
        #expect((caught as? String)?.contains("java.webSocket 参数必须是对象") == true)
    }

    @Test func 取消时立即断开() async throws {
        let ws = MockWebSocket()
        let tts = engine(320, ws)
        let task = Task { try await tts.synthesize("一") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(ws.connections.count == 1 && ws.connections.allSatisfy { $0.isClosed })

        let hanging = MockWebSocket(connectHangs: true)
        let connecting = Task { [tts = engine(321, hanging)] in try await tts.synthesize("一") }
        try await Task.sleep(for: .milliseconds(300))
        connecting.cancel()
        await #expect(throws: CancellationError.self) { try await connecting.value }
    }

    @Test func 连接失败() async throws {
        let refused = MockWebSocket(connectError: WebSocketError.handshake(status: 401))
        await #expect(throws: WebSocketError.handshake(status: 401)) {
            try await engine(322, refused, retryCount: 2).synthesize("一")
        }
        #expect(refused.requests.count == 1)
        #expect(WebSocketError.handshake(status: 401).localizedDescription == "朗读服务拒绝了连接（HTTP 401）")

        let down = MockWebSocket(connectError: WebSocketError.connectFailed("无法连接服务器"))
        await #expect(throws: WebSocketError.connectFailed("无法连接服务器")) {
            try await engine(323, down, retryCount: 1).synthesize("一")
        }
        #expect(down.requests.count == 2)
    }

    @Test func onMessage可以是表达式字符串() async throws {
        let ws = MockWebSocket { _ in [text("SUQz")] }
        let expression = #""message.type == 'text' ? {audio: message.text, done: true} : null""#
        #expect(try await engine(324, ws, url: customURL, lib: session("{}", handler: expression)).synthesize("一").data == Data("ID3".utf8))

        let body = #""if (message.text) return {audio: message.text, done: true};""#
        #expect(try await engine(325, ws, url: customURL, lib: session("{}", handler: body)).synthesize("一").data == Data("ID3".utf8))

        let named = MockWebSocket { _ in [text(#"{"audio":"SUQz"}"#), text(#"{"done":true}"#)] }
        #expect(try await engine(326, named, url: customURL, lib: session("{}", handler: "'handleFrame'")).synthesize("一").data
            == Data("ID3".utf8))

        do {
            _ = try await engine(327, ws, url: customURL, lib: session("{}", handler: "function () { throw new Error('坏帧') }"))
                .synthesize("一")
            Issue.record("onMessage 抛出异常时应报错")
        } catch WebSocketError.script(let message) {
            #expect(message.contains("坏帧"))
        }
    }

    @Test func 对端正常关闭视为结束() async throws {
        let ws = MockWebSocket { _ in [text(#"{"audio":"SUQz"}"#), .close] }
        #expect(try await engine(328, ws).synthesize("一").data == Data("ID3".utf8))

        let empty = MockWebSocket { _ in [.close] }
        await #expect(throws: TTSError.emptyAudio) { try await engine(329, empty).synthesize("一") }
    }

    @Test func concurrentRate作用于整次会话() async throws {
        let ws = MockWebSocket { _ in [text(#"{"audio":"SUQz"}"#), text(#"{"done":true}"#)] }
        let tts = engine(330, ws) { $0.concurrentRate = "300" }
        try await withThrowingTaskGroup(of: TTSAudio.self) { group in
            for word in ["一", "二", "三"] { group.addTask { try await tts.synthesize(word) } }
            try await group.waitForAll()
        }
        let times = ws.connectTimes.sorted()
        #expect(times.count == 3)
        #expect(zip(times.dropFirst(), times).allSatisfy { $0.timeIntervalSince($1) >= 0.27 })
    }
}
