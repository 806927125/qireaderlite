import Foundation

// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//   · Linux 沙盒没有 JavaScriptCore ⇒ `ReaderThemeScript` 的脚本执行部分编不到 ⭐⭐⭐
//   ⇒ 真实实现整体放进 `#if canImport(JavaScriptCore)`；Linux 上用 `ReaderThemeScriptStub.swift` 的桩 ⭐⭐⭐
//   ⇒ **Apple 平台功能完全不变**；桩「如实失败」（不伪装成功）⇒ 门禁不会假绿 ⭐⭐⭐
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// 页眉页脚的三段文字
public struct ReaderChromeText: Sendable, Hashable {
    public var left: String
    public var center: String
    public var right: String

    public init(left: String = "", center: String = "", right: String = "") {
        self.left = left
        self.center = center
        self.right = right
    }

    public var isEmpty: Bool { left.isEmpty && center.isEmpty && right.isEmpty }
}

/// 传给脚本的 `ctx`
public struct ReaderScriptContext: Sendable, Hashable {
    public var book: String
    public var author: String
    public var chapter: String
    public var chapterIndex: Int
    public var chapterCount: Int
    /// 从 1 开始
    public var page: Int
    public var pages: Int
    /// 全书进度 0–100
    public var percent: Double
    public var time: String
    /// 0–100，未知时为 -1
    public var battery: Int

    public init(book: String, author: String, chapter: String, chapterIndex: Int, chapterCount: Int, page: Int, pages: Int,
                percent: Double, time: String, battery: Int) {
        self.book = book
        self.author = author
        self.chapter = chapter
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.page = page
        self.pages = pages
        self.percent = percent
        self.time = time
        self.battery = battery
    }

    var dictionary: [String: Any] {
        ["book": book, "author": author, "chapter": chapter, "chapterIndex": chapterIndex, "chapterCount": chapterCount,
         "page": page, "pages": pages, "percent": percent, "time": time, "battery": battery]
    }
}

/// 阅读主题脚本。可定义的函数（都可省略）：
/// - `header(ctx)` / `footer(ctx)`：返回字符串或 `{ left, center, right }`，返回 null 用默认内容
/// - `paragraphClass(text, index)`：返回类名（对应样式表里的 `p.类名`），null 表示不分类
///
/// 脚本跑在独立线程的 JavaScriptCore 里，没有网络、文件与定时器；单次调用超时后整份脚本停用，阅读照常
#if canImport(JavaScriptCore)
public final class ReaderThemeScript: @unchecked Sendable {
    public private(set) var error: String?
    public private(set) var hasHeader = false
    public private(set) var hasFooter = false
    public private(set) var hasParagraphClass = false
    /// 超时或出错次数过多后停用
    public private(set) var disabled = false
    /// 运行中输出的 console.log 与异常，供编辑器显示
    public var log: [String] { lock.withLock { messages } }

    private let queue = DispatchQueue(label: "chaiyue.theme-script")
    private var context: JSContext?
    private let lock = NSLock()
    private var messages: [String] = []
    private var failures = 0

    public init(source: String, timeout: TimeInterval = 1) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let done = run(timeout: max(timeout, 1)) { [self] () -> String? in
            guard let context = JSContext() else { return "无法创建脚本环境" }
            context.name = "柴阅主题脚本"
            var thrown: String?
            context.exceptionHandler = { _, value in
                thrown = value?.toString()
            }
            let logger: @convention(block) () -> Void = { [weak self] in
                let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
                self?.record(parts.joined(separator: " "))
            }
            let console = JSValue(newObjectIn: context)
            console?.setObject(logger, forKeyedSubscript: "log" as NSString)
            context.setObject(console, forKeyedSubscript: "console" as NSString)
            context.evaluateScript(Self.prelude)
            context.evaluateScript(source)
            if let thrown { return thrown }
            context.exceptionHandler = { [weak self] _, value in
                self?.record("异常：\(value?.toString() ?? "")")
            }
            self.context = context
            func defined(_ name: String) -> Bool {
                context.evaluateScript("typeof \(name) === 'function'")?.toBool() ?? false
            }
            hasHeader = defined("header")
            hasFooter = defined("footer")
            hasParagraphClass = defined("paragraphClass")
            return nil
        }
        switch done {
        case .some(.some(let message)): error = message
        case .some(.none): break
        case .none: error = "脚本执行超时（可能有死循环）"
        }
        if error != nil { disabled = true }
    }

    public var isUsable: Bool { !disabled && context != nil }

    public func header(_ ctx: ReaderScriptContext) -> ReaderChromeText? {
        guard hasHeader else { return nil }
        return chrome("header", ctx)
    }

    public func footer(_ ctx: ReaderScriptContext) -> ReaderChromeText? {
        guard hasFooter else { return nil }
        return chrome("footer", ctx)
    }

    /// 一章所有段落的类名，下标为段落序号；没有类的段落不出现
    public func paragraphClasses(_ paragraphs: [String]) -> [Int: String] {
        guard hasParagraphClass, isUsable, !paragraphs.isEmpty else { return [:] }
        let result = run(timeout: 1.5) { [self] () -> [Int: String] in
            guard let context, let function = context.objectForKeyedSubscript("__classify") else { return [:] }
            let values = function.call(withArguments: [paragraphs])?.toArray() ?? []
            var map: [Int: String] = [:]
            for (index, value) in values.enumerated() {
                if let name = value as? String, !name.isEmpty { map[index] = name }
            }
            return map
        }
        guard let result else {
            timedOut()
            return [:]
        }
        return result
    }

    private func chrome(_ name: String, _ ctx: ReaderScriptContext) -> ReaderChromeText? {
        guard isUsable else { return nil }
        let result = run(timeout: 0.1) { [self] () -> ReaderChromeText? in
            guard let context, let function = context.objectForKeyedSubscript(name) else { return nil }
            guard let value = function.call(withArguments: [ctx.dictionary]), !value.isNull, !value.isUndefined else { return nil }
            if value.isString { return ReaderChromeText(left: value.toString() ?? "") }
            guard value.isObject else { return ReaderChromeText(left: value.toString() ?? "") }
            func part(_ key: String) -> String {
                guard let item = value.objectForKeyedSubscript(key), !item.isUndefined, !item.isNull else { return "" }
                return item.toString() ?? ""
            }
            return ReaderChromeText(left: part("left"), center: part("center"), right: part("right"))
        }
        guard let result else {
            timedOut()
            return nil
        }
        return result
    }

    /// 在脚本线程上执行，超时返回 nil（脚本线程可能还卡着，之后不再往里派活）
    private func run<T>(timeout: TimeInterval, _ work: @escaping () -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        queue.async {
            box.value = work()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private func timedOut() {
        record("调用超时，脚本已停用")
        disabled = true
    }

    private func record(_ message: String) {
        lock.withLock {
            messages.append(message)
            if messages.count > 50 { messages.removeFirst(messages.count - 50) }
        }
    }

    /// 批量分类：单段出错只影响这一段
    private static let prelude = """
    var __classify = function (list) {
      if (typeof paragraphClass !== 'function') return [];
      return list.map(function (text, index) {
        try { var r = paragraphClass(text, index); return r == null ? '' : String(r); } catch (e) { return ''; }
      });
    };
    """
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
#endif  // #if canImport(JavaScriptCore)
