import Foundation
import ChaiyueModels

/// 登录界面的一行（Legado `RowUi`）
public struct LoginRow: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, password, button, toggle, select
    }

    public var name: String
    public var type: Kind
    public var action: String?
    public var chars: [String]?
    public var defaultValue: String?
    public var style: ExploreKind.Style?
    /// ⭐⭐⭐ **显示名（可选）**（2026-11-21 移植补丁）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么加它**：有些书源把「人话标题」放在 `viewName`（而不是 `name`）⭐⭐⭐
    ///   而 `name` 是技术名（如 `jmModeN`）⇒ ⇒ 宿主直接显示 `name` ⇒ **用户看到的是技术名** ⭐⭐⭐
    ///   ⇒ 症状：「登录面板没有『小说 / 漫画 / 视频』这些按钮」（其实有，只是显示成了 `jmModeN`）⭐⭐⭐
    /// ⚠️ `viewName` 的值通常是**表达式**（如 `jmModeLabel('漫画')`）⇒ **要由宿主求值**才能拿到人话名 ⭐⭐⭐
    public var viewName: String?

    enum CodingKeys: String, CodingKey {
        case name, type, action, chars, style, viewName
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(Kind.self, forKey: .type)) ?? .text
        action = try? c.decode(String.self, forKey: .action)
        chars = try? c.decode([String].self, forKey: .chars)
        defaultValue = try? c.decode(String.self, forKey: .defaultValue)
        style = try? c.decode(ExploreKind.Style.self, forKey: .style)
        viewName = try? c.decode(String.self, forKey: .viewName)
    }

    // MARK: - 移植补丁（2026-11-27）：给 `LoginRow` 加一个 **public 成员构造器**

    /// ⭐⭐⭐⭐⭐ **这个 init 为什么必须写在【主声明】里、不能用 extension**（CI336 实锤）⭐⭐⭐⭐⭐
    ///
    /// ⚠️⚠️ **踩过的两条弯路**（别再踩）：
    ///   ① 写在 **extension** 里 ⇒ CI336 报
    ///      `'self' used before 'self.init' call` / `'self.init' isn't called on all paths` ⭐⭐⭐
    ///      ⇒ **Swift 的硬规则**：`extension` 里新增的 init **不能给存储属性赋值**
    ///      （必须调 `self.init(...)` 委托给别的 init）⇒ 而这里唯一的其它 init 是 `init(from:)`
    ///      ⇒ 它要 decoder ⇒ ⇒ **extension 这条路根本不通** ⭐⭐⭐
    ///   ② 以为「init 必须定义在宿主能看见的模块里」⇒ 其实**不是** ⭐⭐⭐
    ///      `public init` 只要和类型同模块即可 ⇒ 宿主只 `import LegadoEngine`（门面）
    ///      通过 `LegadoEngineHost.LoginRow`（typealias）**照样能调**（沙盒已用 swiftc 实测证过）⭐⭐⭐
    ///
    /// ⇒ 结论：**init 写在 `LoginRow` 的主声明里**（本文件）⇒ 类型与 init 同模块 ⇒ 一律可用 ⭐⭐⭐
    ///
    /// ⚠️ **不要动 `init(from:)`**（站方 `loginUi` 的 JSON 解码靠它 ⇒ 缺字段不炸）⭐⭐⭐
    public init(name: String,
                type: Kind = .text,
                action: String? = nil,
                chars: [String]? = nil,
                defaultValue: String? = nil,
                style: ExploreKind.Style? = nil,
                viewName: String? = nil) {
        self.name = name
        self.type = type
        self.action = action
        self.chars = chars
        self.defaultValue = defaultValue
        self.style = style
        self.viewName = viewName
    }
}

/// 书源操作的对外接口。所有方法都在独立线程上同步执行规则，可安全地从任意并发上下文调用。
public final class WebBook: Sendable {
    public let source: BookSource
    public let environment: SourceEnvironment

    public init(source: BookSource, environment: SourceEnvironment) {
        self.source = source
        self.environment = environment
    }

    // MARK: - 执行

    private func run<T: Sendable>(watchCookies: Bool = false,
                                  _ body: @escaping @Sendable (RuleSession) throws -> T) async throws -> T {
        try await RuleSession.run(SourceDescriptor(source), env: environment, watchCookies: watchCookies, body)
    }

