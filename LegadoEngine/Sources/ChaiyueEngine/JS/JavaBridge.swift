#if canImport(JavaScriptCore) && !os(Linux)
import Foundation
import JavaScriptCore
import SwiftSoup

/// 构建 JS 中的 `java` 对象与 `__native` 原生辅助函数
final class JavaBridge {
    unowned let runtime: JSRuntime

    init(runtime: JSRuntime) { self.runtime = runtime }

    private var session: RuleSession { runtime.session }
    private var context: JSContext { runtime.context }
    private var host: JSAnalyzerHost? { runtime.currentHost }

    typealias Body = ([JSValue]) throws -> Any?

    private static func block(_ body: @escaping Body) -> @convention(block) () -> Any? {
        return {
            let args = (JSContext.currentArguments() as? [JSValue]) ?? []
            do {
                return JSRuntime.toJSObject(try body(args)) ?? NSNull()
            } catch {
                JSRuntime.throwError(error)
                return nil
            }
        }
    }

    private static func define(_ object: JSValue, _ name: String, _ body: @escaping Body) {
        object.setObject(block(body), forKeyedSubscript: name as NSString)
    }

    // MARK: - 参数读取

    private static func arg(_ args: [JSValue], _ i: Int) -> JSValue? {
        guard i < args.count else { return nil }
        let v = args[i]
        return v.isUndefined || v.isNull ? nil : v
    }

    private static func str(_ args: [JSValue], _ i: Int) -> String? {
        JSRuntime.stringArgument(arg(args, i))
    }

    private static func int(_ args: [JSValue], _ i: Int) -> Int? {
        guard let v = arg(args, i) else { return nil }
        if v.isNumber { return Int(v.toDouble()) }
        return Int(v.toString().trimmedWhitespace)
    }

    private static func bytes(_ args: [JSValue], _ i: Int) -> Data? {
        JSRuntime.bytesArgument(arg(args, i))
    }

    private static func headers(_ value: JSValue?) -> [String: String] {
        guard let value else { return [:] }
        if value.isString { return LenientJSON.stringMap(value.toString()) ?? [:] }
        guard let dict = JSRuntime.fromJS(value) as? [String: Any] else { return [:] }
        return dict.mapValues { RuleValue.jsString($0) ?? "" }
    }

    private static func encoding(_ name: String?) -> String.Encoding {
        Charsets.encoding(named: name) ?? .utf8
    }

    private static func byteArray(_ data: Data) -> [NSNumber] {
        data.map { NSNumber(value: Int8(bitPattern: $0)) }
    }

    // MARK: - java 对象

