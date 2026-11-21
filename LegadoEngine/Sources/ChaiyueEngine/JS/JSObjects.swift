#if canImport(JavaScriptCore) && !os(Linux)
import Foundation
import JavaScriptCore
import ChaiyueModels
import SwiftSoup

// MARK: - book

@objc protocol JSBookExports: JSExport {
    var name: String { get set }
    var author: String { get set }
    var bookUrl: String { get set }
    var tocUrl: String { get set }
    var origin: String { get }
    var originName: String { get }
    var coverUrl: String? { get set }
    var customCoverUrl: String? { get set }
    var intro: String? { get set }
    var customIntro: String? { get set }
    var kind: String? { get set }
    var wordCount: String? { get set }
    var latestChapterTitle: String? { get set }
    var durChapterTitle: String? { get set }
    var durChapterIndex: Int { get set }
    var durChapterPos: Int { get set }
    var totalChapterNum: Int { get set }
    var type: Int { get set }
    var order: Int { get set }
    var charset: String? { get set }
    var variable: String? { get set }
    var infoHtml: String? { get }
    var tocHtml: String? { get }
    var readConfig: NSDictionary? { get }

    func getVariable(_ key: JSValue) -> String
    func putVariable(_ key: String, _ value: JSValue) -> Bool
    func getCustomVariable() -> String
    func putCustomVariable(_ value: JSValue)
    func setUseReplaceRule(_ use: Bool)
    func getUseReplaceRule() -> Bool
    func getReverseToc() -> Bool
    func toString() -> String
}

final class JSBook: NSObject, JSBookExports {
    let ref: BookRef

    init(_ ref: BookRef) { self.ref = ref }

    var name: String { get { ref.book.name } set { ref.book.name = newValue } }
    var author: String { get { ref.book.author } set { ref.book.author = newValue } }
    var bookUrl: String { get { ref.book.bookUrl } set { ref.book.bookUrl = newValue } }
    var tocUrl: String { get { ref.book.tocUrl } set { ref.book.tocUrl = newValue } }
    var origin: String { ref.book.origin }
    var originName: String { ref.book.originName }
    var coverUrl: String? { get { ref.book.coverUrl } set { ref.book.coverUrl = newValue } }
    var customCoverUrl: String? { get { ref.book.customCoverUrl } set { ref.book.customCoverUrl = newValue } }
    var intro: String? { get { ref.book.intro } set { ref.book.intro = newValue } }
    var customIntro: String? { get { ref.book.customIntro } set { ref.book.customIntro = newValue } }
    var kind: String? { get { ref.book.kind } set { ref.book.kind = newValue } }
    var wordCount: String? { get { ref.book.wordCount } set { ref.book.wordCount = newValue } }
    var latestChapterTitle: String? { get { ref.book.latestChapterTitle } set { ref.book.latestChapterTitle = newValue } }
    var durChapterTitle: String? { get { ref.book.durChapterTitle } set { ref.book.durChapterTitle = newValue } }
    var durChapterIndex: Int { get { ref.book.durChapterIndex } set { ref.book.durChapterIndex = newValue } }
    var durChapterPos: Int { get { ref.book.durChapterPos } set { ref.book.durChapterPos = newValue } }
    var totalChapterNum: Int { get { ref.book.totalChapterNum } set { ref.book.totalChapterNum = newValue } }
    var type: Int { get { ref.book.type } set { ref.book.type = newValue } }
    var order: Int { get { ref.book.order } set { ref.book.order = newValue } }
    var charset: String? { get { ref.book.charset } set { ref.book.charset = newValue } }
    var variable: String? { get { ref.book.variable } set { ref.book.variable = newValue } }
    var infoHtml: String? { ref.book.infoHtml }
    var tocHtml: String? { ref.book.tocHtml }

