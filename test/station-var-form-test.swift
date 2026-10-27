import Foundation

// ============================================================
// ⭐⭐⭐⭐⭐ 站方变量的「形态」静态判定（2026-10-27 真机复盘）
//
// ────────────────────────────────────────────────────────────
// ⚠️ **为什么必须有静态判定**（真机上的血泪）：
//   运行时证据（站方写过什么）**要等它写过才知道** ⇒
//   ⇒ 手机上**已经躺着的旧污染**（`{"androidId":…}`）**第一次 op 之前永远判不出来** ⭐⭐⭐
//   ⇒ 判不出来 = 不许清 ⇒ **污染永远清不掉** ⇒ `Bearer {…}` ⇒ 403「无效JWT」永远好不了 ⭐⭐⭐
//   ⇒ **静态扫描站方 jsLib** ⇒ 装机第一次跑就知道这一格是 map 还是凭据 ⭐⭐⭐
//
// ────────────────────────────────────────────────────────────
// 本门禁用**真源**（仓库里的书源文件）当断言对象 ⇒ 不是 mock ⭐⭐⭐
// ============================================================

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String, _ extra: String = "") {
    if cond { pass += 1 } else { fail += 1; print("  ✗ " + msg + (extra.isEmpty ? "" : "  → " + extra)) }
}

/// 读真源的 jsLib（多文件源取第一个）
func jsLib(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    if let arr = obj as? [[String: Any]], let first = arr.first { return first["jsLib"] as? String }
    if let d = obj as? [String: Any] { return d["jsLib"] as? String }
    return nil
}

print("=== ① 静态扫描：合成片段（判据本身） ===")
ok(StationVarFormScanner.form(jsLib: nil) == .unknown, "没有 jsLib ⇒ 不知道（不许动）")
ok(StationVarFormScanner.form(jsLib: "") == .unknown, "空 jsLib ⇒ 不知道")
ok(StationVarFormScanner.form(jsLib: "function f(){}") == .unknown, "压根没用这一格 ⇒ 不知道")

// 凭据形态：拼进请求头
ok(StationVarFormScanner.form(jsLib: "let h = {authorization: 'Bearer ' + source.getVariable()}")
   == .credential, "⭐ getVariable 拼进字符串 ⇒ 凭据形态（UAA 那种）")
ok(StationVarFormScanner.form(jsLib: "let u = `x?token=${source.getVariable()}`") == .credential,
   "⭐ getVariable 进模板字符串 ⇒ 凭据形态")
// map 形态：被解析
ok(StationVarFormScanner.form(jsLib: "let d = JSON.parse(source.getVariable())") == .map,
   "⭐ getVariable 被 JSON.parse ⇒ map 形态")
ok(StationVarFormScanner.form(jsLib: "let s = getArguments(source.getVariable(), 'server')") == .map,
   "⭐ getVariable 喂给 getArguments ⇒ map 形态（大灰狼那种）")
// 写：写什么形态就是什么形态
ok(StationVarFormScanner.form(jsLib: "source.setVariable(JSON.stringify({a:1}))") == .map,
   "⭐ setVariable(JSON.stringify(…)) ⇒ map 形态")
ok(StationVarFormScanner.form(jsLib: "source.setVariable(token)") == .credential,
   "⭐ setVariable(标量) ⇒ 凭据形态")
// 注释里出现的**不算**
ok(StationVarFormScanner.form(jsLib: "// source.getVariable() 用在这儿\nfunction f(){}") == .unknown,
   "⭐ 注释里的 getVariable 不算（不许被注释骗）")
ok(StationVarFormScanner.form(jsLib: "/* JSON.parse(source.getVariable()) */ function f(){}") == .unknown,
   "⭐ 块注释里的也不算")

