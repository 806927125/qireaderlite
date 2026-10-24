import Foundation

// ⭐⭐⭐ 门禁：**导入时用原始 JSON 补齐模型丢掉的字段**
//
// ⚠️⚠️ 背景（2026-10-24 真机）：「登录界面整没了」+「打开登录把 app 卡死」
//   - `BookSource.init(from:)` 是**白名单解码** ⇒ 模型后加的字段（`loginUi` 是 build153 才加的）
//     ⇒ **老版本存下来的源，存储里根本没有这个键** ⇒ 登录面板永远显示「loginUi 是空的」
//     ⇒ 站方登录按钮、邮箱/密码输入框**一起消失** ⭐
//   - 同源会丢的还有 `jsLib` / `loginUrl` / `header` / `searchUrl` / `exploreUrl`
//     ⇒ 「站方 JS 跑不起来」「请求头丢了」「搜索/发现静默失效」⭐⭐⭐
//
// ⇒ 修法：**导入时**用原始 JSON（权威）把模型里缺的字段补上。

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✓ \(msg)") }
    else { fail += 1; print("  ✗ \(msg)") }
}

// ─────────────────────────────────────────────────────────────
// ① 模拟「老存储里的源」：模型里这些字段是空的
// ─────────────────────────────────────────────────────────────
print("=== ① 原始 JSON 能把模型缺的字段补回来 ===")
let raw: [String: Any] = [
    "bookSourceUrl": "https://example.com",
    "bookSourceName": "测试源",
    "loginUi": #"[{"name":"邮箱","type":"text"},{"name":"密码","type":"password"}]"#,
    "loginUrl": "function login(flag){}",
    "jsLib": "var host = ['https://x'];",
    "header": "User-Agent: test",
    "searchUrl": "https://example.com/s?q={{key}}",
    "exploreUrl": "https://example.com/e",
    "bookUrlPattern": "https://example.com/b/\\d+",
]

var legacy = BookSource()
legacy.bookSourceUrl = "https://example.com"
legacy.bookSourceName = "测试源"
// ⭐ 老存储的源：这些字段**根本没这个键** ⇒ 解码出来是 nil
ok(legacy.loginUi == nil, "前提：老存储的源 loginUi 是空的")
ok(legacy.jsLib == nil, "前提：老存储的源 jsLib 是空的")

let patched = BookSourceParser.patchMissingFields(legacy, from: raw)
ok(patched.loginUi == raw["loginUi"] as? String, "loginUi 补回来了")
ok(patched.loginUrl == raw["loginUrl"] as? String, "loginUrl 补回来了")
ok(patched.jsLib == raw["jsLib"] as? String, "jsLib 补回来了")
ok(patched.header == raw["header"] as? String, "header 补回来了")
ok(patched.searchUrl == raw["searchUrl"] as? String, "searchUrl 补回来了")
ok(patched.exploreUrl == raw["exploreUrl"] as? String, "exploreUrl 补回来了")
ok(patched.bookUrlPattern == raw["bookUrlPattern"] as? String, "bookUrlPattern 补回来了")

// ─────────────────────────────────────────────────────────────
// ② **模型里有值就不动**（站方更新过的字段仍以模型为准）
// ─────────────────────────────────────────────────────────────
print("\n=== ② 模型里有值 ⇒ 不覆盖 ===")
var hasValue = BookSource()
hasValue.bookSourceUrl = "https://example.com"
hasValue.loginUi = "模型里的值"
hasValue.jsLib = "模型里的 jsLib"
let patched2 = BookSourceParser.patchMissingFields(hasValue, from: raw)
ok(patched2.loginUi == "模型里的值", "loginUi 不被原始 JSON 覆盖")
ok(patched2.jsLib == "模型里的 jsLib", "jsLib 不被原始 JSON 覆盖")

