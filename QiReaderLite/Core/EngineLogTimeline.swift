import Foundation

/// **引擎日志 → 分步时间线**
///
/// ⭐ 对齐栖阅的诊断体系（用户给的截图）：栖阅的日志是**分步事件链**，
///   轻阅原来只有一坨字符串流水 ⇒ 排查「时好时坏」时**看不出断在哪一步**。
///
/// 日志行格式（`RuleSandbox.appendLog` 统一加工）：
///     `[19:56:07.123] [目录] 内容…`
///
/// 这个解析器是**纯 Foundation** ⇒ 沙盒 swiftc 能真编真跑 ✅
enum EngineLogTimeline {

    /// 一个步骤的日志组
    struct Group: Identifiable, Equatable {
        let id: String
        var lines: [String] = []
        /// 出错的条数
        var errors: Int = 0
    }

    /// 一条日志 → 步骤名
    ///
    /// - Parameter fallback: 当前 op 的步骤名（`[两遍跑]…` 这种没有自己步骤名的日志用它）
    static func step(of line: String, fallback: String = "引擎") -> String {
        if line.hasPrefix("[目录]") { return "目录" }
        if line.hasPrefix("[详情]") { return "详情" }
        if line.hasPrefix("[正文]") { return "正文" }
        if line.hasPrefix("[发现]") { return "发现" }
        if line.hasPrefix("[搜索]") { return "搜索" }
        if line.hasPrefix("[登录]") { return "登录" }
        if line.hasPrefix("[ajax") { return "网络" }
        if line.hasPrefix("[Swift·") { return "宿主" }
        if line.hasPrefix("[选线]") { return "选线" }
        if line.hasPrefix("[诊断]") { return "诊断" }
        return fallback.isEmpty ? "引擎" : fallback
    }

    /// **出错？** —— 这些词出现就当错误（栖阅用 ⚠️ 标，我们用关键词）
    static func isError(_ line: String) -> Bool {
        let marks = ["失败", "异常", "错误", "轮数用尽", "不可用", "超时", "崩"]
        return marks.contains { line.contains($0) }
    }

    /// 按步骤分组（保持首次出现的顺序 = 时间顺序）
    static func groups(_ logs: [String]) -> [Group] {
        var order: [String] = []
        var map: [String: Group] = [:]
        for line in logs {
            let s = step(of: line)
            if map[s] == nil {
                order.append(s)
                map[s] = Group(id: s)
            }
            map[s]?.lines.append(line)
            if isError(line) { map[s]?.errors += 1 }
        }
        return order.compactMap { map[$0] }
    }

    /// **每一步的耗时**（从 `⏱ op「toc」耗时 123ms` 里解析）
    /// ⇒ 栖阅那种「目录 2.32s / 正文 1.38s」
    static func timings(_ logs: [String]) -> [(step: String, ms: Int)] {
        var out: [(step: String, ms: Int)] = []
        for line in logs {
            guard let r = line.range(of: "op「"),
                  let t = line.range(of: "」耗时 ") else { continue }
            let op = String(line[r.upperBound..<t.lowerBound])
            let rest = line[t.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let ms = Int(digits) {
                out.append((RuleSandbox.stepNameForOp(op), ms))
            }
        }
        return out
    }

    /// 毫秒 → 人话
    static func fmtMS(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.2fs", Double(ms) / 1000.0)
    }
}
