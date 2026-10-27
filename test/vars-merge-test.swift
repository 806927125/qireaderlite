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

// ============================================================
// ⭐⭐⭐⭐⭐ 站方变量的「两种形态」（2026-10-27 真机「获取 token 不了」的根因）
//
// ⚠️⚠️ 站方变量是「一整串」⇒ **两种形态并存**：
//   · **map 形态**（🍅大灰狼）：`getArguments(source.getVariable(),'server')`
//     ⇒ 站方变量里放 `{"server":…}` 这种 JSON map
//   · **凭据形态**（✿UAA四合一（知秋））：`authorization: Bearer ${source.getVariable()}`
//     ⇒ 站方变量里放 **token 那一串**（不是 JSON）
//
// ⇒⇒ **App 把「书籍变量 / 线路表」写进站方变量 ⇒ 凭据形态的源直接被毁** ⭐⭐⭐
//   （UAA：站方变量变成 `{"androidId":"…"}` ⇒ `Bearer {"androidId":"…"}`
//     ⇒ 服务端 **403「无效JWT」** ⇒ 「获取 token」永远失败 ⭐⭐⭐）
//
// ⇒⇒⇒ 真服务器实证（2026-10-27 直接打 UAA 的接口）：
//   · 不带 authorization 头   ⇒ `403 口令1错误`（JWT 层放行 ⇒ 口令层才拒）✅
//   · `authorization: Bearer `（空）⇒ `403 口令1错误`（**空 Bearer 能过 JWT 层**）✅
//   · `authorization: Bearer {"androidId":"…"}` ⇒ `403 无效JWT` ❌（**这才是真凶**）
// ============================================================
print("\n=== ⑥ 站方变量的两种形态：map 形态 vs 凭据形态 ===")
ok(SourceVariables.canWriteMapIntoVariable(""), "空站方变量 ⇒ 允许写 map")
ok(SourceVariables.canWriteMapIntoVariable("{\"server\":\"https://v5\"}"), "map 形态 ⇒ 允许写 map")
ok(!SourceVariables.canWriteMapIntoVariable(String(repeating: "a", count: 72)),
   "⭐ 凭据形态（token 串）⇒ **不许**被 map 覆盖（否则 Bearer {…} ⇒ 403 无效JWT）")

print("\n=== ⑦ 线路写回：非 map 形态的源 ⇒ 站方变量不许被碰（UAA 那个坑）===")
let uaa = "UAA四合一＃知秋#形状门禁"
let token = String(repeating: "a", count: 72)
SourceVariables.setVariable(token, for: uaa)                  // 站方变量 = token（站方自己写的）
SourceVariables.setVars("{\"androidId\":\"b4e6060006b920bc\"}", for: uaa)
// ① App 合成 map 写回（非 map 形态的源）
SourceVariables.setLineVars("{\"server\":\"https://v1\",\"androidId\":\"b4e6060006b920bc\"}",
                             for: uaa, isMapStyle: false)
ok(SourceVariables.variable(for: uaa) == token,
   "⭐ 非 map 形态 ⇒ 站方变量（token）**没被** map 覆盖")
ok(SourceVariables.vars(for: uaa).contains("server"), "书源变量照样写了线路（站方读 map 形态用）")
ok(SourceVariables.vars(for: uaa).contains("androidId"), "书源变量里的 androidId 还在")

print("\n=== ⑧ map 形态的源（大灰狼）⇒ 线路照旧写进站方变量（不能回归）===")
let dhl = "大灰狼#形状门禁"
SourceVariables.setVariable("{\"tab\":\"小说\"}", for: dhl)
SourceVariables.setLineVars("{\"server\":\"https://v1\",\"tab\":\"小说\"}", for: dhl, isMapStyle: true)
ok(SourceVariables.variable(for: dhl).contains("server"), "map 形态 ⇒ 站方变量拿到了线路")
ok(SourceVariables.vars(for: dhl).contains("server"), "map 形态 ⇒ 书源变量也拿到了线路")

print("\n=== ⑨ 就算 isMapStyle=true，站方变量是 token 时也不许被覆盖 ===")
SourceVariables.setLineVars("{\"server\":\"https://v2\"}", for: uaa, isMapStyle: true)
ok(SourceVariables.variable(for: uaa) == token,
   "⭐ 站方变量是凭据形态 ⇒ 即使 isMapStyle=true 也不许被 map 覆盖")

// 清理（别把门禁数据留在盘上）
SourceVariables.clear(for: uaa)
SourceVariables.clear(for: dhl)
ok(SourceVariables.variable(for: uaa).isEmpty, "clear() 把站方变量也清了（以前漏了 ⇒ token 残留）")

print("\n=== ⑩ isMapStyleVariable：map 形态判定 ===")
ok(!SourceVariables.isMapStyleVariable(""), "空 ⇒ 不是 map 形态")
ok(SourceVariables.isMapStyleVariable("{\"server\":\"https://v1\"}"), "JSON object ⇒ 是 map 形态")
ok(!SourceVariables.isMapStyleVariable(token), "token 串 ⇒ 不是 map 形态（凭据形态）")
ok(!SourceVariables.isMapStyleVariable("[1,2]"), "JSON 数组 ⇒ 不是 map 形态（要的是 object）")

print("\n=== ⑪ 「map 形态」要有证据：站方自己写过 map ===")
let nov = "NovelHub#形状门禁"
ok(!SourceVariables.isStationMapStyle(nov), "没写过 ⇒ 不是 map 形态")
SourceVariables.setVariable("{\"src\":\"x\"}", for: nov)   // 站方自己写的 map
ok(SourceVariables.isStationMapStyle(nov), "⭐ 站方写过 map ⇒ 是 map 形态（证据）")
ok(!SourceVariables.isStationMapStyle(uaa), "UAA 没写过 map ⇒ 不是 map 形态")

print("\n=== ⑫ 迁移：旧实现灌进站方变量的「污染」要清掉（真机上还躺着）===")
// 模拟旧实现（2026-10-27 之前）：把线路表整份灌进站方变量
SourceVariables.setVariable("{\"androidId\":\"b4e6060006b920bc\",\"server\":\"https://v1\"}",
                            for: uaa, origin: .app)
ok(SourceVariables.isMapStyleVariable(SourceVariables.variable(for: uaa)), "（前提）站方变量里现在是一份 map")
SourceVariables.setLineVars("{\"server\":\"https://v2\"}", for: uaa, isMapStyle: false)
ok(SourceVariables.variable(for: uaa).isEmpty,
   "⭐ 非 map 形态的源 ⇒ 污染被清掉（不清 ⇒ `Bearer {\"androidId\":…}` ⇒ 403 无效JWT ⇒ 永远拿不到 token）")
ok(SourceVariables.vars(for: uaa).contains("server"), "书源变量照样写了线路")

print("\n=== ⑬ map 形态的源（NovelHub：站方写过 map）⇒ 不清、照旧写 ===")
SourceVariables.setLineVars("{\"server\":\"https://v2\",\"src\":\"x\"}", for: nov, isMapStyle: true)
ok(SourceVariables.variable(for: nov).contains("server"), "map 形态的源 ⇒ 站方变量照旧写（不能回归）")

// 清理（别把门禁数据留在盘上）
SourceVariables.clear(for: uaa)
SourceVariables.clear(for: dhl)
SourceVariables.clear(for: nov)
ok(SourceVariables.variable(for: uaa).isEmpty, "clear() 把站方变量也清了（以前漏了 ⇒ token 残留）")
ok(!SourceVariables.isStationMapStyle(nov), "clear() 把「map 形态」证据也清了")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
