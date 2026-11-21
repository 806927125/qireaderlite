import Foundation

/// 由若干可选字符串字段组成的规则对象（搜索/发现/详情/目录/正文/段评规则）。
/// 统一走宽松编解码，并保留未识别字段。
public protocol StringFieldsRule: Codable, Hashable, Sendable {
    init()
    static var stringFields: [(key: String, path: WritableKeyPath<Self, String?>)] { get }
    var extras: [String: JSONValue] { get set }
}

public extension StringFieldsRule {
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var known = Set<String>()
        for field in Self.stringFields {
            known.insert(field.key)
            self[keyPath: field.path] = container.string(field.key)
        }
        extras = container.unknownFields(excluding: known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeExtras(extras)
        for field in Self.stringFields {
            try container.encodeIfPresent(self[keyPath: field.path], field.key)
        }
    }

    /// 所有字段都为空时视为未配置。
    var isEmpty: Bool {
        Self.stringFields.allSatisfy { (self[keyPath: $0.path] ?? "").isEmpty }
    }
}

/// 搜索规则
public struct SearchRule: StringFieldsRule {
    public var checkKeyWord: String?
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?
    public var extras: [String: JSONValue] = [:]

    public init() {}

    public static var stringFields: [(key: String, path: WritableKeyPath<SearchRule, String?>)] {
        [
            ("checkKeyWord", \.checkKeyWord), ("bookList", \.bookList), ("name", \.name),
            ("author", \.author), ("intro", \.intro), ("kind", \.kind),
            ("lastChapter", \.lastChapter), ("updateTime", \.updateTime), ("bookUrl", \.bookUrl),
            ("coverUrl", \.coverUrl), ("wordCount", \.wordCount),
        ]
    }
}

/// 发现规则（字段与搜索规则一致，没有 checkKeyWord）
public struct ExploreRule: StringFieldsRule {
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?
    public var extras: [String: JSONValue] = [:]

    public init() {}

    public static var stringFields: [(key: String, path: WritableKeyPath<ExploreRule, String?>)] {
        [
            ("bookList", \.bookList), ("name", \.name), ("author", \.author), ("intro", \.intro),
            ("kind", \.kind), ("lastChapter", \.lastChapter), ("updateTime", \.updateTime),
            ("bookUrl", \.bookUrl), ("coverUrl", \.coverUrl), ("wordCount", \.wordCount),
        ]
    }
}

/// 书籍详情规则
public struct BookInfoRule: StringFieldsRule {
    public var initRule: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var coverUrl: String?
    public var tocUrl: String?
    public var wordCount: String?
    public var canReName: String?
    public var downloadUrls: String?
    public var extras: [String: JSONValue] = [:]

    public init() {}

    public static var stringFields: [(key: String, path: WritableKeyPath<BookInfoRule, String?>)] {
        [
            ("init", \.initRule), ("name", \.name), ("author", \.author), ("intro", \.intro),
            ("kind", \.kind), ("lastChapter", \.lastChapter), ("updateTime", \.updateTime),
            ("coverUrl", \.coverUrl), ("tocUrl", \.tocUrl), ("wordCount", \.wordCount),
            ("canReName", \.canReName), ("downloadUrls", \.downloadUrls),
        ]
    }
}

/// 目录规则
public struct TocRule: StringFieldsRule {
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
    public var extras: [String: JSONValue] = [:]

    public init() {}

    public static var stringFields: [(key: String, path: WritableKeyPath<TocRule, String?>)] {
        [
            ("preUpdateJs", \.preUpdateJs), ("chapterList", \.chapterList), ("chapterName", \.chapterName),
            ("chapterUrl", \.chapterUrl), ("formatJs", \.formatJs), ("isVolume", \.isVolume),
            ("isVip", \.isVip), ("isPay", \.isPay), ("updateTime", \.updateTime),
            ("nextTocUrl", \.nextTocUrl),
        ]
    }
}

/// 正文规则
public struct ContentRule: StringFieldsRule {
    public var content: String?
    public var title: String?
    public var subContent: String?
    public var nextContentUrl: String?
    public var webJs: String?
    public var sourceRegex: String?
    public var replaceRegex: String?
    public var imageStyle: String?
    public var imageDecode: String?
    public var payAction: String?
    public var callBackJs: String?
    public var extras: [String: JSONValue] = [:]

    public init() {}

    public static var stringFields: [(key: String, path: WritableKeyPath<ContentRule, String?>)] {
        [
            ("content", \.content), ("title", \.title), ("subContent", \.subContent),
            ("nextContentUrl", \.nextContentUrl), ("webJs", \.webJs), ("sourceRegex", \.sourceRegex),
            ("replaceRegex", \.replaceRegex), ("imageStyle", \.imageStyle), ("imageDecode", \.imageDecode),
            ("payAction", \.payAction), ("callBackJs", \.callBackJs),
        ]
    }
}

/// 段评规则
public struct ReviewRule: StringFieldsRule {
    public var reviewUrl: String?
    public var avatarRule: String?
    public var contentRule: String?
    public var postTimeRule: String?
    public var reviewQuoteUrl: String?
    public var voteUpUrl: String?
    public var voteDownUrl: String?
    public var postReviewUrl: String?
    public var postQuoteUrl: String?
    public var deleteUrl: String?
    public var extras: [String: JSONValue] = [:]

    public init() {}

    public static var stringFields: [(key: String, path: WritableKeyPath<ReviewRule, String?>)] {
        [
            ("reviewUrl", \.reviewUrl), ("avatarRule", \.avatarRule), ("contentRule", \.contentRule),
            ("postTimeRule", \.postTimeRule), ("reviewQuoteUrl", \.reviewQuoteUrl),
            ("voteUpUrl", \.voteUpUrl), ("voteDownUrl", \.voteDownUrl),
            ("postReviewUrl", \.postReviewUrl), ("postQuoteUrl", \.postQuoteUrl),
            ("deleteUrl", \.deleteUrl),
        ]
    }
}
