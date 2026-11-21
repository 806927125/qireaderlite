import Foundation
import ChaiyueModels

/// 合成得到的一段音频
public struct TTSAudio: Sendable, Hashable {
    public enum Format: String, Sendable {
        case mp3, wav, aac, m4a, flac, caf, ogg, webm, unknown

        /// `AVAudioPlayer` 能否直接播放（Ogg、WebM 需要另行解码）
        public var isNativelyPlayable: Bool {
            switch self {
            case .mp3, .wav, .aac, .m4a, .flac, .caf: true
            case .ogg, .webm, .unknown: false
            }
        }

        /// 写临时文件时使用的扩展名
        public var fileExtension: String { self == .unknown ? "bin" : rawValue }
    }

    public let data: Data
    /// 响应的 Content-Type 原文
    public let contentType: String?
    public let format: Format

    public init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType
        format = Self.detect(data, contentType: contentType)
    }

    /// 先按文件头识别，识别不了再看 Content-Type
    static func detect(_ data: Data, contentType: String?) -> Format {
        let b = [UInt8](data.prefix(12))
        func ascii(_ range: Range<Int>) -> String? {
            range.upperBound <= b.count ? String(bytes: b[range], encoding: .ascii) : nil
        }
        if ascii(0..<3) == "ID3" { return .mp3 }
        if b.count >= 2, b[0] == 0xFF {
            if b[1] & 0xF6 == 0xF0 { return .aac }
            if b[1] & 0xE0 == 0xE0 { return .mp3 }
        }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return .wav }
        if ascii(0..<4) == "OggS" { return .ogg }
        if ascii(0..<4) == "fLaC" { return .flac }
        if ascii(0..<4) == "caff" { return .caf }
        if ascii(4..<8) == "ftyp" { return .m4a }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return .webm }
        let mime = HttpTTSEngine.mimeType(contentType)
        switch mime {
        case "audio/mpeg", "audio/mp3", "audio/mpeg3": return .mp3
        case "audio/wav", "audio/x-wav", "audio/wave": return .wav
        case "audio/aac", "audio/x-aac", "audio/aacp": return .aac
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return .m4a
        case "audio/flac", "audio/x-flac": return .flac
        case "audio/ogg", "audio/opus", "application/ogg": return .ogg
        case "audio/webm": return .webm
        default: return .unknown
        }
    }
}

public enum TTSError: LocalizedError, Equatable, Sendable {
    case emptyURL
    case emptyText
    /// 服务端返回了文字（JSON、HTML 等）而不是音频，附带服务端文字
    case server(String)
    /// Content-Type 与朗读源设置的 `contentType` 不匹配
    case unexpectedContentType(String, message: String)
    case http(status: Int, message: String)
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .emptyURL: "朗读源地址为空"
        case .emptyText: "没有可朗读的文字"
        case .server(let message): "朗读服务返回错误：\(message)"
        case .unexpectedContentType(let type, let message):
            "朗读服务返回的不是音频（\(type)）" + (message.isEmpty ? "" : "：\(message)")
        case .http(let status, let message): "朗读服务请求失败（HTTP \(status)）" + (message.isEmpty ? "" : "：\(message)")
        case .emptyAudio: "朗读服务返回的音频为空"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .http(let status, _): status >= 500 || status == 429 || status == 408
        case .emptyAudio: true
        case .emptyURL, .emptyText, .server, .unexpectedContentType: false
        }
    }
}

/// 在线朗读（Legado HttpTTS）。请求地址支持 `{{speakText}}`、`{{speakSpeed}}` 等 JS 模板、`@js:`/`<js>` 规则与
/// `,{"method":"POST","body":…}` 选项，使用朗读源的 header、登录头、Cookie 与 concurrentRate 限流。
/// url 规则调用 `java.webSocket(config)` 得到音频时直接返回该音频，不再发 HTTP 请求（也不执行 loginCheckJs）
public final class HttpTTSEngine: Sendable {
    public let tts: HttpTTS
    public let environment: SourceEnvironment
    /// 网络错误、5xx/429/408、空音频的重试次数；服务端返回文字或类型不匹配不重试
    public let retryCount: Int
    public let retryDelay: TimeInterval

    public init(tts: HttpTTS, environment: SourceEnvironment, retryCount: Int = 2, retryDelay: TimeInterval = 0.5) {
        self.tts = tts
        self.environment = environment
        self.retryCount = retryCount
        self.retryDelay = retryDelay
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (RuleSession) throws -> T) async throws -> T {
        try await RuleSession.run(SourceDescriptor(tts), env: environment, body)
    }

