import Foundation
import LegadoEngine

/// ⭐⭐⭐⭐⭐ **轻阅 ⇄ LegadoEngine 接线层**（2026-11-19 · 老的两条引擎全部退役）
///
/// **老引擎（已删）**
/// · ① WebView JS 引擎（`Resources/engine/*.js` + `Engine/WebViewJSExecutor.swift`）
/// · ② 自研 Swift 引擎（`legado-engine` 这个 SPM 包）
///
/// **新引擎**
/// · `LegadoEngine`（Legado 3.0 语义，从「六阅 LegadoR iOS」二进制逆向重建）
///   - 规则层：`AnalyzeRule` / `AnalyzeUrl` / `RuleSplitter`
///   - 解析层：SwiftSoup（默认规则）· **Kanna（真 XPath）** · JSONPath · 正则
///   - JS 层：JavaScriptCore + 从原二进制 1:1 提取的 Rhino 兼容 shim
///   - 网络层：自带 `HTTPClient`（用 `HTTPCookieStorage.shared` ⇒ **登录态与 App 共用一个罐** ✔）
///
/// ⚠️ **架构纪律**（沿用旧层的硬约束）
/// · 本文件**不许 import UIKit**（沙盒 swift 门禁在 Linux 上编译它）⭐⭐⭐
/// · 引擎调用**必须离开主线程**（引擎内部全同步 ⇒ 主线程会卡 UI）⭐⭐⭐
/// · 失败必须**如实抛错**（不假成功）⭐⭐⭐
final class LegadoEngineBackend {

    static let shared = LegadoEngineBackend()

