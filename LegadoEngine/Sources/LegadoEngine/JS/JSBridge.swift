import Foundation

/// JS 宿主回调（log / toast）。默认空实现。
public protocol JSHost: AnyObject {
    func jsLog(_ msg: String)
    func jsToast(_ msg: String)
}
extension JSHost {
    public func jsLog(_ msg: String) {}
    public func jsToast(_ msg: String) {}
}

#if canImport(JavaScriptCore) && !os(Linux)
import JavaScriptCore
import SwiftSoup

/// JavaScriptCore 桥：安装原生 java/cookie/__native 面，按序加载从原 app 二进制
/// 原样提取的 5 个 JS bootstrap（Resources/01…05），然后执行书源规则脚本。
/// 语义对齐 Legado Rhino 引擎（JsExtensions / AnalyzeRule.evalJS）。
public final class JSBridge {
    public private(set) var lastError: String?

    let context: JSContext
    var source: BookSource?
    let book: Book?
    let chapter: BookChapter?
    let variables: RuleVariables
    weak var host: JSHost?

    /// bootstrap 加载顺序（node 冒烟验证过：core → graphics → response → crypto → ttf）
    static let bootstrapFiles = ["01_core", "02_graphics", "03_response", "04_crypto", "05_ttf"]

    // 原二进制提取的 Rhino 兼容改写正则（精确常量）
    static let bareLengthCallRegex = try! NSRegularExpression(pattern: #"([\w$\]\)]+)\.length\(\)"#)
    static let rhinoArrowRegex = try! NSRegularExpression(
        pattern: #"((?:^|[(,=:?&|!;{}\n])\s*|\breturn\s+)(\[[\w$\s,]*\]|\{[\w$\s,:]*\})\s*=>"#,
        options: [.anchorsMatchLines])

    public init(source: BookSource?, book: Book?, chapter: BookChapter?,
                variables: RuleVariables, host: JSHost? = nil) {
        self.source = source
        self.book = book
        self.chapter = chapter
        self.variables = variables
        self.host = host
        self.context = JSContext()!
        context.exceptionHandler = { [weak self] _, exc in
            self?.lastError = exc?.toString()
        }
        installDispatchers()
        loadBootstrap()
        if let lib = source?.jsLib, !lib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.evaluateScript(lib)
            if context.exception != nil { context.exception = nil }
        }
    }

    // MARK: - 求值

    public func eval(_ script: String, bindings: [String: Any?] = [:]) throws -> Any? {
        applyBindings(bindings)
        lastError = nil
        let pre = Self.rhinoPreprocess(script)
        let v = context.evaluateScript(pre)
        if let exc = context.exception {
            let msg = lastError ?? exc.toString()
            context.exception = nil
            throw LegadoError("JS 执行错误: \(msg ?? "unknown")")
        }
        return Self.unwrap(v)
    }

    static func rhinoPreprocess(_ script: String) -> String {
        var s = script
        let full = NSRange(s.startIndex..., in: s)
        s = bareLengthCallRegex.stringByReplacingMatches(in: s, range: full, template: "$1.length")
        let full2 = NSRange(s.startIndex..., in: s)
        s = rhinoArrowRegex.stringByReplacingMatches(in: s, range: full2, template: "$1($2) =>")
        return s
    }

    private func applyBindings(_ bindings: [String: Any?]) {
        for (k, val) in bindings {
            switch k {
            case "source":
                if let s = val as? BookSource {
                    source = s
                    context.setObject(Self.modelDict(s, extra: ["__loginUi": s.loginUi ?? ""]),
                                      forKeyedSubscript: "source" as NSString)
                    context.evaluateScript("__mkSource(source)")
                } else {
                    context.setObject(NSNull(), forKeyedSubscript: "source" as NSString)
                }
            case "book":
                if let b = val as? Book {
                    context.setObject(Self.modelDict(b), forKeyedSubscript: "book" as NSString)
                    context.evaluateScript("__mkBook(book, 'book')")
                } else if val == nil {
                    context.setObject(NSNull(), forKeyedSubscript: "book" as NSString)
                }
            case "chapter":
                if let c = val as? BookChapter {
                    context.setObject(Self.modelDict(c), forKeyedSubscript: "chapter" as NSString)
                    context.evaluateScript("__mkBook(chapter, 'chapter')")
                } else if val == nil {
                    context.setObject(NSNull(), forKeyedSubscript: "chapter" as NSString)
                }
            default:
                context.setObject(val ?? NSNull(), forKeyedSubscript: k as NSString)
            }
            if context.exception != nil { context.exception = nil }
        }
        // 确保常用全局存在（bootstrap 已声明，这里兜底）
        if context.objectForKeyedSubscript("baseUrl") == nil || context.objectForKeyedSubscript("baseUrl").isUndefined {
            context.evaluateScript("var baseUrl = baseUrl || ''; var key = key || ''; var page = page || 1;")
        }
    }

