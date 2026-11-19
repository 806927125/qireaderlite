import Foundation

/// ⭐⭐⭐⭐⭐ **站方 exploreUrl 的分类归一化**（2026-11-19 真机 build296 实证）
///
/// ## 为什么单独一个文件
///
/// ⚠️⚠️ **根因**：换装新引擎后，`LegadoEngine.exploreKinds` **静态**读 `source.exploreUrl`
///   （只认 JSON 数组 / `标题::url` 两行式）⇒ **从不求值 `@js:`** ⭐⭐⭐
///   而 NovelHub（🍒NovelHub）的 `exploreUrl` 是 **`@js:` 薄壳**（正文在 jsLib 里）
///   ⇒ 静态解析把 `@js:` 那行当成「标题」⇒ **分类 url 为空**
///   ⇒ `AnalyzeUrl` 对空 url 求值 ⇒ `url 解析失败: ` ⇒ **LegadoError 错误 1** ⭐⭐⭐
///   ⇒ **与真机日志逐字吻合**（「url 解析失败:」冒号后为空）⭐⭐⭐
///
/// ## 权威规格
///
/// ⭐ **已删的旧引擎**（git `0b5c481^:QiReaderLite/Resources/engine/engine.js` 的
///   `exploreKinds` / `normalizeKinds` / `filterParamKey` + `jsoup-compat.js` 的 `absolutize`）
///   —— 旧引擎的 `exploreKinds` **会先求值 `@js:`** ⇒ 换装时丢的就是这条能力 ⇒ 属**能力回退** ⭐⭐⭐
///   ⇒ 本文件的语义**逐条对齐**它 ⇒ 门禁用「旧引擎 JS ⇔ 本文件 Swift」双实现对拍证明 ⭐⭐⭐
///
/// ## 为什么独立成文件（而不留在 LegadoEngineBackend 里）
///
/// ⭐ **门禁要能直接编它**（Linux 沙盒 3 秒反馈，不用等 CI 5 分钟）
///   ⇒ 它**只依赖 Foundation** ⇒ 不 import 引擎 / UIKit ⇒ 沙盒能编能跑 ⭐⭐⭐
///   ⇒ App 侧（`LegadoEngineBackend`）与门禁**共用同一份** ⇒ **永不漂** ⭐⭐⭐
enum ExploreKindsNormalizer {

    /// 归一化结果：**分类**（点得动的）+ **筛选栏**（点不动的 select 项）+ 分组
    struct NormalizedKinds {
        var kinds: [[String: Any]] = []
        var filters: [[String: Any]] = []
    }

    /// 判断是不是 JS 规则（`@js:` / `<js>`）
    ///
    /// ⚠️ 与引擎的 `AnalyzeRule.isJSRule` 同口径（那边是 private ⇒ 这里自己判一份）
    static func isJSRule(_ r: String) -> Bool {
        let t = r.trimmingCharacters(in: .whitespaces)
        return t.lowercased().hasPrefix("@js:") || t.lowercased().hasPrefix("<js>")
    }

    /// 剥掉 JS 包装（`@js:` 前缀 / `<js>…</js>` 外壳）⇒ 只留**代码**
    ///
    /// ⚠️⚠️ **不能做 `{{}}` 插值**（旧引擎 2026-10-22 实测 NovelHub 聚合源炸在这）：
    ///   Legado / 栖阅语义 = **`@js:` 是 JS 源码**，里面的 `{{}}`（JS 对象展开语法）原样保留 ⭐⭐⭐
    ///   ⇒ 插值会把 `{...}` 吃成空串 ⇒ 整个 JS 语法坏掉 ⇒ 「Invalid or unexpected token」⭐
    ///   ⇒ **站方 JS 拼出来的分类 URL 里的 `{{page}}` 也要原样留着**
    ///     ⇒ 后面 `explore` op 的 `AnalyzeUrl` 才插值 ⇒ **发现页翻页正常** ✅
    static func stripJSWrapper(_ spec: String) -> String {
        let t = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("@js:") { return String(t.dropFirst(4)) }
        if t.lowercased().hasPrefix("<js>") {
            if let r = t.range(of: "</js>", options: .caseInsensitive) {
                return String(t[t.index(t.startIndex, offsetBy: 4)..<r.lowerBound])
            }
            return String(t.dropFirst(4))
        }
        return t
    }

