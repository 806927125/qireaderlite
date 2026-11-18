import Foundation

/// JSONPath 解析后端（自实现，语义对齐 Legado AnalyzeByJSonPath）。
public final class ByJSONPath {
    let root: Any

    public init(_ content: Any) {
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
                root = o
            } else { root = s }
        } else { root = content }
    }

    // MARK: 公开接口

    public func getList(_ rule: String) -> [Any] {
        var r = embed(rule)
        r = r.trimmingCharacters(in: .whitespaces)
        // || / && 备选路径（括号外切分）
        let alts = splitTop(r, separators: ["||", "&&"])
        if alts.count > 1 {
            let sep = r.contains("&&") && !r.contains("||") ? "&&" : "||"
            var out: [Any] = []
            for a in alts {
                let v = getList(a)
                if sep == "||" { if !v.isEmpty { return v } } else { out += v }
            }
            return out
        }
        if !r.hasPrefix("$") { r = "$." + r }
        guard let v = Self.evaluate(r, on: root) else { return [] }
        if let arr = v as? [Any] { return arr }
        return [v]
    }

    public func getStringList(_ rule: String) -> [String] {
        getList(rule).map { Self.stringify($0) }
    }

    public func getString(_ rule: String) -> String? {
        let list = getStringList(rule)
        if list.isEmpty { return nil }
        return list.count == 1 ? list[0] : list.joined(separator: "\n")
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }

    /// {$.xxx} 内嵌：用根对象求值后替换
    func embed(_ rule: String) -> String {
        var out = rule
        let pat = try! NSRegularExpression(pattern: "\\{(\\$[^{}]*)\\}")
        let ns = out as NSString
        let ms = pat.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for m in ms.reversed() {
            let sub = ns.substring(with: m.range(at: 1))
            if let v = Self.evaluate(sub, on: root) {
                out = (out as NSString).replacingCharacters(in: m.range, with: Self.stringify(v))
            }
        }
        return out
    }

    /// 括号外按分隔符切分
    func splitTop(_ s: String, separators: [String]) -> [String] {
        var parts: [String] = []
        var depth = 0, cur = "", i = s.startIndex
        var inQuote: Character? = nil
        while i < s.endIndex {
            let c = s[i]
            if let q = inQuote {
                cur.append(c)
                if c == q { inQuote = nil }
            } else if c == "'" || c == "\"" {
                inQuote = c; cur.append(c)
            } else if c == "[" || c == "(" || c == "{" {
                depth += 1; cur.append(c)
            } else if c == "]" || c == ")" || c == "}" {
                depth -= 1; cur.append(c)
            } else if depth == 0 {
                var matched = false
                for sep in separators where s[i...].hasPrefix(sep) {
                    parts.append(cur); cur = ""
                    i = s.index(i, offsetBy: sep.count)
                    matched = true
                    break
                }
                if matched { continue }
                cur.append(c)
            } else { cur.append(c) }
            i = s.index(after: i)
        }
        parts.append(cur)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: 路径求值

    enum Step {
        case key(String)
        case recursive(String)
        case index(Int)
        case indices([Int])
        case slice(Int?, Int?, Int)
        case wildcard
        case filter(String)
    }

    public static func evaluate(_ rule: String, on root: Any) -> Any? {
        var r = rule.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("$") { r.removeFirst() }
        let steps = parse(r)
        var nodes: [Any] = [root]
        for (i, step) in steps.enumerated() {
            var next: [Any] = []
            for n in nodes { apply(step, n, &next, afterDeep: i > 0 && isRecursivePrev(steps, i)) }
            nodes = next
            if nodes.isEmpty { return nil }
        }
        if nodes.count == 1 { return nodes[0] }
        return nodes
    }

    private static func isRecursivePrev(_ steps: [Step], _ i: Int) -> Bool {
        if case .recursive = steps[i - 1] { return true }
        return false
    }

    static func parse(_ r: String) -> [Step] {
        var steps: [Step] = []
        var i = r.startIndex
        func peek() -> Character? { i < r.endIndex ? r[i] : nil }
        while i < r.endIndex {
            let c = r[i]
            if c == "." {
                i = r.index(after: i)
                if peek() == "." { // 递归
                    i = r.index(after: i)
                    let name = readName(r, &i)
                    steps.append(.recursive(name.isEmpty ? "*" : name))
                } else if peek() == "[" || peek() == nil {
                    continue
                } else {
                    let name = readName(r, &i)
                    if !name.isEmpty { steps.append(.key(name)) }
                }
            } else if c == "[" {
                i = r.index(after: i)
                var body = "", depth = 1
                var q: Character? = nil
                while i < r.endIndex {
                    let ch = r[i]
                    if let qq = q { body.append(ch); if ch == qq { q = nil } }
                    else if ch == "'" || ch == "\"" { q = ch; body.append(ch) }
                    else if ch == "[" { depth += 1; body.append(ch) }
                    else if ch == "]" { depth -= 1; if depth == 0 { break }; body.append(ch) }
                    else { body.append(ch) }
                    i = r.index(after: i)
                }
                if i < r.endIndex { i = r.index(after: i) }
                steps.append(parseBracket(body))
            } else {
                let name = readName(r, &i)
                if !name.isEmpty { steps.append(.key(name)) }
            }
        }
        return steps
    }

    private static func readName(_ r: String, _ i: inout String.Index) -> String {
        var name = ""
        while i < r.endIndex, r[i] != ".", r[i] != "[" {
            name.append(r[i]); i = r.index(after: i)
        }
        return name
    }

    private static func parseBracket(_ body: String) -> Step {
        let b = body.trimmingCharacters(in: .whitespaces)
        if b == "*" { return .wildcard }
        if b.hasPrefix("?") {
            var f = String(b.dropFirst())
            f = f.trimmingCharacters(in: .whitespaces)
            if f.hasPrefix("(") && f.hasSuffix(")") { f = String(f.dropFirst().dropLast()) }
            return .filter(f)
        }
        if b.hasPrefix("'") || b.hasPrefix("\"") {
            return .key(String(b.dropFirst().dropLast()))
        }
        if b.contains(":") {
            let ps = b.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .slice(ps.count > 0 ? ps[0] : nil, ps.count > 1 ? ps[1] : nil, ps.count > 2 ? (ps[2] ?? 1) : 1)
        }
        if b.contains(",") {
            return .indices(b.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        if let n = Int(b) { return .index(n) }
        return .key(b)
    }

    static func apply(_ step: Step, _ n: Any, _ out: inout [Any], afterDeep: Bool) {
        switch step {
        case .key(let k):
            if k == "*" { collectValues(n, &out); return }
            if let d = n as? [String: Any], let v = d[k] { out.append(v) }
        case .recursive(let k):
            var all: [Any] = []
            collectDeep(n, &all)
            for a in all {
                if k == "*" { collectValues(a, &out) }
                else if let d = a as? [String: Any], let v = d[k] { out.append(v) }
            }
        case .index(let i):
            if let arr = n as? [Any] {
                let idx = i < 0 ? arr.count + i : i
                if idx >= 0 && idx < arr.count { out.append(arr[idx]) }
            }
        case .indices(let is_):
            if let arr = n as? [Any] {
                for i in is_ {
                    let idx = i < 0 ? arr.count + i : i
                    if idx >= 0 && idx < arr.count { out.append(arr[idx]) }
                }
            }
        case .slice(let s, let e, let st):
            if let arr = n as? [Any], st != 0 {
                let count = arr.count
                var start = s ?? (st > 0 ? 0 : count - 1)
                var end = e ?? (st > 0 ? count : -count - 1)
                if start < 0 { start += count }
                if end < 0 { end += count }
                start = max(0, min(start, count))
                end = max(-1, min(end, count))
                if st > 0 {
                    var i = start
                    while i < end { out.append(arr[i]); i += st }
                } else {
                    var i = min(start, count - 1)
                    while i > end && i >= 0 { out.append(arr[i]); i += st }
                }
            }
        case .wildcard:
            collectValues(n, &out)
        case .filter(let expr):
            if let arr = n as? [Any] {
                for a in arr where matchFilter(expr, a) { out.append(a) }
            } else if matchFilter(expr, n) { out.append(n) }
        }
    }

    static func collectValues(_ n: Any, _ out: inout [Any]) {
        if let arr = n as? [Any] { out += arr }
        else if let d = n as? [String: Any] { out += Array(d.values) }
    }

    static func collectDeep(_ n: Any, _ out: inout [Any]) {
        out.append(n)
        if let arr = n as? [Any] { for a in arr { collectDeep(a, &out) } }
        else if let d = n as? [String: Any] { for v in d.values { collectDeep(v, &out) } }
    }

    // MARK: 过滤器

    static func matchFilter(_ expr: String, _ item: Any) -> Bool {
        // 逻辑 || / &&（括号外）
        if let r = splitLogic(expr, "||") { return r.contains { matchFilter($0, item) } }
        if let r = splitLogic(expr, "&&") { return r.allSatisfy { matchFilter($0, item) } }
        var e = expr.trimmingCharacters(in: .whitespaces)
        if e.hasPrefix("(") && e.hasSuffix(")") { e = String(e.dropFirst().dropLast()) }
        if e.hasPrefix("!") { return !matchFilter(String(e.dropFirst()), item) }
        // 比较运算
        for op in ["==", "!=", ">=", "<=", "=~", ">", "<"] {
            if let r = e.range(of: op) {
                let lhs = String(e[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rhs = String(e[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard let lv = operand(lhs, item) else { return false }
                if op == "=~" {
                    var p = rhs
                    if p.hasPrefix("/") { p = String(p.dropFirst()); if let s = p.lastIndex(of: "/") { p = String(p[..<s]) } }
                    guard let re = try? NSRegularExpression(pattern: p) else { return false }
                    let s = stringify(lv)
                    return re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
                }
                let rv = operand(rhs, item) ?? rhs
                return compare(lv, rv, op)
            }
        }
        // 存在性
        return operand(e, item) != nil
    }

    private static func splitLogic(_ e: String, _ sep: String) -> [String]? {
        var depth = 0, parts: [String] = [], cur = ""
        var i = e.startIndex
        var q: Character? = nil
        while i < e.endIndex {
            let c = e[i]
            if let qq = q { cur.append(c); if c == qq { q = nil } }
            else if c == "'" || c == "\"" { q = c; cur.append(c) }
            else if c == "(" { depth += 1; cur.append(c) }
            else if c == ")" { depth -= 1; cur.append(c) }
            else if depth == 0 && e[i...].hasPrefix(sep) {
                parts.append(cur); cur = ""
                i = e.index(i, offsetBy: sep.count)
                continue
            } else { cur.append(c) }
            i = e.index(after: i)
        }
        parts.append(cur)
        return parts.count > 1 ? parts : nil
    }

    static func operand(_ token: String, _ item: Any) -> Any? {
        var t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("'") || t.hasPrefix("\"") { return String(t.dropFirst().dropLast()) }
        if t == "true" { return true }
        if t == "false" { return false }
        if t == "null" { return NSNull() }
        if let n = Double(t) { return n }
        if t.hasPrefix("@") {
            t.removeFirst()
            if t.hasPrefix(".") { t.removeFirst() }
            var cur: Any? = item
            for part in t.split(separator: ".") {
                if let d = cur as? [String: Any] { cur = d[String(part)] } else { return nil }
            }
            return cur
        }
        if t.hasPrefix("$") { return nil } // 根引用在过滤中不支持
        return nil
    }

    private static func compare(_ l: Any, _ r: Any, _ op: String) -> Bool {
        if op == "==" { return stringify(l) == stringify(r) }
        if op == "!=" { return stringify(l) != stringify(r) }
        let ln = (l as? NSNumber)?.doubleValue ?? Double(stringify(l)) ?? 0
        let rn = (r as? NSNumber)?.doubleValue ?? Double(stringify(r)) ?? 0
        switch op {
        case ">": return ln > rn
        case "<": return ln < rn
        case ">=": return ln >= rn
        case "<=": return ln <= rn
        default: return false
        }
    }
}