    var readConfig: NSDictionary? {
        guard let config = ref.book.readConfig,
              let data = try? JSONEncoder().encode(config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else { return nil }
        return obj
    }

    func getVariable(_ key: JSValue) -> String {
        // 无参数时与 Rhino 访问 Kotlin 属性 variable 一致，返回全部变量的 JSON
        if key.isUndefined || key.isNull { return ref.book.variable ?? "" }
        return ref.getVariable(key.toString())
    }

    func putVariable(_ key: String, _ value: JSValue) -> Bool {
        ref.putVariable(key, value.isUndefined || value.isNull ? nil : value.toString())
        return true
    }

    func getCustomVariable() -> String { ref.getVariable("custom") }

    func putCustomVariable(_ value: JSValue) {
        ref.putVariable("custom", value.isUndefined || value.isNull ? nil : value.toString())
    }

    func setUseReplaceRule(_ use: Bool) {
        var config = ref.book.readConfig ?? BookReadConfig()
        config.useReplaceRule = use
        ref.book.readConfig = config
    }

    func getUseReplaceRule() -> Bool { ref.book.readConfig?.useReplaceRule ?? true }

    func getReverseToc() -> Bool { ref.book.readConfig?.reverseToc ?? false }

    func toString() -> String { "Book(\(ref.book.name), \(ref.book.bookUrl))" }
}

// MARK: - chapter

@objc protocol JSChapterExports: JSExport {
    var title: String { get set }
    var url: String { get set }
    var baseUrl: String { get }
    var bookUrl: String { get }
    var index: Int { get set }
    var isVolume: Bool { get set }
    var isVip: Bool { get set }
    var isPay: Bool { get set }
    var tag: String? { get set }
    var resourceUrl: String? { get set }
    var wordCount: String? { get set }
    var variable: String? { get set }

    func getVariable(_ key: JSValue) -> String
    func putVariable(_ key: String, _ value: JSValue) -> Bool
    func getAbsoluteURL() -> String
    func toString() -> String
}

final class JSChapter: NSObject, JSChapterExports {
    let ref: ChapterRef

    init(_ ref: ChapterRef) { self.ref = ref }

    var title: String { get { ref.chapter.title } set { ref.chapter.title = newValue } }
    var url: String { get { ref.chapter.url } set { ref.chapter.url = newValue } }
    var baseUrl: String { ref.chapter.baseUrl }
    var bookUrl: String { ref.chapter.bookUrl }
    var index: Int { get { ref.chapter.index } set { ref.chapter.index = newValue } }
    var isVolume: Bool { get { ref.chapter.isVolume } set { ref.chapter.isVolume = newValue } }
    var isVip: Bool { get { ref.chapter.isVip } set { ref.chapter.isVip = newValue } }
    var isPay: Bool { get { ref.chapter.isPay } set { ref.chapter.isPay = newValue } }
    var tag: String? { get { ref.chapter.tag } set { ref.chapter.tag = newValue } }
    var resourceUrl: String? { get { ref.chapter.resourceUrl } set { ref.chapter.resourceUrl = newValue } }
    var wordCount: String? { get { ref.chapter.wordCount } set { ref.chapter.wordCount = newValue } }
    var variable: String? { get { ref.chapter.variable } set { ref.chapter.variable = newValue } }

    func getVariable(_ key: JSValue) -> String {
        if key.isUndefined || key.isNull { return ref.chapter.variable ?? "" }
        return ref.getVariable(key.toString())
    }

    func putVariable(_ key: String, _ value: JSValue) -> Bool {
        ref.putVariable(key, value.isUndefined || value.isNull ? nil : value.toString())
        return true
    }

    func getAbsoluteURL() -> String { ref.chapter.absoluteURL }

    func toString() -> String { "BookChapter(\(ref.chapter.title), \(ref.chapter.url))" }
}

// MARK: - source

@objc protocol JSSourceExports: JSExport {
    var bookSourceUrl: String { get }
    var bookSourceName: String { get }
    var bookSourceGroup: String? { get }
    var bookSourceType: Int { get }
    var loginUrl: String? { get }
    var loginUi: String? { get }
    var header: String? { get }
    var jsLib: String? { get }
    var searchUrl: String? { get }
    var exploreUrl: String? { get }
    var concurrentRate: String? { get }
    var enabledCookieJar: Bool { get }
    var variableComment: String? { get }
    var bookSourceComment: String? { get }

