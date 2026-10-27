import Foundation

// ============================================================
// ⭐⭐⭐⭐⭐ 站方变量的「形态」—— **静态判定**（看站方自己怎么用这一格）
//
// ────────────────────────────────────────────────────────────
// ⚠️ **为什么不能只看运行时状态**（2026-10-27 真机复盘）：
//   运行时的证据（站方写过什么）**要等它写过才知道** ⇒
//   ⇒ 手机上**已经躺着的旧污染**，在第一次 op 之前永远判不出来 ⭐⭐⭐
//   ⇒ 而「判不出来」= 不许清 ⇒ **污染永远清不掉** ⇒ 403「无效JWT」永远好不了 ⭐⭐⭐
//   ⇒ **静态扫描站方的 jsLib** ⇒ 装机第一次跑就知道这一格是 map 还是凭据 ⭐⭐⭐
//
// ────────────────────────────────────────────────────────────
// ⭐ **判据 = 站方「怎么消费」这个值**：
//   · 被 `JSON.parse(...)` / `getArguments(...)` 解析 ⇒ **map 形态**（大灰狼 / NovelHub / 番茄）
//   · 被拼进字符串/请求头（`Bearer ${…}`）⇒ **凭据形态**（✿UAA：这一格放 token）
//   ⇒ **有 map 证据 ⇒ map**（站方确实把它当 map 用）⭐
//   ⇒ **只有凭据证据 ⇒ 凭据**（这一格是放凭据的位置 ⇒ **绝不许塞 map**）⭐⭐⭐
//
// ⚠️ **为什么「map 优先」**（真实语料实测，2026-10-27）：
//   大灰狼 / NovelHub / 番茄 的 jsLib **两种用法都有**（既 JSON.parse 读它，
//   也偶尔当字符串用）⇒ 按「凭据优先」会把它们误判成凭据形态 ⇒
//   ⇒ **大灰狼的线路表就写不进站方变量了** ⇒ 大灰狼变回「8 条线路慢速」⭐⭐⭐
//   ⇒ 而 UAA 原版/轻阅版 **只有凭据用法** ⇒ 判成凭据 ⇒ 污染被清 ⭐⭐⭐
// ============================================================

/// 站方变量（Legado `source.getVariable()` 那一格）的形态
enum StationVarForm: String {
    /// 站方拿它当 **JSON map** 用（大灰狼 / NovelHub / 番茄）
    case map
    /// 站方拿它当**一整串凭据**用（✿UAA：这一格放 token）
    case credential
    /// **还不知道** ⇒ 不许动这一格（宁可不改，也别把好状态弄坏）
    case unknown
}

/// ⭐⭐⭐ **静态扫描站方 jsLib** ⇒ 这一格是 map 还是凭据
enum StationVarFormScanner {

