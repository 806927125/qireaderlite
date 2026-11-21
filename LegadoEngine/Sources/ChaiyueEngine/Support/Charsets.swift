import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 字符集与 URL 编码
public enum Charsets {
    public static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    )

    /// 根据 IANA 名称取编码；GBK/GB2312 统一按 GB18030 处理（向下兼容）
    public static func encoding(named rawName: String?) -> String.Encoding? {
        guard let rawName else { return nil }
        let name = rawName.trimmedWhitespace.lowercased()
        switch name {
        case "": return nil
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030", "gb_2312-80", "x-gbk", "cp936": return gb18030
        case "iso-8859-1", "latin1": return .isoLatin1
        case "ascii", "us-ascii": return .ascii
        case "utf-16", "utf16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        default:
            #if canImport(Darwin)
            // ⭐⭐⭐ **Darwin 专属**（Linux 的 swift-corelibs-foundation 不接受 `as CFString`）⭐⭐⭐
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            #else
            // ⚠️ **Linux 沙盒**：IANA 字符集名转不了 ⇒ 返回 nil（门禁里已知差异）⭐⭐⭐
            return nil
            #endif
        }
    }

    /// 解码响应：显式字符集 > Content-Type > HTML meta > UTF-8 > GB18030
    public static func decode(_ data: Data, charset: String? = nil, contentType: String? = nil) -> String {
        if let enc = encoding(named: charset), let s = String(data: data, encoding: enc) {
            return s
        }
        if let ct = contentType, let cs = charsetFromContentType(ct),
           let enc = encoding(named: cs), let s = String(data: data, encoding: enc) {
            return s
        }
        if let cs = sniffHTMLCharset(data), let enc = encoding(named: cs), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        if let s = String(data: data, encoding: gb18030) {
            return s
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func charsetFromContentType(_ contentType: String) -> String? {
        guard let m = contentType.firstMatch(#"charset\s*=\s*["']?([\w.:-]+)"#, options: .caseInsensitive) else { return nil }
        return contentType.group(m, 1)
    }

    static func sniffHTMLCharset(_ data: Data) -> String? {
        let head = data.prefix(4096)
        let text = String(decoding: head, as: UTF8.self)
        guard let m = text.firstMatch(#"<meta[^>]+charset\s*=\s*["']?([\w.:-]+)"#, options: .caseInsensitive) else {
            return nil
        }
        return text.group(m, 1)
    }

    private static let urlSafe: Set<UInt8> = {
        var set = Set<UInt8>()
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(c) }
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(c) }
        for c in "*-._".utf8 { set.insert(c) }
        return set
    }()

    /// Java `URLEncoder.encode` 语义：安全字符 `A-Za-z0-9*-._`，空格编码为 `+`
    public static func urlEncode(_ text: String, charset: String? = nil) -> String {
        let enc = encoding(named: charset) ?? .utf8
        let bytes = text.data(using: enc, allowLossyConversion: true) ?? Data(text.utf8)
        var out = ""
        out.reserveCapacity(bytes.count * 3)
        for b in bytes {
            if urlSafe.contains(b) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else if b == 0x20 {
                out.append("+")
            } else {
                out.append(String(format: "%%%02X", b))
            }
        }
        return out
    }

    public static func urlDecode(_ text: String, charset: String? = nil) -> String {
        let enc = encoding(named: charset) ?? .utf8
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            let c = utf8[i]
            if c == UInt8(ascii: "+") {
                bytes.append(0x20)
            } else if c == UInt8(ascii: "%"), i + 2 < utf8.count,
                      let v = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v)
                i += 2
            } else {
                bytes.append(c)
            }
            i += 1
        }
        return String(data: Data(bytes), encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static let queryAllowed: Set<UInt8> = {
        var set = urlSafe
        for c in "!$&()*+,-./:;=?@[\\]^_`{|}~".utf8 { set.insert(c) }
        return set
    }()

    /// 判断查询参数是否已经编码过（Legado `NetworkUtils.encodedQuery`）
    public static func isEncodedQuery(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if queryAllowed.contains(c) {
                i += 1
                continue
            }
            if c == UInt8(ascii: "%"), i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                i += 3
                continue
            }
            return false
        }
        return true
    }

    private static func isHex(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c)
    }
}
