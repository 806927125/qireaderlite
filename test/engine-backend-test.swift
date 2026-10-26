import Foundation
import LegadoCore

// ============================================================
// ⭐⭐⭐ **新引擎适配层**的门禁（老 JS 引擎 → 自研 Swift 引擎）
//
// 为什么要有这个门禁：
//   适配层要**把两个模型的字段名一一对上**（轻阅的 `RuleValue` / `ListRule` /
//   `BookInfoRule` ⇄ 引擎的 `RuleFields`）⇒ **对错一个字段就是「某条规则静默失效」**
//   ⇒ 而 iOS 真机构建要等 CI ⇒ 沙盒里能真编真跑 ⇒ 3 秒抓错 ⭐
//
// 验的四件事：
//   ① **源转换**：规则字段（含**数组形式**、**`init` 规则**）都转对了
//   ② **`data:` 伪 URL**：载荷要被当响应体（真去 fetch 会抛 base64 错 ⇒ 整本书崩）
//   ③ **书单形状**：新引擎的返回值要和**老引擎一模一样**（否则上层解码不出来）
//   ④ **筛选栏的 paramKey**：从站方 action 里抠出源级变量名
// ============================================================

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1 } else { fail += 1; print("  ✗ " + msg) }
}

// ── 造一个轻阅的书源（规则写法尽量贴近真书源）────────────────
var src = BookSource()
src.bookSourceName = "测试源"
src.bookSourceUrl = "https://example.com"
src.searchUrl = "https://example.com/s?q={{key}}&page={{page}}"
src.exploreUrl = "[{\"title\":\"玄幻\",\"url\":\"https://example.com/list\",\"style\":{}}]"
src.header = "{\"User-Agent\":\"QR/1.0\"}"
src.ruleSearch.bookList = .text("$.data.books")
src.ruleSearch.name = .text("bookName")
src.ruleSearch.author = .text("authorName")
src.ruleSearch.bookUrl = .text("bookId")
// ⭐ 数组形式的规则（站方这么写 ⇒ 以前整条规则**静默丢失**）
src.ruleSearch.intro = .list(["summary", "description"])
// ⭐ `init` 规则（JSON 接口源几乎全靠它）
src.ruleBookInfo.initRule = .text("$.data")
src.ruleBookInfo.name = .text("bookName")
src.ruleBookInfo.tocUrl = .text("catalog")
src.ruleToc.chapterList = .text("result.chapterList[*].chapterViewList[*]")
src.ruleToc.chapterName = .text("chapterName")
src.ruleContent.content = .text(".content@p@text")

print("=== ① 源转换：规则字段要一个不丢 ===")
let e = LegadoEngineBackend.convert(src)
ok(e.bookSourceName == "测试源", "书源名")
ok(e.bookSourceUrl == "https://example.com", "书源 URL")
ok(e.searchUrl == "https://example.com/s?q={{key}}&page={{page}}", "搜索 URL")
ok(e.exploreUrl?.contains("玄幻") == true, "发现页 URL")
ok(e.header == "{\"User-Agent\":\"QR/1.0\"}", "源级请求头")
ok(e.ruleSearch?.bookList == "$.data.books", "列表规则")
ok(e.ruleSearch?.name == "bookName", "书名字段")
ok(e.ruleSearch?.bookUrl == "bookId", "书籍 URL 字段")
ok(e.ruleSearch?.author == "authorName", "作者字段")
// ⭐⭐ 数组形式 ⇒ **合并成换行**（站方的多规则写法）
ok(e.ruleSearch?.intro == "summary\ndescription", "数组规则要合并成换行（不是丢掉）")
// ⭐⭐ `init` 规则（属性名是 initRule，JSON 键仍是 init）
ok(e.ruleBookInfo?.initRule == "$.data", "⭐ init 规则要转过去（JSON 接口源全靠它）")
ok(e.ruleBookInfo?.name == "bookName", "详情字段")
ok(e.ruleBookInfo?.tocUrl == "catalog", "目录 URL 字段")
ok(e.ruleToc?.chapterList == "result.chapterList[*].chapterViewList[*]", "目录规则")
ok(e.ruleContent?.content == ".content@p@text", "正文规则")

print("\n=== ② `data:` 伪 URL：载荷当响应体（不能真去 fetch）===")
let payload = URLSessionTransport.dataPayload("data:;base64,eyJhIjoxfQ==,{\"type\":\"qingtian2\"}")
ok(payload == "{\"a\":1}", "base64 载荷要解出来（拿到的是 \(payload)）")
let plain = URLSessionTransport.dataPayload("data:text/plain,hello")
ok(plain == "hello", "明文载荷原样返回")
let bad = URLSessionTransport.dataPayload("data:;base64,!!!not-base64!!!,{}")
ok(bad.isEmpty, "解不了 base64 要**返回空**（不是乱码 ⇒ 否则站方 JSON.parse 炸）")

