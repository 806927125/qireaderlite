import Foundation

/// Swift 侧调用 JS 引擎的唯一入口。
/// 引擎返回的是普通 JSON 对象，这里统一转成 Codable。
@MainActor
final class SourceService {
    static let shared = SourceService()
    private init() {}

    enum ServiceError: LocalizedError {
        case engineFailed(String)
        case badPayload
        var errorDescription: String? {
            switch self {
            case .engineFailed(let m): return m
            case .badPayload: return "引擎返回的数据格式不对"
            }
        }
    }

    // MARK: 登录

    /// 跑书源的登录动作（loginUrl 里的 `login(true)` / `register()` / `checkStatus()` …）
    ///
    /// - Parameters:
    ///   - action: loginUi 里按钮的 action（如 `login(true)`）
    ///   - formValues: 表单值（字段名 → 值）。引擎把它挂在 `result` 上，
    ///     站方 login() 里读的就是 `result['邮箱']` / `result['密码']`。
    /// - Returns: 是否成功 + 失败原因 + **站方自己吐出来的原文**
    ///
    /// ⚠️ `messages` 才是**真话**：`ok == true` 只说明「JS 跑完了没抛异常」，
    ///    站方报的是「✅️登录成功」还是「💔登录失败」全在 messages 里。
    ///    以前这些只弹 toast 就没了 → 用户永远不知道登录成没成。
    func login(source: BookSource, action: String,
               formValues: [String: String]) async throws -> (ok: Bool, message: String, messages: [String]) {
        var p: [String: Any] = ["action": action, "formValues": formValues]
        let srcData = try AppEncoder.encode(source)
        var srcDict = (try JSONSerialization.jsonObject(with: srcData) as? [String: Any]) ?? [:]
        srcDict["__variables"] = SourceVariables.vars(for: source.bookSourceUrl)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        p["source"] = srcDict
        p["cookieSnapshot"] = CookieJar.snapshot()
        let raw = try await RuleSandbox.shared.invoke("login", p, source: source)
        // 登录动作会改书籍变量 / 登录信息 → 落盘
        if let obj = raw as? [String: Any] {
            if let v = obj["__sourceVars"] as? String {
                SourceVariables.setVars(v, for: source.bookSourceUrl)
            }
            if let l = obj["__loginInfo"] as? String {
                SourceVariables.setLoginInfoJSON(l, for: source.bookSourceUrl)
            }
        }
        let dict = raw as? [String: Any] ?? [:]
        let ok = dict["ok"] as? Bool ?? false
        let err = dict["error"] as? String ?? ""
        // 站方原文（toast / log）。这是判断「登录成没成」的唯一依据。
        let msgs = (dict["messages"] as? [String]) ?? []
        return (ok, err, msgs)
    }

    /// 登录状态检测（引擎侧）
    ///
    /// 跑站方自己的 `checkStatus()`，并把服务器地址解析出来。
    /// 返回的 `messages` 是站方的原文（会员卡片 / 失败原因）。
    func probeLogin(source: BookSource) async throws
        -> (baseUrl: String, messages: [String], stationCheck: Bool) {
        let srcData = try AppEncoder.encode(source)
        var srcDict = (try JSONSerialization.jsonObject(with: srcData) as? [String: Any]) ?? [:]
        srcDict["__variables"] = SourceVariables.vars(for: source.bookSourceUrl)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        var p: [String: Any] = ["source": srcDict]
        p["cookieSnapshot"] = CookieJar.snapshot()
        let raw = try await RuleSandbox.shared.invoke("loginProbe", p, source: source)
        let dict = raw as? [String: Any] ?? [:]
        if let e = dict["error"] as? String, !e.isEmpty {
            throw ServiceError.engineFailed(e)
        }
        return (
            baseUrl: (dict["baseUrl"] as? String) ?? "",
            messages: (dict["messages"] as? [String]) ?? [],
            stationCheck: (dict["stationCheck"] as? Bool) ?? false
        )
    }

    // MARK: 桥接

    private func json(_ payload: [String: Any]) -> [String: Any] { payload }