    // ⭐⭐⭐ **移植补丁（2026-11-21）**：`private` → internal ⇒ 让 `Compat/LegadoPublicAPI.swift`
    //   的诊断出口能复用它（否则要复制一份 ⇒ 逻辑漂移）⭐⭐⭐
    static func loginCheck(_ session: RuleSession, _ analyzeUrl: AnalyzeUrl, _ res: StrResponse) throws -> StrResponse {
        guard let checkJs = session.source.loginCheckJs, !checkJs.isBlank else { return res }
        return (try analyzeUrl.evalJS(checkJs, result: res) as? StrResponse) ?? res
    }

    // MARK: - 搜索与发现

    public func searchBook(_ key: String, page: Int = 1) async throws -> [SearchBook] {
        guard let searchUrl = source.searchUrl, !searchUrl.isBlank else { throw RuleError.message("搜索地址为空") }
        return try await run { session in
            let ruleData = RuleData()
            let analyzeUrl = try AnalyzeUrl(searchUrl, key: key, page: page, baseUrl: session.source.key,
                                            session: session, ruleData: ruleData)
            let res = try Self.loginCheck(session, analyzeUrl, try analyzeUrl.getStrResponse())
            return try BookListParser.analyze(session: session, ruleData: ruleData, analyzeUrl: analyzeUrl, baseUrl: res.url(),
                                              body: res.body(), isSearch: true, isRedirect: res.url() != analyzeUrl.url)
        }
    }

    public func exploreBook(url: String, page: Int = 1) async throws -> [SearchBook] {
        try await run { session in
            let ruleData = RuleData()
            let analyzeUrl = try AnalyzeUrl(url, page: page, baseUrl: session.source.key, session: session, ruleData: ruleData)
            let res = try Self.loginCheck(session, analyzeUrl, try analyzeUrl.getStrResponse())
            return try BookListParser.analyze(session: session, ruleData: ruleData, analyzeUrl: analyzeUrl, baseUrl: res.url(),
                                              body: res.body(), isSearch: false, isRedirect: res.url() != analyzeUrl.url)
        }
    }

    /// 发现页分类。JS 生成的分类会缓存，`refresh` 为 true 或书源登录状态变化后重新执行
    /// （JS 常按是否登录输出不同条目，并把当时的 Cookie 写进分类地址）
    public func exploreKinds(refresh: Bool = false) async throws -> [ExploreKind] {
        guard let exploreUrl = source.exploreUrl, !exploreUrl.isBlank else { return [] }
        let cacheKey = "exploreKinds_" + Hex.encode(Digests.digest("MD5", Data((source.bookSourceUrl + exploreUrl).utf8)) ?? Data())
        let stamp = environment.loginStamp(source.bookSourceUrl) + "\u{2}"
        return try await run { session in
            var ruleStr = exploreUrl
            if exploreUrl.startsWith("<js>", ignoreCase: true) || exploreUrl.startsWith("@js:", ignoreCase: true) {
                if !refresh, let cached = session.env.cache.get(cacheKey), cached.hasPrefix(stamp),
                   !String(cached.dropFirst(stamp.count)).isBlank {
                    ruleStr = String(cached.dropFirst(stamp.count))
                } else {
                    var js = String(exploreUrl.dropFirst(4))
                    if exploreUrl.hasPrefix("<"), let end = js.range(of: "<", options: .backwards) {
                        js = String(js[..<end.lowerBound])
                    }
                    ruleStr = AnalyzeUrl.stringify(try session.evalSourceJS(js)).trimmedWhitespace
                    session.env.cache.put(cacheKey, stamp + ruleStr)
                    // 生成分类时顺手写的登录信息不算登录变化，否则会反复刷新发现页
                    session.state.loginChanged = false
                }
            }
            return Self.parseExploreKinds(ruleStr)
        }
    }

    static func parseExploreKinds(_ text: String) -> [ExploreKind] {
        if text.isJsonArray, let arr = LenientJSON.array(text), let data = LenientJSON.serialize(arr)?.data(using: .utf8) {
            return (try? JSONDecoder().decode([Failable<ExploreKind>].self, from: data))?.compactMap(\.value) ?? []
        }
        return text.splitNotBlank(regex: "(&&|\n)+").map { item in
            let parts = item.components(separatedBy: "::")
            var kind = ExploreKind(title: parts[0])
            kind.url = parts.count > 1 ? parts[1] : nil
            return kind
        }
    }

    /// 执行发现页按钮等控件的 action；`infoMap` 为当前表单数据
    public func runExploreAction(_ action: String, infoMap: [String: String] = [:]) async throws {
        _ = try await run(watchCookies: true) { session -> Bool in
            _ = try session.evalSourceJS(action, extra: ["infoMap": JavaMap(infoMap)])
            return true
        }
    }

    // MARK: - 详情、目录、正文

