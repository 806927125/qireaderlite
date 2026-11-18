import Foundation

/// 通用规则切分器（语义对齐 Kotlin RuleAnalyzer）。
/// 用法：`splitRule(data, "&&", "||", "%%")` —— 第一个参数为待切分规则串，
/// 其余参数为候选分隔符；首个出现的分隔符决定 `elementsType`，整串按该分隔符切分，
/// 平衡组 `[...]` / `(...)`（含引号、转义）与 `<js>...</js>` / `@js:` 代码块内的分隔符被跳过。
public final class RuleSplitter {
    /// 当前切分使用的分隔符（切分后有效）
    public var elementsType: String = ""

    var chars: [Character] = []
    var code: Bool = false

    private var pos = 0
    private var start = 0
    private var startX = 0
    private var step = 0
    private var rule: [String] = []

    public init() {}

    /// 切分规则。rules[0] 为数据，rules[1...] 为分隔符；仅一个参数时原样返回。
    public func splitRule(_ rules: String...) -> [String] {
        guard let data = rules.first else { return [] }
        reset(data, code: code)
        if rules.count == 1 { return [data] }
        return split(Array(rules.dropFirst()))
    }

    // MARK: - 内部复用接口（供各解析后端使用）

    func reset(_ data: String, code: Bool = false) {
        self.chars = Array(data)
        self.code = code
        self.pos = 0
        self.start = 0
        self.startX = 0
        self.step = 0
        self.rule = []
        self.elementsType = ""
    }

    func reSetPos() {
        pos = 0
        startX = 0
    }

    /// 修剪当前位置之前的 "@" 或空白/控制字符
    func trim() {
        while pos < chars.count, chars[pos] == "@" || isSpace(chars[pos]) { pos += 1 }
        start = pos
        startX = pos
    }

    func split(_ delimiters: [String]) -> [String] {
        rule = []
        splitFirst(delimiters.map { Array($0) })
        return rule
    }

    /// 替换内嵌规则（如 "{$.xxx}"），fr 解析成功且非空时替换，否则视为普通文本跳过。
    func innerRule(_ inner: String, startStep: Int = 1, endStep: Int = 1, _ fr: (String) -> String?) -> String {
        let seq = Array(inner)
        var st = ""
        while consumeTo(seq) {
            let posPre = pos
            if chompCodeBalanced("{", "}") {
                let body = sub(posPre + startStep, pos - endStep)
                if let frv = fr(body), !frv.isEmpty {
                    st += sub(startX, posPre) + frv
                    startX = pos
                    continue
                }
            }
            pos += seq.count
        }
        if startX == 0 { return "" }
        return st + sub(startX, chars.count)
    }

    // MARK: - RuleAnalyzer 算法移植

    private func isSpace(_ c: Character) -> Bool {
        if let a = c.asciiValue { return a < 33 }
        return false
    }