    private func call<T: Decodable>(_ op: String, _ payload: [String: Any],
                                    as type: T.Type, source: BookSource) async throws -> T {
        var p = payload
        // 必须是**嵌套对象**。塞 JSON 字符串的话，引擎里 src.ruleSearch 全是 undefined，
        // 表现是「所有字段都空」这种很难查的问题。
        let srcData = try AppEncoder.encode(source)
        var srcDict = (try JSONSerialization.jsonObject(with: srcData) as? [String: Any]) ?? [:]
        // 书籍变量 / 登录信息：Legado 的 source.getVariable() 是**同步** API，
        // 我们的原生桥是异步的（只能 postMessage）→ 只能原生侧读出来塞进去，
        // 引擎侧同步读。改完由引擎回传（见下面 __sourceVars）。
        srcDict["__variables"] = SourceVariables.vars(for: source.bookSourceUrl)
        srcDict["__loginInfo"] = SourceVariables.loginInfo(for: source.bookSourceUrl)
        p["source"] = srcDict
        // cookie 快照：同理，Legado 的 cookie.getCookie(url) 也是同步的。
        p["cookieSnapshot"] = CookieJar.snapshot()
        let raw = try await RuleSandbox.shared.invoke(op, p, source: source)
        // 站方 JS 改过的书籍变量 / 登录信息 → 落盘（下次调用直接生效）
        if let obj = raw as? [String: Any] {
            if let v = obj["__sourceVars"] as? String {
                SourceVariables.setVars(v, for: source.bookSourceUrl)
            }
            if let l = obj["__loginInfo"] as? String {
                SourceVariables.setLoginInfoJSON(l, for: source.bookSourceUrl)
            }
        }
        return try decode(T.self, from: raw)
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: Any?) throws -> T {
        guard let obj = raw, !(obj is NSNull) else { throw ServiceError.badPayload }
        if let dict = obj as? [String: Any], let msg = dict["error"] as? String, !msg.isEmpty {
            throw ServiceError.engineFailed(msg)
        }
        // 书单走宽松解析：单本书坏掉不该让整页消失
        if type == BookListDTO.self, let lenient = BookListDTO.lenient(obj) {
            return lenient as! T
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        do {
            return try AppDecoder.decode(type, from: data)
        } catch let e as DecodingError {
            // 把「哪一列出的问题」带出来，别只丢一句"解码失败"。
            // ⚠️ codingPath 挂在每个 case 的 **context** 上，不在 DecodingError 本体上。
            var keys: [CodingKey] = []
            let why: String
            switch e {
            case .keyNotFound(let key, let ctx):
                keys = ctx.codingPath; why = "缺字段 \(key.stringValue)"
            case .typeMismatch(let t, let ctx):
                keys = ctx.codingPath; why = "类型不匹配，要的是 \(t)"
            case .valueNotFound(let t, let ctx):
                keys = ctx.codingPath; why = "值缺失（\(t)），该字段是 null"
            case .dataCorrupted(let ctx):
                keys = ctx.codingPath; why = "数据损坏：\(ctx.debugDescription)"
            @unknown default:
                why = e.localizedDescription
            }
            let path = keys.map { k -> String in
                k.intValue.map { "[\($0)]" } ?? k.stringValue
            }.joined(separator: ".")
            let preview = String(data: data, encoding: .utf8)?.prefix(1200) ?? ""
            throw ServiceError.engineFailed(
                "解析 \(type) 失败 —— 出错字段：\(path.isEmpty ? "(根)" : path) / \(why)\n返回：\(preview)")
        } catch {
            // 引擎某一列的形状变了时，把原文带出来，别让上层只看到"解码失败"
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw ServiceError.engineFailed("解析 \(type) 失败: \(error.localizedDescription) | 返回: \(preview)")
        }
    }

    // MARK: 返回模型

    struct BookDTO: Codable {
        var name: String = ""
        var author: String = ""
        var intro: String = ""
        var kind: String = ""
        var lastChapter: String = ""
        var coverUrl: String = ""
        var bookUrl: String = ""
        var wordCount: String = ""
        /// 引擎 bookInfo 会返回 tocUrl。之前这个字段压根没在 DTO 里声明，
        /// 解码时直接丢掉、toBook 再硬传 `tocUrl: ""`，于是**每本书的 tocUrl 都是空的**
        /// → 目录永远退回书籍页 → 0 章且不报错。
        var tocUrl: String = ""

        init() {}

        /// ⚠️ 逐列 `decodeIfPresent` + 默认值兜底，**不依赖编译器合成的行为** ——
        ///    少一个字段（列表书没有 tocUrl）、某列是 null、或者站方换了字段形状，
        ///    都只影响那一列，不会让整本书解不出来，进而让整页书单挂掉。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func g(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            name = g(.name);           author   = g(.author)
            intro = g(.intro);         kind     = g(.kind)
            lastChapter = g(.lastChapter); coverUrl = g(.coverUrl)
            bookUrl = g(.bookUrl);     wordCount = g(.wordCount)
            tocUrl = g(.tocUrl)
        }
        private enum K: String, CodingKey {
            case name, author, intro, kind, lastChapter, coverUrl, bookUrl, wordCount, tocUrl
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(name, forKey: .name);         try c.encode(author, forKey: .author)
            try c.encode(intro, forKey: .intro);       try c.encode(kind, forKey: .kind)
            try c.encode(lastChapter, forKey: .lastChapter); try c.encode(coverUrl, forKey: .coverUrl)
            try c.encode(bookUrl, forKey: .bookUrl);   try c.encode(wordCount, forKey: .wordCount)
            try c.encode(tocUrl, forKey: .tocUrl)
        }
    }
    struct BookListDTO: Codable {
        var books: [BookDTO] = []
        var total: Int = 0
        var nextUrl: String = ""
        /// 引擎失败时会把原因放在这里。以前这个字段直接被丢掉，
        /// 结果就是「搜不出东西」但界面什么都不显示。
        var error: String? = nil

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            books    = (try? c.decodeIfPresent([BookDTO].self, forKey: .books)) as? [BookDTO] ?? []
            total    = (try? c.decodeIfPresent(Int.self, forKey: .total)) as? Int ?? 0
            nextUrl  = (try? c.decodeIfPresent(String.self, forKey: .nextUrl)) as? String ?? ""
            error    = try? c.decodeIfPresent(String.self, forKey: .error)
        }
        private enum K: String, CodingKey { case books, total, nextUrl, error }