    /// ⭐⭐⭐ **一个源一个会话**（站方变量/登录态要在 op 之间延续）
    fileprivate final class Session {
        let engineSource: LegadoEngineHost.Source
        /// 站方变量（新引擎是**一个 map**；老引擎是两套 ⇒ 这里统一成 map）
        let variables: LegadoEngineHost.Vars
        /// 灌进去时的种子（判定「站方到底改没改」—— **证据不许自证**）⭐⭐⭐
        let seeded: String

        init(engineSource: LegadoEngineHost.Source, payload: [String: Any]) {
            self.engineSource = engineSource
            let raw = (payload["source"] as? [String: Any]) ?? [:]
            let vars = LegadoEngineHost.Vars()
            // ① 书源变量（map）
            if let seed = raw["__variables"] as? String, !seed.isEmpty,
               let d = seed.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { vars.put(k, "\(v)") }
            }
            // ② 站方变量（Legado 语义：一整串 JSON）⇒ 也并进同一格
            if let sv = raw["__variable"] as? String, !sv.isEmpty {
                vars.putVariable(sv)
            }
            self.variables = vars
            self.seeded = vars.getVariable()
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    // MARK: - 入口

    /// ⭐ **同步外壳 + 异步内核**（App 的调用点是同步的 ⇒ 这里用 Task + 信号量桥接）
    /// ⚠️ 调用方**必须**在后台线程（`SourceService` 已经保证）⭐⭐⭐
    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Any?, Error> = .success(nil)
        Task.detached(priority: .userInitiated) {
            do {
                let v = try await Self.run(op, payload, source: source, sessions: self)
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
    func dropSession(for key: String) {
        lock.lock(); sessions.removeValue(forKey: key); lock.unlock()
    }

    /// ⭐⭐⭐ **清空所有会话**（诊断面板「重置会话」）
    func dropAllSessions() {
        lock.lock(); sessions.removeAll(); lock.unlock()
    }

    /// op 的超时预算（内容类给得宽，因为站方会逐条试多条线路）
    static func timeoutSeconds(for op: String) -> TimeInterval {
        switch op {
        case "bookInfo", "toc", "content": return 300
        case "login", "loginProbe": return 120
        default: return 60
        }
    }

    // MARK: - 真正的实现（异步）

    private static func run(_ op: String, _ payload: [String: Any],
                            source: BookSource,
                            sessions: LegadoEngineBackend) async throws -> Any? {
        let engineSource = try parseSource(payload, fallback: source)
        let session = LegadoEngineBackend.session(for: engineSource.bookSourceUrl,
                                                 engineSource: engineSource,
                                                 payload: payload, sessions: sessions)
        var out: [String: Any]
        #if canImport(JavaScriptCore) && !os(Linux)
        // ⭐⭐⭐⭐⭐ **筛选栏 action**（2026-11-19 新引擎接线）
        //   ⇒ 站方 action 里的 `source.put('order', 2)` / `source.put('type', …)` **必须写进去**
        //   ⇒ 写不进去 ⇒ explore 的 `order_type` 取旧值 ⇒ **服务端 HTTP 500** ⇒ 发现页全空 ⭐⭐⭐
        //   ⇒ 用引擎的 `JSBridge` 跑（它会自动加载站方 jsLib ⇒ 站方函数都在）⭐⭐⭐
        if op == "filterAction" {
            let action = (payload["action"] as? String) ?? ""
            guard !action.isEmpty else {
                out = ["ok": false, "error": "没有筛选动作", "msgs": []]
                break
            }
            let host = LegadoJSHost()
            let bridge = LegadoEngineHost.Bridge(source: engineSource, book: book(from: payload),
                                                 chapter: nil, variables: session.variables, host: host)
            do {
                _ = try bridge.eval(action, bindings: ["result": [:]])
                out = ["ok": true, "msgs": host.messages]
            } catch {
                out = ["ok": false, "error": String(describing: error), "msgs": host.messages]
            }
            out["__sourceVars"] = session.variables.getVariable()
            out["__sourceVariable"] = session.variables.getVariable()
            out["__sourceVariableChanged"] = (session.variables.getVariable() != session.seeded)
            return out
        }
        // ⭐⭐⭐ **登录链路**：新引擎不含登录 UI ⇒ 宿主自己跑站方的 `loginUrl` 动作 / `loginCheckJs`
        //   ⇒ 用引擎的 `JSBridge`（它会自动加载站方 jsLib ⇒ 站方函数都在）⭐⭐⭐
        if op == "login" || op == "loginProbe" {
            let host = LegadoJSHost()
            let bridge = LegadoEngineHost.Bridge(source: engineSource, book: book(from: payload),
                                                 chapter: nil, variables: session.variables, host: host)
            if op == "login" {
                let action = (payload["action"] as? String) ?? ""
                guard !action.isEmpty else {
                    out = ["ok": false, "error": "没有登录动作", "msgs": []]
                    break
                }
                // 表单值先并进 `result`（站方 login(true) 第一步就是 putLoginInfo(result)）
                let formValues = (payload["formValues"] as? [String: Any]) ?? [:]
                do {
                    _ = try bridge.eval(action, bindings: ["result": formValues])
                    out = ["ok": true, "msgs": host.messages]
                } catch {
                    out = ["ok": false, "error": String(describing: error), "msgs": host.messages]
                }
            } else {
                // 登录态探测：跑站方的 `loginCheckJs`
                let js = engineSource.loginCheckJs ?? ""
                if js.isEmpty {
                    out = ["ok": false, "error": "书源没有 loginCheckJs", "msgs": []]
                } else {
                    do {
                        _ = try bridge.eval(js, bindings: [:])
                        out = ["ok": true, "msgs": host.messages]
                    } catch {
                        out = ["ok": false, "error": String(describing: error), "msgs": host.messages]
                    }
                }
            }
            // ⭐⭐⭐ **站方 JS 改过的变量 ⇒ 回传**（宿主落盘 ⇒ 下次直接生效）
            out["__sourceVars"] = session.variables.getVariable()
            out["__sourceVariable"] = session.variables.getVariable()
            out["__sourceVariableChanged"] = (session.variables.getVariable() != session.seeded)
            return out
        }
        #endif
        switch op {
        case "search":
            let key = (payload["keyword"] as? String) ?? ""
            let page = (payload["page"] as? Int) ?? 1
            let books = try await LegadoEngine.search(source: engineSource, key: key,
                                                      page: page, variables: session.variables)
            out = ["books": books.map { bookListItem($0) }]
            out["total"] = books.count
            out["nextUrl"] = ""
        case "exploreKinds":
            let kinds = LegadoEngine.exploreKinds(source: engineSource)
            out = ["kinds": kinds.map { ["title": $0.title, "url": $0.url] }, "filters": []]
        case "explore":
            let kind = LegadoEngineHost.Kind(title: (payload["kindTitle"] as? String) ?? "",
                                            url: (payload["kindUrl"] as? String) ?? "")
            let page = (payload["page"] as? Int) ?? 1
            let books = try await LegadoEngine.explore(source: engineSource, kind: kind,
                                                      page: page, variables: session.variables)
            out = ["books": books.map { bookListItem($0) }]
            out["total"] = books.count
            out["nextUrl"] = ""
        case "bookInfo":
            let info = try await LegadoEngine.bookInfo(source: engineSource, book: book(from: payload),
                                                       variables: session.variables)
            out = ["book": bookPayload(info)]
        case "toc":
            let b = book(from: payload)
            let chapters = try await LegadoEngine.chapters(source: engineSource, book: b,
                                                          variables: session.variables)
            let list: [[String: Any]] = chapters.map { c in
                ["url": c.url, "title": c.title, "index": c.index,
                 "isVolume": c.isVolume, "isVip": c.isVip, "isPay": c.isPay,
                 "updateTime": c.updateTime ?? "", "tag": ""]
            }
            out = ["chapters": list, "rawCount": chapters.count, "bookName": b.name]
        case "explain", "explainToc":
            // ⭐⭐⭐ **诊断 op**（老引擎的 `explain` / `explainToc` 随老引擎一起退役）
            //   ⇒ 用**新引擎的 AnalyzeUrl** 复刻：发一次请求，把 URL/状态/字节报出来 ⭐⭐⭐
            let ruleUrl = (payload["tocUrl"] as? String) ?? (payload["kindUrl"] as? String)
                ?? (payload["bookUrl"] as? String) ?? ""
            do {
                let au = try LegadoEngineHost.UrlBuilder(ruleUrl: ruleUrl,
                                                        key: payload["keyword"] as? String,
                                                        page: (payload["page"] as? Int) ?? 1,
                                                        source: engineSource,
                                                        book: book(from: payload),
                                                        variables: session.variables)
                let resp = try await au.fetch()
                out = ["请求URL": ruleUrl, "最终URL": resp.url.absoluteString,
                       "状态码": String(resp.statusCode), "响应字节": String(resp.body.utf8.count),
                       "页面标题": "", "说明": "诊断已随老引擎退役 ⇒ 这里用新引擎的 AnalyzeUrl 复刻"]
            } catch {
                out = ["请求URL": ruleUrl, "错误": String(describing: error)]
            }
        case "content":
            let ch = chapter(from: payload)
            let text = try await LegadoEngine.content(source: engineSource, book: book(from: payload),
                                                       chapter: ch, variables: session.variables)
            out = ["title": ch.title, "content": text, "nextUrl": ""]
        default:
            // ⚠️ **不认识就明确报错**（不静默返回空 ⇒ 不假成功）⭐⭐⭐
            throw ServiceError.engineFailed("新引擎不支持「\(op)」这个操作")
        }
        // ⭐⭐⭐ **站方 JS 改过的变量 ⇒ 回传**（宿主落盘 ⇒ 下次直接生效）
        out["__sourceVars"] = session.variables.getVariable()
        out["__sourceVariable"] = session.variables.getVariable()
        // ⭐⭐⭐ **「改没改」只认与种子比较**（证据不许自证）⭐⭐⭐
        out["__sourceVariableChanged"] = (session.variables.getVariable() != session.seeded)
        return out
    }

    /// 取（or 建）这个源的会话
    fileprivate static func session(for key: String, engineSource: LegadoEngineHost.Source,
                                     payload: [String: Any], sessions: LegadoEngineBackend) -> Session {
        sessions.lock.lock()
        if let s = sessions.sessions[key] { sessions.lock.unlock(); return s }
        sessions.lock.unlock()
        let s = Session(engineSource: engineSource, payload: payload)
        sessions.lock.lock(); sessions.sessions[key] = s; sessions.lock.unlock()
        return s
    }

    // MARK: - 形状对齐（App 侧的契约）

    private static func bookListItem(_ b: LegadoEngineHost.SearchResult) -> [String: Any] {
        [
            "name": b.name,
            "author": b.author,
            "intro": b.intro ?? "",
            "kind": b.kind ?? "",
            "lastChapter": b.lastChapter ?? "",
            "coverUrl": b.coverUrl ?? "",
            "bookUrl": b.bookUrl,
            "wordCount": b.wordCount ?? "",
            "tocUrl": "",
            "group": b.originName,
            "updateTime": b.updateTime ?? "",
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
        b.latestChapterTitle = raw["lastChapter"] as? String
        b.tocUrl = (payload["tocUrl"] as? String) ?? (raw["tocUrl"] as? String) ?? ""
        b.variable = raw["variable"] as? String
        return b
    }

    /// 从 payload 里还原引擎的 `BookChapter`
    private static func chapter(from payload: [String: Any]) -> LegadoEngineHost.ChapterModel {
        let raw = (payload["chapter"] as? [String: Any]) ?? [:]
        let c = LegadoEngineHost.ChapterModel()
        c.url = (payload["chapterUrl"] as? String) ?? (raw["url"] as? String) ?? ""
        c.title = (raw["title"] as? String) ?? ""
        c.index = (raw["index"] as? Int) ?? 0
        c.isVolume = (raw["isVolume"] as? Bool) ?? false
        c.isVip = (raw["isVip"] as? Bool) ?? false
        c.isPay = (raw["isPay"] as? Bool) ?? false
        c.updateTime = raw["updateTime"] as? String
        c.variable = raw["variable"] as? String
        return c
    }

    // MARK: - 书源解析

    /// ⭐⭐⭐ **书源 JSON 优先用 payload 里那份**（带 `__variables` ⇒ 宿主注入的解锁态/登录态）
    ///   ⇒ 不用 App 自己的模型回编 JSON（少一层漂移）⭐⭐⭐
    private static func parseSource(_ payload: [String: Any],
                                    fallback: BookSource) throws -> LegadoEngineHost.Source {
        if let dict = payload["source"] as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let parsed = try? LegadoEngineHost.Source.parse(data), !parsed.isEmpty {
            return parsed[0]
        }
        // 兜底：用 App 的模型回编
        if let data = try? JSONEncoder().encode(fallback),
           let parsed = try? LegadoEngineHost.Source.parse(data), !parsed.isEmpty {
            return parsed[0]
        }
        throw ServiceError.engineFailed("书源 JSON 解析失败")
    }
}

/// ⭐⭐⭐ **站方 JS 的宿主**（新引擎 `JSHost` 协议）
///
/// ⚠️ 站方**只用 toast / log 报登录结果**（「✅️登录成功」/「💔登录失败」）
///   ⇒ toast 一闪而过 ⇒ 用户根本不知道成没成 ⇒ 这里**把原文收回来**给 UI 显示 ⭐⭐⭐
#if canImport(JavaScriptCore) && !os(Linux)
final class LegadoJSHost: LegadoEngineHost.Host {
    private(set) var messages: [String] = []

    func jsLog(_ msg: String) {
        messages.append(msg)
    }

    func jsToast(_ msg: String) {
        messages.append(msg)
    }
}
#endif