    func getKey() -> String
    func getTag() -> String
    func getVariable() -> String
    func setVariable(_ value: JSValue)
    func put(_ key: String, _ value: JSValue) -> String
    func get(_ key: String) -> String
    func getLoginInfo() -> JSValue
    func getLoginInfoMap() -> JSValue
    func putLoginInfo(_ info: JSValue) -> Bool
    func removeLoginInfo()
    func getLoginHeader() -> JSValue
    func getLoginHeaderMap() -> JSValue
    func putLoginHeader(_ header: JSValue)
    func removeLoginHeader()
    func getLoginJs() -> String
    func login()
    func getHeaderMap(_ hasLoginHeader: JSValue) -> JSValue
    func refreshExplore()
    func refreshJSLib()
    func putConcurrent(_ rate: JSValue)
}

final class JSSource: NSObject, JSSourceExports {
    unowned let session: RuleSession

    init(_ session: RuleSession) { self.session = session }

    private var source: SourceDescriptor { session.source }

    var bookSourceUrl: String { source.key }
    var bookSourceName: String { source.name }
    var bookSourceGroup: String? { source.bookSource?.bookSourceGroup }
    var bookSourceType: Int { source.bookSource?.bookSourceType ?? 0 }
    var loginUrl: String? { source.loginUrl }
    var loginUi: String? { source.loginUi }
    var header: String? { source.header }
    var jsLib: String? { source.jsLib }
    var searchUrl: String? { source.bookSource?.searchUrl }
    var exploreUrl: String? { source.bookSource?.exploreUrl }
    var concurrentRate: String? { source.concurrentRate }
    var enabledCookieJar: Bool { source.enabledCookieJar }
    var variableComment: String? { source.bookSource?.variableComment }
    var bookSourceComment: String? { source.bookSource?.bookSourceComment }

    func getKey() -> String { source.key }
    func getTag() -> String { source.name }
    func getVariable() -> String { session.state.variable ?? "" }

    func setVariable(_ value: JSValue) {
        session.state.variable = value.isUndefined || value.isNull ? nil : value.toString()
    }

    func put(_ key: String, _ value: JSValue) -> String {
        let v = value.toString() ?? ""
        session.sourcePut(key, v)
        return v
    }

    func get(_ key: String) -> String { session.sourceGet(key) }

    func getLoginInfo() -> JSValue {
        let ctx = JSContext.current()!
        guard let info = session.state.loginInfo else { return JSValue(nullIn: ctx) }
        return JSValue(object: info, in: ctx)
    }

    func getLoginInfoMap() -> JSValue {
        let ctx = JSContext.current()!
        return JSRuntime.makeJavaMap(session.loginInfoMap(), in: ctx)
    }

    func putLoginInfo(_ info: JSValue) -> Bool {
        session.state.loginInfo = JSRuntime.stringArgument(info)
        return true
    }

    func removeLoginInfo() { session.state.loginInfo = nil }

    func getLoginHeader() -> JSValue {
        let ctx = JSContext.current()!
        guard let header = session.state.loginHeader else { return JSValue(nullIn: ctx) }
        return JSValue(object: header, in: ctx)
    }

    func getLoginHeaderMap() -> JSValue {
        let ctx = JSContext.current()!
        guard let header = session.state.loginHeader, let map = LenientJSON.stringMap(header) else {
            return JSValue(nullIn: ctx)
        }
        return JSRuntime.makeJavaMap(map, in: ctx)
    }

    func putLoginHeader(_ header: JSValue) {
        guard let text = JSRuntime.stringArgument(header) else { return }
        session.state.loginHeader = text
        // 与 Legado 一致：登录头里的 Cookie 同步写入 Cookie 存储
        if let map = LenientJSON.stringMap(text) {
            let cookie = map.first { $0.key.lowercased() == "cookie" }?.value
            if let cookie, !cookie.isEmpty {
                session.env.cookies.replaceCookie(url: source.key, cookie: cookie)
            }
        }
    }

    func removeLoginHeader() { session.state.loginHeader = nil }

    func getLoginJs() -> String { source.loginJs ?? "" }

    func login() {
        do {
            try session.runLogin()
        } catch {
            JSRuntime.throwError(error)
        }
    }