// ─────────────────────────────────────────────────────────────
// ③ 端到端：**真书源**导入后，登录界面必须还在
// ─────────────────────────────────────────────────────────────
print("\n=== ③ 真书源导入后，loginUi 必须还在（这正是真机丢的那条）===")
let repo = FileManager.default.currentDirectoryPath
let candidates = [
    repo + "/sources/🍅大灰狼聚合5.9.30-轻阅适配版v2.json",
    repo + "/sources/dahlang-v2.json",
]
if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
   let data = FileManager.default.contents(atPath: path),
   let list = try? BookSourceParser.parse(data),
   let s = list.first {
    ok((s.loginUi ?? "").isEmpty == false, "导入后 loginUi 非空")
    if let lu = s.loginUi, let d = lu.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
        ok(arr.count >= 3, "loginUi 至少 3 项（邮箱/密码/登录按钮）· 实际 \(arr.count) 项")
        ok(arr.contains { ($0["name"] as? String) == "邮箱" }, "loginUi 里有「邮箱」输入框")
        ok(arr.contains { ($0["type"] as? String) == "button" }, "loginUi 里有按钮（站方登录入口）")
    } else {
        ok(false, "loginUi 不是合法的 JSON 数组")
    }
    ok((s.jsLib ?? "").isEmpty == false, "导入后 jsLib 非空（站方 JS 要它）")
    ok((s.loginUrl ?? "").isEmpty == false, "导入后 loginUrl 非空（站方 login() 要它）")
} else {
    ok(false, "找不到大灰狼源文件（仓库副本）")
}

// ─────────────────────────────────────────────────────────────
// ④ 回归：白名单解码本身没坏
// ─────────────────────────────────────────────────────────────
print("\n=== ④ 没改坏别的 ===")
let minimal = #"{"bookSourceUrl":"https://x.com","bookSourceName":"最小源"}"#
if let d = minimal.data(using: .utf8), let s = try? BookSourceParser.parse(d), let one = s.first {
    ok(one.bookSourceName == "最小源", "最小源照样能解析")
    ok(one.enabled == true, "缺字段时用默认值（enabled）")
    ok(one.loginUi == nil, "源里本来就没有 loginUi ⇒ 保持 nil（不编造）")
} else {
    ok(false, "最小源解析失败")
}

// ─────────────────────────────────────────────────────────────
// ⑤ 「原始 JSON 存档」：导入时留一份 ⇒ 老源**不用重导**也能补回来
// ─────────────────────────────────────────────────────────────
print("\n=== ⑤ 原始 JSON 存档（老源不用重导也能补回来）===")
let archUrl = "https://archive.example.com/src"
let archRaw: [String: Any] = [
    "bookSourceUrl": archUrl,
    "bookSourceName": "存档测试源",
    "loginUi": #"[{"name":"邮箱","type":"text"}]"#,
    "jsLib": "var host = ['https://archive'];",
    "loginUrl": "function login(flag){}",
]
SourceRawArchive.save(archRaw, for: archUrl)
ok(SourceRawArchive.raw(for: archUrl) != nil, "原始 JSON 存下来了")
var stored = BookSource()
stored.bookSourceUrl = archUrl
ok(stored.loginUi == nil, "前提：模型里的 loginUi 是空的（老存储的源）")
let restored = SourceRawArchive.patch(stored)
ok(restored.loginUi == archRaw["loginUi"] as? String, "从存档把 loginUi 补回来了")
ok(restored.jsLib == archRaw["jsLib"] as? String, "从存档把 jsLib 补回来了")
ok(restored.loginUrl == archRaw["loginUrl"] as? String, "从存档把 loginUrl 补回来了")
// 没缺口的源不该去读存档（省 IO）
var complete = BookSource()
complete.bookSourceUrl = archUrl
complete.loginUi = "有"
complete.jsLib = "有"
complete.loginUrl = "有"
complete.searchUrl = "有"
complete.exploreUrl = "有"
ok(SourceRawArchive.patch(complete).loginUi == "有", "没缺口的源不被存档覆盖")

print("\n✅ 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