    /// - Parameter jsLib: 站方的 jsLib 原文
    /// - Returns: 形态
    static func form(jsLib: String?) -> StationVarForm {
        guard let jsLib, !jsLib.isEmpty else { return .unknown }
        let code = stripComments(jsLib)
        var sawMap = false
        var sawCredential = false

        for call in calls(of: ["getVariable", "setVariable"], in: code) {
            switch call.name {
            case "getVariable":
                // ⭐ **看外层调用栈**：被 JSON.parse / getArguments 包着 ⇒ 这一格是 map
                if call.stack.contains(where: { $0 == "JSON.parse" || $0 == "getArguments" }) {
                    sawMap = true
                } else {
                    sawCredential = true
                }
            case "setVariable":
                // ⭐ **看写进去的是什么**：JSON.stringify(...) / 对象字面量 ⇒ map；标量 ⇒ 凭据
                let arg = call.argument
                if arg.contains("JSON.stringify")
                    || arg.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    sawMap = true
                } else {
                    sawCredential = true
                }
            default: break
            }
        }
        if sawMap { return .map }
        if sawCredential { return .credential }
        return .unknown
    }

    // MARK: - 词法扫描

    struct Call {
        let name: String
        let argument: String
        /// 外层调用名栈（内→外；元素可能是 `JSON.parse` 这种带点的全名）
        let stack: [String]
    }

    /// 找出所有 `getVariable(` / `setVariable(` 调用
    ///
    /// ⭐ **要处理两种坑**（都真踩过）：
    ///   ① **点号名**：`JSON.parse(...)` ⇒ 名字是 `JSON.parse`（不是 `parse`）⭐
    ///   ② **模板字符串里的 `${}`**：`Bearer ${source.getVariable()}` ⇒
    ///      **`${}` 里面是真实代码** ⇒ 不能当字符串跳过 ⭐⭐⭐
    static func calls(of names: [String], in code: String) -> [Call] {
        let chars = Array(code)
        let n = chars.count
        var out: [Call] = []
        var stack: [String] = []                       // 调用名栈（内→外）
        var pending: [(name: String, argStart: Int, stackAtCall: [String])] = []
        var i = 0
        var lastIdent: String = ""

        while i < n {
            let c = chars[i]
            // 字符串（' / "）
            if c == "'" || c == "\"" {
                i = skipQuoted(chars, i, quote: c)
                continue
            }
            // 模板字符串：`` ` `` ⇒ 里面的 ${} 是真实代码 ⇒ 逐段扫
            if c == "`" {
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "`" { i += 1; break }
                    if chars[i] == "$", i + 1 < n, chars[i + 1] == "{" {
                        // ⇒ `${}` 里是**真实代码** ⇒ 单独扫这一段（外层栈照带上）⭐
                        i += 2
                        let end = matchBrace(chars, from: i - 1)
                        let expr = String(chars[i...min(end, chars.count - 1)])
                        for c2 in calls(of: names, in: expr) {
                            out.append(Call(name: c2.name,
                                            argument: c2.argument,
                                            stack: c2.stack + stack))
                        }
                        i = min(end + 1, chars.count)
                        continue
                    }
                    i += 1
                }
                continue
            }
            // 花括号（普通代码块）⇒ 不影响括号栈
            if c == "{" || c == "}" { i += 1; continue }
            // 标识符链（`JSON.parse` 这种带点的）
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                var chain = ""
                while j < n {
                    let ch = chars[j]
                    if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
                        chain.append(ch); j += 1
                    } else if ch == ".", j + 1 < n,
                              chars[j + 1].isLetter || chars[j + 1] == "_" || chars[j + 1] == "$" {
                        chain.append(ch); j += 1
                    } else { break }
                }
                lastIdent = chain
                var k = j
                while k < n, chars[k] == " " { k += 1 }
                if k < n, chars[k] == "(" {
                    let leaf = chain.split(separator: ".").last.map(String.init) ?? chain
                    pending.append((name: leaf, argStart: k + 1, stackAtCall: stack))
                    stack.append(chain)                 // ⭐ 存**全名**（`JSON.parse`）⭐
                    lastIdent = ""
                    i = k + 1
                    continue
                }
                i = j; continue
            }
            if c == "(" {
                pending.append((name: lastIdent, argStart: i + 1, stackAtCall: stack))
                stack.append(lastIdent)
                lastIdent = ""
                i += 1; continue
            }
            if c == ")" {
                if let p = pending.popLast() {
                    let a0 = min(p.argStart, n), a1 = min(max(i, a0), n)
                    let arg = String(chars[a0..<a1])
                    if names.contains(p.name) {
                        out.append(Call(name: p.name, argument: arg, stack: p.stackAtCall))
                    }
                }
                if !stack.isEmpty { stack.removeLast() }
                lastIdent = ""
                i += 1; continue
            }
            lastIdent = ""
            i += 1
        }
        return out
    }

    /// 跳过一段带引号的字符串（返回结束后的下标）
    private static func skipQuoted(_ chars: [Character], _ start: Int, quote: Character) -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == quote { return i + 1 }
            i += 1
        }
        return i
    }

    /// 从 `{` 开始按花括号配平 ⇒ 返回匹配的 `}` 的下标
    private static func matchBrace(_ chars: [Character], from start: Int) -> Int {
        var depth = 0
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" { i = skipQuoted(chars, i, quote: c); continue }
            if c == "`" {
                // 模板里可能有 ${} ⇒ 粗略跳过（花括号在 ${} 里会配平，模板里的普通花括号很少）
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "`" { break }
                    j += 1
                }
                i = j + 1; continue
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return chars.count - 1
    }

    /// ⭐ **剥注释**（字符串里的 `//` 不算注释！）
    static func stripComments(_ src: String) -> String {
        let chars = Array(src)
        let n = chars.count
        var out = String()
        out.reserveCapacity(n)
        var i = 0
        var inString: Character? = nil
        while i < n {
            let c = chars[i]
            if let q = inString {
                out.append(c)
                if c == "\\" && i + 1 < n {
                    i += 1; out.append(chars[i]); i += 1; continue
                }
                if c == q { inString = nil }
                i += 1; continue
            }
            if c == "\"" || c == "'" {
                inString = c; out.append(c); i += 1; continue
            }
            // ⭐ 模板字符串：注释在模板里也是注释 ⇒ 但 `${}` 里是代码 ⇒ 模板整体保留
            if c == "/" , i + 1 < n, chars[i + 1] == "/" {
                while i < n && chars[i] != "\n" { i += 1 }
                out.append(" "); continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < n && !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                i = min(j + 2, n)
                out.append(" "); continue
            }
            out.append(c); i += 1
        }
        return out
    }
}