    func getHeaderMap(_ hasLoginHeader: JSValue) -> JSValue {
        let ctx = JSContext.current()!
        let withLogin = hasLoginHeader.isBoolean ? hasLoginHeader.toBool() : false
        let map = (try? session.headerMap(hasLoginHeader: withLogin)) ?? [:]
        return JSRuntime.makeJavaMap(map, in: ctx)
    }

    func refreshExplore() { session.env.notify(.refreshExplore(sourceKey: source.key)) }

    func refreshJSLib() {}

    /// 改版阅读的运行时并发率。书源用它在批量请求后恢复限流，这里不改变书源配置，只记日志
    func putConcurrent(_ rate: JSValue) {
        session.env.log(source.key, "putConcurrent(\(JSRuntime.stringArgument(rate) ?? "")) 已忽略")
    }
}

// MARK: - cookie

@objc protocol JSCookieExports: JSExport {
    func getCookie(_ url: String) -> String
    func getKey(_ url: String, _ key: String) -> String
    func setCookie(_ url: String, _ cookie: JSValue)
    func replaceCookie(_ url: String, _ cookie: JSValue)
    func removeCookie(_ url: String)
    func getCookieNoSession(_ url: String) -> String
}

final class JSCookie: NSObject, JSCookieExports {
    let store: CookieStore

    init(_ store: CookieStore) { self.store = store }

    func getCookie(_ url: String) -> String { store.getCookie(url: url) }
    func getKey(_ url: String, _ key: String) -> String { store.getKey(url: url, key: key) }
    func setCookie(_ url: String, _ cookie: JSValue) { store.setCookie(url: url, cookie: JSRuntime.stringArgument(cookie) ?? "") }
    func replaceCookie(_ url: String, _ cookie: JSValue) { store.replaceCookie(url: url, cookie: JSRuntime.stringArgument(cookie) ?? "") }
    func removeCookie(_ url: String) { store.removeCookie(url: url) }
    func getCookieNoSession(_ url: String) -> String { store.getCookie(url: url) }
}

// MARK: - cache

@objc protocol JSCacheExports: JSExport {
    func put(_ key: String, _ value: JSValue, _ saveTime: JSValue)
    func get(_ key: String) -> JSValue
    func delete(_ key: String)
    func putFile(_ key: String, _ value: JSValue, _ saveTime: JSValue)
    func getFile(_ key: String) -> JSValue
    func putMemory(_ key: String, _ value: JSValue)
    func getFromMemory(_ key: String) -> JSValue
    func deleteMemory(_ key: String)
}

final class JSCache: NSObject, JSCacheExports {
    let store: CacheStore

    init(_ store: CacheStore) { self.store = store }

    func put(_ key: String, _ value: JSValue, _ saveTime: JSValue) {
        let seconds = saveTime.isNumber ? saveTime.toInt32() : 0
        store.put(key, JSRuntime.stringArgument(value) ?? "", saveTime: Int(seconds))
    }

    func get(_ key: String) -> JSValue {
        let ctx = JSContext.current()!
        guard let v = store.get(key) else { return JSValue(nullIn: ctx) }
        return JSValue(object: v, in: ctx)
    }

    func delete(_ key: String) { store.delete(key) }

    func putFile(_ key: String, _ value: JSValue, _ saveTime: JSValue) { put(key, value, saveTime) }

    func getFile(_ key: String) -> JSValue { get(key) }

    func putMemory(_ key: String, _ value: JSValue) {
        store.putMemory(key, JSRuntime.fromJS(value))
    }

    func getFromMemory(_ key: String) -> JSValue {
        let ctx = JSContext.current()!
        guard let v = store.getFromMemory(key) else { return JSValue(nullIn: ctx) }
        return JSValue(object: JSRuntime.toJSObject(v), in: ctx)
    }

