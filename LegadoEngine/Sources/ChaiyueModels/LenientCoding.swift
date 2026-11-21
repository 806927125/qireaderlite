import Foundation

/// 动态 key，用于读取/写入模型里未声明的字段。
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    public init?(stringValue: String) {
        self.init(stringValue)
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// 宽松解码：书源/规则 JSON 来自不同版本的 Legado 与各类第三方工具，
/// 同一字段可能是字符串、数字、布尔，子规则也可能被写成 JSON 字符串。
public extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        guard contains(key), let value = try? decode(JSONValue.self, forKey: key) else { return nil }
        return value.stringValue
    }

    func lenientInt(_ key: Key) -> Int? {
        guard let value = lenientInt64(key) else { return nil }
        return Int(clamping: value)
    }

    func lenientInt64(_ key: Key) -> Int64? {
        guard contains(key), let value = try? decode(JSONValue.self, forKey: key) else { return nil }
        switch value {
        case .number(let n):
            guard n.isFinite else { return nil }
            return Int64(max(min(n, Double(Int64.max)), Double(Int64.min)))
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if let i = Int64(trimmed) { return i }
            if let d = Double(trimmed), d.isFinite { return Int64(d) }
            return nil
        case .bool(let b):
            return b ? 1 : 0
        default:
            return nil
        }
    }

    func lenientBool(_ key: Key) -> Bool? {
        guard contains(key), let value = try? decode(JSONValue.self, forKey: key) else { return nil }
        switch value {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off", "": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// 读取一个子对象：既接受 JSON 对象，也接受内容为 JSON 对象的字符串。
    func lenientObject<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard contains(key) else { return nil }
        if let obj = try? decode(T.self, forKey: key) {
            return obj
        }
        guard let text = lenientString(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("{"),
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 收集未在 `known` 中声明的字段。
    func unknownFields(excluding known: Set<String>) -> [String: JSONValue] where Key == AnyCodingKey {
        var extras: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }
        return extras
    }
}

public extension KeyedEncodingContainer where Key == AnyCodingKey {
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, _ key: String) throws {
        if let value {
            try encode(value, forKey: AnyCodingKey(key))
        }
    }

    mutating func encode<T: Encodable>(_ value: T, _ key: String) throws {
        try encode(value, forKey: AnyCodingKey(key))
    }

    mutating func encodeExtras(_ extras: [String: JSONValue]) throws {
        for (key, value) in extras {
            try encode(value, forKey: AnyCodingKey(key))
        }
    }
}

public extension KeyedDecodingContainer where Key == AnyCodingKey {
    func string(_ key: String) -> String? { lenientString(AnyCodingKey(key)) }
    func int(_ key: String) -> Int? { lenientInt(AnyCodingKey(key)) }
    func int64(_ key: String) -> Int64? { lenientInt64(AnyCodingKey(key)) }
    func bool(_ key: String) -> Bool? { lenientBool(AnyCodingKey(key)) }
    func object<T: Decodable>(_ type: T.Type, _ key: String) -> T? { lenientObject(type, AnyCodingKey(key)) }
}
