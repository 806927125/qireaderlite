#if canImport(JavaScriptCore) && !os(Linux)
import Foundation
import JavaScriptCore
import Kanna
import SwiftSoup

/// 书源 JS 运行时。每个解析会话一个 JSContext，只在会话所在线程使用。
final class JSRuntime {
    let context: JSContext
    unowned let session: RuleSession
    private var lastException: JSValue?
    private var jsLibLoaded = false
    private var hostStack: [JSAnalyzerHost?] = []
    private(set) var bridge: JavaBridge!

    init(session: RuleSession) {
        self.session = session
        context = JSContext()!
        context.name = "Source: \(session.source.name)"
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception
        }
        bridge = JavaBridge(runtime: self)
        installGlobals()
    }

    /// 当前执行中的解析器（`java.getString` 等使用）
    var currentHost: JSAnalyzerHost? { hostStack.last ?? nil }

    private func installGlobals() {
        context.evaluateScript(JSPrelude.source)
        let java = bridge.makeJavaObject()
        context.setObject(java, forKeyedSubscript: "java" as NSString)
        context.setObject(JSSource(session), forKeyedSubscript: "source" as NSString)
        context.setObject(JSCookie(session.env.cookies), forKeyedSubscript: "cookie" as NSString)
        context.setObject(JSCache(session.env.cache), forKeyedSubscript: "cache" as NSString)
        bridge.installNativeHelpers()
        context.evaluateScript(JSPrelude.packages)
        lastException = nil
    }

    /// jsLib 只在首次执行 JS 时加载
    private func loadJSLibIfNeeded() throws {
        guard !jsLibLoaded else { return }
        jsLibLoaded = true
        guard let lib = session.source.jsLib, !lib.isBlank else { return }
        if lib.trimmedWhitespace.hasPrefix("{"), let map = LenientJSON.stringMap(lib) {
            // JSON 形式：{"name": "url或代码"}
            for value in map.values {
                let code = value.isAbsUrl ? ((try? session.fetchText(url: value)) ?? "") : value
                _ = try evaluateRaw(code, sourceURL: "jsLib")
            }
        } else {
            _ = try evaluateRaw(lib, sourceURL: "jsLib")
        }
    }

    private func evaluateRaw(_ script: String, sourceURL: String) throws -> JSValue? {
        lastException = nil
        let value = context.evaluateScript(script, withSourceURL: URL(string: "source://\(sourceURL)"))
        if let ex = lastException {
            lastException = nil
            throw RuleError.js(Self.describe(ex))
        }
        return value
    }

    /// 在嵌套于外层脚本的原生调用中执行脚本，异常不影响外层
    func evaluateNested(_ script: String) throws -> JSValue? {
        let saved = lastException
        defer { lastException = saved }
        return try evaluateRaw(script, sourceURL: "nested")
    }

    /// 在嵌套于外层脚本的原生调用中调用 JS 函数，异常转换为 `RuleError.js`
    func call(_ function: JSValue, _ arguments: [Any]) throws -> JSValue? {
        let saved = lastException
        defer { lastException = saved }
        lastException = nil
        let value = function.call(withArguments: arguments)
        if let ex = lastException { throw RuleError.js(Self.describe(ex)) }
        return value
    }

    /// 执行脚本并返回 Swift 值。绑定变量在执行后恢复，保证嵌套执行互不干扰。
    func eval(_ script: String, bindings: JSBindings) throws -> Any? {
        let value = try evalValue(script, bindings: bindings)
        return value.flatMap { Self.fromJS($0) }
    }

    func evalValue(_ script: String, bindings: JSBindings) throws -> JSValue? {
        try loadJSLibIfNeeded()
        let global = context.globalObject!
        var saved: [String: JSValue] = [:]
        let names = JSBindings.keys + Array(bindings.extra.keys)
        for name in names {
            saved[name] = global.objectForKeyedSubscript(name)
        }
        hostStack.append(bindings.host)
        defer {
            hostStack.removeLast()
            for (name, value) in saved {
                global.setObject(value, forKeyedSubscript: name as NSString)
            }
        }
        set("result", jsValue(bindings.result))
        set("baseUrl", bindings.baseUrl)
        set("src", Self.toJSObject(bindings.src))
        set("book", bindings.book.map(JSBook.init))
        set("chapter", bindings.chapter.map(JSChapter.init))
        set("title", bindings.title)
        set("nextChapterUrl", bindings.nextChapterUrl)
        set("key", bindings.key)
        set("page", bindings.page.map { NSNumber(value: $0) })
        set("speakText", bindings.speakText)
        set("speakSpeed", bindings.speakSpeed.map { NSNumber(value: $0) })
        for (name, value) in bindings.extra {
            set(name, jsValue(value))
        }
        return try run(script)
    }

    private func jsValue(_ value: Any?) -> Any? {
        if let map = value as? JavaMap { return Self.makeJavaMap(map.dict, in: context) }
        return Self.toJSObject(value)
    }

    private func set(_ name: String, _ value: Any?) {
        let global = context.globalObject!
        if let value {
            global.setObject(value, forKeyedSubscript: name as NSString)
        } else {
            global.setObject(JSValue(nullIn: context), forKeyedSubscript: name as NSString)
        }
    }

    /// 先包成块语句执行（避免 let/const 重复声明，保留最后表达式的值），
    /// 语法错误时再按表达式执行（兼容 `{a:1}` 这类对象字面量）。
    private func run(_ script: String) throws -> JSValue? {
        lastException = nil
        let wrapped = "{\n\(script)\n}"
        var value = context.evaluateScript(wrapped)
        if let ex = lastException {
            let name = ex.objectForKeyedSubscript("name")?.toString() ?? ""
            guard name == "SyntaxError" else {
                lastException = nil
                throw RuleError.js(Self.describe(ex))
            }
            lastException = nil
            value = context.evaluateScript("(\(script)\n)")
            if let ex2 = lastException {
                lastException = nil
                // 两种方式都失败时报告原始错误
                _ = ex2
                throw RuleError.js(Self.describe(ex))
            }
        }
        return value
    }

    static func describe(_ exception: JSValue) -> String {
        var message = exception.toString() ?? "未知错误"
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber {
            message += " (line \(line.toInt32()))"
        }
        return message
    }

    // MARK: - 值转换

    /// Swift → 可交给 JSC 的对象（元素包装为 JSElement）
    static func toJSObject(_ value: Any?) -> Any? {
        switch value {
        case nil:
            return nil
        case let v as JSValue:
            return v
        case let el as Element:
            return JSElement(el)
        case let el as Kanna.XMLElement:
            return el.toHTML ?? ""
        case let list as [Element]:
            return JSElement.wrap(list)
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = toJSObject(v) ?? NSNull() }
            return out
        case let arr as [Any]:
            return arr.map { toJSObject($0) ?? NSNull() }
        case let data as Data:
            return data.map { NSNumber(value: Int8(bitPattern: $0)) }
        default:
            return value
        }
    }

    /// JS → Swift：数组/对象递归转换，包装对象还原
    static func fromJS(_ value: JSValue) -> Any? {
        if value.isUndefined || value.isNull { return nil }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber { return value.toNumber() }
        if value.isArray {
            let length = Int(value.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            var out: [Any] = []
            out.reserveCapacity(length)
            for i in 0..<length {
                out.append(fromJS(value.atIndex(i)) ?? NSNull())
            }
            return out
        }
        if value.isDate { return value.toDate() }
        if let obj = value.toObject() {
            switch obj {
            case let el as JSElement: return el.element
            case let r as JSResponse: return r
            case let b as JSBook: return b.ref
            case let c as JSChapter: return c.ref
            case is NSDictionary:
                return unwrap(obj)
            default:
                return obj
            }
        }
        return nil
    }

    private static func unwrap(_ obj: Any) -> Any {
        switch obj {
        case let el as JSElement:
            return el.element
        case let dict as NSDictionary:
            var out: [String: Any] = [:]
            for (k, v) in dict { out["\(k)"] = unwrap(v) }
            return out
        case let arr as NSArray:
            return arr.map { unwrap($0) }
        default:
            return obj
        }
    }

    /// 读取字符串参数：undefined/null 返回 nil，对象序列化为 JSON
    static func stringArgument(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        if value.isObject, !value.isArray, let obj = fromJS(value), JSONSerialization.isValidJSONObject(obj) {
            return LenientJSON.serialize(obj)
        }
        if value.isArray, let obj = fromJS(value) as? [Any] {
            if obj.allSatisfy({ $0 is NSNumber }), !obj.isEmpty {
                // 字节数组按 UTF-8 解码
                let bytes = obj.compactMap { ($0 as? NSNumber).map { UInt8(bitPattern: $0.int8Value) } }
                return String(decoding: bytes, as: UTF8.self)
            }
            return LenientJSON.serialize(obj)
        }
        return value.toString()
    }

    /// 读取字节参数：数组按字节，字符串按 UTF-8
    static func bytesArgument(_ value: JSValue?) -> Data? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isArray, let arr = fromJS(value) as? [Any] {
            return Data(arr.map { UInt8(truncatingIfNeeded: ($0 as? NSNumber)?.intValue ?? 0) })
        }
        if let obj = value.toObject(), let data = obj as? Data { return data }
        return value.toString().data(using: .utf8)
    }

    /// 带 Java Map 方法（get/put/containsKey…）的 JS 对象
    static func makeJavaMap(_ dict: [String: Any], in context: JSContext) -> JSValue {
        let obj = JSValue(object: toJSObject(dict), in: context)!
        guard let maker = context.objectForKeyedSubscript("__makeJavaMap"), !maker.isUndefined else { return obj }
        return maker.call(withArguments: [obj]) ?? obj
    }

    static func throwError(_ error: Error) {
        guard let ctx = JSContext.current() else { return }
        let message = (error as? RuleError)?.description ?? error.localizedDescription
        ctx.exception = JSValue(newErrorFromMessage: message, in: ctx)
    }
}

#endif  // #if canImport(JavaScriptCore) && !os(Linux)