    private func sub(_ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, chars.count))
        let hi = max(lo, min(b, chars.count))
        return String(chars[lo..<hi])
    }

    private func matches(_ seq: [Character], at p: Int, caseInsensitive: Bool = false) -> Bool {
        guard p + seq.count <= chars.count else { return false }
        for i in 0..<seq.count {
            let a = chars[p + i], b = seq[i]
            if caseInsensitive {
                if Character(a.lowercased()) != Character(b.lowercased()) { return false }
            } else if a != b { return false }
        }
        return true
    }

    /// 拉取直到 seq（不含），找到则 pos 指向 seq 起点
    private func consumeTo(_ seq: [Character]) -> Bool {
        start = pos
        guard !seq.isEmpty else { return false }
        var p = pos
        while p <= chars.count - seq.count {
            if matches(seq, at: p) { pos = p; return true }
            p += 1
        }
        return false
    }

    private func consumeToAny(_ seqs: [[Character]]) -> Bool {
        var p = pos
        while p < chars.count {
            for s in seqs where matches(s, at: p) {
                step = s.count
                pos = p
                return true
            }
            p += 1
        }
        return false
    }

    private enum Special { case bracket, jsBlock, jsRest }

    /// 查找筛选器 '[' '(' 以及 JS 代码块标记 "<js>" / "@js:"
    private func findSpecial() -> (Int, Special)? {
        var p = pos
        while p < chars.count {
            let c = chars[p]
            if c == "[" || c == "(" { return (p, .bracket) }
            if (c == "<" && matches(Array("<js>"), at: p, caseInsensitive: true)) { return (p, .jsBlock) }
            if (c == "@" && matches(Array("@js:"), at: p, caseInsensitive: true)) { return (p, .jsRest) }
            p += 1
        }
        return nil
    }

    /// 跳过 JS 块；返回新的 pos。不平衡的筛选器按剩余整串处理（Kotlin 抛错，此处降级）
    private func skipSpecial(_ kind: Special, at st: Int) -> Int {
        switch kind {
        case .jsRest:
            return chars.count
        case .jsBlock:
            let close = Array("</js>")
            var p = st + 4
            while p <= chars.count - close.count {
                if matches(close, at: p, caseInsensitive: true) { return p + close.count }
                p += 1
            }
            return chars.count
        case .bracket:
            pos = st
            let open = chars[st]
            let close: Character = open == "[" ? "]" : ")"
            let ok = code ? chompCodeBalanced(open, close) : chompRuleBalanced(open, close)
            return ok ? pos : chars.count
        }
    }

    /// 代码平衡组（JSON/JS）：'[' 嵌套 + open/close 嵌套，引号内不参与平衡，支持转义
    private func chompCodeBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var otherDepth = 0
        var inSingle = false
        var inDouble = false
        repeat {
            if p == chars.count { break }
            let c = chars[p]
            p += 1
            if c != "\\" {
                if c == "'" && !inDouble { inSingle.toggle() }
                else if c == "\"" && !inSingle { inDouble.toggle() }
                if inSingle || inDouble { continue }
                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1 }
                else if depth == 0 {
                    if c == open { otherDepth += 1 }
                    else if c == close { otherDepth -= 1 }
                }
            } else {
                p += 1
            }
        } while depth > 0 || otherDepth > 0
        if depth > 0 || otherDepth > 0 { return false }
        pos = p
        return true
    }

    /// 规则平衡组（xpath/jsoup）：引号内转义无效，引号外 '\' 转义下一字符
    private func chompRuleBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var inSingle = false
        var inDouble = false
        repeat {
            if p == chars.count { break }
            let c = chars[p]
            p += 1
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            if inSingle || inDouble { continue }
            if c == "\\" { p += 1; continue }
            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
        } while depth > 0
        if depth > 0 { return false }
        pos = p
        return true
    }

    /// 首段匹配：先找任意分隔符确定 elementsType
    private func splitFirst(_ splits: [[Character]]) {
        while true {
            if splits.count == 1 {
                elementsType = String(splits[0])
                if !consumeTo(splits[0]) {
                    rule.append(sub(startX, chars.count))
                    return
                }
                step = splits[0].count
                splitNext()
                return
            } else if !consumeToAny(splits) {
                rule.append(sub(startX, chars.count))
                return
            }

            let end = pos
            pos = start
            var matched = false
            while true {
                guard let (st, kind) = findSpecial() else {
                    rule = [sub(startX, end)]
                    elementsType = sub(end, end + step)
                    pos = end + step
                    let typeSeq = Array(elementsType)
                    while consumeTo(typeSeq) {
                        rule.append(sub(start, pos))
                        pos += step
                    }
                    rule.append(sub(pos, chars.count))
                    return
                }
                if st > end {
                    rule = [sub(startX, end)]
                    elementsType = sub(end, end + step)
                    pos = end + step
                    let typeSeq = Array(elementsType)
                    while consumeTo(typeSeq) && pos < st {
                        rule.append(sub(start, pos))
                        pos += step
                    }
                    if pos > st {
                        startX = start
                        splitNext()
                        return
                    } else {
                        rule.append(sub(pos, chars.count))
                        return
                    }
                }
                pos = skipSpecial(kind, at: st)
                if !(end > pos) { matched = true; break }
            }
            if matched {
                start = pos
                continue // 递归首段匹配（tailrec 展开）
            }
        }
    }

    /// 二段匹配：elementsType 已确定
    private func splitNext() {
        while true {
            let end = pos
            pos = start
            // break 来源：true = st>end 且 pos>st（pos 已指向分隔符）；false = 筛选器跳过后的循环出口
            var atDelimiter = false
            while true {
                guard let (st, kind) = findSpecial() else {
                    rule.append(sub(startX, end))
                    pos = end + step
                    let typeSeq = Array(elementsType)
                    while consumeTo(typeSeq) {
                        rule.append(sub(start, pos))
                        pos += step
                    }
                    rule.append(sub(pos, chars.count))
                    return
                }
                if st > end {
                    rule.append(sub(startX, end))
                    pos = end + step
                    let typeSeq = Array(elementsType)
                    while consumeTo(typeSeq) && pos < st {
                        rule.append(sub(start, pos))
                        pos += step
                    }
                    if pos > st {
                        startX = start
                        atDelimiter = true
                        break
                    } else {
                        rule.append(sub(pos, chars.count))
                        return
                    }
                }
                pos = skipSpecial(kind, at: st)
                if !(end > pos) { break }
            }
            if !atDelimiter {
                start = pos
                let typeSeq = Array(elementsType)
                if !consumeTo(typeSeq) {
                    rule.append(sub(startX, chars.count))
                    return
                }
            }
            // 下一轮：end = pos（分隔符位置）
        }
    }
}