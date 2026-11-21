import Foundation

/// 规则模式
enum RuleMode {
    case xpath, json, defaultMode, js, regex
}

/// 规则片段（对应 Legado AnalyzeRule.SourceRule）。
/// 负责模式判定、`@put` 拆分、`@get`/`{{}}`/`$n` 模板拼接与 `##` 替换拆分。
final class SourceRule {
    var mode: RuleMode
    var rule: String
    var replaceRegex = ""
    var replacement = ""
    var replaceFirst = false
    var putMap: [String: String] = [:]

    private enum Param {
        case text(String)
        case regexGroup(Int, String)
        case js(String)
        case get(String)
    }

    private var params: [Param] = []

    static let jsPattern = #"(?i)<js>([\w\W]*?)</js>|@js:([\w\W]*)"#
    static let putPattern = #"(?i)@put:(\{[^}]+?\})"#
    static let evalPattern = #"(?i)@get:\{[^}]+?\}|\{\{[\w\W]*?\}\}"#
    static let regexPattern = #"\$\d{1,2}"#

    init(_ ruleStr: String, mode initialMode: RuleMode = .defaultMode, isJSON: Bool) {
        var mode = initialMode
        var rule: String
        switch true {
        case mode == .js || mode == .regex:
            rule = ruleStr
        case ruleStr.startsWith("@CSS:", ignoreCase: true):
            mode = .defaultMode
            rule = ruleStr
        case ruleStr.hasPrefix("@@"):
            mode = .defaultMode
            rule = String(ruleStr.dropFirst(2))
        case ruleStr.startsWith("@XPath:", ignoreCase: true):
            mode = .xpath
            rule = String(ruleStr.dropFirst(7))
        case ruleStr.startsWith("@Json:", ignoreCase: true):
            mode = .json
            rule = String(ruleStr.dropFirst(6))
        case isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$["):
            mode = .json
            rule = ruleStr
        case ruleStr.hasPrefix("/"):
            mode = .xpath
            rule = ruleStr
        default:
            rule = ruleStr
        }
        self.mode = mode
        self.rule = rule
        self.rule = splitPutRule(rule)
        parseTemplate()
    }

    private func splitPutRule(_ ruleStr: String) -> String {
        guard let re = try? RegexCache.shared.regex(Self.putPattern) else { return ruleStr }
        var out = ruleStr
        for m in re.matches(in: ruleStr, range: ruleStr.fullRange) {
            let whole = ruleStr.substring(with: m.range)
            out = out.replacingOccurrences(of: whole, with: "")
            if let json = ruleStr.group(m, 1), let map = LenientJSON.stringMap(json) {
                putMap.merge(map) { _, new in new }
            }
        }
        return out
    }

    private func parseTemplate() {
        guard let re = try? RegexCache.shared.regex(Self.evalPattern) else { return }
        let ns = rule as NSString
        let matches = re.matches(in: rule, range: rule.fullRange)
        var start = 0
        if let first = matches.first {
            let before = ns.substring(to: first.range.location)
            if mode != .js, mode != .regex, first.range.location == 0 || !before.contains("##") {
                mode = .regex
            }
            for m in matches {
                if m.range.location > start {
                    splitRegex(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
                }
                let token = ns.substring(with: m.range)
                if token.startsWith("@get:", ignoreCase: true) {
                    params.append(.get(String(token.dropFirst(6).dropLast())))
                } else if token.hasPrefix("{{") {
                    params.append(.js(String(token.dropFirst(2).dropLast(2))))
                } else {
                    splitRegex(token)
                }
                start = m.range.location + m.range.length
            }
        }
        if ns.length > start {
            splitRegex(ns.substring(from: start))
        }
    }

    /// 拆分 `$n`
    private func splitRegex(_ ruleStr: String) {
        let head = ruleStr.components(separatedBy: "##").first ?? ruleStr
        let ns = ruleStr as NSString
        var start = 0
        if let re = try? RegexCache.shared.regex(Self.regexPattern) {
            let matches = re.matches(in: head, range: head.fullRange)
            if !matches.isEmpty, mode != .js, mode != .regex {
                mode = .regex
            }
            for m in matches {
                if m.range.location > start {
                    params.append(.text(ns.substring(with: NSRange(location: start, length: m.range.location - start))))
                }
                let token = ns.substring(with: m.range)
                let index = Int(token.dropFirst()) ?? 0
                // 与 Legado 一致：$0 不做替换
                params.append(index > 0 ? .regexGroup(index, token) : .text(token))
                start = m.range.location + m.range.length
            }
        }
        if ns.length > start {
            params.append(.text(ns.substring(from: start)))
        }
    }

    var paramCount: Int { params.count }

    /// 用当前结果替换模板，并拆出 `##` 替换参数
    func makeUpRule(_ result: Any?, analyzer: AnalyzeRule) throws {
        if !params.isEmpty {
            var parts: [String] = []
            for param in params.reversed() {
                switch param {
                case .regexGroup(let index, let raw):
                    if let groups = result as? [String] {
                        if groups.count > index { parts.append(groups[index]) }
                    } else if let list = result as? [Any] {
                        if list.count > index { parts.append(RuleValue.text(of: list[index])) }
                    } else {
                        parts.append(raw)
                    }
                case .js(let code):
                    if Self.isRule(code) {
                        parts.append(try analyzer.getString([SourceRule(code, isJSON: analyzer.isJSON)]))
                    } else if let value = try analyzer.evalJS(code, result: result) {
                        parts.append(RuleValue.jsString(value) ?? "")
                    }
                case .get(let key):
                    parts.append(analyzer.get(key))
                case .text(let text):
                    parts.append(text)
                }
            }
            rule = parts.reversed().joined()
        }
        let pieces = rule.components(separatedBy: "##")
        rule = pieces[0].trimmedWhitespace
        if pieces.count > 1 { replaceRegex = pieces[1] }
        if pieces.count > 2 { replacement = pieces[2] }
        if pieces.count > 3 { replaceFirst = true }
    }

    /// `{{}}` 中以 @、$.、$[、// 开头的视为规则，其余视为 JS
    static func isRule(_ text: String) -> Bool {
        text.hasPrefix("@") || text.hasPrefix("$.") || text.hasPrefix("$[") || text.hasPrefix("//")
    }
}
