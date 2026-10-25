import Foundation

// ============================================================
// 轻阅原生层：**URL 规则**（Core/AnalyzeUrl.swift）真跑测试
//
// 跑法：bash test/run-swift-tests.sh
//
// 为什么要有这个：
//   栖阅的 URL 规则是**原生 Swift**；轻阅原来放在 JS 里 →
//   沙盒（Node fetch）和真机（URL(string:）**两套 URL 实现** → 已经栽了两次：
//     ① POST 的 query 没编码 → iOS 判非法 → 请求压根发不出去
//     ② query 里的 '+' 没编码成 %2B → 服务器 form 解码成空格 → base64 book_id 损坏
//   ⇒ 放到 Core/（纯 Foundation）→ 沙盒 swiftc 能真编真跑，
//     验的就是跟真机同一套 Foundation 代码。
//
// ⚠️ 汇总行要放最后（exit() 放中间 → 后面的用例不跑）
// ============================================================

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1 } else { fail += 1; print("  ✗ \(msg)") }
}

// ───────── ① analyzeFields：Legado 语义 ─────────
print("\n── 1. analyzeFields（查询/表单编码）──")
ok(AnalyzeUrl.analyzeFields("a=1&b=2") == "a=1&b=2", "普通字段不动")
ok(AnalyzeUrl.analyzeFields("source=番茄") == "source=%E7%95%AA%E8%8C%84", "中文 → %XX")
ok(AnalyzeUrl.analyzeFields("variable={\"custom\":\"\"}")
   == "variable=%7B%22custom%22%3A%22%22%7D", "花括号/引号 → %XX")
ok(AnalyzeUrl.analyzeFields("id=abc+def") == "id=abc%2Bdef",
   "**'+' → %2B**（留着会被服务器解成空格 → base64 损坏）")
ok(AnalyzeUrl.analyzeFields("x=%E4%B8%AD") == "x=%E4%B8%AD", "已有 %XX 不重复编码")
ok(AnalyzeUrl.analyzeFields("k=a=b") == "k=a=b", "值里的 '=' 不动")

// ───────── ② smartPercentEncode：URL 非法字符 ─────────
print("\n── 2. smartPercentEncode（URL 本身）──")
ok(AnalyzeUrl.smartPercentEncode("https://x.com/a b") == "https://x.com/a%20b", "空格 → %20")
ok(AnalyzeUrl.smartPercentEncode("https://x.com/番茄") == "https://x.com/%E7%95%AA%E8%8C%84",
   "裸中文 → %XX")
ok(AnalyzeUrl.smartPercentEncode("https://x.com/a?b=c&d=e") == "https://x.com/a?b=c&d=e",
   "URL 结构符不动")
ok(AnalyzeUrl.smartPercentEncode("https://x.com/%E4%B8%AD") == "https://x.com/%E4%B8%AD",
   "已有 %XX 不重复编码")

// ───────── ③ 切 URL 选项后缀 ─────────
print("\n── 3. splitOptions（,{json} 后缀）──")
let opt1 = AnalyzeUrl.splitOptions("https://x.com/a,{\"method\":\"POST\",\"body\":{\"html\":\"\"}}")
ok(opt1.url == "https://x.com/a", "切掉选项后缀")
ok((opt1.options["method"] as? String) == "POST", "选项解析出来了")
let opt2 = AnalyzeUrl.splitOptions("https://x.com/a,b,c")
ok(opt2.url == "https://x.com/a,b,c", "普通逗号不能误伤")

// ───────── ④ 整条 URL 规则 ─────────
print("\n── 4. parse（整条 URL 规则）──")
let u = AnalyzeUrl.parse(
    "https://v5.x.com/detail?book_id=NzE4&source=番茄&tab=小说&variable={\"custom\":\"\"}"
    + ",{\"method\":\"POST\",\"body\":{\"html\":\"\"}}",
    baseUrl: "")
print("  → url   = \(u.url)")
print("  → method= \(u.method)")
print("  → body  = \(u.body)")
print("  → ct    = \(u.headers["Content-Type"] ?? "(无)")")
ok(u.method == "POST", "方法是 POST")
ok(!u.url.contains("番茄"), "query 里没有裸中文")
ok(!u.url.contains("{"), "query 里没有裸花括号")
ok(u.url.contains("%E7%95%AA%E8%8C%84"), "中文做了百分号编码")
ok(u.body == "{\"html\":\"\"}", "对象 body 是正规 JSON（不是 [object Object]）")
ok((u.headers["Content-Type"] ?? "").contains("application/json"), "JSON body 补了 Content-Type")

// GET 的 query 也要编码
let g = AnalyzeUrl.parse("https://x.com/s?kw=番茄", baseUrl: "")
ok(g.url == "https://x.com/s?kw=%E7%95%AA%E8%8C%84", "GET 的 query 也编码")
ok(g.body.isEmpty, "GET 没有 body")

// 表单 body → form 编码 + form Content-Type
let f = AnalyzeUrl.parse("https://x.com/p,{\"method\":\"POST\",\"body\":\"a=1&b=番茄\"}", baseUrl: "")
ok(f.body == "a=1&b=%E7%95%AA%E8%8C%84", "表单 body 做 form 编码")
ok((f.headers["Content-Type"] ?? "").contains("x-www-form-urlencoded"),
   "表单 body 补 form Content-Type")

// 相对地址 → 绝对地址
let rel = AnalyzeUrl.parse("../a/b.html", baseUrl: "https://x.com/x/y/")
print("  → 相对地址解析 = \(rel.url)")
ok(rel.url.hasPrefix("https://x.com/"), "相对地址按 baseUrl 绝对化")

