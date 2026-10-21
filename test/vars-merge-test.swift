import Foundation

// ============================================================
// 书源变量合并（纯 Foundation → 沙盒 swiftc 能真编真跑）
//
// ⭐ 为什么要有这个门禁（2026-10-21 真机「目录 0 章」的根因）：
//   站方的 `getArguments(open_argument, key)` **只有变量串解析失败时**
//   （也就是空串）才返回它的默认变量表；一旦写入任何一项
//   （比如「测速选最快线路」写 `{"server":"…"}`），它就**不再给默认**
//   ⇒ `tab / sources / source_type / proxy …` 全变 undefined
//   ⇒ 源被改坏。实测：只写 `{"proxy":"本地"}` ⇒ `server` 没了
//   ⇒ 请求 URL 变成 `undefined/catalog` ⇒ 4 本书全部 0 章 ❗
//
// ⇒ App 写变量时必须**拿站方自己的默认值做底**，用户的改动盖在上面 ✅
// ============================================================

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1 } else { fail += 1; print("  ✗ " + msg) }
}

func json(_ text: String) -> [String: Any] {
    guard let d = text.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

// 站方的默认变量表（照 🍅大灰狼 jsLib 的 getArguments 兜底默认值）
let stationDefaults: [String: Any] = [
    "tab": "小说",
    "tone_id": "默认音色",
    "server": "https://v5.langge.uk",
    "sources": "全部",
    "source_type": "男频",
    "fqpara": "on",
    "pstyle": "0"
]

print("=== ① 合并：用户的改动盖住默认，其余默认项保住 ===")
let merged = json(SourceVariables.mergeVars(
    userJSON: "{\"server\":\"https://v2.langge.uk\"}", defaults: stationDefaults))
ok((merged["server"] as? String) == "https://v2.langge.uk", "用户的 server 覆盖了站方默认")
ok((merged["tab"] as? String) == "小说", "站方默认的 tab 保住了（原来会丢）")
ok((merged["sources"] as? String) == "全部", "站方默认的 sources 保住了")
ok((merged["source_type"] as? String) == "男频", "站方默认的 source_type 保住了")
ok((merged["fqpara"] as? String) == "on", "站方默认的 fqpara 保住了")

print("\n=== ② 变量为空 ⇒ 站方默认整份生效 ===")
let empty = json(SourceVariables.mergeVars(userJSON: "", defaults: stationDefaults))
ok((empty["server"] as? String) == "https://v5.langge.uk", "空变量 → 用站方默认 server")
ok((empty["tab"] as? String) == "小说", "空变量 → 用站方默认 tab")

print("\n=== ③ 非法 JSON 不炸，退回默认 ===")
let broken = json(SourceVariables.mergeVars(userJSON: "{不是 json", defaults: stationDefaults))
ok((broken["server"] as? String) == "https://v5.langge.uk", "变量串坏了也还有站方默认")

print("\n=== ④ 用户写了 proxy（本地/云端）⇒ 其它默认项照样在 ===")
let withProxy = json(SourceVariables.mergeVars(
    userJSON: "{\"proxy\":\"本地\"}", defaults: stationDefaults))
ok((withProxy["proxy"] as? String) == "本地", "proxy 写进去了")
ok((withProxy["server"] as? String) == "https://v5.langge.uk",
   "⭐ 只写 proxy 时 server 仍在（原来会丢 → URL 变 undefined/catalog → 0 章）")

print("\n=== ⑤ 没有站方默认（普通书源）⇒ 原样保留用户写的 ===")
let plain = json(SourceVariables.mergeVars(userJSON: "{\"a\":\"1\"}", defaults: [:]))
ok((plain["a"] as? String) == "1", "没有站方默认时用户变量原样保留")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