print("\n=== ③ 书单形状：要和老引擎一模一样 ===")
var book = EngineBook()
book.name = "斗破苍穹"
book.author = "天蚕土豆"
book.bookUrl = "https://example.com/book/101"
book.raw = ["bookId": "101", "bid": "XID-001"]
let payload3 = LegadoEngineBackend.bookListPayload([book])
let books = (payload3["books"] as? [[String: Any]]) ?? []
ok(books.count == 1, "书单条数")
ok((books.first?["name"] as? String) == "斗破苍穹", "书名")
ok((books.first?["bookUrl"] as? String) == "https://example.com/book/101", "书籍 URL")
let raw = (books.first?["raw"] as? [String: String]) ?? [:]
ok(raw["bid"] == "XID-001", "⭐ 原始字段要带上（站方聚合源要 book_id 之类）")
ok((payload3["total"] as? Int) == 1, "总数")

print("\n=== ④ 筛选栏：paramKey 从站方 action 里抠出来 ===")
ok(LegadoEngineBackend.paramKey(from: "show(infoMap['平台'],'find_source')") == "find_source",
   "paramKey = find_source")
ok(LegadoEngineBackend.paramKey(from: nil) == "", "没有 action ⇒ 空")

print("\n=== ⑤ 引擎状态显示（2026-10-25：老引擎退役 ⇒ 只剩一个引擎）===")
// ⭐⭐⭐ 2026-10-26：**老引擎（WKWebView）接回来了**（用户明确：「换回老引擎」「JSC 给我彻底删掉」）
//   ⇒ **默认老引擎** ⇒ 状态行要说清「现在是谁在服务」⇒ 不能再写死「新引擎」⭐⭐⭐
EngineBackend.lastError = nil
EngineBackend.useNewEngine = false          // ⭐ 默认老引擎
var lines = EngineBackend.statusLines()
ok(lines.count == 1, "成功时只有一行（引擎），不该有失败原因")
ok(lines.contains { $0.label == "引擎" && $0.value.contains("老") },
   "引擎那行要说清现在是谁在服务（默认老引擎）")
ok(!lines.contains { $0.isError }, "没有失败就不该有错误行")

// ⭐ 失败 ⇒ **两行**，第二行是错误（失败原因要看得见）
EngineBackend.lastError = "「search」失败：emptyResult(\"bookList\")"
lines = EngineBackend.statusLines()
ok(lines.count == 2, "失败时要有两行（多了失败原因）")
let errLine = lines.first { $0.label == "失败原因" }
ok(errLine != nil, "⭐ 必须有「失败原因」行（不然用户看不出哪儿坏了）")
ok(errLine?.isError == true, "失败原因那行要标成错误（UI 显示红色）")
ok(errLine?.value.contains("emptyResult") == true, "失败原因要带原始错误")

// ⭐⭐⭐ 2026-10-26：**老引擎回来了** ⇒ 状态里**应该**出现它（默认就是它）
ok(lines.contains { $0.value.contains("老") }, "状态行里要说明当前是老引擎")
// ⭐ 短版文案要说清用的是哪个引擎（老引擎 / 新引擎）
ok(EngineBackend.description.contains("老"), "短版文案要说清用的是哪个引擎（默认老引擎）")
EngineBackend.useNewEngine = true
ok(EngineBackend.description.contains("新"), "切到新引擎后短版文案要跟着变")
EngineBackend.useNewEngine = false

// 复原
EngineBackend.lastError = nil


// ── ⭐⭐⭐ cookie 快照 ⇒ 引擎的 cookie 罐（2026-10-24 真机栽的）────────────
//   症状：🍅大灰狼发现页只剩「未分组」⇒ 站方 /discovestyle（拿真分类）没通
//   根因：老引擎的 java.ajax 用 App 的 cookie 罐（有登录态）⇒ 新引擎用自己的罐（空的）⇒ 登录态丢了
//   ⇒ 修：每次 op 前把 App 的 cookie 快照灌进引擎的罐
let ckJar = LegadoCore.CookieJar()
LegadoEngineBackend.seedCookies(from: ["cookieSnapshot": ["v5.langge.uk": "qttoken=abc; sessionid=YWJjZA=="]],
                                 into: ckJar)
let ckHeader = ckJar.cookieHeader(for: "https://v5.langge.uk/api/x") ?? ""
ok(ckHeader.contains("qttoken=abc"), "⭐⭐ 引擎的 cookie 罐里要有 qttoken（登录态）")
ok(ckHeader.contains("sessionid=YWJjZA=="), "⭐⭐ base64 padding 的 = 不能被截断")
ok(ckJar.cookieHeader(for: "https://other.example.com/x") == nil, "⭐ 别的域不该拿到 cookie")
let ckEmpty = LegadoCore.CookieJar()
LegadoEngineBackend.seedCookies(from: [:], into: ckEmpty)
ok(ckEmpty.cookieHeader(for: "https://v5.langge.uk/x") == nil, "没有快照就不能凭空造 cookie")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
