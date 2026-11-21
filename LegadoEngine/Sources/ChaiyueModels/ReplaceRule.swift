import Foundation

/// 替换净化规则
public struct ReplaceRule: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var name: String = ""
    public var group: String?
    public var pattern: String = ""
    public var replacement: String = ""
    /// 作用范围：书名或书源地址，多个用逗号/分号分隔；为空表示全部
    public var scope: String?
    public var scopeTitle: Bool = false
    public var scopeContent: Bool = true
    /// 排除范围，格式同 `scope`
    public var excludeScope: String?
    public var isEnabled: Bool = true
    public var isRegex: Bool = true
    public var timeoutMillisecond: Int64 = 3000
    public var order: Int = Int(Int32.min)

    public init(id: Int64 = Int64(Date().timeIntervalSince1970 * 1000), name: String = "", pattern: String = "", replacement: String = "") {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
    }

    /// 判断规则是否作用于指定书籍
    public func applies(toBookName name: String, origin: String) -> Bool {
        let includes = Self.splitScope(scope)
        if !includes.isEmpty, !includes.contains(where: { $0 == name || $0 == origin }) {
            return false
        }
        let excludes = Self.splitScope(excludeScope)
        return !excludes.contains(where: { $0 == name || $0 == origin })
    }

    static func splitScope(_ scope: String?) -> [String] {
        guard let scope else { return [] }
        return scope
            .components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

enum StableHash {
    static func fnv1a64(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
    }
}

extension ReplaceRule: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let fallbackId = Int64(Date().timeIntervalSince1970 * 1000)
        // 部分工具导出的 id 是 UUID 字符串，转成稳定的数字 id
        let id = c.int64("id") ?? c.string("id").map(StableHash.fnv1a64) ?? fallbackId
        self.init(id: id, name: c.string("name") ?? "", pattern: c.string("pattern") ?? "", replacement: c.string("replacement") ?? "")
        group = c.string("group")
        scope = c.string("scope")
        scopeTitle = c.bool("scopeTitle") ?? false
        scopeContent = c.bool("scopeContent") ?? true
        excludeScope = c.string("excludeScope")
        isEnabled = c.bool("isEnabled") ?? c.bool("enabled") ?? true
        isRegex = c.bool("isRegex") ?? true
        timeoutMillisecond = c.int64("timeoutMillisecond") ?? 3000
        order = c.int("order") ?? c.int("sortOrder") ?? Int(Int32.min)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encodeIfPresent(group, "group")
        try c.encode(pattern, "pattern")
        try c.encode(replacement, "replacement")
        try c.encodeIfPresent(scope, "scope")
        try c.encode(scopeTitle, "scopeTitle")
        try c.encode(scopeContent, "scopeContent")
        try c.encodeIfPresent(excludeScope, "excludeScope")
        try c.encode(isEnabled, "isEnabled")
        try c.encode(isRegex, "isRegex")
        try c.encode(timeoutMillisecond, "timeoutMillisecond")
        try c.encode(order, "order")
    }
}