    public func getBookInfo(_ book: Book, canReName: Bool = true) async throws -> Book {
        try await run { session in
            let ref = BookRef(book)
            ref.book.type = session.source.bookSource?.bookSourceType ?? book.type
            if let html = book.infoHtml, !html.isEmpty {
                try BookInfoParser.analyze(session: session, ref: ref, body: html, baseUrl: book.bookUrl,
                                           redirectUrl: book.bookUrl, canReName: canReName)
            } else {
                let analyzeUrl = try AnalyzeUrl(book.bookUrl, baseUrl: session.source.key, session: session, ruleData: ref)
                let res = try Self.loginCheck(session, analyzeUrl, try analyzeUrl.getStrResponse())
                try BookInfoParser.analyze(session: session, ref: ref, body: res.body(), baseUrl: book.bookUrl,
                                           redirectUrl: res.url(), canReName: canReName)
            }
            return ref.book
        }
    }

    public func getChapterList(_ book: Book, runPreUpdateJs: Bool = false) async throws -> (book: Book, chapters: [BookChapter]) {
        try await run { session in
            let ref = BookRef(book)
            ref.book.type = session.source.bookSource?.bookSourceType ?? book.type
            if runPreUpdateJs, let js = session.source.bookSource?.tocRule.preUpdateJs, !js.isBlank {
                _ = try AnalyzeRule(session: session, ruleData: ref).evalJS(js, result: nil)
            }
            let chapters: [BookChapter]
            if book.bookUrl == book.tocUrl, let html = book.tocHtml, !html.isEmpty {
                chapters = try ChapterListParser.analyze(session: session, ref: ref, baseUrl: book.tocUrl,
                                                         redirectUrl: book.tocUrl, body: html)
            } else {
                let analyzeUrl = try AnalyzeUrl(book.tocUrl, baseUrl: book.bookUrl, session: session, ruleData: ref)
                let res = try Self.loginCheck(session, analyzeUrl, try analyzeUrl.getStrResponse())
                chapters = try ChapterListParser.analyze(session: session, ref: ref, baseUrl: book.tocUrl,
                                                         redirectUrl: res.url(), body: res.body())
            }
            ref.book.tocHtml = nil
            return (ref.book, chapters)
        }
    }

    /// 返回正文与（可能被正文标题规则更新的）章节
    public func getContent(_ book: Book, chapter: BookChapter, nextChapterUrl: String? = nil) async throws -> (content: String, chapter: BookChapter) {
        try await run { session in
            guard let rule = session.source.bookSource?.contentRule, !(rule.content ?? "").isEmpty else {
                return (chapter.url, chapter)
            }
            if chapter.isVolume, chapter.url.hasPrefix(chapter.title) {
                return (chapter.tag ?? "", chapter)
            }
            let ref = BookRef(book)
            let chapterRef = ChapterRef(chapter)
            let absolute = chapter.absoluteURL
            let content: String
            if chapter.url == book.bookUrl, let html = book.tocHtml, !html.isEmpty {
                content = try ContentParser.analyze(session: session, ref: ref, chapter: chapterRef, baseUrl: absolute,
                                                    redirectUrl: absolute, body: html, nextChapterUrl: nextChapterUrl)
            } else {
                let analyzeUrl = try AnalyzeUrl(absolute, baseUrl: book.tocUrl, session: session, ruleData: ref, chapter: chapterRef)
                let res = try Self.loginCheck(session, analyzeUrl,
                                              try analyzeUrl.getStrResponse(jsStr: rule.webJs, sourceRegex: rule.sourceRegex))
                content = try ContentParser.analyze(session: session, ref: ref, chapter: chapterRef, baseUrl: absolute,
                                                    redirectUrl: res.url(), body: res.body(), nextChapterUrl: nextChapterUrl)
            }
            return (content, chapterRef.chapter)
        }
    }

    /// 下载图片：带书源请求头与 Cookie。封面用书源的 coverDecodeJs、正文插图用正文规则的 imageDecode 解密
    /// （与 Legado 一致：脚本里 `result` 为原始字节，`src` 为图片地址，返回解密后的字节）
    public func fetchImage(_ url: String, isContent: Bool = false) async throws -> Data {
        if isContent, InlineImage.isAction(url) { throw RuleError.message("点按动作图片不加载") }
        return try await run { session in
            let analyzeUrl = try AnalyzeUrl(url, baseUrl: session.source.key, session: session, ruleData: RuleData())
            let data = try analyzeUrl.getByteArray()
            let bookSource = session.source.bookSource
            let script = isContent ? bookSource?.ruleContent?.imageDecode : bookSource?.coverDecodeJs
            guard let js = script, !js.isBlank else { return data }
            return Self.bytes(from: try session.evalSourceJS(js, extra: ["src": url], result: data)) ?? data
        }
    }