print("\n=== ② ⭐⭐⭐ 真源（不是 mock！）：形态判对了吗 ===")
// ✿UAA 原版（一字不改）⇒ 站方变量 = 纯 token ⇒ 凭据形态
if let js = jsLib("test/fixtures/uaa-original.json") {
    ok(StationVarFormScanner.form(jsLib: js) == .credential,
       "⭐⭐⭐ 原版 UAA ⇒ 凭据形态（那一格放的是 token）")
} else {
    ok(false, "读不到 test/fixtures/uaa-original.json")
}
if let js = jsLib("sources/✿UAA四合一（知秋）✿-轻阅版.json") {
    ok(StationVarFormScanner.form(jsLib: js) == .credential,
       "⭐⭐⭐ 轻阅版 UAA ⇒ 凭据形态")
} else {
    ok(false, "读不到 轻阅版 UAA")
}
// 大灰狼 / NovelHub / 番茄 ⇒ map 形态（**判错就会把大灰狼的线路表写不进去** ⇒ 变回 8 条线路慢速）
if let js = jsLib("sources/🍅大灰狼聚合5.9.30-轻阅适配版v2.json") {
    ok(StationVarFormScanner.form(jsLib: js) == .map,
       "⭐⭐⭐ 大灰狼 ⇒ map 形态（线路表要能写进站方变量）")
} else {
    ok(false, "读不到 大灰狼")
}
if let js = jsLib("sources/NovelHub聚合小说-轻阅版.json") {
    ok(StationVarFormScanner.form(jsLib: js) == .map, "⭐⭐⭐ NovelHub ⇒ map 形态")
} else {
    ok(false, "读不到 NovelHub")
}
if let js = jsLib("sources/配置文件125个-轻阅适配版.json") {
    // 这个包里有 125 个源 ⇒ 逐个扫 ⇒ 有用到这一格的都该判成 map（番茄小说TS）
    if let data = FileManager.default.contents(atPath: "sources/配置文件125个-轻阅适配版.json"),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        var used = 0, wrong = 0
        for s in arr {
            guard let js = s["jsLib"] as? String, !js.isEmpty else { continue }
            guard js.contains("getVariable") || js.contains("setVariable") else { continue }
            used += 1
            if StationVarFormScanner.form(jsLib: js) != .map { wrong += 1 }
        }
        ok(used > 0, "125 源包里确实有用到这一格的源", "只有 \(used) 个")
        ok(wrong == 0, "⭐⭐⭐ 125 源包里用到这一格的都判成 map 形态（不能误伤）", "有 \(wrong) 个判错")
    }
}

print("\n=== ③ 集成：`form(for:jsLib:)` 的优先级（静态 > 运行时证据 > 默认表） ===")
let uaa = "form-gate-#uaa"
let dhl = "form-gate-#dahl"
for u in [uaa, dhl] { SourceVariables.clear(for: u) }

// ① 静态判据优先：jsLib 说凭据 ⇒ 即使运行时证据写着 map，也判凭据
SourceVariables.setVariable("{\"a\":1}", for: uaa, origin: .station)   // 运行时证据 = map
ok(SourceVariables.form(for: uaa, jsLib: "let h='Bearer '+source.getVariable()") == .credential,
   "⭐⭐⭐ 静态判据**压过**运行时证据（旧的 map 证据不许再把 UAA 判成 map）")
// ② 没有 jsLib ⇒ 退回运行时证据
ok(SourceVariables.form(for: uaa) == .map, "没有 jsLib ⇒ 退回运行时证据（map）")
// ③ 静态判据说 map ⇒ 即使默认表是空的，也判 map（大灰狼的线路表要写得进去）
SourceVariables.setDefaultVars([:], for: dhl)
ok(SourceVariables.form(for: dhl, jsLib: "let d=JSON.parse(source.getVariable())") == .map,
   "⭐ 静态判据说 map ⇒ 就是 map（不因默认表空而变凭据）")
// ④ 静态说凭据 + 槽里躺着一个 map ⇒ 迁移清掉它
SourceVariables.setVariable("{\"androidId\":\"b4e6\"}", for: uaa, origin: .app)
ok(SourceVariables.variable(for: uaa).contains("androidId"), "（前提）槽里躺着一份 map（真机上的旧污染）")
let seeded = SourceVariables.stationVariableToSeed(for: uaa, jsLib: "let h='Bearer '+source.getVariable()")
ok(seeded.isEmpty, "⭐⭐⭐ 凭据形态 + 槽里是 map ⇒ 灌进引擎的那一串被清空（污染清掉了）")
ok(SourceVariables.variable(for: uaa).isEmpty, "⭐⭐⭐ 落盘的那一格也清空了")
// ⑤ map 形态的源 ⇒ 不许清（大灰狼的合法 map）
SourceVariables.setVariable("{\"server\":\"https://v1\"}", for: dhl, origin: .app)
let seeded2 = SourceVariables.stationVariableToSeed(for: dhl, jsLib: "let d=JSON.parse(source.getVariable())")
ok(seeded2.contains("server"), "⭐ map 形态的源 ⇒ 迁移**不许**清（否则大灰狼线路丢失）")

for u in [uaa, dhl] { SourceVariables.clear(for: u) }

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
