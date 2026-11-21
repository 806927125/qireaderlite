import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// 任意 JSON 值。用于保留模型中未识别的字段，保证导入再导出时不丢数据。
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// 转成 Foundation 对象（`JSONSerialization` 可直接序列化）。
    public var foundationValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { return Int64(n) }
            return n
        case .bool(let b): return b
        case .object(let dict): return dict.mapValues { $0.foundationValue }
        case .array(let arr): return arr.map { $0.foundationValue }
        case .null: return NSNull()
        }
    }

    /// 从 Foundation 对象构造（`JSONSerialization` 的解析结果）。
    public init(foundation value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(foundation: $0) })
        case let arr as [Any]:
            self = .array(arr.map { JSONValue(foundation: $0) })
        default:
            self = .string(String(describing: value!))
        }
    }

    /// 以字符串形式读取：字符串原样返回，数字/布尔转文本，对象/数组序列化成 JSON 文本。
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { return String(Int64(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .object, .array: return jsonText
        case .null: return nil
        }
    }

    public var jsonText: String {
        let obj = foundationValue
        guard JSONSerialization.isValidJSONObject(obj) else {
            return stringValue ?? ""
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