    /// 音频、视频直链：解析 `,{选项}`，带上书源请求头与 Cookie，供系统播放器直接请求
    public func playbackRequest(_ url: String, baseUrl: String = "") async throws -> (url: String, headers: [String: String]) {
        try await run { session in
            let analyzeUrl = try AnalyzeUrl(url, baseUrl: baseUrl.isEmpty ? session.source.key : baseUrl,
                                            session: session, ruleData: RuleData())
            return analyzeUrl.playbackRequest()
        }
    }

    static func bytes(from value: Any?) -> Data? {
        switch value {
        case let data as Data: data
        case let array as [Any]: Data(array.map { UInt8(truncatingIfNeeded: ($0 as? NSNumber)?.intValue ?? 0) })
        default: nil
        }
    }

    // MARK: - 登录

    public var loginRows: [LoginRow] { Self.parseLoginRows(source.loginUi) }

    /// 登录界面控件：`loginUi` 为 `@js:`/`<js>` 时执行 `loginJs + 脚本` 生成（Legado `SourceLoginDialog`），
    /// 脚本里 `result` 为已保存的表单数据
    public func resolveLoginRows(book: Book? = nil, chapter: BookChapter? = nil) async throws -> [LoginRow] {
        guard let js = SourceDescriptor.inlineJs(source.loginUi) else { return loginRows }
        return try await run { session in
            var bindings = JSBindings(host: nil)
            bindings.baseUrl = session.source.key
            bindings.result = JavaMap(session.state.loginInfo.flatMap { LenientJSON.stringMap($0) } ?? [:])
            bindings.book = book.map(BookRef.init)
            bindings.chapter = chapter.map(ChapterRef.init)
            let value = try session.evalJS((session.source.loginJs ?? "") + "\n" + js, bindings: bindings)
            return Self.parseLoginRows(AnalyzeUrl.stringify(value))
        }
    }

    static func parseLoginRows(_ loginUi: String?) -> [LoginRow] {
        guard let ui = loginUi, let data = ui.data(using: .utf8) else { return [] }
        if let rows = try? JSONDecoder().decode([Failable<LoginRow>].self, from: data) {
            return rows.compactMap(\.value)
        }
        guard let arr = LenientJSON.array(ui), let normalized = LenientJSON.serialize(arr)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Failable<LoginRow>].self, from: normalized))?.compactMap(\.value) ?? []
    }

    /// 已保存的登录表单
    public var savedLoginInfo: [String: String] {
        let state = SourceState(key: source.bookSourceUrl, env: environment)
        return state.loginInfo.flatMap { LenientJSON.stringMap($0) } ?? [:]
    }

    /// 登录界面按钮。表单数据会先保存，再执行按钮脚本。
    public func runLoginAction(_ action: String, formData: [String: String]) async throws {
        _ = try await run(watchCookies: true) { session -> Bool in
            if !formData.isEmpty, let json = LenientJSON.serialize(formData) {
                session.state.loginInfo = json
            }
            try session.runLoginAction(action, formData: formData)
            return true
        }
    }

    /// 登录界面的确认：保存表单并执行 `login()`
    public func login(formData: [String: String]) async throws {
        _ = try await run(watchCookies: true) { session -> Bool in
            if formData.isEmpty {
                session.state.loginInfo = nil
                return true
            }
            session.state.loginInfo = LenientJSON.serialize(formData)
            try session.runLogin()
            return true
        }
    }

    public var loginHeader: String? {
        SourceState(key: source.bookSourceUrl, env: environment).loginHeader
    }

    /// 正文里的点按脚本（段评气泡的 onPress、图片选项的 click/js），可用 book、chapter 与 jsLib
    public func runContentAction(_ script: String, book: Book, chapter: BookChapter?) async throws {
        _ = try await run { session -> Bool in
            var bindings = JSBindings(host: nil)
            bindings.baseUrl = chapter?.absoluteURL ?? session.source.key
            bindings.book = BookRef(book)
            bindings.chapter = chapter.map(ChapterRef.init)
            _ = try session.evalJS(script, bindings: bindings)
            return true
        }
    }

    /// 执行任意书源脚本（调试用），返回字符串结果
    public func evalJS(_ script: String) async throws -> String {
        try await run { session in AnalyzeUrl.stringify(try session.evalSourceJS(script)) }
    }
}
