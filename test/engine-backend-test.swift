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
// ⭐⭐⭐ 2026-10-25：**老 JS 引擎已退役**（用户明确要求）⇒
//   ⇒ 没有「开关」⇒ 没有「回退」⇒ **只剩新引擎** ⇒ 状态行也简化成一行 ⭐⭐⭐
EngineBackend.lastError = nil
var lines = EngineBackend.statusLines()
ok(lines.count == 1, "成功时只有一行（引擎），不该有失败原因")
ok(lines.contains { $0.label == "引擎" && $0.value.contains("新") }, "引擎那行要有")
ok(!lines.contains { $0.isError }, "没有失败就不该有错误行")

// ⭐ 失败 ⇒ **两行**，第二行是错误（失败原因要看得见）
EngineBackend.lastError = "「search」失败：emptyResult(\"bookList\")"
lines = EngineBackend.statusLines()
ok(lines.count == 2, "失败时要有两行（多了失败原因）")
let errLine = lines.first { $0.label == "失败原因" }
ok(errLine != nil, "⭐ 必须有「失败原因」行（不然用户看不出哪儿坏了）")
ok(errLine?.isError == true, "失败原因那行要标成错误（UI 显示红色）")
ok(errLine?.value.contains("emptyResult") == true, "失败原因要带原始错误")

// ⭐⭐⭐ **不再有「老引擎」这个概念**（2026-10-25 老引擎退役）⇒ 状态里不许出现它
ok(!lines.contains { $0.value.contains("老") }, "状态行里不该再提老引擎")
ok(EngineBackend.description.contains("legado-engine"), "短版文案要说清用的是哪个引擎")
ok(!EngineBackend.description.contains("回退"), "短版文案不该再提回退（已经没有回退了）")

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

// ── ⭐⭐⭐⭐⭐ 站方变量感知的 source（2026-10-28 真机 403 实证）────────────────
//   症状：✿UAA 目录 op 报 403「无效JWT」⇒ 请求头是 `Bearer {"androidId":"…"}`
//   根因：**引擎的 `toc()` / `content()` 重建 `sourceObject` 时漏传 `sourceVariable:`**
//         ⇒ 那个对象退回老语义（`getVariable()` = 整份 varBox JSON = 一个 map）
//   ⇒ 宿主侧兜底：包一层（`getVariable`/`setVariable` 走站方变量槽，其余原样委托）
//   ⚠️ 这组门禁**直接复刻引擎的重建**（不传 sourceVariable）⇒ 改坏实现必须红 ⭐⭐⭐
print("\n=== ⑤ 站方变量感知的 source（引擎漏传槽 ⇒ 宿主侧兜底）===")
let engineSource5 = LegadoEngineBackend.convert(src)
var madeSession: LegadoEngineBackend.Session? = nil
do {
    madeSession = try LegadoEngineBackend.Session(source: engineSource5,
                                                   jar: LegadoCore.CookieJar(),
                                                   jsLib: nil)
} catch {
    print("  ✗ 建会话失败：\(error)")
}
if let session = madeSession, let engine = session.engine {
    // 站方变量槽 = 站方自己写的那一串（✿UAA 放的是 token）
    session.sourceVariable.text = "TOKEN-ABC123"
    // 书源变量（Legado 的 get/put 那套）
    engine.varBox.set("server", "https://line1.example.com")
    engine.varBox.set("androidId", "4ad2abe07c5eded1")

    // ⭐⭐⭐ **复刻引擎 `toc()` / `content()` 的重建**（漏传 sourceVariable ⇒ 老语义）
    let legacy = SourceEngine.makeSourceObject(engineSource5, varBox: engine.varBox)
    let legacyValue = legacy.call("getVariable", [])?.scalarString ?? ""
    ok(legacyValue.contains("androidId"),
       "复刻成功：引擎重建的那个对象 getVariable() = 整份 varBox（map）—— \(legacyValue.prefix(40))")

    // ⭐⭐⭐ 宿主那份必须是「站方变量感知」的
    let host = session.api.stationVariableSourceObject()
    let hostValue = host?.call("getVariable", [])?.scalarString ?? ""
    ok(hostValue == "TOKEN-ABC123",
       "⭐⭐ 宿主 source.getVariable() = 站方变量那一串（不是 map）—— 实际 \(hostValue.prefix(40))")
    // ⭐ 其余方法**原样委托**给引擎那个对象（不重复实现 ⇒ 不会漂）
    ok(host?.call("getKey", [])?.scalarString == engineSource5.bookSourceUrl,
       "其余方法原样委托（getKey 仍返回源 URL）")
    // ⭐⭐ 属性也要**原样带着**（站方 JS 读 `source.bookSourceUrl` / `bookSourceName`）
    //    ⚠️ 这条**必须能红**（属性丢了 ⇒ 站方拼 URL 用空串 ⇒ 静默失效）⭐
    ok(host?.property("bookSourceUrl")?.scalarString == engineSource5.bookSourceUrl,
       "⭐ 属性也原样委托（bookSourceUrl 在）")
    ok(host?.property("bookSourceName")?.scalarString == engineSource5.bookSourceName,
       "⭐ 属性也原样委托（bookSourceName 在）")

    // ⭐⭐⭐ `setVariable(str)` = 写站方变量；**不得**把书源变量整份冲掉
    host?.call("setVariable", [.string("NEW-TOKEN")])
    ok(session.sourceVariable.text == "NEW-TOKEN", "setVariable(str) 写进站方变量槽")
    ok(engine.varBox.get("androidId") == "4ad2abe07c5eded1",
       "⭐⭐ setVariable 不得把书源变量整份冲掉（老语义会并进 varBox）")
    ok(engine.varBox.get("server") == "https://line1.example.com", "⭐⭐ 书源变量一个都不能少")

    // ⭐ 两参数形式 = 改**书源变量**的一项（Legado 两套语义）
    host?.call("setVariable", [.string("tab"), .string("v2")])
    ok(engine.varBox.get("tab") == "v2", "setVariable(key,value) 改书源变量的一项")
    ok(session.sourceVariable.text == "NEW-TOKEN", "⭐ 两参数形式不得动站方变量")

    // ⭐ 站方变量的槽与引擎的是**同一个引用** ⇒ 引擎那边也看得见
    ok(engine.sourceVariable?.text == "NEW-TOKEN", "⭐ 站方变量槽与引擎共享（同一个引用）")
} else {
    ok(false, "⭐ 建不出引擎会话（后面几条没法验）")
}

