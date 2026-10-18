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

    // MARK: 桥接

    private func json(_ payload: [String: Any]) -> [String: Any] { payload }

    private func call<T: Decodable>(_ op: String, _ payload: [String: Any],
                                    as type: T.Type, source: BookSource) async throws -> T {
        var p = payload
        // 必须是**嵌套对象**。塞 JSON 字符串的话，引擎里 src.ruleSearch 全是 undefined，
        // 表现是「所有字段都空」这种很难查的问题。
        let srcData = try AppEncoder.encode(source)
        p["source"] = try JSONSerialization.jsonObject(with: srcData) as? [String: Any] ?? [:]
        let raw = try await RuleSandbox.shared.invoke(op, p, source: source)
        return try decode(T.self, from: raw)
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: Any?) throws -> T {
        guard let obj = raw, !(obj is NSNull) else { throw ServiceError.badPayload }
        if let dict = obj as? [String: Any], let msg = dict["error"] as? String, !msg.isEmpty {
            throw ServiceError.engineFailed(msg)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        do {
            return try AppDecoder.decode(type, from: data)
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
        /// ⚠️ 这个字段以前**根本没在 DTO 里声明** ——
        /// 引擎 bookInfo 返回了 tocUrl，Swift 解码时直接丢掉，
        /// toBook 再硬传 `tocUrl: ""`，于是**每一本书的 tocUrl 都是空的**。
        /// 后果：目录永远退回书籍页 → chapterList 打不中 → 0 章，
        /// 而且不报错，页面上什么都看不出来（详情看着还挺正常，因为
        /// 书名/作者简介是从列表页带过来的）。实测「免费追书」全中招。
        var tocUrl: String = ""
    }
    struct BookListDTO: Codable {
        var books: [BookDTO] = []
        var total: Int = 0
        var nextUrl: String = ""
        /// 引擎失败时会把原因放在这里。以前这个字段直接被丢掉，
        /// 结果就是「搜不出东西」但界面什么都不显示。
        var error: String? = nil
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
