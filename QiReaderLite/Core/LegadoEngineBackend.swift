import Foundation
import LegadoEngine

// ⭐⭐⭐⭐⭐ **轻阅 Lite 的引擎宿主（2026-11-21 起 = 柴阅/Chaiyue 的引擎）** ⭐⭐⭐
//
// ⚠️⚠️⚠️ **这一版的性质**：**整个引擎换成柴阅的权威实现** ⭐⭐⭐
//   · 引擎 = 柴阅的 `ReaderModels` + `RuleEngine`（vendor 进 `LegadoEngine/Sources/Chaiyue*`）⭐⭐⭐
//   · 宿主只走柴阅的 **public API**（`WebBook` / `SourceEnvironment` / `KeyValueStore`）⭐⭐⭐
//   ⇒ **不再自建 JS bridge、不再自己解析规则、不再自己灌站方变量** ⭐⭐⭐
//   ⇒ 站方变量的两套语义、charset、`@js:` 规则、URL 选项键……**全部由柴阅原生处理** ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **为什么这是「根治」**（2026-11-19 build297–302 的教训）：
//   之前四版都在修**我们自己那套半成品引擎**的表层（求值 / 灌值 / 回传 / 登录）⭐⭐⭐
//   ⇒ 真因（**站方变量的两套语义**）在更下一层 ⇒ 反复修表层永远修不到 ⭐⭐⭐
//   ⇒ 现在换成**权威实现** ⇒ 那类根因**根本不会存在**（柴阅自己是对的）⭐⭐⭐
//
// ⚠️⚠️ **UI 一行都没改**（用户明确要求）⇒ 本文件的**输出格式契约必须逐字保持** ⭐⭐⭐
final class LegadoEngineBackend {
    static let shared = LegadoEngineBackend()

    private let lock = NSLock()
    /// ⭐⭐⭐ **会话缓存**：柴阅的状态在 `KeyValueStore`（⇒ 跨会话自动保持）⭐⭐⭐
    ///   ⇒ 这里**不再缓存引擎会话**（柴阅的 `WebBook` 每次 op 新建即可）⭐⭐⭐
    ///   ⇒ 只保留一个「清缓存」的开关（`dropSession` 仍是 UI 的 API）⭐⭐⭐
    private var droppedSourceKeys: Set<String> = []

    // MARK: - 对外 API（UI/Service 依赖的形状不变）

