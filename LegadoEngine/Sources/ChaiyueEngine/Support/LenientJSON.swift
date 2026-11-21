import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 宽松 JSON 解析，兼容 Gson lenient 模式常见写法：
/// 单引号字符串、无引号 key、尾随逗号、注释、`=` 作为键值分隔符等。
/// 用于 URL 选项、`@put`、请求头、loginUi、exploreUrl 等书源字段。
enum LenientJSON {
    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let offset: Int
        var description: String { "JSON 解析失败(\(offset)): \(message)" }
    }

    static func parse(_ text: String) throws -> Any {
        let trimmed = text.trimmedWhitespace
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return obj
        }
        var parser = Parser(Array(trimmed.unicodeScalars))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        return value
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? parse(text)) as? [String: Any]
    }

    static func array(_ text: String) -> [Any]? {
        (try? parse(text)) as? [Any]
    }

    /// 解析为 [String: String]，值统一转成字符串
    static func stringMap(_ text: String) -> [String: String]? {
        guard let obj = object(text) else { return nil }
        var map: [String: String] = [:]
        for (k, v) in obj {
            map[k] = stringify(v)
        }
        return map
    }

    /// Foundation JSON 值转字符串：字符串原样，对象/数组序列化
    static func stringify(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let s as String:
            return s
        case let n as NSNumber:
            return numberString(n)
        case let v where JSONSerialization.isValidJSONObject(v as Any):
            let data = (try? JSONSerialization.data(withJSONObject: v as Any, options: [.withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        default:
            return String(describing: value!)
        }
    }

    static func numberString(_ n: NSNumber) -> String {
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        #if canImport(Darwin)
        guard CFNumberIsFloatType(n) else { return n.stringValue }
        #else
        // ⚠️ **Linux 沙盒**：没有 CFNumberIsFloatType ⇒ 用 doubleValue 判断（门禁里已知差异）⭐⭐⭐
        let probe = n.doubleValue
        if probe.rounded() == probe && abs(probe) < 1e15 && n.stringValue.range(of: ".", options: .literal) == nil {
            return n.stringValue
        }
        #endif
        let d = n.doubleValue
        if d.isFinite, d.rounded() == d, abs(d) < 1e15 {
            return String(Int64(d))
        }
        return "\(d)"
    }

    /// 序列化成 JSON 文本（失败时返回 nil）
    static func serialize(_ value: Any, sortedKeys: Bool = false) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if sortedKeys { opts.insert(.sortedKeys) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: opts) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skipWhitespace() {
            while i < s.count {
                let c = s[i]
                if c.properties.isWhitespace || c == "\u{FEFF}" {
                    i += 1
                } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i += 2
                } else if c == "#" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        func error(_ msg: String) -> ParseError { ParseError(message: msg, offset: i) }

        mutating func parseValue() throws -> Any {
            skipWhitespace()
            guard i < s.count else { throw error("意外结束") }
            switch s[i] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"", "'": return try parseString(quote: s[i])
            default: return try parseLiteral()
            }
        }

        mutating func parseObject() throws -> [String: Any] {
            i += 1
            var obj: [String: Any] = [:]
            while true {
                skipWhitespace()
                guard i < s.count else { throw error("对象未闭合") }
                if s[i] == "}" { i += 1; return obj }
                if s[i] == "," || s[i] == ";" { i += 1; continue }
                let key: String
                if s[i] == "\"" || s[i] == "'" {
                    key = try parseString(quote: s[i])
                } else {
                    key = parseBareWord(stopAt: [":", "=", "}", ","]).trimmedWhitespace
                }
                skipWhitespace()
                guard i < s.count else { throw error("缺少值") }
                if s[i] == ":" {
                    i += 1
                } else if s[i] == "=" {
                    i += 1
                    if i < s.count, s[i] == ">" { i += 1 }
                } else {
                    throw error("缺少冒号")
                }
                obj[key] = try parseValue()
            }
        }

        mutating func parseArray() throws -> [Any] {
            i += 1
            var arr: [Any] = []
            while true {
                skipWhitespace()
                guard i < s.count else { throw error("数组未闭合") }
                if s[i] == "]" { i += 1; return arr }
                if s[i] == "," || s[i] == ";" { i += 1; continue }
                arr.append(try parseValue())
            }
        }

        mutating func parseString(quote: Unicode.Scalar) throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == quote { i += 1; return String(out) }
                if c == "\\", i + 1 < s.count {
                    i += 1
                    let e = s[i]
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        if i + 4 < s.count, let code = UInt32(String(String.UnicodeScalarView(s[(i + 1)...(i + 4)])), radix: 16) {
                            i += 4
                            var scalarValue = code
                            // 代理对
                            if (0xD800...0xDBFF).contains(code), i + 6 < s.count, s[i + 1] == "\\", s[i + 2] == "u",
                               let low = UInt32(String(String.UnicodeScalarView(s[(i + 3)...(i + 6)])), radix: 16),
                               (0xDC00...0xDFFF).contains(low) {
                                scalarValue = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                                i += 6
                            }
                            if let scalar = Unicode.Scalar(scalarValue) { out.append(scalar) }
                        } else {
                            out.append("u")
                        }
                    default: out.append(e)
                    }
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
            }
            throw error("字符串未闭合")
        }

        mutating func parseBareWord(stopAt: Set<Unicode.Scalar>) -> String {
            var out = String.UnicodeScalarView()
            while i < s.count, !stopAt.contains(s[i]), !s[i].properties.isWhitespace {
                out.append(s[i])
                i += 1
            }
            return String(out)
        }

        mutating func parseLiteral() throws -> Any {
            let word = parseBareWord(stopAt: [",", "}", "]", ":", ";"])
            switch word {
            case "true": return true
            case "false": return false
            case "null", "undefined": return NSNull()
            case "": throw error("无效的值")
            default:
                if let i = Int64(word) { return NSNumber(value: i) }
                if let d = Double(word) { return NSNumber(value: d) }
                if word.hasPrefix("0x"), let h = Int64(word.dropFirst(2), radix: 16) { return NSNumber(value: h) }
                // Gson lenient 允许无引号字符串
                return word
            }
        }
    }
}