    static func modelDict<T: Encodable>(_ model: T, extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(model),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = obj
        }
        for (k, v) in extra { dict[k] = v }
        return dict
    }

    /// JSValue → Swift 值（undefined/null → nil）
    static func unwrap(_ v: JSValue?) -> Any? {
        guard let v else { return nil }
        if v.isUndefined || v.isNull { return nil }
        if v.isBoolean { return v.toBool() }
        if v.isNumber {
            let d = v.toDouble()
            if d == d.rounded() && abs(d) < 9.007199254740992e15 { return Int(d) }
            return d
        }
        if v.isString { return v.toString() }
        if v.isArray {
            return (v.toArray() ?? []).map(unwrapAny)
        }
        if v.isObject {
            if let dict = v.toDictionary() as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, val) in dict { out[k] = unwrapAny(val) }
                return out
            }
            return v.toObject()
        }
        return v.toObject()
    }

    private static func unwrapAny(_ v: Any) -> Any {
        if v is NSNull { return "" }
        if let arr = v as? [Any] { return arr.map(unwrapAny) }
        if let dict = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in dict { out[k] = unwrapAny(val) }
            return out
        }
        return v
    }

    // MARK: - bootstrap / 原生分发器

    private func loadBootstrap() {
        for name in Self.bootstrapFiles {
            guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "JS/Resources")
                    ?? Bundle.module.url(forResource: name, withExtension: "js") else {
                lastError = "缺少 JS 资源 \(name).js"
                continue
            }
            if let js = try? String(contentsOf: url, encoding: .utf8) {
                context.evaluateScript(js, withSourceURL: URL(string: "legado://\(name).js"))
                if let exc = context.exception {
                    lastError = "bootstrap \(name): \(exc.toString() ?? "")"
                    context.exception = nil
                }
            }
        }
        // Packages.java.* 命名空间挂到 java 上（java.lang.String / java.util.* 等 Rhino 写法）
        context.evaluateScript("""
        (function(){ var have = Object.keys(java);
          for (var k in Packages.java) { if (have.indexOf(k) < 0) java[k] = Packages.java[k]; }
          if (typeof android === 'undefined') { android = Packages.android; }
        })();
        """)
        if context.exception != nil { context.exception = nil }
    }

    /// java / cookie / __native 都用 Proxy 分发：未覆盖的成员落到原生 switch。
    private func installDispatchers() {
        let nativeCall: @convention(block) (JSValue, JSValue) -> Any? = { [weak self] name, args in
            guard let self else { return nil }
            return self.dispatch(name.toString() ?? "", args.toArray() ?? [])
        }
        context.setObject(nativeCall, forKeyedSubscript: "__nativeCall" as NSString)
        context.setObject(nativeCall, forKeyedSubscript: "__javaCall" as NSString)
        context.setObject(nativeCall, forKeyedSubscript: "__cookieCall" as NSString)
        context.evaluateScript("""
        var __native = new Proxy({}, { get: function(t, k){
            if (typeof k !== 'string') return undefined;
            return function(){ return __nativeCall(k, Array.prototype.slice.call(arguments)); }; } });
        var java = new Proxy({}, {
          get: function(t, k){ if (k in t) return t[k];
            if (typeof k !== 'string') return undefined;
            return function(){ return __javaCall(k, Array.prototype.slice.call(arguments)); }; },
          set: function(t, k, v){ t[k] = v; return true; },
          has: function(t, k){ return k in t; } });
        var cookie = new Proxy({}, {
          get: function(t, k){ if (k in t) return t[k];
            if (typeof k !== 'string') return undefined;
            return function(){ return __cookieCall(k, Array.prototype.slice.call(arguments)); }; },
          set: function(t, k, v){ t[k] = v; return true; } });
        """)
    }

    func jsThrow(_ msg: String) {
        lastError = msg
        context.exception = JSValue(newErrorFromMessage: msg, in: context)
    }

    // MARK: - 参数 helpers（供 JSNatives.swift 使用）

    func str(_ a: [Any], _ i: Int) -> String? {
        guard i < a.count else { return nil }
        let v = a[i]
        if v is NSNull { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    func num(_ a: [Any], _ i: Int) -> Double? {
        guard i < a.count else { return nil }
        if let n = a[i] as? NSNumber { return n.doubleValue }
        if let s = a[i] as? String { return Double(s) }
        return nil
    }
    func bool(_ a: [Any], _ i: Int) -> Bool {
        guard i < a.count else { return false }
        if let n = a[i] as? NSNumber { return n.boolValue }
        if let s = a[i] as? String { return s == "true" || s == "1" }
        return false
    }
}

#else

/// 非 Apple 平台（Linux CI）stub：保持签名一致，eval 抛错。
public final class JSBridge {
    public private(set) var lastError: String?
    public init(source: BookSource?, book: Book?, chapter: BookChapter?,
                variables: RuleVariables, host: JSHost? = nil) {}
    public func eval(_ script: String, bindings: [String: Any?] = [:]) throws -> Any? {
        throw LegadoError("JavaScriptCore 在当前平台不可用，无法执行 JS 规则")
    }
}

#endif