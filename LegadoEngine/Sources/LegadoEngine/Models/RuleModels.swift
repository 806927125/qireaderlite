import Foundation

/// Dynamic coding key for lenient rule decoding.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ s: String) { self.stringValue = s }
}

/// All rule models are plain string-valued bags, decoded leniently.
protocol StringRule: Codable, Hashable {
    init()
    static var ruleKeyPaths: [String: WritableKeyPath<Self, String?>] { get }
}

extension StringRule {
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: AnyCodingKey.self) else { return }
        for (name, kp) in Self.ruleKeyPaths {
            let key = AnyCodingKey(name)
            if c.contains(key), let v = c.lenientString(key) { self[keyPath: kp] = v }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (name, kp) in Self.ruleKeyPaths {
            if let v = self[keyPath: kp] { try c.encode(v, forKey: AnyCodingKey(name)) }
        }
    }
    /// First non-empty value among the given key paths' raw values (helper for rules with aliases).
    func value(_ name: String) -> String? {
        guard let kp = Self.ruleKeyPaths[name] else { return nil }
        let v = self[keyPath: kp]
        return (v?.isEmpty == false) ? v : nil
    }
}

public struct SearchRule: StringRule {
    public var checkKeyWord: String?
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var kind: String?
    public var wordCount: String?
    public var lastChapter: String?
    public var intro: String?
    public var coverUrl: String?
    public var bookUrl: String?
    public var updateTime: String?
    public init() {}
    static var ruleKeyPaths: [String: WritableKeyPath<SearchRule, String?>] {[
        "checkKeyWord": \.checkKeyWord, "bookList": \.bookList, "name": \.name,
        "author": \.author, "kind": \.kind, "wordCount": \.wordCount,
        "lastChapter": \.lastChapter, "intro": \.intro, "coverUrl": \.coverUrl,
        "bookUrl": \.bookUrl, "updateTime": \.updateTime,
    ]}
}

public struct ExploreRule: StringRule {
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var kind: String?
    public var wordCount: String?
    public var lastChapter: String?
    public var intro: String?
    public var coverUrl: String?
    public var bookUrl: String?
    public var updateTime: String?
    public init() {}
    static var ruleKeyPaths: [String: WritableKeyPath<ExploreRule, String?>] {[
        "bookList": \.bookList, "name": \.name, "author": \.author, "kind": \.kind,
        "wordCount": \.wordCount, "lastChapter": \.lastChapter, "intro": \.intro,
        "coverUrl": \.coverUrl, "bookUrl": \.bookUrl, "updateTime": \.updateTime,
    ]}
}

public struct BookInfoRule: StringRule {
    public var `init`: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var coverUrl: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var wordCount: String?
    public var tocUrl: String?
    public var canReName: String?
    public var downloadUrls: String?
    public init() {}
    static var ruleKeyPaths: [String: WritableKeyPath<BookInfoRule, String?>] {[
        "init": \.`init`, "name": \.name, "author": \.author, "intro": \.intro,
        "kind": \.kind, "coverUrl": \.coverUrl, "lastChapter": \.lastChapter,
        "updateTime": \.updateTime, "wordCount": \.wordCount, "tocUrl": \.tocUrl,
        "canReName": \.canReName, "downloadUrls": \.downloadUrls,
    ]}
}

public struct TocRule: StringRule {
    public var preUpdateJs: String?
    public var chapterList: String?
    public var chapterName: String?
    public var chapterUrl: String?
    public var formatJs: String?
    public var isVolume: String?
    public var isVip: String?
    public var isPay: String?
    public var updateTime: String?
    public var nextTocUrl: String?
    public init() {}
    static var ruleKeyPaths: [String: WritableKeyPath<TocRule, String?>] {[
        "preUpdateJs": \.preUpdateJs, "chapterList": \.chapterList, "chapterName": \.chapterName,
        "chapterUrl": \.chapterUrl, "formatJs": \.formatJs, "isVolume": \.isVolume,
        "isVip": \.isVip, "isPay": \.isPay, "updateTime": \.updateTime, "nextTocUrl": \.nextTocUrl,
    ]}
}

public struct ContentRule: StringRule {
    public var content: String?
    public var title: String?
    public var nextContentUrl: String?
    public var webJs: String?
    public var sourceRegex: String?
    public var replaceRegex: String?
    public var imageStyle: String?
    public var imageDecode: String?
    public var payAction: String?
    public init() {}
    static var ruleKeyPaths: [String: WritableKeyPath<ContentRule, String?>] {[
        "content": \.content, "title": \.title, "nextContentUrl": \.nextContentUrl,
        "webJs": \.webJs, "sourceRegex": \.sourceRegex, "replaceRegex": \.replaceRegex,
        "imageStyle": \.imageStyle, "imageDecode": \.imageDecode, "payAction": \.payAction,
    ]}
}