// '+' 在 query 里（base64 book_id 会遇到）
let plus = AnalyzeUrl.parse("https://x.com/d?book_id=abc+def", baseUrl: "")
ok(plus.url.contains("%2B"), "query 里的 '+' 编码成 %2B（base64 book_id 不被损坏）")

// ───────── ⑤ 对齐 fixture（**JS 侧也对着它断言**）─────────
// ⚠️ 这段的价值是**防漂移**：JS 那份和这份 Swift 是两份实现，
//    以后谁改了其中一份，另一份立刻红（不然就是「Swift 全绿、真机跑另一套」）。
let fixturePath = "test/fixtures/analyze-url-cases.json"
print("\n── 5. 对齐 fixture（JS 侧同款断言）──")
if let fdata = FileManager.default.contents(atPath: fixturePath),
   let farr = try? JSONSerialization.jsonObject(with: fdata) as? [[String: Any]] {
    for c in farr {
        let name = c["name"] as? String ?? "?"
        let raw = c["raw"] as? String ?? ""
        let base = c["base"] as? String ?? ""
        let exp = c["expected"] as? [String: Any] ?? [:]
        let u = AnalyzeUrl.parse(raw, baseUrl: base)
        let eURL = exp["url"] as? String ?? ""
        let eMethod = exp["method"] as? String ?? ""
        let eBody = exp["body"] as? String ?? ""
        let eCT = exp["contentType"] as? String ?? ""
        ok(u.url == eURL, "\(name)：URL 一致\n      期望: \(eURL)\n      实际: \(u.url)")
        ok(u.method == eMethod, "\(name)：方法一致")
        ok(u.body == eBody, "\(name)：body 一致")
        ok((u.headers["Content-Type"] ?? "") == eCT, "\(name)：Content-Type 一致")
    }
} else {
    ok(false, "读不到 fixture: \(fixturePath)")
}

// 汇总行放最后
print("\n=== ⑤ 请求构造必须走 URLBuilder（2026-10-21 真机「目录 0 章」的根因之二）===")
// ⚠️ 以前 Core/AnalyzeUrl.swift 写好了（build166/167 的 `+`→`%2B`、`/`→`%2F` 修复），
//    **在 App 里一次都没被调用** ⇒ 原生请求只做 Foundation 的百分号编码
//    ⇒ query 里的 `+` 原样保留 ⇒ 服务器 form 解码成空格
//    ⇒ 🍅大灰狼的 book_id 是 base64 ⇒ **book_id 被损坏** ⇒ 「有的书能开、有的书开不了」。
//
// ⭐⭐⭐ **2026-10-25 迁移**（老 JS 引擎物理退役）：
//    App 侧**已经不自建请求层**了（`RuleSandbox.swift` 的 WKWebView 壳已删 ⇒ 调用点也没了）
//    ⇒ 请求构造**整体搬进引擎仓**（`legado-engine/Sources/LegadoCore`）
//    ⇒ 断言**跟着语义走**（不是退休覆盖）：语义还在，只是住址变了 ⭐⭐⭐
//      ① 请求路径走 `URLBuilder.parse`（query 语义 = 参考实现 AnalyzeUrl）
//      ② `URLBuilder` 能拆站方选项后缀 `,{json}`（method / body / headers）
//      ③ 站方 `java.ajax(url, options)` 把 options 转成规则后缀
//         ⇒ **两条链复用同一套编码**（老 App 侧靠 `hasOptionSuffix` 切这两条链）
//      ④ 引擎的 URLBuilder 与参考实现 AnalyzeUrl **有对拍**（Conformance 目标）
if let path = ProcessInfo.processInfo.environment["QR_REPO_DIR"] {
    let engineDir = path + "/../legado-engine/Sources/LegadoCore"
    let read = { (p: String) in
        ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "//.*\n", with: "\n", options: .regularExpression)
    }
    let ub = read(engineDir + "/Host/URLBuilder.swift")
    let tr = read(engineDir + "/Host/HTTPTransport.swift")
    let en = read(engineDir + "/Pipeline/SourceEngine.swift")
    let cf = read(path + "/../legado-engine/Sources/Conformance/main.swift")

    ok(ub.contains("public static func parse("), "引擎有 URLBuilder.parse（URL 规则入口）")
    ok(tr.contains("URLBuilder.parse("), "请求路径走 URLBuilder.parse（query 语义跟参考实现一致）")
    ok(ub.contains("splitOptions")
       && ub.contains("options[\"method\"]")
       && ub.contains("options[\"body\"]")
       && ub.contains("options[\"headers\"]"),
       "URLBuilder 能拆站方选项后缀（method / body / headers）")
    ok(en.contains("rule = u + \",\" + text"),
       "站方 java.ajax 的 options 转成 URL 规则后缀（两条链同语义）")
    ok(cf.contains("URLBuilder.parse(") && cf.contains("AnalyzeUrl.parse("),
       "引擎的 URL 规则与参考实现 AnalyzeUrl 有对拍（Conformance）")
} else {
    ok(false, "拿不到引擎仓源码（QR_REPO_DIR 没设）")
}
// data: 伪 URL 必须原样（载荷是 base64，百分号编码会改掉里面的 + /）
let dataParsed = AnalyzeUrl.parse("data:;base64,eyJib29rX2lkIjoiTnpBNE5qYzQ+,{\"type\":\"qingtian3\"}", baseUrl: "")
ok(dataParsed.url == "data:;base64,eyJib29rX2lkIjoiTnpBNE5qYzQ+,{\"type\":\"qingtian3\"}",
   "data: 伪 URL 原样返回（载荷不被百分号编码改掉）")

print("\n" + (fail == 0 ? "✅" : "❌") + " 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