// ── ⭐⭐⭐⭐⭐ ⑥ JSON 列表项的字段规则要写成 JSONPath（2026-10-29 真机：目录没标题）────
//   症状：✿UAA 目录**有行、点得开、就是没名字**；正文也没章节标题
//   根因：引擎给**字段规则**用的 `isJSON` 取自**页面正文**（✿UAA 的目录页正文 = 纯数字 id ⇒ false）
//         ⇒ 裸字段名 `title` 被当 **CSS** 解析 ⇒ 抽不到（`url` 是引擎特殊字段 ⇒ 能抽到）
//   ⇒ 宿主侧兜底：列表规则是 JS / JSONPath ⇒ 列表项一定是 JSON ⇒ 字段规则改写成 `$.xxx`
print("\n=== ⑥ JSON 列表项的字段规则要写成 JSONPath ===")
func tocSource(_ list: String, _ name: String, _ url: String,
               _ vol: String? = nil, _ vip: String? = nil) -> BookSource {
    var s = BookSource()
    s.bookSourceName = "T"
    s.bookSourceUrl = "https://example.com"
    var t = TocRule()
    t.chapterList = .text(list)
    t.chapterName = .text(name)
    t.chapterUrl = .text(url)
    if let vol { t.isVolume = .text(vol) }
    if let vip { t.isVip = .text(vip) }
    s.ruleToc = t
    return s
}
// ① JS 列表规则 + 裸字段名（✿UAA 的形状）
let e6a = LegadoEngineBackend.convert(
    tocSource("@js:\n[{\"title\":\"第一章\",\"url\":\"u\"}]", "title", "url", "voltype", "isVip"))
ok(e6a.ruleToc?.chapterName == "$.title", "⭐ 裸字段名 title ⇒ $.title（JSON 列表项要按 JSON 取）")
ok(e6a.ruleToc?.chapterUrl == "$.url", "⭐ 裸字段名 url ⇒ $.url")
ok(e6a.ruleToc?.isVolume == nil,
   "⭐⭐ isVolume 直接丢掉（改成 $.voltype ⇒ JSON 的 false 取出来是 \"false\"（非空）⇒ 每章都成卷）")
ok(e6a.ruleToc?.isVip == "isVip", "⭐ isVip 不动（同上：布尔字段不能改写）")
// ② DOM 源：一个字都不改
let e6b = LegadoEngineBackend.convert(
    tocSource(".catalog-section-title,.article-title", "text", "href", ".catalog-section-title"))
ok(e6b.ruleToc?.chapterName == "text", "DOM 源不改（CSS 语义必须原样）")
ok(e6b.ruleToc?.chapterUrl == "href", "DOM 源的 chapterUrl 不改")
ok(e6b.ruleToc?.isVolume == ".catalog-section-title", "DOM 源的 isVolume 不改")
// ③ 已经是 JSONPath ⇒ 不动
let e6c = LegadoEngineBackend.convert(tocSource("$.data.chapterList", "$.title", "$.url"))
ok(e6c.ruleToc?.chapterName == "$.title", "已是 JSONPath 的不改（别写成 $.$.title）")
ok(e6c.ruleToc?.chapterUrl == "$.url", "已是 JSONPath 的 chapterUrl 不改")
// ④ 正则抠名（NovelHub 那种）⇒ 不动
let e6d = LegadoEngineBackend.convert(
    tocSource("@js:\n[]", "##^[^|]*\\|\\|([\\s\\S]*)", "##^([^|]*)\\|\\|[\\s\\S]*"))
ok(e6d.ruleToc?.chapterName == "##^[^|]*\\|\\|([\\s\\S]*)", "正则抠名的规则不改（不是纯路径）")
// ⑤ 绝对 URL 的 chapterUrl ⇒ 不动
let e6e = LegadoEngineBackend.convert(tocSource("@js:\n[]", "title", "https://x.com/a?b=1"))
ok(e6e.ruleToc?.chapterUrl == "https://x.com/a?b=1", "绝对 URL 的 chapterUrl 不改")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)