// ⭐⭐⭐⭐⭐ **移植补丁（2026-11-21）**：把纯 Swift 的 JS 相关类型从 `JS/JSBindings.swift` 挪到这里 ⭐⭐⭐
//
// ⚠️⚠️ **为什么挪**：`JS/JSBindings.swift` 整个文件在 `#if canImport(JavaScriptCore)` 里
//   ⇒ 而 `Engine/`、`Rule/`、`Network/` 里的**非 JS 文件**也引用这些类型 ⭐⭐⭐
//   ⇒ 不挪 ⇒ **Linux 沙盒编不到整个引擎** ⇒ **沙盒门禁全废**（记忆老坑：「沙盒编不到 = 没有门禁」）⭐⭐⭐
//   ⇒ 这些类型**本身不依赖 JSC**（纯 Swift）⇒ 挪出来即可两边都用 ⭐⭐⭐
//
// ⚠️ **与上游的 diff**（同步柴阅上游时需重新套用）⭐⭐⭐
import Foundation
import ChaiyueModels

protocol VariableHolder: AnyObject {
    func putVariable(_ key: String, _ value: String?)
    func getVariable(_ key: String) -> String
}


final class BookRef: VariableHolder {
    var book: Book

    init(_ book: Book) { self.book = book }

    func putVariable(_ key: String, _ value: String?) {
        if let value { book.variableMap[key] = value } else { book.variableMap.removeValue(forKey: key) }
    }

    func getVariable(_ key: String) -> String { book.variableMap[key] ?? "" }
}


final class ChapterRef: VariableHolder {
    var chapter: BookChapter

    init(_ chapter: BookChapter) { self.chapter = chapter }

    func putVariable(_ key: String, _ value: String?) {
        if let value { chapter.variableMap[key] = value } else { chapter.variableMap.removeValue(forKey: key) }
    }

    func getVariable(_ key: String) -> String { chapter.variableMap[key] ?? "" }
}


final class RuleData: VariableHolder {
    var variables: [String: String] = [:]

    func putVariable(_ key: String, _ value: String?) {
        if let value { variables[key] = value } else { variables.removeValue(forKey: key) }
    }

    func getVariable(_ key: String) -> String { variables[key] ?? "" }
}


protocol JSAnalyzerHost: AnyObject {
    var hostRuleData: VariableHolder? { get }
    var hostChapter: ChapterRef? { get }
    func jsGetString(_ rule: String, content: Any?, isUrl: Bool) throws -> String
    func jsGetStringList(_ rule: String, content: Any?, isUrl: Bool) throws -> [String]
    func jsGetElements(_ rule: String) throws -> [Any]
    func jsGetElement(_ rule: String) throws -> Any?
    func jsSetContent(_ content: Any?, baseUrl: String?) throws
    func jsPut(_ key: String, _ value: String) -> String
    func jsGet(_ key: String) -> String
}

/// 单次 JS 执行的绑定变量
struct JSBindings {
    weak var host: JSAnalyzerHost?
    var result: Any?
    var baseUrl: String?
    var src: Any?
    var book: BookRef?
    var chapter: ChapterRef?
    var title: String?
    var nextChapterUrl: String?
    var key: String?
    var page: Int?
    var speakText: String?
    var speakSpeed: Int?
    var extra: [String: Any] = [:]

    init(host: JSAnalyzerHost?) {
        self.host = host
    }

    static let keys = [
        "result", "baseUrl", "src", "book", "chapter", "title", "nextChapterUrl",
        "key", "page", "speakText", "speakSpeed",
    ]
}

// ⭐⭐⭐ **Hex / Base64Codec 是纯 Swift 编码** ⇒ 从 `Crypto/Crypto.swift`（依赖 CommonCrypto）拆出来
//   ⇒ Linux 沙盒可编（`SourceEnvironment` 用 `Hex.encode` 算 androidID）⭐⭐⭐

enum Base64Codec {
    static let noPadding = 1
    static let noWrap = 2
    static let crlf = 4
    static let urlSafe = 8

    static func encode(_ data: Data, flags: Int = noWrap) -> String {
        var s = data.base64EncodedString()
        if flags & urlSafe != 0 {
            s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if flags & noPadding != 0 {
            while s.hasSuffix("=") { s.removeLast() }
        }
        if flags & noWrap == 0 {
            let newline = flags & crlf != 0 ? "\r\n" : "\n"
            var wrapped = ""
            var index = s.startIndex
            while index < s.endIndex {
                let end = s.index(index, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
                wrapped += s[index..<end] + newline
                index = end
            }
            s = wrapped
        }
        return s
    }

    /// 宽松解码：忽略空白，同时接受标准与 URL 安全字母表，自动补齐填充
    static func decode(_ text: String) -> Data? {
        var s = text.filter { !$0.isWhitespace }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if let comma = s.firstIndex(of: ","), s.hasPrefix("data:") {
            s = String(s[s.index(after: comma)...])
        }
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

enum Hex {
    static func encode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> Data? {
        let chars = Array(text.utf8).filter { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = value(chars[i]), let lo = value(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func isHex(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { value($0) != nil }
    }

    private static func value(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
