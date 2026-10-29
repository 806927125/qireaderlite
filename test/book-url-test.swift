import Foundation

// ============================================================
// 轻阅原生层：**书籍 URL 规范化**（Core/Book.swift）真跑测试
//
// 跑法：bash test/run-swift-tests.sh
//
// 起因（2026-10-21 真机，用户原话「大灰狼还是一样」）：
//   聚合源（🍅大灰狼）的书籍 URL 是
//     `data:;base64,<载荷>,{"type":"qingtian"}`
//   而 `URL(string:).absoluteString` 会把那个 `{"type":…}` **百分号编码**成
//     `,%7B%22type%22%3A%22qingtian%22%7D`
//   ⇒ 引擎的 `,{` 后缀剥离**失效** → 载荷被污染 →
//     站方 `JSON.parse(java.hexDecodeToString(result))` 炸
//     → 「JSON Parse error: Unable to parse JSON string」→ 详情页整条规则静默失效。
//
// ⚠️ **沙盒为什么测不到**：活体测试传的是**原始** bookUrl，
//    而 App 传的是 `cleanBookUrl`（规范化后的）—— 两边走的不是同一条路！
//    ⇒ 这道门禁钉死「data:/blob:/qireaderlite: 必须原样返回」。
// ============================================================

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1 } else { fail += 1; print("  ✗ \(msg)") }
}

print("\n── 1. data: 伪 URL 必须原样返回 ──")
let payload = "eyJib29rX2lkIjoiTnpFNE9UVTBOREEzTnprNE5EQXdPVEkzTnciLCJzb3VyY2VzIjoi57O277yMIn0"
let dataURL = "data:;base64,\(payload),{\"type\":\"qingtian\"}"
let n1 = Book.normalizeURL(dataURL)
print("  → \(n1)")
ok(n1 == dataURL, "**data: URL 一字不改**（后缀被编码的话引擎就剥不掉了）")
ok(n1.contains("{\"type\":\"qingtian\"}"), "后缀的原始形态还在")

print("\n── 2. blob: / 自定义 scheme 同样原样 ──")
ok(Book.normalizeURL("blob:https://x.com/abc") == "blob:https://x.com/abc", "blob: 原样")
ok(Book.normalizeURL("qireaderlite://import?x=1") == "qireaderlite://import?x=1", "qireaderlite: 原样")

print("\n── 3. 普通 http URL 照常规范化 ──")
let h = "https://v5.langge.uk/detail?source=番茄"
let n3 = Book.normalizeURL(h)
print("  → \(n3)")
ok(n3.hasPrefix("https://v5.langge.uk/detail"), "http 仍然规范化")
ok(n3.contains("%E7%95%AA%E8%8C%84"), "中文被百分号编码（iOS 的 URL(string:) 才认）")

print("\n── 4. 边界 ──")
ok(Book.normalizeURL("") == "", "空串 → 空串")
ok(Book.normalizeURL("   ") == "", "空白 → 空串")
ok(Book.normalizeURL("  data:;base64,abc  ") == "data:;base64,abc", "data: 也会去首尾空白")
// ⚠️ 关键不是「原样」，是**别清空** —— 以前 `guard let u = URL(string:) else { return "" }`
//    会把解析不了的 URL 直接清成空串 → 书打不开。
let weird = Book.normalizeURL("not a url")
print("  → 'not a url' 规范化后 = \(weird)")
ok(!weird.isEmpty, "解析不了也别清空（以前是 return \"\"）")

// ── ⭐⭐⭐⭐⭐ 带 `,{…}` 后缀的 URL（2026-10-29 真机：封面改了还是占位图）──
//   症状：封面永远占位图 ⇒ 查下来是**上游**把后缀**百分号编码**了（`%7B`）⇒ 拆不出请求头
print("\n── 5. 带 ,{…} 后缀的 URL：后缀不许被百分号编码 ──")
let coverRaw = "https://cdn.uaa010.com/file/bucket-media/image/cover/x.jpg,{\"method\":\"GET\",\"headers\":{\"Referer\":\"uaa.com\"}}"
let coverNorm = Book.normalizeURL(coverRaw)
print("  → \(coverNorm)")
ok(!coverNorm.contains("%7B"), "⭐⭐ 后缀里的 `{` 没被百分号编码（编码了就废了）")
ok(!coverNorm.contains("%22"), "⭐⭐ 后缀里的引号也没被编码")
ok(coverNorm.hasPrefix("https://cdn.uaa010.com/file/bucket-media/image/cover/x.jpg,"),
   "⭐⭐ URL 部分原样，后缀跟在逗号后面")
ok(coverNorm.contains("\"Referer\":\"uaa.com\""), "⭐⭐ 后缀里的请求头还在")
// ⭐ 关键闭环：规范化之后**还能拆出请求头**（这才是封面能出来的前提）
let (u5, o5) = AnalyzeUrl.splitOptionsRaw(coverNorm)
ok(u5 == "https://cdn.uaa010.com/file/bucket-media/image/cover/x.jpg", "⭐⭐⭐ 规范化后仍能拆出干净的 URL")
ok(!o5.isEmpty && (try? JSONSerialization.jsonObject(with: Data(o5.utf8))) != nil,
   "⭐⭐⭐ 规范化后仍能拆出请求头（后缀还是合法 JSON）")
// 相对路径 + 后缀 ⇒ URL 部分要绝对化（后缀照旧保留）
let relCover = "/img/a.jpg,{\"headers\":{\"Referer\":\"uaa.com\"}}"
let relNorm = Book.normalizeURL(relCover)
print("  → \(relNorm)")
ok(!relNorm.contains("%7B"), "⭐ 相对路径 + 后缀：后缀也没被编码")
ok(relNorm.contains("/img/a.jpg"), "⭐ 相对路径 + 后缀：路径部分还在")
// 没有后缀的 URL 不受影响
ok(Book.normalizeURL("https://x.com/a.jpg") == "https://x.com/a.jpg", "没有后缀的不受影响")

// 汇总行放最后
print("\n" + (fail == 0 ? "✅" : "❌") + " 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