    /// ⭐⭐⭐⭐⭐ **归一化站方给的分类数组**（照抄已删旧引擎的 `normalizeKinds` 语义）
    ///
    /// ⚠️ **站方（🍅大灰狼 / 🍒NovelHub）的 exploreUrl 返回的是混合数组**：
    ///   · `type:"select"` 项 = **筛选栏**（平台/模式/频道…）⇒ **没有 url** ⇒ 不是分类 ⭐⭐⭐
    ///   · 有 url 的对象项 = **真正的分类**
    ///   · **url 为空的对象项 = 组标题行**（装饰行 / 「当前为: XX」/ 「分类」）⇒ 只当组标题 ⭐⭐⭐
    ///   · 字符串项 = `标题::url` 两行式；**没有 `::` 的 = 组标题**（装饰符号剥掉）⭐⭐⭐
    ///
    /// ⚠️⚠️ **判据只能是「url 空不空」，不能看 style**（旧引擎 2026-10-22 实证）：
    ///   站方组标题行的 `style.pct` 也可能是 1 ⇒ 按 style 判会把真分类误杀 ⭐⭐⭐
    static func normalizeKinds(_ raw: Any?, baseUrl: String) -> NormalizedKinds {
        var out = NormalizedKinds()
        var group = ""
        // ① 结果可能是：数组 / JSON 字符串 / 纯文本（`标题::url`）
        var items: [Any] = []
        if let arr = raw as? [Any] {
            items = arr
        } else if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("[") || t.hasPrefix("{") {
                if let d = t.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) {
                    if let a = o as? [Any] { items = a }
                }
            } else {
                // ⭐⭐⭐ **纯文本分类**："玄幻::/type/xh\n仙侠::/type/xx"（Legado 用 (&&|\n)+ 切）
                //
                // ⚠️⚠️ **切成【对象】而不是【字符串】**（旧引擎 `exploreKinds` 原样）：
                //   旧引擎：`t.split(/(&&|\n)+/)…map(l => { var q = l.split('::'); return {title:q[0], url:q[1]||''}; })`
                //   ⇒ 切完是 `{title, url}` **对象** ⇒ 后面走【对象分支】
                //     ⇒ **组标题不剥装饰符**（对象分支是 `group = objTitle` 原样）⭐⭐⭐
                //   ⇒ 若切成字符串 ⇒ 走字符串分支 ⇒ 剥装饰符
                //     ⇒ 「☆热门☆」变「热门」⇒ **与旧引擎不一致** ⭐⭐⭐
                for line in t.components(separatedBy: "\n") {
                    for part in line.components(separatedBy: "&&") {
                        let l = part.trimmingCharacters(in: .whitespacesAndNewlines)
                        if l.isEmpty { continue }
                        let q = l.components(separatedBy: "::")
                        items.append([
                            "title": q.count > 0 ? q[0] : "",
                            "url": q.count > 1 ? q[1] : "",
                        ])
                    }
                }
            }
        }
        for item in items {
            // ② 字符串项 = `标题::url` 两行式；没有 `::` ⇒ 组标题
            if let s = item as? String {
                let rawLine = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawLine.isEmpty { continue }
                guard let sep = rawLine.range(of: "::") else {
                    // ⚠️ **字符串分支才剥装饰符**（旧引擎 `raw.replace(/[*☆○●•·　\s]+/g,'')`）
                    group = rawLine.replacingOccurrences(of: "[*☆○●•·　\\s]+", with: "",
                                                        options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if group.isEmpty { group = rawLine }
                    continue
                }
                let title = String(rawLine[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let url = String(rawLine[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                if title.isEmpty || url.isEmpty { continue }
                out.kinds.append(["title": title, "url": Self.absolutize(url, baseUrl),
                                   "style": "", "group": group])
                continue
            }
            guard let d = item as? [String: Any] else { continue }
            // ③ `type:"select"` = **筛选栏**（不是分类）
            let ktype = (d["type"] as? String ?? "").lowercased()
            if ktype == "select" {
                var chars: [String] = []
                if let a = d["chars"] as? [Any] {
                    chars = a.map { "\($0)" }
                } else if let s = d["chars"] as? String {
                    chars = s.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                let title = (d["title"] as? String ?? "")
                if !title.isEmpty {
                    let action = (d["action"] as? String ?? "")
                    out.filters.append([
                        "title": title,
                        "type": "select",
                        "chars": chars,
                        "default": (d["default"] as? String ?? ""),
                        // ⭐ 参数名从 action 里抠：`show(infoMap['平台'],'find_source')` → 'find_source'
                        "paramKey": Self.filterParamKey(action),
                        "action": action,
                    ])
                }
                continue
            }
            // ④ 对象项：url 空 ⇒ **组标题行**（不作为分类输出）
            // ⭐ 旧引擎：`k.title || k.name || k.text` ⇒ 空串要**继续往后取**（不是 ?? 短路）
            let objTitle = Self.firstNonEmpty(d, ["title", "name", "text"])
            if objTitle.isEmpty { continue }
            // ⭐ 旧引擎：`k.url || k.link` ⇒ 空串要继续往后取
            let objURL = Self.firstNonEmpty(d, ["url", "link"])
            var styleStr = ""
            if let st = d["style"] {
                if let dict = st as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: dict),
                   let txt = String(data: data, encoding: .utf8) {
                    styleStr = txt
                } else {
                    styleStr = "\(st)"
                }
            }
            if objURL.isEmpty {
                // ⚠️「--」这种垃圾行不当组标题（它后面没内容 ⇒ 空组 ⇒ UI 也不显示）
                // ⚠️⚠️ **对象分支的组标题【不剥装饰符】**（旧引擎 `group = objTitle` 原样）
                //   ⇒ 只有**字符串分支**才剥 ⇒ 混在一起剥 ⇒ 与旧引擎不一致 ⭐⭐⭐
                if objTitle != "--" && !Self.isJunkGroupTitle(objTitle) {
                    group = objTitle
                }
                continue
            }
            // ⭐ 旧引擎：`group: String(k.group || '') || group` ⇒ **站方自带 group 优先**
            let ownGroup = (d["group"] as? String) ?? ""
            out.kinds.append(["title": objTitle, "url": Self.absolutize(objURL, baseUrl),
                               "style": styleStr, "group": ownGroup.isEmpty ? group : ownGroup])
        }
        return out
    }

    /// 依次取几个键里**第一个非空**的字符串（对齐旧引擎的 `a || b || c` 语义）
    ///
    /// ⚠️ 为什么不能用 `??`：`??` 只判 nil ⇒ **空串会直接赢** ⇒ 与 JS 的 `||` 不同 ⭐⭐⭐
    static func firstNonEmpty(_ d: [String: Any], _ keys: [String]) -> String {
        for k in keys {
            if let v = d[k] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    /// 「--」「——」这类垃圾行**不当组标题**（它后面没内容 ⇒ 空组 ⇒ UI 也不显示）
    static func isJunkGroupTitle(_ s: String) -> Bool {
        let junk = Set(["-", "\u{2013}", "\u{2014}", "_", " "])
        return !s.isEmpty && s.allSatisfy { junk.contains(String($0)) }
    }

    /// 从筛选栏的 `action` 里抠出**源级变量名**
    ///
    /// 站方写法：`show(infoMap['平台'],'find_source')` ⇒ 第二个参数就是变量名。
    /// 抠不出来就返回空串（宿主侧会把这一项标成「不可选」，而不是乱写变量）。
    ///
    /// ⭐⭐⭐ **两种形态都要认**（2026-11-19 实证）：
    ///   ① **旧引擎 / 🍅大灰狼形态**：`show(infoMap['平台'],'find_source')`
    ///      ⇒ 第二个引号参数就是变量名
    ///   ② **🍒NovelHub 形态**：整个 action 是个 **IIFE**，里面直接写变量：
    ///      `(function(){var c={};…var v=infoMap['平台'];…c['src']=v;c['find_source']=String(v);c['find_tab']='小说';…})()`
    ///      ⇒ 变量名藏在 **`c['xxx']=` 赋值**里 ⇒ 只认 ① 会把 NovelHub 的筛选栏全判成「不可选」⭐⭐⭐
    ///      ⇒ 而「不可选」⇒ 宿主不写那个变量 ⇒ **切台点了没反应**（静默失效）⭐⭐⭐
    static func filterParamKey(_ action: String) -> String {
        // ① 旧引擎 / 大灰狼形态：`show(infoMap['平台'],'find_source')`
        if let v = Self.secondQuotedArg(in: action, pattern: #"infoMap\[['"]([^'"]+)['"]\]\s*,\s*['"]([^'"]+)['"]"#) {
            return v
        }
        // ①' 兜底：`show('平台','find_source')` 这种不带 infoMap 的写法
        if let v = Self.secondQuotedArg(in: action, pattern: #"\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*\)"#) {
            return v
        }
        // ② ⭐⭐⭐ **NovelHub 形态**：`c['find_source']=…` / `c['find_tab']=…`
        //   ⚠️ 取**第一个** `c['xxx']=`（那是站方要改的主变量；后面的 find_tab 是附属）⭐⭐⭐
        //   ⚠️ 排除 `c['src']`（那是站方内部的旧字段名，不是宿主要写的源级变量）
        if let v = Self.firstAssignedKey(in: action) {
            return v
        }
        return ""
    }

    /// 从 `c['xxx']=` 这种赋值里抠出**第一个**键名（排除 `src`）
    static func firstAssignedKey(in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"\[\s*['"]([A-Za-z_][A-Za-z0-9_]*)['"]\s*\]\s*="#) else { return nil }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            // ⚠️ `src` 是站方内部的旧字段（不是宿主要写的源级变量）⇒ 跳过但继续找
            if key == "src" { continue }
            return key
        }
        return nil
    }

    /// 取正则的第 2 个捕获组（没有则 nil）
    static func secondQuotedArg(in s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 2 else { return nil }
        let r = m.range(at: 2)
        if r.location == NSNotFound { return nil }
        return ns.substring(with: r)
    }

    /// 相对路径 → 绝对地址（对齐旧引擎的 `dom.absolutize`）
    ///
    /// ⚠️⚠️ **两条必须对齐的语义**（旧引擎 `jsoup-compat.js` 的 `absolutize`）：
    ///   ① **协议白名单**：http/https/ftp/qireaderlite/data/blob/javascript/mailto ⇒ 原样返回
    ///      （`data:` 是聚合源塞参数的伪 URL ⇒ **绝不能**被当成相对路径拼到 base 后面）⭐⭐⭐
    ///   ② **`{{page}}` 占位保护**：`new URL()` 会把 `{` 编码成 `%7B` ⇒ 后面再也展开不了页码
    ///      ⇒ 这里用「先摘占位符、拼好再放回」的办法 ⭐⭐⭐
    ///      ⇒ **否则发现页翻页会静默失效**（分类 URL 里的 `{{page}}` 变成 `%7B%7Bpage%7D%7D`）⭐
    static func absolutize(_ url: String, _ base: String) -> String {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "" }
        // ① **协议白名单**（旧引擎 `jsoup-compat.js` 的 `absolutize` 同款）
        let absPrefixes = ["http://", "https://", "ftp://", "qireaderlite:", "data:",
                           "blob:", "javascript:", "mailto:"]
        for p in absPrefixes where u.lowercased().hasPrefix(p) { return u }
        // ② 协议相对 `//host/x` ⇒ 补 https:
        if u.hasPrefix("//") { return "https:" + u }
        guard !base.isEmpty else { return u }
        // ③ ⭐⭐⭐ **`{{page}}` 占位保护**：URL 引擎会把 `{` 编码成 `%7B` ⇒ 后面再也展开不了页码
        //   ⇒ 先摘出占位符 ⇒ 拼好再放回 ⇒ **发现页翻页不失效** ⭐⭐⭐
        var holes: [String] = []
        var s = ""
        var i = u.startIndex
        while i < u.endIndex {
            if u[i] == "{", let close = u.range(of: "}}", range: i..<u.endIndex) {
                // ⚠️⚠️ **占位符要连两个 `}` 一起摘**（旧引擎 `/\{\{[^{}]*\}\}/g` 捕获完整 token）
                //   ⇒ 只摘到 `}}` 的**起始** ⇒ 会丢掉最后一个 `}` ⇒ `{{page}}` 变 `{{page}` ⭐⭐⭐
                //   ⇒ 站方的 `{{page}}` 展开就废了（宿主认不出这个占位符）⭐⭐⭐
                // ⚠️ `close.upperBound` 是**开区间**（指向 `}` 之后）⇒ 闭区间切片要用 `upperBound` 前一个字符
                holes.append(String(u[i..<close.upperBound]))
                s += "\u{0001}\(holes.count - 1)\u{0001}"
                i = close.upperBound
                continue
            }
            s.append(u[i])
            i = u.index(after: i)
        }
        // ④ 拼 base
        var joined: String
        if s.hasPrefix("/") {
            // 取 base 的 origin
            if let schemeEnd = base.range(of: "://") {
                let afterScheme = base[schemeEnd.upperBound...]
                let hostEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
                joined = String(base[..<hostEnd]) + s
            } else {
                joined = s
            }
        } else {
            var b = base
            if !b.hasSuffix("/") { b += "/" }
            joined = b + s
        }
        // ⑤ 把占位符放回去
        var out = joined
        for (n, hole) in holes.enumerated() {
            out = out.replacingOccurrences(of: "\u{0001}\(n)\u{0001}", with: hole)
        }
        return out
    }
}