        /// 从 WKWebView 桥过来的字典里**尽力**取出书单。
        /// 之前是整份 JSON 丢给 JSONDecoder，一旦有**一本书**的字段形状对不上，
        /// 整个数组就解不出来 → 页面直接显示「解析 BookListDTO 失败」+ 一个空列表。
        /// 改成逐本单独解：坏的那本跳过，好的照常显示。
        static func lenient(_ obj: Any?) -> BookListDTO? {
            guard let dict = obj as? [String: Any] else { return nil }
            var out = BookListDTO()
            out.error = dict["error"] as? String
            out.total = (dict["total"] as? NSNumber)?.intValue ?? 0
            out.nextUrl = (dict["nextUrl"] as? String) ?? ""
            var list: [BookDTO] = []
            if let arr = dict["books"] as? [Any] {
                for item in arr {
                    guard let one = item as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: one),
                          let b = try? AppDecoder.decode(BookDTO.self, from: data)
                    else { continue }
                    list.append(b)
                }
            }
            out.books = list
            return out
        }
    }
    struct BookInfoDTO: Codable {
        var book: BookDTO?
        var error: String? = nil
    }
    struct ChapterDTO: Codable {
        var url: String = ""
        var title: String = ""
        var index: Int = 0
        var isVolume: Bool = false
        var tag: String = ""
    }
    struct TocDTO: Codable {
        var chapters: [ChapterDTO] = []
        var error: String? = nil
    }
    struct ContentDTO: Codable {
        var title: String = ""
        var content: String = ""
        var nextUrl: String = ""
        var error: String? = nil
    }
    struct KindDTO: Codable {
        var title: String = ""
        var url: String = ""
        var style: String = ""
    }
    struct KindsDTO: Codable {
        var kinds: [KindDTO] = []
        var error: String? = nil
    }

    // MARK: 对外方法

    func search(source: BookSource, keyword: String, page: Int = 1) async throws -> [Book] {
        let dto: BookListDTO = try await call("search",
            json(["keyword": keyword, "page": page]), as: BookListDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto.books.map { $0.toBook(origin: source.bookSourceUrl, sourceName: source.name) }
    }

    func exploreKinds(source: BookSource) async throws -> [KindDTO] {
        let dto: KindsDTO = try await call("exploreKinds", json([:]), as: KindsDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto.kinds
    }

    func explore(source: BookSource, kindUrl: String, page: Int = 1) async throws -> [Book] {
        let dto: BookListDTO = try await call("explore",
            json(["kindUrl": kindUrl, "page": page]), as: BookListDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto.books.map { $0.toBook(origin: source.bookSourceUrl, sourceName: source.name) }
    }

    /// 诊断一次目录请求：URL / 状态 / 命中数 / 第一条章节的 HTML 都摆出来
    func explainToc(source: BookSource, tocUrl: String, bookUrl: String) async throws -> String {
        let raw = try await RuleSandbox.shared.invoke("explainToc",
            ["tocUrl": tocUrl, "bookUrl": bookUrl], source: source)
        guard let dict = raw as? [String: Any] else { return "引擎没有返回诊断数据" }
        var out: [String] = []
        for k in ["请求URL", "最终URL", "状态码", "响应字节", "页面标题",
                  "chapterList规则", "chapterName规则", "chapterUrl规则",
                  "规则命中元素", "取到的章节名", "取到的章节URL",
                  "选择器报错", "解析报错", "元素统计", "命中条目样本",
                  "候选容器", "目录容器样本", "结论"] {
            if let v = dict[k] {
                let s = (v is String) ? (v as! String) : String(describing: v)
                if s.isEmpty { continue }
                out.append("\(k)：\(s)")
            }
        }
        return out.isEmpty ? "没有诊断信息" : out.joined(separator: "\n")
    }

    /// 诊断一次发现页请求，把 URL / 状态码 / 字节数 / 命中元素数拼成人话。
    func explain(source: BookSource, kindUrl: String, page: Int = 1) async throws -> String {
        let raw = try await RuleSandbox.shared.invoke("explain",
            ["kindUrl": kindUrl, "page": page], source: source)
        guard let dict = raw as? [String: Any] else { return "引擎没有返回诊断数据" }
        var out: [String] = []
        for k in ["请求URL", "最终URL", "方式", "状态码", "响应字节", "页面标题",
                  "用的规则", "bookList规则", "规则命中元素", "元素统计", "选择器报错",
                  "解析报错", "结论", "候选列表容器", "书单条目样本"] {
            if let v = dict[k] {
                let s = (v is String) ? (v as! String) : String(describing: v)
                if s.isEmpty { continue }
                out.append("\(k)：\(s)")
            }
        }
        let head = dict["正文开头"] as? String ?? ""
        if !head.isEmpty { out.append("正文开头：\(head)") }
        return out.isEmpty ? "没有诊断信息" : out.joined(separator: "\n")
    }

    func bookInfo(source: BookSource, bookUrl: String, fallback: Book? = nil) async throws -> Book {
        var p: [String: Any] = ["bookUrl": bookUrl]
        if let f = fallback { p["book"] = f.rawJSON }
        let dto: BookInfoDTO = try await call("bookInfo", p, as: BookInfoDTO.self, source: source)
        guard var b = dto.book?.toBook(origin: source.bookSourceUrl, sourceName: source.name) else {
            throw ServiceError.engineFailed("详情页没解析出书名")
        }
        b.origin = source.bookSourceUrl
        b.sourceName = source.name
        b.bookUrl = bookUrl
        b.detailLoaded = true
        if b.tocUrl.isEmpty { b.tocUrl = bookUrl }
        return b
    }

    func toc(source: BookSource, tocUrl: String, bookUrl: String) async throws -> [Chapter] {
        let dto: TocDTO = try await call("toc",
            json(["tocUrl": tocUrl, "bookUrl": bookUrl, "maxPages": 5]), as: TocDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto.chapters.map {
            Chapter(url: $0.url, title: $0.title, index: $0.index, isVolume: $0.isVolume, tag: $0.tag)
        }
    }

    func content(source: BookSource, chapter: Chapter) async throws -> ContentDTO {
        var p: [String: Any] = ["chapterUrl": chapter.url]
        p["chapter"] = ["title": chapter.title, "url": chapter.url]
        let dto = try await call("content", p, as: ContentDTO.self, source: source)
        if let e = dto.error, !e.isEmpty { throw ServiceError.engineFailed(e) }
        return dto
    }
}

extension SourceService.BookDTO {
    func toBook(origin: String, sourceName: String) -> Book {
        Book(origin: origin, bookUrl: bookUrl, name: name, author: author, intro: intro,
             kind: kind, lastChapter: lastChapter, coverUrl: coverUrl, wordCount: wordCount,
             tocUrl: tocUrl, sourceName: sourceName, detailLoaded: false)
    }
}

extension Book {
    /// 送进沙盒的原始字典（引擎不认识 Swift 的 Book 类型）
    var rawJSON: [String: Any] {
        ["bookUrl": bookUrl, "name": name, "author": author, "intro": intro,
         "kind": kind, "lastChapter": lastChapter, "coverUrl": coverUrl, "wordCount": wordCount,
         "tocUrl": tocUrl]
    }
}

// MARK: - 视图用的异步包装

/// SwiftUI 里直接 await 引擎，用这个轻量 view model 驱动 loading / error 状态。
@MainActor
final class AsyncLoader: ObservableObject {
    @Published var isLoading = false
    @Published var errorText: String?

    func run<T>(_ work: @escaping () async throws -> T) async -> T? {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do { return try await work() }
        catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Toast.show(errorText ?? "出错了")
            return nil
        }
    }
}
