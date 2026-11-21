import Foundation

/// 发现分类（UI 中称为「书签」）
public struct ExploreKind: Hashable, Sendable, Identifiable {
    public var title: String
    public var url: String?
    /// 新版 Legado 的交互类型：url（默认）/ text / select / toggle / button
    public var type: String?
    /// select/toggle 的可选值
    public var chars: [String]?
    public var defaultValue: String?
    /// button 点击时执行的脚本
    public var action: String?
    public var style: Style?

    public var id: String { "\(title)\u{1}\(url ?? "")" }

    public init(title: String, url: String? = nil) {
        self.title = title
        self.url = url
    }

    /// 没有 url 的条目是分组标题
    public var isTitle: Bool { (url ?? "").isEmpty && (type ?? "url") == "url" }

    /// 弹性布局参数（Legado 使用 FlexboxLayout）
    public struct Style: Codable, Hashable, Sendable {
        public var layoutFlexGrow: Double = 0
        public var layoutFlexShrink: Double = 1
        public var layoutAlignSelf: String = "auto"
        public var layoutFlexBasisPercent: Double = -1
        public var layoutWrapBefore: Bool = false

        public init() {}

        enum CodingKeys: String, CodingKey {
            case layoutFlexGrow = "layout_flexGrow"
            case layoutFlexShrink = "layout_flexShrink"
            case layoutAlignSelf = "layout_alignSelf"
            case layoutFlexBasisPercent = "layout_flexBasisPercent"
            case layoutWrapBefore = "layout_wrapBefore"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            layoutFlexGrow = c.string("layout_flexGrow").flatMap { Double($0) } ?? 0
            layoutFlexShrink = c.string("layout_flexShrink").flatMap { Double($0) } ?? 1
            layoutAlignSelf = c.string("layout_alignSelf") ?? "auto"
            layoutFlexBasisPercent = c.string("layout_flexBasisPercent").flatMap { Double($0) } ?? -1
            layoutWrapBefore = c.bool("layout_wrapBefore") ?? false
        }
    }
}

extension ExploreKind: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(title: c.string("title") ?? "", url: c.string("url"))
        type = c.string("type")
        if let values = try? c.decode([JSONValue].self, forKey: AnyCodingKey("chars")) {
            chars = values.compactMap(\.stringValue)
        }
        defaultValue = c.string("default") ?? c.string("defaultValue")
        action = c.string("action")
        style = c.object(Style.self, "style")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(title, "title")
        try c.encodeIfPresent(url, "url")
        try c.encodeIfPresent(type, "type")
        try c.encodeIfPresent(chars, "chars")
        try c.encodeIfPresent(defaultValue, "default")
        try c.encodeIfPresent(action, "action")
        try c.encodeIfPresent(style, "style")
    }
}
