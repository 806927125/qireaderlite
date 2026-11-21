import Foundation

public enum SourceImportError: Error, Equatable, Sendable {
    case notJSON
    case empty
}

/// 单条解码失败时返回 nil，避免一条坏数据导致整批导入失败
public struct Failable<T: Decodable>: Decodable {
    public let value: T?

    public init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public enum SourceImport {
    /// 解析书源 JSON：支持数组或单个对象
    public static func bookSources(from data: Data) throws -> [BookSource] {
        try decodeList(BookSource.self, from: data)
    }

    public static func replaceRules(from data: Data) throws -> [ReplaceRule] {
        try decodeList(ReplaceRule.self, from: data)
    }

    public static func httpTTS(from data: Data) throws -> [HttpTTS] {
        try decodeList(HttpTTS.self, from: data)
    }

    public static func decodeList<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        let payload = stripBOM(data)
        guard let first = payload.first(where: { !isWhitespace($0) }) else {
            throw SourceImportError.empty
        }
        let decoder = JSONDecoder()
        switch first {
        case UInt8(ascii: "["):
            let items = try decoder.decode([Failable<T>].self, from: payload)
            return items.compactMap(\.value)
        case UInt8(ascii: "{"):
            return [try decoder.decode(T.self, from: payload)]
        default:
            throw SourceImportError.notJSON
        }
    }

    /// 导出为 Legado 兼容的 JSON 数组
    public static func export<T: Encodable>(_ items: [T], pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return try encoder.encode(items)
    }

    private static func stripBOM(_ data: Data) -> Data {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return data.dropFirst(3)
        }
        return data
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}
