import Foundation
import LegadoCore

/// ⭐⭐⭐⭐⭐ **WKWebView 版 JS 执行器**（2026-10-26 · 跟老引擎一样）
///
/// ⭐⭐⭐ **它换掉了什么**：
///   旧：`JSCExecutor` ⇒ 站方 JS 跑在 **App 进程内**（JSC）⇒ 一次能吃几 GB ⇒ **jetsam 秒杀 App**
///   新：`WebViewJSExecutor` ⇒ 站方 JS 跑在 **WebContent 独立进程** ⇒ **炸的也是它** ⇒ App 不死 ⭐⭐⭐
///
/// ⭐⭐⭐ **行为必须与 JSC 版逐字一致**（不然同一个书源两个引擎结果不同 ⇒ 没法对比）
///   ⇒ **形态链**用引擎的同一份真相 `JSEvalShape.scripts(for:scope:)`（public）⭐
///   ⇒ **scope 前导**用同一份 `JSScopeBuilder.build(_:)`（public）⭐
///   ⇒ **宿主调用**用同一套约定（`__hostJSON` ⇒ 数组包一层 / `__qrNotImplemented`）⭐
///   ⇒ **全局治理**照抄 JSC 版的两个脚本（枚举 / 置 undefined）⭐
///
/// ⚠️ **线程**：`run` 必须**不在主线程**调用（要阻塞等主线程回话）
///   ⇒ App 侧 `withRealTimeout` 已经把引擎调用放在 `DispatchQueue.global` 上 ✔（老引擎同款约束）
///   ⇒ 万一在主线程调 ⇒ 立刻抛错（**不许死等**）⭐
final class WebViewJSExecutor: JSExecutor {

    /// 宿主 API（`java.*` 与宿主对象）
    private let api: JSHostAPIProvider

    /// ⭐ 引擎侧接管的 `java.*`（`ajax` / `md5Encode` / …）
    private var engineAPI: JSEngineAPIHandler?

    /// ⭐ 当前基准（`java.getString('$.x')` 要对它求值）
    private var currentBase: RuleBase = .page("")

    /// ⭐ 本次求值的宿主对象（`source` / `book` / `chapter`）
    private var currentHostObjects: [String: HostObject] = [:]

    /// ⭐ 基线全局快照（相对它新增的全局每次清掉 ⇒ 站方 jsLib 不串源）
    private var baselineGlobals: Set<String> = []

    init(api: JSHostAPIProvider) {
        self.api = api
    }

    // MARK: - 协议

    func setEngineAPI(_ handler: JSEngineAPIHandler?) {
        engineAPI = handler
    }

    func markGlobalsAsBaseline() {
        WebViewJSBridge.shared.lock.lock()
        defer { WebViewJSBridge.shared.lock.unlock() }
        baselineGlobals = WebViewJSBridge.shared.currentGlobals()
    }

    func invalidate() {
        WebViewJSBridge.shared.lock.lock()
        defer { WebViewJSBridge.shared.lock.unlock() }
        // ⭐ 共享 WebView ⇒ 「作废上下文」= 把全局恢复成启动时的样子
        let boot = WebViewJSBridge.shared.bootGlobals
        if !boot.isEmpty { WebViewJSBridge.shared.removeGlobals(notIn: boot) }
        baselineGlobals = boot
    }

    /// ⭐⭐⭐ **刷新宿主对象的属性**（JSC 路径 `injectHostProperties` 的等价物）
    ///
    /// ⚠️ **为什么必须有**：JSC 每次 op 前都把 `source.name` / `source.bookSourceUrl` 这类
    ///   **属性值**重新写进 JS（不只方法）⇒ WebView 若只在启动时写一次 ⇒ **属性是过期的**
    ///   ⇒ 站方 JS 读到上一次的 source ⇒ 静默出错（不报错、结果不对）⭐⭐⭐
    /// ⇒ 方法走 `__hostJSON`（每次都新）⇒ **只有属性需要刷新** ⭐
    private func refreshHostProperties() {
        var lines: [String] = []
        for name in ["source", "book", "chapter", "cookie", "cache"] {
            guard let obj = api.hostObject(named: name) else { continue }
            for (prop, value) in obj.properties {
                lines.append("try{\(name).\(prop)=\(JSScopeBuilder.jsonLiteral(value));}catch(e){}")
            }
        }
        guard !lines.isEmpty else { return }
        _ = try? evaluateSync(lines.joined(separator: "\n"))
    }

