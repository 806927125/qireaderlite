import Foundation
import ChaiyueModels
@testable import ChaiyueEngine
import Testing

private let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0xFF, 0xFB, 0x90])

private func audio(_ req: HTTPRequest, type: String = "audio/mpeg", data: Data = mp3) -> HTTPResponse {
    HTTPResponse(url: req.url, headers: ["Content-Type": type], body: data)
}

private func query(_ url: String) -> [String: String] {
    let items = URLComponents(string: url)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

/// 记录每个请求开始的时间
private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [Date] = []
    func mark() { lock.withLock { starts.append(Date()) } }
    var gaps: [TimeInterval] {
        let sorted = lock.withLock { starts.sorted() }
        return zip(sorted.dropFirst(), sorted).map { $0.timeIntervalSince($1) }
    }
    var count: Int { lock.withLock { starts.count } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var current: Int { lock.withLock { value } }
}

@Suite("在线朗读合成")
struct HttpTTSEngineTests {
    let transport = MockTransport()
    let env: SourceEnvironment

    init() {
        env = makeEnvironment(transport)
    }

    func engine(_ id: Int64, _ url: String, configure: (inout HttpTTS) -> Void = { _ in }, retryCount: Int = 2) -> HttpTTSEngine {
        var tts = HttpTTS(id: id, name: "测试朗读", url: url)
        configure(&tts)
        return HttpTTSEngine(tts: tts, environment: env, retryCount: retryCount, retryDelay: 0.01)
    }

    @Test func GET模板替换speakText与speakSpeed() async throws {
        transport.on("https://tts.test/speak") { audio($0) }
        let result = try await engine(101, "https://tts.test/speak?text={{speakText}}&speed={{speakSpeed}}&v={{1+1}}")
            .synthesize("你好，世界！", speed: 12)
        #expect(result.data == mp3 && result.format == .mp3 && result.contentType == "audio/mpeg")
        let request = try #require(transport.lastRequest)
        #expect(request.method == "GET")
        #expect(query(request.url) == ["text": "你好，世界！", "speed": "12", "v": "2"])
    }

    @Test func POST选项_请求头与登录头() async throws {
        transport.on("https://tts.test/post") { audio($0) }
        let tts = engine(102, #"https://tts.test/post,{"method":"POST","body":{"text":"{{speakText}}","rate":{{speakSpeed}}},"headers":{"X-Key":"k"}}"#) {
            $0.header = #"{"Authorization":"Bearer t"}"#
        }
        SourceState(key: "102", env: env).loginHeader = #"{"X-Login":"yes"}"#
        _ = try await tts.synthesize("第一句")
        let request = try #require(transport.lastRequest)
        #expect(request.method == "POST" && request.url == "https://tts.test/post")
        let body = try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["text"] as? String == "第一句" && (body["rate"] as? NSNumber)?.intValue == 10)
        #expect(request.headers["X-Key"] == "k" && request.headers["Authorization"] == "Bearer t")
        #expect(request.headers["X-Login"] == "yes")
        #expect(request.headers["Content-Type"]?.hasPrefix("application/json") == true)
    }

    @Test func JS规则与jsLib() async throws {
        transport.on("https://tts.test/js") { audio($0) }
        let js = engine(103, "@js:'https://tts.test/js?t=' + encodeURIComponent(speakText) + '&s=' + (speakSpeed * 2)")
        _ = try await js.synthesize("春眠不觉晓", speed: 10)
        #expect(query(try #require(transport.lastRequest).url) == ["t": "春眠不觉晓", "s": "20"])

        let lib = engine(104, "<js>'https://tts.test/js?sig=' + sign(speakText)</js>") {
            $0.jsLib = "function sign(t) { return 'S' + t.length }"
        }
        _ = try await lib.synthesize("四个汉字")
        #expect(query(try #require(transport.lastRequest).url) == ["sig": "S4"])
    }

    @Test func 返回文字或类型不匹配时抛出带服务端文字的错误() async throws {
        transport.on("https://tts.test/json") { req in
            HTTPResponse(url: req.url, headers: ["Content-Type": "application/json; charset=utf-8"],
                         body: Data(#"{"error":"额度已用完"}"#.utf8))
        }
        transport.on("https://tts.test/html") { req in
            HTTPResponse(url: req.url, headers: ["Content-Type": "text/html"], body: Data("<h1>维护中</h1>".utf8))
        }
        transport.on("https://tts.test/wav") { audio($0, type: "audio/wav") }
        transport.on("https://tts.test/untyped") { req in HTTPResponse(url: req.url, body: Data(#"{"code":1}"#.utf8)) }
        transport.on("https://tts.test/forbidden") { req in
            HTTPResponse(url: req.url, statusCode: 403, headers: ["Content-Type": "text/plain"], body: Data("密钥无效".utf8))
        }

        await #expect(throws: TTSError.server(#"{"error":"额度已用完"}"#)) {
            try await engine(105, "https://tts.test/json").synthesize("一")
        }
        await #expect(throws: TTSError.server("<h1>维护中</h1>")) {
            try await engine(106, "https://tts.test/html").synthesize("一")
        }
        do {
            _ = try await engine(107, "https://tts.test/wav") { $0.contentType = "audio/mpeg|audio/mp3" }.synthesize("一")
            Issue.record("类型不匹配应抛出错误")
        } catch TTSError.unexpectedContentType(let type, _) {
            #expect(type == "audio/wav")
        }
        let wav = try await engine(108, "https://tts.test/wav") { $0.contentType = "audio/.*" }.synthesize("一")
        #expect(wav.data == mp3)
        await #expect(throws: TTSError.server(#"{"code":1}"#)) {
            try await engine(109, "https://tts.test/untyped").synthesize("一")
        }
        await #expect(throws: TTSError.http(status: 403, message: "密钥无效")) {
            try await engine(110, "https://tts.test/forbidden").synthesize("一")
        }
        // 服务端明确返回的错误不重试
        #expect(transport.requests.count == 6)

        let error = TTSError.server(#"{"error":"额度已用完"}"#)
        #expect(error.localizedDescription == #"朗读服务返回错误：{"error":"额度已用完"}"#)
        await #expect(throws: TTSError.emptyText) { try await engine(111, "https://tts.test/json").synthesize(" \n") }
        await #expect(throws: TTSError.emptyURL) { try await engine(112, " ").synthesize("一") }
    }

    @Test func 失败重试() async throws {
        let counter = Counter()
        transport.on("https://tts.test/flaky") { req in
            counter.next() <= 2 ? HTTPResponse(url: req.url, statusCode: 503, body: Data()) : audio(req)
        }
        let result = try await engine(113, "https://tts.test/flaky").synthesize("一")
        #expect(result.data == mp3 && counter.current == 3)

        transport.on("https://tts.test/down") { req in HTTPResponse(url: req.url, statusCode: 500, body: Data("down".utf8)) }
        await #expect(throws: TTSError.http(status: 500, message: "down")) {
            try await engine(114, "https://tts.test/down", retryCount: 1).synthesize("一")
        }
        #expect(transport.requests.filter { $0.url.hasPrefix("https://tts.test/down") }.count == 2)
    }

    @Test func 重试等待中取消() async throws {
        transport.on("https://tts.test/busy") { req in HTTPResponse(url: req.url, statusCode: 503, body: Data()) }
        let tts = HttpTTSEngine(tts: HttpTTS(id: 115, url: "https://tts.test/busy"), environment: env, retryCount: 3, retryDelay: 10)
        let task = Task { try await tts.synthesize("一") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func concurrentRate限流() async throws {
        let interval = Timeline()
        transport.on("https://tts.test/interval") { req in interval.mark(); return audio(req) }
        let spaced = engine(116, "https://tts.test/interval?t={{speakText}}") { $0.concurrentRate = "300" }
        try await withThrowingTaskGroup(of: TTSAudio.self) { group in
            for text in ["一", "二", "三"] { group.addTask { try await spaced.synthesize(text) } }
            try await group.waitForAll()
        }
        #expect(interval.count == 3)
        #expect(interval.gaps.allSatisfy { $0 >= 0.27 })

        let window = Timeline()
        transport.on("https://tts.test/window") { req in window.mark(); return audio(req) }
        let windowed = engine(117, "https://tts.test/window?t={{speakText}}") { $0.concurrentRate = "2/600" }
        try await withThrowingTaskGroup(of: TTSAudio.self) { group in
            for text in ["一", "二", "三"] { group.addTask { try await windowed.synthesize(text) } }
            try await group.waitForAll()
        }
        let gaps = window.gaps
        #expect(gaps.count == 2 && gaps[0] < 0.45 && gaps[0] + gaps[1] >= 0.55)
    }

    @Test func loginCheckJs可检查并替换响应() async throws {
        let binary = Data([0xFF, 0xFB, 0x90, 0x00, 0x80, 0xFE])
        transport.on("https://tts.test/raw") { audio($0, data: binary) }
        let keep = engine(118, "https://tts.test/raw") {
            $0.loginCheckJs = "if (result.code() != 200 || result.header('Content-Type') != 'audio/mpeg') throw 'bad'; result"
        }
        #expect(try await keep.synthesize("一").data == binary)

        transport.on("https://tts.test/expired") { req in
            HTTPResponse(url: req.url, headers: ["Content-Type": "audio/mpeg", "X-Need-Login": "1"], body: Data())
        }
        transport.on("https://tts.test/fresh") { req in
            HTTPResponse(url: req.url, headers: ["Content-Type": "audio/mpeg"], body: Data("ID3fresh".utf8))
        }
        let relogin = engine(119, "https://tts.test/expired") {
            $0.loginCheckJs = "result.header('X-Need-Login') ? java.connect('https://tts.test/fresh') : result"
        }
        #expect(try await relogin.synthesize("一").data == Data("ID3fresh".utf8))
    }

    @Test func CookieJar保存并带上Cookie() async throws {
        let counter = Counter()
        transport.on("https://tts.test/cookie") { req in
            var res = audio(req)
            if counter.next() == 1 { res.setCookies = ["sid=abc"] }
            return res
        }
        let tts = engine(120, "https://tts.test/cookie") { $0.enabledCookieJar = true }
        _ = try await tts.synthesize("一")
        #expect(transport.lastRequest?.headers["Cookie"] == nil)
        _ = try await tts.synthesize("二")
        #expect(transport.lastRequest?.headers["Cookie"] == "sid=abc")
    }

    @Test func 识别音频格式() {
        func format(_ bytes: [UInt8], _ type: String? = nil) -> TTSAudio.Format {
            TTSAudio(data: Data(bytes), contentType: type).format
        }
        #expect(format(Array("ID3".utf8)) == .mp3)
        #expect(format([0xFF, 0xFB, 0x90]) == .mp3)
        #expect(format([0xFF, 0xF1, 0x50]) == .aac)
        #expect(format(Array("RIFF\0\0\0\0WAVE".utf8)) == .wav)
        #expect(format(Array("OggS".utf8)) == .ogg && !TTSAudio.Format.ogg.isNativelyPlayable)
        #expect(format(Array("\0\0\0\u{18}ftypM4A ".utf8)) == .m4a)
        #expect(format([0x1A, 0x45, 0xDF, 0xA3]) == .webm)
        #expect(format([1, 2, 3], "audio/mpeg; charset=x") == .mp3)
        #expect(format([1, 2, 3]) == .unknown)
        #expect(TTSAudio.Format.mp3.isNativelyPlayable && TTSAudio.Format.mp3.fileExtension == "mp3")
    }

    @Test func 语速换算() {
        #expect(HttpTTS.speakSpeed(fromSpeechRate: 0.5) == 10)
        #expect(HttpTTS.speakSpeed(fromSpeechRate: 0.1) == 5)
        #expect(HttpTTS.speakSpeed(fromSpeechRate: 0.9) == 18)
        #expect(HttpTTS.speakSpeed(fromSpeechRate: 1) == 20)
        #expect(HttpTTS.speechRate(fromSpeakSpeed: 10) == 0.5)
        #expect(HttpTTS.speechRate(fromSpeakSpeed: 50) == 1)
    }

    @Test func 解析Legado朗读源JSON() throws {
        let json = #"""
        [{"id":1700000000000,"name":"示例","url":"https://tts.test/a?t={{speakText}}","contentType":"audio/mpeg",
          "concurrentRate":"1000","header":"{\"Referer\":\"https://tts.test\"}","enabledCookieJar":true,
          "loginUrl":"","loginCheckJs":"","lastUpdateTime":"1700000000001","unknownField":{"x":1}}]
        """#
        let tts = try #require(SourceImport.httpTTS(from: Data(json.utf8)).first)
        #expect(tts.id == 1_700_000_000_000 && tts.name == "示例" && tts.contentType == "audio/mpeg")
        #expect(tts.concurrentRate == "1000" && tts.enabledCookieJar && tts.lastUpdateTime == 1_700_000_000_001)
        let roundTrip = try SourceImport.httpTTS(from: SourceImport.export([tts]))
        #expect(roundTrip == [tts])
    }
}