    /// ⭐⭐⭐ **调用一个引擎操作**（带超时保护 ⇒ 站方死循环不会卡死 App）⭐⭐⭐
    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Any?, Error> = .success(nil)
        Task.detached(priority: .userInitiated) {
            do {
                let v = try await Self.run(op, payload, source: source)
                result = .success(v)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        // ⚠️ **必须有上限**：引擎内部死循环（站方脚本）⇒ 不加就会永久卡住 ⭐⭐⭐
        let budget = Self.timeoutSeconds(for: op)
        if sem.wait(timeout: .now() + budget) == .timedOut {
            throw ServiceError.engineFailed("「\(op)」超时（\(Int(budget))s）—— 引擎里可能有死循环")
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    /// 换掉卡死的会话（这个源的变量/登录态重置 ⇒ 下一个 op 重新开始）
    ///
    /// ⭐⭐⭐ **柴阅的语义**：状态在 `KeyValueStore` ⇒ 这里**只清内存态**⭐⭐⭐
    ///   ⇒ ⚠️ **不清磁盘态**（否则用户的解锁态/登录态被抹掉 ⇒ 不能这么做）⭐⭐⭐
    func dropSession(for key: String) {
        lock.lock(); droppedSourceKeys.insert(key); lock.unlock()
    }

    /// ⭐⭐⭐ **清空所有会话**（诊断面板「重置会话」）
    func dropAllSessions() {
        lock.lock(); droppedSourceKeys.removeAll(); lock.unlock()
    }

    /// op 的超时预算（内容类给得宽，因为站方会逐条试多条线路）
    static func timeoutSeconds(for op: String) -> TimeInterval {
        switch op {
        case "bookInfo", "toc", "content": return 300
        case "login", "loginProbe": return 120
        default: return 60
        }
    }

    // MARK: - 主链（全部走柴阅的 `WebBook`）

    private static func run(_ op: String, _ payload: [String: Any],
                            source: BookSource) async throws -> Any? {
        // ① 解析书源（柴阅的模型 ⇒ 直接用柴阅的解码器）⭐⭐⭐
        let parsed = try parseSource(payload, fallback: source)
        // ② 引擎环境（全局共享 ⇒ 状态/缓存都共享）⭐⭐⭐
        let env = ChaiyueRuntime.environment
        // ③ 柴阅的引擎门面 ⭐⭐⭐
        let web = LegadoEngineHost.WebBook(source: parsed, environment: env)

        switch op {
        case "search":
            let key = (payload["keyword"] as? String) ?? ""
            let page = (payload["page"] as? Int) ?? 1
            let books = try await web.searchBook(key, page: page)
            let items: [[String: Any]] = books.map { bookListItem($0) }
            return ["books": items, "total": books.count, "nextUrl": ""]

        case "exploreKinds":
            // ⭐⭐⭐⭐⭐ **分类 + 筛选栏**：柴阅原生求值 `@js:` 的 `exploreUrl` ⭐⭐⭐
            //   ⇒ **不再需要**旧的 `ExploreKindsNormalizer`（那是宿主自己 eval + 解析）⭐⭐⭐
            //   ⇒ 柴阅的 `exploreKinds` 是权威实现 ⇒ **行为与柴阅逐字一致** ⭐⭐⭐
            // ⭐⭐⭐⭐⭐ **必须 `refresh: true`**（2026-11-21 真机「筛选键没用」实证）⭐⭐⭐
            //   柴阅的 `exploreKinds` 默认 **refresh: false** ⇒ 命中缓存 ⭐⭐⭐
            //   ⇒ 缓存键 = md5(源URL + exploreUrl **文本**) ⇒ **站方变量变了键也不变** ⭐⭐⭐
            //   ⇒ ⇒ 筛选后重跑分类 ⇒ 拿回**旧平台的 URL** ⇒ 列表还是旧平台的 ⇒ **筛选无效** ⭐⭐⭐
            //   ⇒ 而 NovelHub 的分类 URL 是**求值出来的**（含平台参数）⇒ 必须重算 ⭐⭐⭐
            //   ⇒ ⚠️ UI 侧已有 `kindsLoaded` 短路 ⇒ 真正需要重算的时刻才调到这里 ⇒ 代价可接受 ⭐⭐⭐
            let kinds = try await web.exploreKinds(refresh: true)
            let norm = ChaiyueKindsAdapter.normalize(kinds)
            return ["kinds": norm.kinds, "filters": norm.filters]

        case "explore":
            let kindUrl = (payload["kindUrl"] as? String) ?? ""
            let page = (payload["page"] as? Int) ?? 1
            // ⭐⭐⭐⭐⭐ **用【诊断版】**（2026-11-21 真机「书单 0 本」定责实证）⭐⭐⭐
            //   ⇒ 一次请求 ⇒ 同时拿到「书单」与「站方状态/字节/规则是否命中」⭐⭐⭐
            //   ⇒ **分得清是站方没数据、还是规则没匹配上、还是 URL 错了** ⭐⭐⭐
            //   ⇒ 没有它就只能说「0 本」⇒ **定不了责**（书源问题 vs 引擎问题）⭐⭐⭐
            let (books, diag) = try await web.exploreBookWithDiagnostics(url: kindUrl, page: page)
            let items: [[String: Any]] = books.map { bookListItem($0) }
            var out: [String: Any] = ["books": items, "total": books.count, "nextUrl": ""]
            out["__diag"] = diag
            // ⭐⭐⭐ **诊断也进引擎日志**（用户能直接看到「谁的问题」）⭐⭐⭐
            if books.isEmpty {
                let summary = diag.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")
                engineLog("[explore] 0 本 ⇒ \(summary)")
            }
            return out

        case "bookInfo":
            let info = try await web.getBookInfo(book(from: payload))
            return ["book": bookPayload(info)]

        case "toc":
            let b = book(from: payload)
            let result = try await web.getChapterList(b)
            let list: [[String: Any]] = result.chapters.map { c -> [String: Any] in
                var item: [String: Any] = [:]
                item["url"] = c.url
                item["title"] = c.title
                item["index"] = c.index
                item["isVolume"] = c.isVolume
                item["isVip"] = c.isVip
                item["isPay"] = c.isPay
                // ⚠️ 柴阅的 `BookChapter` 没有 `updateTime` ⇒ 输出空串（UI 键名不变）⭐⭐⭐
                item["updateTime"] = ""
                item["tag"] = c.tag ?? ""
                return item
            }
            return ["chapters": list, "rawCount": result.chapters.count,
                    "bookName": result.book.name]

        case "content":
            let ch = chapter(from: payload)
            let result = try await web.getContent(book(from: payload), chapter: ch)
            return ["title": result.chapter.title, "content": result.content, "nextUrl": ""]

        case "filterAction":
            // ⭐⭐⭐ **筛选栏动作**（站方 `source.put(...)` 写回变量 ⇒ 柴阅自己落盘）⭐⭐⭐
            let action = (payload["action"] as? String) ?? ""
            guard !action.isEmpty else {
                return ["ok": false, "error": "没有筛选动作", "msgs": []]
            }
            let infoMap = (payload["infoMap"] as? [String: String]) ?? [:]
            do {
                try await web.runExploreAction(action, infoMap: infoMap)
                return ["ok": true, "msgs": []]
            } catch {
                return ["ok": false, "error": String(describing: error), "msgs": []]
            }

        case "loginRows":
            // ⭐⭐⭐⭐⭐ **登录表单行 = 柴阅的 `resolveLoginRows`**（2026-11-21 真机「登录界面没按钮」实证）⭐⭐⭐
            //   ⇒ 站方的 `loginUi` 常常是 **`@js:` / `<js>` 薄壳**（正文在 jsLib 里）⭐⭐⭐
            //   ⇒ 轻阅自己解析只能吃**静态 JSON** ⇒ 解析失败 ⇒ **面板空白、一个按钮都没有** ⭐⭐⭐
            //   ⇒ 柴阅的 `resolveLoginRows` 会**先跑 `loginJs`、再求值 `loginUi`** ⇒ 行拿得到 ⭐⭐⭐
            //   ⇒ `result` 绑的是**已保存的登录信息**（柴阅的 `userInfo_` 槽 ⇒ 经我们的 store 转换）⭐⭐⭐
            let rows = try await web.resolveLoginRows()
            return ["rows": rows.map { row in
                ["name": row.name,
                 "type": row.type.rawValue,
                 "action": row.action ?? "",
                 "chars": row.chars ?? [],
                 "default": row.defaultValue ?? ""]
            }]

        case "login":
            // ⭐⭐⭐ **登录动作**（柴阅的 `runLoginAction` 会自己把表单值写进 `loginInfo`）⭐⭐⭐
            //   ⇒ **不再需要**宿主手工灌 `sourceVars["loginInfo"]`（build300 那套）⭐⭐⭐
            let action = (payload["action"] as? String) ?? ""
            guard !action.isEmpty else {
                return ["ok": false, "error": "没有登录动作", "msgs": []]
            }
            let formValues = (payload["formValues"] as? [String: String]) ?? [:]
            do {
                try await web.runLoginAction(action, formData: formValues)
                return ["ok": true, "msgs": []]
            } catch {
                return ["ok": false, "error": String(describing: error), "msgs": []]
            }

        case "loginProbe":
            // ⭐⭐⭐ **登录态探测**：跑站方的 `loginCheckJs`（不报错 = 登录态正常）⭐⭐⭐
            let js = parsed.loginCheckJs ?? ""
            if js.isEmpty {
                return ["ok": false, "error": "书源没有 loginCheckJs", "msgs": []]
            }
            do {
                _ = try await web.evalJS(js)
                return ["ok": true, "msgs": []]
            } catch {
                return ["ok": false, "error": String(describing: error), "msgs": []]
            }

        case "explain", "explainToc":
            // ⭐⭐⭐ **诊断 op**：发一次请求，把 URL/状态/字节报出来 ⭐⭐⭐
            let ruleUrl = (payload["tocUrl"] as? String) ?? (payload["kindUrl"] as? String)
                ?? (payload["bookUrl"] as? String) ?? ""
            do {
                let info = try await LegadoEngineHost.Diagnostics.probe(url: ruleUrl, source: parsed, environment: env)
                var out: [String: Any] = info
                out["说明"] = "诊断走柴阅引擎（2026-11-21 换装）"
                return out
            } catch {
                return ["请求URL": ruleUrl, "错误": String(describing: error)]
            }

        default:
            // ⚠️ **不认识就明确报错**（不静默返回空 ⇒ 不假成功）⭐⭐⭐
            throw ServiceError.engineFailed("新引擎不支持「\(op)」这个操作")
        }
    }

    // MARK: - 形状对齐（App 侧的契约 —— **UI 不改 ⇒ 键名一字不改**）

    private static func bookListItem(_ b: LegadoEngineHost.SearchResult) -> [String: Any] {
        [
            "name": b.name,
            "author": b.author,
            "intro": b.intro ?? "",
            "kind": b.kind ?? "",
            // ⚠️ 柴阅的字段叫 `latestChapterTitle`（旧的叫 `lastChapter`）⇒ **输出键名不变** ⭐⭐⭐
            "lastChapter": b.latestChapterTitle ?? "",
            "coverUrl": b.coverUrl ?? "",
            "bookUrl": b.bookUrl,
            "wordCount": b.wordCount ?? "",
            "tocUrl": b.tocUrl,
            "group": b.originName,
            // ⚠️ 柴阅的字段叫 `time`（旧的叫 `updateTime`）⇒ **输出键名不变** ⭐⭐⭐
            "updateTime": String(b.time),
            "origin": b.origin,
        ]
    }

    private static func bookPayload(_ b: LegadoEngineHost.BookModel) -> [String: Any] {
        [
            "name": b.name,
            "author": b.author,
            "intro": b.intro ?? "",
            "kind": b.kind ?? "",
            "group": "",
            "lastChapter": b.latestChapterTitle ?? "",
            "coverUrl": b.coverUrl ?? "",
            "bookUrl": b.bookUrl,
            "tocUrl": b.tocUrl,
            "wordCount": b.wordCount ?? "",
            "updateTime": String(b.latestChapterTime),
        ]
    }

    /// 从 payload 里还原引擎的 `Book`
    private static func book(from payload: [String: Any]) -> LegadoEngineHost.BookModel {
        let raw = (payload["book"] as? [String: Any]) ?? [:]
        var b = LegadoEngineHost.BookModel(bookUrl: (raw["bookUrl"] as? String) ?? (payload["bookUrl"] as? String) ?? "",
                                           origin: (raw["origin"] as? String) ?? "")
        b.originName = (raw["group"] as? String) ?? ""
        b.name = (raw["name"] as? String) ?? ""
        b.author = (raw["author"] as? String) ?? ""
        b.kind = raw["kind"] as? String
        b.intro = raw["intro"] as? String
        b.coverUrl = raw["coverUrl"] as? String
        b.wordCount = raw["wordCount"] as? String
        b.latestChapterTitle = (raw["lastChapter"] as? String) ?? (raw["latestChapterTitle"] as? String)
        b.tocUrl = (payload["tocUrl"] as? String) ?? (raw["tocUrl"] as? String) ?? ""
        b.variable = raw["variable"] as? String
        return b
    }

    /// 从 payload 里还原引擎的 `BookChapter`
    private static func chapter(from payload: [String: Any]) -> LegadoEngineHost.ChapterModel {
        let raw = (payload["chapter"] as? [String: Any]) ?? [:]
        var c = LegadoEngineHost.ChapterModel()
        c.url = (payload["chapterUrl"] as? String) ?? (raw["url"] as? String) ?? ""
        c.title = (raw["title"] as? String) ?? ""
        c.index = (raw["index"] as? Int) ?? 0
        c.isVolume = (raw["isVolume"] as? Bool) ?? false
        c.isVip = (raw["isVip"] as? Bool) ?? false
        c.isPay = (raw["isPay"] as? Bool) ?? false
        // ⚠️ 柴阅的 `BookChapter` **没有 `updateTime` 字段** ⇒ 输出空串（UI 键名不变）⭐⭐⭐
        c.variable = raw["variable"] as? String
        return c
    }

    // MARK: - 书源解析

    /// ⭐⭐⭐ **书源 JSON 优先用 payload 里那份**（宿主注入的字段都在里面）⭐⭐⭐
    ///
    /// ⚠️⚠️ **必须先剔除 `__` 前缀的内部键**（`__variables` / `__variable` / `__loginInfo` …）：
    ///   那是**宿主注入引擎的内部通道**，柴阅的模型不认识 ⇒ 解码前要剥掉 ⭐⭐⭐
    ///   ⇒ ⚠️ **状态不再靠这些键注入**（柴阅自己从 `KeyValueStore` 读）⭐⭐⭐
    private static func parseSource(_ payload: [String: Any],
                                    fallback: BookSource) throws -> LegadoEngineHost.Source {
        if let dict = payload["source"] as? [String: Any] {
            var clean: [String: Any] = [:]
            for (k, v) in dict where !k.hasPrefix("__") { clean[k] = v }
            if JSONSerialization.isValidJSONObject(clean),
               let data = try? JSONSerialization.data(withJSONObject: clean),
               let parsed = try? JSONDecoder().decode(LegadoEngineHost.Source.self, from: data) {
                return parsed
            }
        }
        // 兜底：用 App 的模型回编
        if let data = try? JSONEncoder().encode(fallback),
           let parsed = try? JSONDecoder().decode(LegadoEngineHost.Source.self, from: data) {
            return parsed
        }
        throw ServiceError.engineFailed("书源 JSON 解析失败")
    }
}

// ⭐⭐⭐⭐⭐ **引擎日志挂到「引擎日志」面板**（App 启动时挂一次 ⇒ 别处直接用 `engineLog`）⭐⭐⭐
///
/// ⚠️ **为什么要挂**（2026-10-28）：诊断写在 `NSLog` 里 ⇒ **只进设备控制台，用户看不到**
///   ⇒ 真机排查只能靠「让用户去 Xcode 看控制台」⇒ 一轮一条信息 ⇒ 极慢 ⭐⭐⭐
///   ⇒ 挂上面板 ⇒ 用户「复制日志」就有 ⭐⭐⭐
///
/// ⚠️⚠️ **必须 `Task { @MainActor in … }`**：
///   · 引擎回调在**后台线程** ⇒ 面板 `EngineLogPanel` 是 `@MainActor`
///   ⇒ 直接调 `appendLog` ⇒ **后台线程改 @Published 状态** ⇒ UI 更新在后台线程 ⇒ 闪退风险 ⭐⭐⭐
///   ⇒ 切主线程再写 ⭐⭐⭐
enum EngineLogBootstrap {
    static func install() {
        EngineLog.sink = { message in
            Task { @MainActor in EngineLogPanel.shared.appendLog(message) }
        }
    }
}