    func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        // ⭐⭐⭐ **全局串行**（所有源共用一台 WebView ⇒ 一条 JS 线程 ⇒ 只能一个一个来）
        //   ⇒ 同时也是「同步通道不会串」的保证（当前上下文唯一）⭐
        WebViewJSBridge.shared.lock.lock()
        defer { WebViewJSBridge.shared.lock.unlock() }

        currentBase = context.base
        currentHostObjects = Self.hostObjects(from: context)
        // ⭐ 同步通道的「当前上下文」= 本执行器（同步通道在主线程回调 ⇒ 必须能拿到它）
        WebViewJSBridge.shared.current = self

        // ⭐⭐⭐ 刷新宿主属性（属性是值 ⇒ 必须每次 op 刷新）★
        refreshHostProperties()
        // ⭐⭐ 清理站方残留的全局（复用 context 的代价 ⇒ 必须治）★ 语义与 JSC 版一致
        WebViewJSBridge.shared.removeGlobals(notIn: baselineGlobals)

        let scope = JSScopeBuilder.build(context)
        var firstError: String?
        var attemptsLog: [String] = []
        for (i, src) in JSEvalShape.scripts(for: code, scope: scope).enumerated() {
            // ⭐ 完成值统一在 JS 侧 `JSON.stringify`（WKWebView 桥接不了对象/函数）
            let wrapped = "JSON.stringify((0,eval)(" + JSEvalShape.jsonLiteral(src) + "))"
            do {
                let text = try WebViewJSBridge.shared.evaluateSync(wrapped)
                return Self.parseValue(text)
            } catch let e as WebViewJSError {
                // ⭐⭐⭐ **只有【语法错】才换下一种形态**（与 JSC 版逐字一致）
                //   ⇒ 运行时错误直接抛 ⇒ **站方 JS 只执行一次** ⇒ 副作用不重复（限流/登录）⭐⭐⭐
                if !e.isSyntaxError {
                    throw e
                }
                attemptsLog.append("#\(i + 1): \(e.message)")
                if firstError == nil { firstError = e.message }
            }
        }
        throw WebViewJSError(message: "站方 JS 三种形态都失败："
                              + (firstError ?? "未知") + " | " + attemptsLog.joined(separator: " || "))
    }

    func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue {
        WebViewJSBridge.shared.lock.lock()
        defer { WebViewJSBridge.shared.lock.unlock() }
        currentBase = context.base
        currentHostObjects = Self.hostObjects(from: context)
        WebViewJSBridge.shared.current = self
        // ⭐ 全局求值（间接 eval）⇒ jsLib 的 `var` / `function` 留在全局（老引擎同款）
        let wrapped = "JSON.stringify((0,eval)(" + JSEvalShape.jsonLiteral(code) + "))"
        let text = try WebViewJSBridge.shared.evaluateSync(wrapped)
        return Self.parseValue(text)
    }

    // MARK: - 宿主对象

    private static func hostObjects(from ctx: JSRunContext) -> [String: HostObject] {
        var out: [String: HostObject] = [:]
        if let s = ctx.source { out["source"] = s }
        if let b = ctx.book { out["book"] = b }
        if let c = ctx.chapter { out["chapter"] = c }
        return out
    }

    // MARK: - 同步通道的 Swift 侧（照抄 JSC 版 `makeHostBlock` 的语义）

    fileprivate func handleSync(_ payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = obj["o"] as? String,
              let method = obj["m"] as? String else {
            return #"{"__qrNotImplemented":true}"#
        }
        let argsJSON = obj["a"] as? String ?? "[]"
        var args: [JSONValue] = []
        if let d = argsJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] {
            args = arr.map { JSONValue.from($0) }
        }
        // ① 引擎侧接管（`ajax` / `md5Encode` / `base64*` / …）⇒ 返回 nil = 「我不接管」⇒ 落回宿主
        if object == "java", let engineAPI, let r = engineAPI(method, args, currentBase) {
            return Self.wrapResult(r)
        }
        // ② 宿主
        let result: JSONValue?
        if object == "java" {
            result = api.callJava(method, args)
        } else {
            result = currentHostObjects[object]?.call(method, args)
                ?? api.hostObject(named: object)?.call(method, args)
        }
        guard let result else { return #"{"__qrNotImplemented":true}"# }
        // ⭐⭐⭐ **取证**：宿主调用返回了多大的东西？（站方的 `java.ajax` 会把整个响应体搬回来）⭐
        if let any = result.foundationValue as? String, any.utf8.count > WebViewJSBridge.logThresholdBytes {
            engineLog("[桥接] op=\(LegadoEngineBackend.currentOp) 宿主返回 \(object).\(method) = "
                      + "\(any.utf8.count / 1024)KB")
        }
        return Self.wrapResult(result)
    }

    /// ⭐ 顶层标量不能 JSON 序列化 ⇒ 统一**包一层数组**（JS 侧取 `[0]` 还原）—— 与 JSC 版逐字一致
    private static func wrapResult(_ value: JSONValue) -> String {
        let any = value.foundationValue
        guard let data = try? JSONSerialization.data(withJSONObject: [any]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func parseValue(_ text: String?) -> JSONValue {
        guard let text, !text.isEmpty else { return .null }
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else {
            return .null
        }
        return JSONValue.from(any)
    }
}

/// ⭐⭐⭐⭐⭐ **共享桥**（所有执行器共用一台 WebView ⇒ 串行 + 同步通道的「当前上下文」唯一）
final class WebViewJSBridge: @unchecked Sendable {
    static let shared = WebViewJSBridge()

    /// ⭐ 全局串行锁（一台 WebView = 一条 JS 线程）
    let lock = NSLock()

    /// ⭐ 当前正在跑的执行器（同步通道在主线程回调 ⇒ 要能找到它）
    weak var current: WebViewJSExecutor?

    /// 启动后的全局快照（`invalidate()` 的还原目标）
    /// ⭐ **惰性取**（第一次用时才回读）⇒ 因为回读必须**不在主线程**（否则死锁）⭐
    private var _bootGlobals: Set<String>?
    var bootGlobals: Set<String> {
        if let g = _bootGlobals { return g }
        let g = readBootGlobals()
        _bootGlobals = g
        return g
    }

    /// ⭐ 读 JS 注入时拍好的那张表（`globalThis.__qrBootGlobals`）
    private func readBootGlobals() -> Set<String> {
        guard let text = try? evaluateSync("JSON.stringify(globalThis.__qrBootGlobals || [])"),
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }

    // MARK: - 求值（同步：后台线程等主线程回话）

    func evaluateSync(_ js: String) throws -> String? {
        // ⭐⭐⭐ **脚本大小闸门**（2026-10-26 jetsam 4.2GB 实证）
        //   ⇒ 站方偶尔产出巨大的脚本/结果 ⇒ 搬进 App 进程就是撑爆 ⇒ 明确拒绝 + 记录长度 ⭐⭐⭐
        let jsBytes = js.utf8.count
        if jsBytes > Self.maxScriptBytes {
            let msg = "脚本 \(jsBytes / 1024 / 1024)MB 超过上限 ⇒ 已拒绝（op=\(LegadoEngineBackend.currentOp)）"
            engineLog("[桥接] ⛔️ " + msg)
            throw WebViewJSError(message: msg)
        }
        if jsBytes > Self.logThresholdBytes {
            engineLog("[桥接] op=\(LegadoEngineBackend.currentOp) 脚本 \(jsBytes / 1024)KB")
        }
        if Thread.isMainThread {
            // ⭐ 绝不阻塞主线程等自己（那叫死锁）⇒ 明确报错
            throw WebViewJSError(message: "引擎调用不能在主线程执行（WKWebView 后端要等主线程回话）")
        }
        final class Box: @unchecked Sendable {
            var text: String?
            var error: Error?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WebViewJSHost.shared.evaluate(js) { result in
                switch result {
                case .success(let t): box.text = t
                case .failure(let e): box.error = e
                }
                sem.signal()
            }
        }
        sem.wait()
        if let error = box.error {
            let msg = (error as NSError).localizedDescription
            throw WebViewJSError(message: msg, isSyntaxError: Self.looksLikeSyntaxError(msg))
        }
        // ⭐⭐⭐ **返回体大小闸门**：站方 JS 的返回值要搬回 App 进程 ⇒ 巨大返回体 = 撑爆 App
        if let text = box.text {
            let outBytes = text.utf8.count
            if outBytes > Self.maxResultBytes {
                let msg = "站方 JS 返回体 \(outBytes / 1024 / 1024)MB 超过上限 ⇒ 已拒绝（op=\(LegadoEngineBackend.currentOp)）"
                engineLog("[桥接] ⛔️ " + msg)
                throw WebViewJSError(message: msg)
            }
            if outBytes > Self.logThresholdBytes {
                engineLog("[桥接] op=\(LegadoEngineBackend.currentOp) 返回 \(outBytes / 1024)KB")
            }
        }
        return box.text
    }

    /// ⭐ 日志阈值（超过就记一笔 ⇒ 下次崩了能直接看出「谁在搬大东西」）
    static let logThresholdBytes = 256 * 1024
    /// ⭐ 脚本上限（8MB）
    static let maxScriptBytes = 8 * 1024 * 1024
    /// ⭐ 返回体上限（32MB）
    static let maxResultBytes = 32 * 1024 * 1024

    /// ⭐ 同步通道的入口（老引擎 `handleSync` 同款 ⇒ 语义同源）
    func handleSync(_ payload: String) -> String {
        current?.handleSync(payload) ?? #"{"__qrNotImplemented":true}"#
    }

    /// ⭐ 语法错判定（与 JSC 版的 `isSyntaxError` 同一套口径）
    static func looksLikeSyntaxError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("syntaxerror") || m.contains("unexpected token")
            || m.contains("illegal return") || m.contains("unexpected identifier")
    }

    // MARK: - 全局治理（照抄 JSC 版的两个脚本）

    func currentGlobals() -> Set<String> {
        let src = """
        (function(){
          var out=[], seen={}, gs=[];
          try{ if(typeof globalThis!=='undefined'&&globalThis) gs.push(globalThis); }catch(e){}
          try{ if(this&&typeof this==='object') gs.push(this); }catch(e){}
          for(var i=0;i<gs.length;i++){
            var names=Object.getOwnPropertyNames(gs[i]);
            for(var j=0;j<names.length;j++){ if(!seen[names[j]]){seen[names[j]]=1;out.push(names[j]);} }
          }
          return out.join(String.fromCharCode(1));
        })()
        """
        guard let text = try? evaluateSync(src), !text.isEmpty else { return [] }
        // ⚠️ `evaluateSync` 的结果是 `JSON.stringify` 过的 ⇒ 字符串带引号 ⇒ 先解包
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? String,
              !raw.isEmpty else { return [] }
        return Set(raw.components(separatedBy: "\u{1}"))
    }

    func removeGlobals(notIn keep: Set<String>) {
        let extras = currentGlobals().subtracting(keep)
        guard !extras.isEmpty else { return }
        let list = extras.sorted().map { name -> String in
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }.joined(separator: ",")
        _ = try? evaluateSync("(function(){var g=this;[\(list)].forEach(function(k){try{g[k]=undefined;}catch(e){}});})()")
    }
}

/// ⭐ WebView 后端的错误（带「是不是语法错」—— 决定要不要换下一种形态）
struct WebViewJSError: Error, LocalizedError {
    let message: String
    let isSyntaxError: Bool

    init(message: String, isSyntaxError: Bool = false) {
        self.message = message
        self.isSyntaxError = isSyntaxError
    }

    var errorDescription: String? { message }
}