    func deleteMemory(_ key: String) { store.deleteMemory(key) }
}

// MARK: - 元素

@objc protocol JSElementExports: JSExport {
    func select(_ css: String) -> [JSElement]
    func selectFirst(_ css: String) -> JSElement?
    func text() -> String
    func ownText() -> String
    func html() -> String
    func outerHtml() -> String
    func data() -> String
    func attr(_ key: String) -> String
    func hasAttr(_ key: String) -> Bool
    func absUrl(_ key: String) -> String
    func id() -> String
    func tagName() -> String
    func children() -> [JSElement]
    func parent() -> JSElement?
    func getElementsByTag(_ tag: String) -> [JSElement]
    func getElementsByClass(_ name: String) -> [JSElement]
    func getElementById(_ id: String) -> JSElement?
    func remove()
    func toString() -> String
}

final class JSElement: NSObject, JSElementExports {
    let element: Element

    init(_ element: Element) { self.element = element }

    static func wrap(_ list: [Element]) -> [JSElement] { list.map(JSElement.init) }

    func select(_ css: String) -> [JSElement] { Self.wrap((try? element.select(css).array()) ?? []) }
    func selectFirst(_ css: String) -> JSElement? { (try? element.select(css).first()).flatMap { $0 }.map(JSElement.init) }
    func text() -> String { (try? element.text()) ?? "" }
    func ownText() -> String { element.ownText() }
    func html() -> String { (try? element.html()) ?? "" }
    func outerHtml() -> String { (try? element.outerHtml()) ?? "" }
    func data() -> String { element.data() }
    func attr(_ key: String) -> String { (try? element.attr(key)) ?? "" }
    func hasAttr(_ key: String) -> Bool { element.hasAttr(key) }
    func absUrl(_ key: String) -> String { (try? element.absUrl(key)) ?? "" }
    func id() -> String { element.id() }
    func tagName() -> String { element.tagName() }
    func children() -> [JSElement] { Self.wrap(element.children().array()) }
    func parent() -> JSElement? { element.parent().map(JSElement.init) }
    func getElementsByTag(_ tag: String) -> [JSElement] { Self.wrap((try? element.getElementsByTag(tag).array()) ?? []) }
    func getElementsByClass(_ name: String) -> [JSElement] { Self.wrap((try? element.getElementsByClass(name).array()) ?? []) }
    func getElementById(_ id: String) -> JSElement? { (try? element.getElementById(id)).flatMap { $0 }.map(JSElement.init) }
    func remove() { try? element.remove() }
    func toString() -> String { outerHtml() }
}

// MARK: - 响应

@objc protocol JSResponseExports: JSExport {
    func body() -> String
    func url() -> String
    func code() -> Int
    func statusCode() -> Int
    func message() -> String
    func headers() -> NSDictionary
    func header(_ name: String) -> String?
    func cookies() -> NSDictionary
    func raw() -> JSResponse
    func toString() -> String
}

/// `java.connect`/`java.get`/`java.post`/`startBrowserAwait` 等返回的响应对象
final class JSResponse: NSObject, JSResponseExports {
    let responseURL: String
    let responseBody: String
    let status: Int
    let responseHeaders: [String: String]
    /// 二进制响应（如朗读音频）的原始字节；`body()` 是按文本解码的结果
    let bodyData: Data?

    init(url: String, body: String, status: Int = 200, headers: [String: String] = [:], bodyData: Data? = nil) {
        responseURL = url
        responseBody = body
        self.status = status
        responseHeaders = headers
        self.bodyData = bodyData
    }

    func body() -> String { responseBody }
    func url() -> String { responseURL }
    func code() -> Int { status }
    func statusCode() -> Int { status }
    func message() -> String { HTTPURLResponse.localizedString(forStatusCode: status) }
    func headers() -> NSDictionary { responseHeaders as NSDictionary }

    func header(_ name: String) -> String? {
        responseHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func cookies() -> NSDictionary {
        var map: [String: String] = [:]
        for (k, v) in responseHeaders where k.lowercased() == "set-cookie" {
            for part in v.components(separatedBy: "\n") {
                guard let pair = part.split(separator: ";").first, let eq = pair.firstIndex(of: "=") else { continue }
                map[String(pair[..<eq]).trimmedWhitespace] = String(pair[pair.index(after: eq)...]).trimmedWhitespace
            }
        }
        return map as NSDictionary
    }

    func raw() -> JSResponse { self }
    func toString() -> String { responseBody }
}

#endif  // #if canImport(JavaScriptCore) && !os(Linux)
