import Foundation
import ChaiyueModels

/// 书源事件（Legado `SourceCallBack`），`eventListener` 开启时以 `event` 变量传给正文规则的 `callBackJs`
public enum SourceCallBackEvent: String, Sendable, CaseIterable {
    case addBookShelf
    case delBookShelf
    case clickCustomButton
    case longClickCustomButton
    case startRead
    case endRead
    case saveRead
    case clickAuthor
    case clickBookName
    case clickShareBook
    case clickClearCache
    case startShelfRefresh
    case endShelfRefresh
}

extension WebBook {
    /// 书源是否监听事件
    public var hasCallBack: Bool {
        source.eventListener && !(source.ruleContent?.callBackJs ?? "").isBlank
    }

    /// 执行 `callBackJs`：可用 jsLib、source、book、chapter、java、cookie、cache，`event` 为事件名。
    /// 在规则线程上执行，出错只写日志
    public func callBack(event: SourceCallBackEvent, book: Book?, chapter: BookChapter? = nil) async {
        guard hasCallBack, let js = source.ruleContent?.callBackJs else { return }
        let key = source.bookSourceUrl
        do {
            _ = try await RuleSession.run(SourceDescriptor(source), env: environment) { session -> Bool in
                var bindings = JSBindings(host: nil)
                bindings.baseUrl = session.source.key
                bindings.book = book.map(BookRef.init)
                bindings.chapter = chapter.map(ChapterRef.init)
                bindings.extra = ["event": event.rawValue]
                _ = try session.evalJS(js, bindings: bindings)
                return true
            }
        } catch {
            environment.log(key, "callBack(\(event.rawValue)) error: \(error)")
        }
    }

    /// 登录界面行：`loginUi` 为 `@js:`/`<js>` 时执行脚本生成（每次 `java.reLoginView()` 后重新执行），否则直接解析
    public func resolveLoginRows() async throws -> [LoginRow] {
        guard let script = SourceDescriptor.inlineJs(source.loginUi) else { return loginRows }
        let saved = savedLoginInfo
        return try await RuleSession.run(SourceDescriptor(source), env: environment) { session in
            let value = try session.withLoginExtensions {
                try session.evalSourceJS((session.source.loginJs ?? "") + "\n" + script, result: JavaMap(saved))
            }
            return Self.parseLoginRows(AnalyzeUrl.stringify(value))
        }
    }
}

extension RuleSession {
    /// 登录界面相关脚本（login、按钮 action、JS 生成的 loginUi）期间才提供 `java.reLoginView`/`java.upLoginData`，
    /// 与 Legado 的 `SourceLoginJsExtensions` 一致；部分书源靠它们是否存在判断运行环境
    func withLoginExtensions<T>(_ body: () throws -> T) rethrows -> T {
        let bridge = js.bridge!
        bridge.enterLoginContext()
        defer { bridge.leaveLoginContext() }
        return try body()
    }

    /// `java.upLoginData`：合并进已保存的登录信息
    func mergeLoginInfo(_ data: [String: String?]) -> [String: String] {
        var info = state.loginInfo.flatMap { LenientJSON.stringMap($0) } ?? [:]
        var changed: [String: String] = [:]
        for (k, v) in data {
            info[k] = v
            changed[k] = v ?? ""
        }
        state.loginInfo = LenientJSON.serialize(info)
        return changed
    }
}
