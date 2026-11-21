import Foundation
import Kanna
import SwiftSoup

/// 规则中间结果的通用处理
enum RuleValue {
    /// 转成文本：元素取外层 HTML，JSON 对象/数组序列化，其他取描述
    static func text(of value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let s as String:
            return s
        case let n as NSNumber:
            return LenientJSON.numberString(n)
        case let el as Element:
            return (try? el.outerHtml()) ?? ""
        case let el as Kanna.XMLElement:
            return el.toHTML ?? el.text ?? ""
        case let list as [Element]:
            return list.compactMap { try? $0.outerHtml() }.joined(separator: "\n")
        case let strings as [String]:
            return strings.joined(separator: "\n")
        case let dict as [String: Any]:
            return LenientJSON.serialize(dict) ?? "\(dict)"
        case let arr as [Any]:
            return LenientJSON.serialize(arr) ?? arr.map { text(of: $0) }.joined(separator: "\n")
        case let data as Data:
            return String(decoding: data, as: UTF8.self)
        case let response as JSResponse:
            return response.body()
        default:
            return String(describing: value!)
        }
    }

    /// JS 结果转字符串（与 Rhino 返回值的 toString 行为接近）
    static func jsString(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let s as String:
            return s
        case let n as NSNumber:
            return LenientJSON.numberString(n)
        case let arr as [Any]:
            return arr.map { jsString($0) ?? "" }.joined(separator: ",")
        default:
            return text(of: value)
        }
    }

    static func isJSON(_ value: Any?) -> Bool {
        switch value {
        case is Element, is Kanna.XMLElement:
            return false
        case is [String: Any]:
            return true
        case let arr as [Any]:
            return !(arr.first is Element)
        case let s as String:
            return s.isJson
        default:
            return false
        }
    }
}