    func makeJavaObject() -> JSValue {
        let java = JSValue(newObjectIn: context)!
        let d = { (name: String, body: @escaping Body) in Self.define(java, name, body) }
        let s = Self.str, i = Self.int, b = Self.bytes

        // 网络
        d("ajax") { [unowned self] args in
            guard let first = Self.arg(args, 0) else { return nil }
            let url = first.isArray ? (JSRuntime.fromJS(first) as? [Any])?.first.map { "\($0)" } ?? "" : first.toString()!
            return session.ajax(url, host: host)
        }
        d("ajaxAll") { [unowned self] args in
            guard let list = Self.arg(args, 0).flatMap({ JSRuntime.fromJS($0) as? [Any] }) else { return [] }
            return list.map { session.connect("\($0)", header: nil, host: host) }
        }
        d("connect") { [unowned self] args in
            session.connect(s(args, 0) ?? "", header: s(args, 1), host: host)
        }
        d("get") { [unowned self] args in
            if args.count <= 1 {
                let key = s(args, 0) ?? ""
                return host?.jsGet(key) ?? session.sourceGet(key)
            }
            return try session.rawRequest(method: "GET", url: s(args, 0) ?? "", body: nil,
                                          headers: Self.headers(Self.arg(args, 1)), timeout: i(args, 2))
        }
        d("head") { [unowned self] args in
            try session.rawRequest(method: "HEAD", url: s(args, 0) ?? "", body: nil,
                                   headers: Self.headers(Self.arg(args, 1)), timeout: i(args, 2))
        }
        d("post") { [unowned self] args in
            try session.rawRequest(method: "POST", url: s(args, 0) ?? "", body: s(args, 1),
                                   headers: Self.headers(Self.arg(args, 2)), timeout: i(args, 3))
        }
        d("getCookie") { [unowned self] args in
            let tag = s(args, 0) ?? ""
            if let key = s(args, 1) { return session.env.cookies.getKey(url: tag, key: key) }
            return session.env.cookies.getCookie(url: tag)
        }
        d("cacheFile") { [unowned self] args in
            try session.cacheFile(url: s(args, 0) ?? "", saveTime: i(args, 1) ?? 0)
        }
        d("webSocket") { [unowned self] args in
            do {
                session.webSocketAudio = try JSWebSocketCall(runtime: runtime).run(args.first)
                session.webSocketError = nil
                return JSWebSocketCall.resultMarker
            } catch {
                session.webSocketAudio = nil
                session.webSocketError = error
                throw error
            }
        }
        d("importScript") { [unowned self] args in
            let path = s(args, 0) ?? ""
            guard path.isAbsUrl else { throw RuleError.message("importScript 仅支持网络地址：\(path)") }
            let code = try session.cacheFile(url: path, saveTime: 0)
            if code.isBlank { throw RuleError.message("\(path) 内容获取失败或者为空") }
            return code
        }

        // 浏览器与界面
        d("webView") { [unowned self] args in
            try session.env.ui.renderWebView(
                WebViewRequest(html: s(args, 0), url: s(args, 1), js: s(args, 2), sourceKey: session.source.key,
                               headers: (try? session.headerMap(hasLoginHeader: true)) ?? [:])
            )
        }
        d("webViewGetSource") { [unowned self] args in
            try session.env.ui.renderWebView(
                WebViewRequest(html: s(args, 0), url: s(args, 1), js: s(args, 2), sourceKey: session.source.key,
                               headers: (try? session.headerMap(hasLoginHeader: true)) ?? [:], sourceRegex: s(args, 3))
            )
        }
        d("startBrowser") { [unowned self] args in
            session.env.ui.startBrowser(url: s(args, 0) ?? "", title: s(args, 1) ?? "", html: s(args, 2), sourceKey: session.source.key)
            return nil
        }
        d("startBrowserDp") { [unowned self] args in
            session.env.ui.startBrowser(url: s(args, 0) ?? "", title: s(args, 1) ?? "", html: nil, sourceKey: session.source.key)
            return nil
        }
        d("showReadingBrowser") { [unowned self] args in
            session.env.ui.showBrowser(BrowserSheet(url: s(args, 0) ?? "", title: s(args, 1), html: nil, js: nil, optionsJSON: nil,
                                                    sourceKey: session.source.key))
            return nil
        }
        d("showBrowser") { [unowned self] args in
            // showBrowser(url, html, js, options)
            session.env.ui.showBrowser(BrowserSheet(url: s(args, 0) ?? "", title: nil, html: s(args, 1), js: s(args, 2),
                                                    optionsJSON: s(args, 3), sourceKey: session.source.key))
            return nil
        }
        d("startBrowserAwait") { [unowned self] args in
            let url = s(args, 0) ?? ""
            let result = try session.env.ui.startBrowserAwait(url: url, title: s(args, 1) ?? "", html: s(args, 3),
                                                              sourceKey: session.source.key)
            return JSResponse(url: result.url, body: result.body)
        }
        d("getVerificationCode") { [unowned self] args in
            try session.env.ui.verificationCode(imageURL: s(args, 0) ?? "", sourceKey: session.source.key)
        }
        d("toast") { [unowned self] args in
            session.env.ui.toast(s(args, 0) ?? "", long: false)
            return nil
        }
        d("longToast") { [unowned self] args in
            session.env.ui.toast(s(args, 0) ?? "", long: true)
            return nil
        }
        d("log") { [unowned self] args in
            let message = s(args, 0) ?? "null"
            session.env.log(session.source.key, message)
            return message
        }
        d("logType") { [unowned self] args in
            let v = Self.arg(args, 0)
            let type: String
            if v == nil { type = "null" } else if v!.isArray { type = "Array" } else if v!.isString { type = "String" }
            else if v!.isNumber { type = "Number" } else if v!.isBoolean { type = "Boolean" }
            else { type = (v!.toObject().map { String(describing: Swift.type(of: $0)) }) ?? "Object" }
            session.env.log(session.source.key, type)
            return nil
        }
        d("refreshExplore") { [unowned self] _ in
            session.env.notify(.refreshExplore(sourceKey: session.source.key))
            return nil
        }
        d("searchBook") { [unowned self] args in
            session.env.notify(.searchBook(key: s(args, 0) ?? "", sourceKey: session.source.key))
            return nil
        }
        d("open") { [unowned self] args in
            session.env.notify(.open(name: s(args, 0) ?? "", url: s(args, 1), title: s(args, 2), sourceKey: session.source.key))
            return nil
        }

        // 解析器
        d("put") { [unowned self] args in
            let key = s(args, 0) ?? "", value = s(args, 1) ?? ""
            if let host { return host.jsPut(key, value) }
            session.sourcePut(key, value)
            return value
        }
        d("getString") { [unowned self] args in
            guard let host else { throw RuleError.message("当前上下文不支持 getString") }
            let (content, isUrl) = Self.contentArgs(args)
            return try host.jsGetString(s(args, 0) ?? "", content: content, isUrl: isUrl)
        }
        d("getStringList") { [unowned self] args in
            guard let host else { throw RuleError.message("当前上下文不支持 getStringList") }
            let (content, isUrl) = Self.contentArgs(args)
            return try host.jsGetStringList(s(args, 0) ?? "", content: content, isUrl: isUrl)
        }
        d("getElement") { [unowned self] args in
            guard let host else { throw RuleError.message("当前上下文不支持 getElement") }
            return try host.jsGetElement(s(args, 0) ?? "")
        }
        d("getElements") { [unowned self] args in
            guard let host else { throw RuleError.message("当前上下文不支持 getElements") }
            return try host.jsGetElements(s(args, 0) ?? "")
        }
        d("setContent") { [unowned self] args in
            guard let host else { throw RuleError.message("当前上下文不支持 setContent") }
            try host.jsSetContent(Self.arg(args, 0).flatMap { JSRuntime.fromJS($0) }, baseUrl: s(args, 1))
            return nil
        }
        d("getSource") { [unowned self] _ in context.objectForKeyedSubscript("source") }
        d("getTag") { [unowned self] _ in session.source.name }

        // 编码
        d("base64Encode") { args in
            guard let text = s(args, 0) else { return nil }
            return Base64Codec.encode(Data(text.utf8), flags: i(args, 1) ?? Base64Codec.noWrap)
        }
        d("base64Decode") { args in
            guard let text = s(args, 0), let data = Base64Codec.decode(text) else { return "" }
            if let second = Self.arg(args, 1), second.isString {
                return String(data: data, encoding: Self.encoding(second.toString())) ?? ""
            }
            return String(decoding: data, as: UTF8.self)
        }
        d("base64DecodeToByteArray") { args in
            guard let text = s(args, 0), !text.isBlank, let data = Base64Codec.decode(text) else { return nil }
            return Self.byteArray(data)
        }
        d("hexDecodeToString") { args in
            guard let hex = s(args, 0), let data = Hex.decode(hex) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        d("hexDecodeToByteArray") { args in
            guard let hex = s(args, 0), let data = Hex.decode(hex) else { return nil }
            return Self.byteArray(data)
        }
        d("hexEncodeToString") { args in
            Hex.encode(Data((s(args, 0) ?? "").utf8))
        }
        d("strToBytes") { args in
            let text = s(args, 0) ?? ""
            return Self.byteArray(text.data(using: Self.encoding(s(args, 1)), allowLossyConversion: true) ?? Data())
        }
        d("bytesToStr") { args in
            let data = b(args, 0) ?? Data()
            return String(data: data, encoding: Self.encoding(s(args, 1))) ?? String(decoding: data, as: UTF8.self)
        }
        d("utf8ToGbk") { args in
            let text = s(args, 0) ?? ""
            let data = text.data(using: Charsets.gb18030, allowLossyConversion: true) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        d("encodeURI") { args in
            Charsets.urlEncode(s(args, 0) ?? "", charset: s(args, 1) ?? "UTF-8")
        }
        d("md5Encode") { args in
            Hex.encode(Digests.digest("MD5", Data((s(args, 0) ?? "").utf8)) ?? Data())
        }
        d("md5Encode16") { args in
            let hex = Hex.encode(Digests.digest("MD5", Data((s(args, 0) ?? "").utf8)) ?? Data())
            return String(hex.dropFirst(8).prefix(16))
        }
        d("digestHex") { args in
            guard let out = Digests.digest(s(args, 1) ?? "MD5", Data((s(args, 0) ?? "").utf8)) else {
                throw CryptoError.unsupported(s(args, 1) ?? "")
            }
            return Hex.encode(out)
        }
        d("digestBase64Str") { args in
            guard let out = Digests.digest(s(args, 1) ?? "MD5", Data((s(args, 0) ?? "").utf8)) else {
                throw CryptoError.unsupported(s(args, 1) ?? "")
            }
            return Base64Codec.encode(out)
        }
        d("HMacHex") { args in
            guard let out = Digests.hmac(s(args, 1) ?? "", key: Data((s(args, 2) ?? "").utf8), data: Data((s(args, 0) ?? "").utf8)) else {
                throw CryptoError.unsupported(s(args, 1) ?? "")
            }
            return Hex.encode(out)
        }
        d("HMacBase64") { args in
            guard let out = Digests.hmac(s(args, 1) ?? "", key: Data((s(args, 2) ?? "").utf8), data: Data((s(args, 0) ?? "").utf8)) else {
                throw CryptoError.unsupported(s(args, 1) ?? "")
            }
            return Base64Codec.encode(out)
        }
        d("createSymmetricCrypto") { args in
            guard let key = b(args, 1) else { throw CryptoError.invalidKey("缺少密钥") }
            return JSSymmetricCrypto(transformation: s(args, 0) ?? "AES", key: key, iv: b(args, 2))
        }
        for (name, transformationIndex, defaultTransformation, output) in Self.legacyCiphers {
            d(name) { args in
                let transformation = (transformationIndex.flatMap { s(args, $0) }) ?? defaultTransformation
                let crypto = JSSymmetricCrypto(transformation: transformation, key: b(args, 1) ?? Data(), iv: b(args, 3))
                return try output(crypto, s(args, 0) ?? "")
            }
        }

        // 其它
        d("randomUUID") { _ in UUID().uuidString.lowercased() }
        d("deviceID") { [unowned self] _ in session.env.deviceID }
        d("androidId") { [unowned self] _ in session.env.androidID }
        d("getWebViewUA") { [unowned self] _ in session.env.webViewUserAgent }
        d("timeFormat") { args in
            let ms = Self.arg(args, 0)?.toDouble() ?? 0
            return Self.formatDate(ms, pattern: "yyyy/MM/dd HH:mm", offsetMillis: nil)
        }
        d("timeFormatUTC") { args in
            let ms = Self.arg(args, 0)?.toDouble() ?? 0
            return Self.formatDate(ms, pattern: s(args, 1) ?? "yyyy-MM-dd HH:mm:ss", offsetMillis: i(args, 2) ?? 0)
        }
        d("htmlFormat") { args in HTMLFormatter.formatKeepImg(s(args, 0)) }
        d("t2s") { args in (s(args, 0) ?? "").applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? "" }
        d("s2t") { args in (s(args, 0) ?? "").applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? "" }
        d("toNumChapter") { args in ChineseNumber.toNumChapter(s(args, 0)) }
        d("reGetBook") { _ in nil }
        d("refreshTocUrl") { _ in nil }

        // 3DES（Legado JsEncodeUtils）：key、iv 按 UTF-8 取字节，ArgsBase64 版本两者为 Base64
        d("tripleDESDecodeStr") { args in try Self.tripleDES(args, base64Args: false).decryptString(s(args, 0) ?? "") }
        d("tripleDESDecodeArgsBase64Str") { args in try Self.tripleDES(args, base64Args: true).decryptString(s(args, 0) ?? "") }
        d("tripleDESEncodeBase64Str") { args in
            Base64Codec.encode(try Self.tripleDES(args, base64Args: false).encryptData(Data((s(args, 0) ?? "").utf8)))
        }
        d("tripleDESEncodeArgsBase64Str") { args in
            Base64Codec.encode(try Self.tripleDES(args, base64Args: true).encryptData(Data((s(args, 0) ?? "").utf8)))
        }

        // 界面
        d("copyText") { [unowned self] args in
            session.env.ui.copyText(s(args, 0) ?? "")
            return nil
        }
        d("openUrl") { [unowned self] args in
            session.env.ui.openURL(s(args, 0) ?? "", mimeType: s(args, 1), sourceKey: session.source.key)
            return nil
        }
        d("openVideoPlayer") { [unowned self] args in
            session.env.ui.openVideoPlayer(url: s(args, 0) ?? "", title: s(args, 1), floating: Self.arg(args, 2)?.toBool() ?? false,
                                           sourceKey: session.source.key)
            return nil
        }
        d("addBook") { [unowned self] args in
            guard let url = s(args, 0), !url.isBlank else { return nil }
            session.env.notify(.addBook(bookUrl: url, sourceKey: session.source.key))
            return nil
        }
        for name in ["refreshContent", "refreshcontent"] {
            d(name) { [unowned self] _ in
                session.env.notify(.refreshContent(sourceKey: session.source.key))
                return nil
            }
        }
        return java
    }

    private static func tripleDES(_ args: [JSValue], base64Args: Bool) -> JSSymmetricCrypto {
        let keyText = str(args, 1) ?? "", ivText = str(args, 4) ?? ""
        let key = base64Args ? Base64Codec.decode(keyText) ?? Data() : Data(keyText.utf8)
        let iv = base64Args ? Base64Codec.decode(ivText) ?? Data() : Data(ivText.utf8)
        let transformation = "DESede/\(str(args, 2) ?? "ECB")/\(str(args, 3) ?? "PKCS5Padding")"
        return JSSymmetricCrypto(transformation: transformation, key: key, iv: iv)
    }

    // MARK: - 登录界面扩展（Legado SourceLoginJsExtensions）

    private var loginDepth = 0
    private static let loginExtensionNames = ["reLoginView", "upLoginData"]

    func enterLoginContext() {
        loginDepth += 1
        guard loginDepth == 1, let java = context.objectForKeyedSubscript("java"), java.isObject else { return }
        Self.define(java, "reLoginView") { [unowned self] _ in
            session.env.notify(.reLoginView(sourceKey: session.source.key))
            return nil
        }
        Self.define(java, "upLoginData") { [unowned self] args in
            guard let value = Self.arg(args, 0) else { return nil }
            var data: [String: String?] = [:]
            if let dict = JSRuntime.fromJS(value) as? [String: Any] {
                for (k, v) in dict { data[k] = v is NSNull ? nil : RuleValue.jsString(v) }
            } else if let text = JSRuntime.stringArgument(value), let map = LenientJSON.stringMap(text) {
                data = map.mapValues { Optional($0) }
            }
            guard !data.isEmpty else { return nil }
            let changed = session.mergeLoginInfo(data)
            session.env.notify(.upLoginData(data: changed, sourceKey: session.source.key))
            return nil
        }
    }

    func leaveLoginContext() {
        loginDepth -= 1
        guard loginDepth == 0, let java = context.objectForKeyedSubscript("java"), java.isObject else { return }
        for name in Self.loginExtensionNames { java.deleteProperty(name) }
    }

    /// 兼容旧版 `java.aesXxx`/`java.desXxx` 加解密函数
    private static var legacyCiphers: [(String, Int?, String, (JSSymmetricCrypto, String) throws -> Any?)] { [
        ("aesDecodeToString", 2, "AES/ECB/PKCS5Padding", { try $0.decryptString($1) }),
        ("aesBase64DecodeToString", 2, "AES/ECB/PKCS5Padding", { try $0.decryptString($1) }),
        ("aesDecodeToByteArray", 2, "AES/ECB/PKCS5Padding", { byteArray(try $0.decryptData($1)) }),
        ("aesBase64DecodeToByteArray", 2, "AES/ECB/PKCS5Padding", { byteArray(try $0.decryptData($1)) }),
        ("aesEncodeToString", 2, "AES/ECB/PKCS5Padding", { String(decoding: try $0.encryptData(Data($1.utf8)), as: UTF8.self) }),
        ("aesEncodeToBase64String", 2, "AES/ECB/PKCS5Padding", { Base64Codec.encode(try $0.encryptData(Data($1.utf8))) }),
        ("aesEncodeToByteArray", 2, "AES/ECB/PKCS5Padding", { byteArray(try $0.encryptData(Data($1.utf8))) }),
        ("aesEncodeToBase64ByteArray", 2, "AES/ECB/PKCS5Padding", { byteArray(Data(Base64Codec.encode(try $0.encryptData(Data($1.utf8))).utf8)) }),
        ("desDecodeToString", 2, "DES/ECB/PKCS5Padding", { try $0.decryptString($1) }),
        ("desBase64DecodeToString", 2, "DES/ECB/PKCS5Padding", { try $0.decryptString($1) }),
        ("desEncodeToString", 2, "DES/ECB/PKCS5Padding", { String(decoding: try $0.encryptData(Data($1.utf8)), as: UTF8.self) }),
        ("desEncodeToBase64String", 2, "DES/ECB/PKCS5Padding", { Base64Codec.encode(try $0.encryptData(Data($1.utf8))) }),
    ] }

    /// `getString(rule)` / `getString(rule, isUrl)` / `getString(rule, content, isUrl)`
    private static func contentArgs(_ args: [JSValue]) -> (Any?, Bool) {
        guard let second = arg(args, 1) else {
            return (nil, arg(args, 2)?.toBool() ?? false)
        }
        if second.isBoolean { return (nil, second.toBool()) }
        return (JSRuntime.fromJS(second), arg(args, 2)?.toBool() ?? false)
    }

    private static func formatDate(_ ms: Double, pattern: String, offsetMillis: Int?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = pattern
        if let offsetMillis {
            formatter.timeZone = TimeZone(secondsFromGMT: offsetMillis / 1000)
        }
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // MARK: - __native（供 Packages 垫片使用）

    func installNativeHelpers() {
        let native = JSValue(newObjectIn: context)!
        let d = { (name: String, body: @escaping Body) in Self.define(native, name, body) }
        let s = Self.str, i = Self.int, b = Self.bytes

        d("strToBytes") { args in
            Self.byteArray((s(args, 0) ?? "").data(using: Self.encoding(s(args, 1)), allowLossyConversion: true) ?? Data())
        }
        d("bytesToStr") { args in
            let data = b(args, 0) ?? Data()
            return String(data: data, encoding: Self.encoding(s(args, 1))) ?? String(decoding: data, as: UTF8.self)
        }
        d("sleep") { args in
            let ms = min(i(args, 0) ?? 0, 30_000)
            if ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
            return nil
        }
        d("cipher") { args in
            let encrypt = (i(args, 1) ?? 1) == 1
            let out = try SymmetricCipher.crypt(
                s(args, 0) ?? "AES", encrypt: encrypt, key: b(args, 2) ?? Data(), iv: b(args, 3),
                data: b(args, 6) ?? Data(), tagLength: (i(args, 4) ?? 128) / 8, aad: b(args, 5) ?? Data()
            )
            return Self.byteArray(out)
        }
        d("digest") { args in
            guard let out = Digests.digest(s(args, 0) ?? "", b(args, 1) ?? Data()) else {
                throw CryptoError.unsupported(s(args, 0) ?? "")
            }
            return Self.byteArray(out)
        }
        d("hmac") { args in
            guard let out = Digests.hmac(s(args, 0) ?? "", key: b(args, 1) ?? Data(), data: b(args, 2) ?? Data()) else {
                throw CryptoError.unsupported(s(args, 0) ?? "")
            }
            return Self.byteArray(out)
        }
        d("base64Encode") { args in Base64Codec.encode(b(args, 0) ?? Data(), flags: i(args, 1) ?? 0) }
        d("base64Decode") { args in
            guard let data = Base64Codec.decode(s(args, 0) ?? "") else { throw RuleError.message("bad base-64") }
            return Self.byteArray(data)
        }
        d("urlEncode") { args in Charsets.urlEncode(s(args, 0) ?? "", charset: s(args, 1)) }
        d("urlDecode") { args in Charsets.urlDecode(s(args, 0) ?? "", charset: s(args, 1)) }
        d("resolveURL") { args in URLUtils.absoluteURL(base: s(args, 0), relative: s(args, 1) ?? "") }
        d("topPrivateDomain") { args in
            let host = s(args, 0) ?? ""
            return URLUtils.isIPAddress(host) ? NSNull() : URLUtils.registrableDomain(host)
        }
        d("parseURL") { args in
            guard let url = s(args, 0), let parts = URLUtils.parse(url) else { return NSNull() }
            var host = parts.authority
            var port = -1
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"), let p = Int(host[host.index(after: colon)...]) {
                port = p
                host = String(host[..<colon])
            }
            var out: [String: Any] = [
                "protocol": parts.scheme.lowercased(), "host": host, "port": port,
                "path": parts.path, "authority": parts.authority,
            ]
            out["query"] = parts.query ?? NSNull()
            out["ref"] = parts.fragment ?? NSNull()
            return out
        }
        d("jsoupParse") { args in
            let html = s(args, 0) ?? ""
            let doc = (try? SwiftSoup.parse(html, s(args, 1) ?? "")) ?? Document("")
            return JSElement(doc)
        }
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }
}

// MARK: - 对称加密对象（hutool SymmetricCrypto 风格）

@objc protocol JSSymmetricCryptoExports: JSExport {
    func setIv(_ iv: JSValue) -> JSSymmetricCrypto
    func encrypt(_ data: JSValue) -> JSValue
    func encryptBase64(_ data: JSValue) -> String
    func encryptHex(_ data: JSValue) -> String
    func decrypt(_ data: JSValue) -> JSValue
    func decryptStr(_ data: JSValue) -> String
}

final class JSSymmetricCrypto: NSObject, JSSymmetricCryptoExports {
    let transformation: String
    let key: Data
    var iv: Data?

    init(transformation: String, key: Data, iv: Data?) {
        self.transformation = transformation
        self.key = key
        self.iv = iv.flatMap { $0.isEmpty ? nil : $0 }
    }

    func encryptData(_ data: Data) throws -> Data {
        try SymmetricCipher.crypt(transformation, encrypt: true, key: key, iv: iv, data: data)
    }

    /// 字符串密文自动识别 Hex 或 Base64
    func decryptData(_ text: String) throws -> Data {
        let trimmed = text.trimmedWhitespace
        let raw: Data?
        if Hex.isHex(trimmed), trimmed.count % 2 == 0 {
            raw = Hex.decode(trimmed)
        } else {
            raw = Base64Codec.decode(trimmed)
        }
        guard let raw else { throw CryptoError.failed("密文既不是 Hex 也不是 Base64") }
        return try SymmetricCipher.crypt(transformation, encrypt: false, key: key, iv: iv, data: raw)
    }

    func decryptString(_ text: String) throws -> String {
        String(decoding: try decryptData(text), as: UTF8.self)
    }

    private func input(_ value: JSValue) -> Data {
        JSRuntime.bytesArgument(value) ?? Data()
    }

    private func perform<T>(_ fallback: T, _ body: () throws -> T) -> T {
        do { return try body() } catch {
            JSRuntime.throwError(error)
            return fallback
        }
    }

    func setIv(_ iv: JSValue) -> JSSymmetricCrypto {
        self.iv = JSRuntime.bytesArgument(iv)
        return self
    }

    func encrypt(_ data: JSValue) -> JSValue {
        let ctx = JSContext.current()!
        let out = perform(Data()) { try encryptData(input(data)) }
        return JSValue(object: out.map { NSNumber(value: Int8(bitPattern: $0)) }, in: ctx)
    }

    func encryptBase64(_ data: JSValue) -> String {
        perform("") { Base64Codec.encode(try encryptData(input(data))) }
    }

    func encryptHex(_ data: JSValue) -> String {
        perform("") { Hex.encode(try encryptData(input(data))) }
    }

    func decrypt(_ data: JSValue) -> JSValue {
        let ctx = JSContext.current()!
        let out: Data = perform(Data()) {
            if data.isString { return try decryptData(data.toString()) }
            return try SymmetricCipher.crypt(transformation, encrypt: false, key: key, iv: iv, data: input(data))
        }
        return JSValue(object: out.map { NSNumber(value: Int8(bitPattern: $0)) }, in: ctx)
    }

    func decryptStr(_ data: JSValue) -> String {
        perform("") {
            if data.isString { return try decryptString(data.toString()) }
            let out = try SymmetricCipher.crypt(transformation, encrypt: false, key: key, iv: iv, data: input(data))
            return String(decoding: out, as: UTF8.self)
        }
    }
}

// MARK: - 中文数字

enum ChineseNumber {
    private static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "壹": 1, "二": 2, "贰": 2, "两": 2, "三": 3, "叁": 3, "四": 4, "肆": 4,
        "五": 5, "伍": 5, "六": 6, "陆": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9,
    ]
    private static let units: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000]

    static func toInt(_ text: String) -> Int? {
        let halfWidth = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        if let n = Int(halfWidth.trimmedWhitespace) { return n }
        var total = 0, section = 0, number = 0
        var matched = false
        for ch in text {
            if let d = digits[ch] {
                number = d
                matched = true
            } else if let u = units[ch] {
                section += (number == 0 && u == 10 ? 1 : number) * u
                number = 0
                matched = true
            } else if ch == "万" || ch == "萬" {
                total += (section + number) * 10_000
                section = 0
                number = 0
                matched = true
            } else if ch == "亿" {
                total = (total + section + number) * 100_000_000
                section = 0
                number = 0
                matched = true
            } else {
                return nil
            }
        }
        return matched ? total + section + number : nil
    }

    static func toNumChapter(_ text: String?) -> String? {
        guard let text else { return nil }
        guard let m = text.firstMatch("(第)(.+?)(章)"),
              let numText = text.group(m, 2), let n = toInt(numText) else { return text }
        return "第\(n)章"
    }
}

#endif  // #if canImport(JavaScriptCore) && !os(Linux)
