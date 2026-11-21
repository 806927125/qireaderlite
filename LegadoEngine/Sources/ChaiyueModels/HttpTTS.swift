import Foundation

/// 在线朗读源（HTTP TTS），格式与 Legado 一致
public struct HttpTTS: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var name: String = ""
    /// 请求地址，支持 `{{speakText}}`、`{{speakSpeed}}` 等模板变量与 URL 选项
    public var url: String = ""
    /// 期望的响应 Content-Type（正则），不匹配时视为错误
    public var contentType: String?
    public var concurrentRate: String? = "0"
    public var loginUrl: String?
    public var loginUi: String?
    public var header: String?
    public var jsLib: String?
    public var enabledCookieJar: Bool = false
    public var loginCheckJs: String?
    public var lastUpdateTime: Int64 = 0
    public var enabled: Bool = true

    public init(id: Int64 = Int64(Date().timeIntervalSince1970 * 1000), name: String = "", url: String = "") {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// 朗读语速 `speakSpeed`，与 Legado 一致：界面语速 0…45 加 5，正常语速为 10，对应系统朗读的 1 倍速
public extension HttpTTS {
    static let defaultSpeakSpeed = 10
    static let speakSpeedRange = 5...50

    /// 由 `AVSpeechUtterance.rate`（0…1，正常 0.5）换算，0.5 → 10
    static func speakSpeed(fromSpeechRate rate: Float) -> Int {
        let value = Int((Double(rate) / 0.5 * Double(defaultSpeakSpeed)).rounded())
        return min(max(value, speakSpeedRange.lowerBound), speakSpeedRange.upperBound)
    }

    /// 换算为 `AVSpeechUtterance.rate`，10 → 0.5
    static func speechRate(fromSpeakSpeed speed: Int) -> Float {
        min(max(Float(speed) / Float(defaultSpeakSpeed) * 0.5, 0), 1)
    }
}

extension HttpTTS: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let id = c.int64("id") ?? c.int64("numericId") ?? Int64(Date().timeIntervalSince1970 * 1000)
        self.init(id: id, name: c.string("name") ?? "", url: c.string("url") ?? "")
        contentType = c.string("contentType")
        concurrentRate = c.string("concurrentRate") ?? "0"
        loginUrl = c.string("loginUrl")
        loginUi = c.string("loginUi")
        header = c.string("header")
        jsLib = c.string("jsLib")
        enabledCookieJar = c.bool("enabledCookieJar") ?? false
        loginCheckJs = c.string("loginCheckJs")
        lastUpdateTime = c.int64("lastUpdateTime") ?? 0
        enabled = c.bool("enabled") ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encode(url, "url")
        try c.encodeIfPresent(contentType, "contentType")
        try c.encodeIfPresent(concurrentRate, "concurrentRate")
        try c.encodeIfPresent(loginUrl, "loginUrl")
        try c.encodeIfPresent(loginUi, "loginUi")
        try c.encodeIfPresent(header, "header")
        try c.encodeIfPresent(jsLib, "jsLib")
        try c.encode(enabledCookieJar, "enabledCookieJar")
        try c.encodeIfPresent(loginCheckJs, "loginCheckJs")
        try c.encode(lastUpdateTime, "lastUpdateTime")
        try c.encode(enabled, "enabled")
    }
}