    /// 合成一句。`speed` 为 Legado 的 speakSpeed（见 `HttpTTS.speakSpeedRange`）。任务取消时抛出 `CancellationError`
    public func synthesize(_ text: String, speed: Int = HttpTTS.defaultSpeakSpeed) async throws -> TTSAudio {
        guard !tts.url.isBlank else { throw TTSError.emptyURL }
        guard !text.isBlank else { throw TTSError.emptyText }
        let tts = tts, retryCount = retryCount, retryDelay = retryDelay
        do {
            return try await run { session in
                var attempt = 0
                while true {
                    do {
                        return try Self.fetch(session: session, tts: tts, text: text, speed: speed)
                    } catch {
                        attempt += 1
                        guard attempt <= retryCount, Self.isRetryable(error), !session.isCancelled else { throw error }
                        session.env.log(session.source.key, "朗读第 \(attempt) 次重试：\(error)")
                        let deadline = Date().addingTimeInterval(retryDelay * Double(attempt))
                        while Date() < deadline {
                            try session.checkCancelled()
                            Thread.sleep(forTimeInterval: min(0.05, max(0, deadline.timeIntervalSinceNow)))
                        }
                    }
                }
            }
        } catch RuleError.cancelled {
            throw CancellationError()
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case let error as TTSError: error.isRetryable
        case let error as WebSocketError: error.isRetryable
        case RuleError.network: true
        default: false
        }
    }

    static func fetch(session: RuleSession, tts: HttpTTS, text: String, speed: Int) throws -> TTSAudio {
        session.webSocketAudio = nil
        session.webSocketError = nil
        let analyzeUrl: AnalyzeUrl
        do {
            analyzeUrl = try AnalyzeUrl(tts.url, speakText: text, speakSpeed: speed, session: session, ruleData: RuleData())
        } catch {
            throw session.webSocketError ?? error
        }
        if let audio = session.webSocketAudio { return audio }
        var res = try analyzeUrl.getResponse()
        if let checkJs = tts.loginCheckJs, !checkJs.isBlank {
            let wrapped = JSResponse(url: res.url, body: Charsets.decode(res.body, contentType: res.header("Content-Type")),
                                     status: res.statusCode, headers: res.headers, bodyData: res.body)
            if let returned = try analyzeUrl.evalJS(checkJs, result: wrapped) as? JSResponse, returned !== wrapped {
                res = HTTPResponse(url: returned.responseURL, statusCode: returned.status, headers: returned.responseHeaders,
                                   body: returned.bodyData ?? Data(returned.responseBody.utf8))
            }
        }
        return try validate(res, expected: tts.contentType)
    }

    /// 与 Legado 一致：JSON 与 text/* 视为服务端错误；设置了 contentType 时必须完整匹配（正则，忽略大小写）
    static func validate(_ res: HTTPResponse, expected: String?) throws -> TTSAudio {
        let contentType = res.header("Content-Type")
        let mime = mimeType(contentType)
        if res.statusCode >= 400 {
            throw TTSError.http(status: res.statusCode, message: message(res.body, contentType: contentType))
        }
        if mime == "application/json" || mime.hasPrefix("text/") {
            throw TTSError.server(message(res.body, contentType: contentType))
        }
        if let expected = expected?.trimmedWhitespace, !expected.isEmpty, !mime.isEmpty,
           !mime.matches("^(?:\(expected))$", options: .caseInsensitive) {
            throw TTSError.unexpectedContentType(contentType ?? mime, message: message(res.body, contentType: contentType))
        }
        guard !res.body.isEmpty else { throw TTSError.emptyAudio }
        let audio = TTSAudio(data: res.body, contentType: contentType)
        if mime.isEmpty, audio.format == .unknown, let first = res.body.first(where: { !" \r\n\t".utf8.contains($0) }),
           first == UInt8(ascii: "{") || first == UInt8(ascii: "[") || first == UInt8(ascii: "<") {
            throw TTSError.server(message(res.body, contentType: contentType))
        }
        return audio
    }

    static func mimeType(_ contentType: String?) -> String {
        (contentType ?? "").components(separatedBy: ";")[0].trimmedWhitespace.lowercased()
    }

    private static func message(_ body: Data, contentType: String?) -> String {
        let text = Charsets.decode(body.prefix(4096), contentType: contentType).trimmedWhitespace
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    // MARK: - 登录

    public var loginRows: [LoginRow] { WebBook.parseLoginRows(tts.loginUi) }

    public var savedLoginInfo: [String: String] {
        SourceState(key: String(tts.id), env: environment).loginInfo.flatMap { LenientJSON.stringMap($0) } ?? [:]
    }

    public var loginHeader: String? {
        SourceState(key: String(tts.id), env: environment).loginHeader
    }

    /// 登录界面的确认：保存表单并执行 `login()`；表单为空时清除登录信息
    public func login(formData: [String: String]) async throws {
        _ = try await run { session -> Bool in
            if formData.isEmpty {
                session.state.loginInfo = nil
                return true
            }
            session.state.loginInfo = LenientJSON.serialize(formData)
            try session.runLogin()
            return true
        }
    }

    /// 登录界面按钮。表单数据会先保存，再执行按钮脚本
    public func runLoginAction(_ action: String, formData: [String: String]) async throws {
        _ = try await run { session -> Bool in
            if !formData.isEmpty, let json = LenientJSON.serialize(formData) {
                session.state.loginInfo = json
            }
            try session.runLoginAction(action, formData: formData)
            return true
        }
    }
}
