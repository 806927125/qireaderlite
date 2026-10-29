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

// ⑥ 宿主写 map ⇒ 凭据形态要拦住（✿UAA 那一格只配放 token）
let host = "form-gate-#host"
SourceVariables.clear(for: host)
SourceVariables.setHostMap("{\"androidId\":\"x\"}", for: host,
                           jsLib: "let h='Bearer '+source.getVariable()")
ok(SourceVariables.variable(for: host).isEmpty,
   "⭐⭐⭐ 凭据形态 ⇒ 宿主往这一格塞 map 被拦住（UAA：否则 Bearer {…} ⇒ 403 无效JWT）")
ok(SourceVariables.vars(for: host).contains("androidId"),
   "⭐ 书源变量照写（那是宿主自己的变量表，跟站方变量是两套）")
// map 形态的源 ⇒ 照旧写得进去（不能回归）
SourceVariables.setHostMap("{\"server\":\"https://v2\"}", for: dhl,
                           jsLib: "let d=JSON.parse(source.getVariable())")
ok(SourceVariables.variable(for: dhl).contains("server"),
   "⭐ map 形态的源 ⇒ 宿主写 map 照旧生效（不能回归）")

// ⑦ ⭐⭐⭐ 结构性判据：**站方从没写过这一格** + 里面躺着一个 map ⇒ 那是**宿主灌的** ⇒ 清
let orphan = "form-gate-#orphan"
SourceVariables.clear(for: orphan)
SourceVariables.setVariable("{\"androidId\":\"b4e6\"}", for: orphan, origin: .app)
ok(SourceVariables.variable(for: orphan).contains("androidId"), "（前提）槽里躺着一份 map")
let seeded3 = SourceVariables.stationVariableToSeed(for: orphan)
ok(seeded3.isEmpty, "⭐⭐⭐⭐⭐ 形态未知 + 站方从没写过 + 槽里是 map ⇒ 照样清（宿主灌的）")
ok(SourceVariables.variable(for: orphan).isEmpty, "⭐⭐⭐ 落盘那一格也清空了")
let own = "form-gate-#own"
SourceVariables.clear(for: own)
SourceVariables.setVariable("{\"server\":\"https://v1\"}", for: own, origin: .station)
let seeded4 = SourceVariables.stationVariableToSeed(for: own)
ok(seeded4.contains("server"), "⭐⭐⭐ 站方自己写过 map ⇒ 不许清（大灰狼的线路表）")
for u in [uaa, dhl, host, orphan, own] { SourceVariables.clear(for: u) }

// ============================================================
// ⭐⭐⭐⭐⭐ ⑧ 凭据双写（2026-10-29 真机 401「目录 0 章」根因）
//
// ────────────────────────────────────────────────────────────
// ⚠️ **根因**：Legado 的**站方变量**与**书源变量**是**两套**：
//   · `source.getVariable()` / `setVariable(str)` ⇒ 站方变量（一整串）
//   · `source.get(k)` / `put(k,v)`             ⇒ 书源变量（map）
//   ⇒ **互不相通** ⭐⭐⭐
//
// ⚠️ **不同版本的站方源把 token 存在不同的地方**：
//   · 老版：`setVariable(token)` + `Bearer ${source.getVariable()}`
//   · **新版：`put('token', t)` + `Bearer ${source.get('token')}`** ⭐⭐⭐
//   ⇒ 宿主只写站方变量 ⇒ **新版站方源读 `source.get('token')` = 空**
//   ⇒ 请求头 `authorization: "Bearer "` ⇒ **401** ⇒ 目录 0 章 ⭐⭐⭐
//   ⇒ 而探针读 `getVariable()` ⇒ 显示「有 token」⇒ **看着一切正常** ⭐
//
// ⭐ **修法 = 两套都写**（不是挑一套）⇒ 新旧版站方源都能读到 ⭐
// ⚠️ **只对「凭据形态」做**（map 形态塞 token = 制造污染 ⇒ 绝不做）
// ============================================================
print("\n=== ⑧ 凭据双写：站方变量 ⇄ 书源变量的 `token` 项 ===")
let newUaa = "form-gate-#newuaa"
let mapUaa = "form-gate-#mapuaa"
for u in [newUaa, mapUaa] { SourceVariables.clear(for: u) }

// ① ⭐⭐⭐ **新版站方源**：jsLib 只用 `source.get('token')`（压根不碰 getVariable）
//   ⇒ 静态扫描判 **unknown**（不是 map）⇒ 双写**放行** ⭐
let newJsLib = "let h = {authorization: 'Bearer ' + source.get('token')}"
ok(SourceVariables.form(for: newUaa, jsLib: newJsLib) == .unknown,
   "⭐⭐⭐ 新版站方源（只用 get('token')）⇒ 形态 unknown（扫描器只认 getVariable/setVariable）")
SourceVariables.setVariable("eyJpZCI6IjRhZDJhYmUwN2M1ZWRlZDEi", for: newUaa, origin: .station)
SourceVariables.mirrorCredentialToVars("eyJpZCI6IjRhZDJhYmUwN2M1ZWRlZDEi", for: newUaa, jsLib: newJsLib)
ok(SourceVariables.varsMap(for: newUaa)["token"] == "eyJpZCI6IjRhZDJhYmUwN2M1ZWRlZDEi",
   "⭐⭐⭐⭐⭐ 凭据双写：token 也进了书源变量 ⇒ 新版站方 `source.get('token')` 读得到 ⇒ 不再是空 Bearer")

// ② ⭐⭐⭐⭐⭐ **老版站方源**（用 getVariable）⇒ 站方变量那一格仍然有效（不能回归）
ok(SourceVariables.variable(for: newUaa) == "eyJpZCI6IjRhZDJhYmUwN2M1ZWRlZDEi",
   "⭐⭐⭐ 站方变量那一格仍然原样保留（老版站方源照样读得到）")

// ③ ⭐⭐⭐⭐⭐ **map 形态的源 ⇒ 绝不许塞 token**（那是污染）
//   ⚠️⚠️ **两道守卫覆盖的场景不同**（变异测试逼出来的）⭐⭐⭐：
//   · 第①道（值不是 JSON map）⇒ 挡「值本身是 map」的
//   · 第②道（形态证据不是 map）⇒ 挡「值是标量、但这个源是 map 形态」的
//   ⇒ **两个场景都要测**（只测一个 ⇒ 变异测试会打不中 ⇒ 门禁没牙齿）⭐⭐⭐
SourceVariables.setVariable("{\"server\":\"https://v1\"}", for: mapUaa, origin: .station)
// ⭐ 场景 B：裸标量（不是 JSON）⇒ 一定穿过第①道 ⇒ 真正检验第②道
SourceVariables.mirrorCredentialToVars("裸标量token", for: mapUaa,
                                        jsLib: "let d=JSON.parse(source.getVariable())")
ok(SourceVariables.varsMap(for: mapUaa)["token"] == nil,
   "⭐⭐⭐⭐⭐ 场景 B（值是标量 + 形态证据 = map）⇒ **不写** token 进书源变量")

// ⭐ 场景 A：**值本身是 JSON map**（凭据形态的源里躺着污染 map）⇒ 第①道就该挡
let polluteUaa = "form-gate-#polluteuaa"
SourceVariables.clear(for: polluteUaa)
SourceVariables.setVariable("{\"androidId\":\"b4e6\"}", for: polluteUaa, origin: .app)
SourceVariables.mirrorCredentialToVars("{\"androidId\":\"b4e6\"}", for: polluteUaa,
                                        jsLib: "let h='Bearer '+source.getVariable()")
ok(SourceVariables.varsMap(for: polluteUaa)["token"] == nil,
   "⭐⭐⭐⭐⭐ 场景 A（值本身是 JSON map）⇒ **不写** token 进书源变量（那份是污染，不是凭据）")

// ④ ⭐⭐⭐ 站方自己写的 token ≠ 宿主那份 ⇒ 不许覆盖
let keepUaa = "form-gate-#keepuaa"
SourceVariables.clear(for: keepUaa)
SourceVariables.setVars("{\"token\":\"站方自己写的\"}", for: keepUaa)
SourceVariables.setVariable("宿主这份", for: keepUaa, origin: .station)
SourceVariables.mirrorCredentialToVars("宿主这份", for: keepUaa, jsLib: newJsLib)
ok(SourceVariables.varsMap(for: keepUaa)["token"] == "站方自己写的",
   "⭐⭐⭐ 站方自己写的 token 优先 ⇒ 宿主那份不许覆盖它")

// ⑤ ⭐⭐⭐ 幂等：双写两次结果一样（不重复折腾）
SourceVariables.mirrorCredentialToVars("eyJpZCI6IjRhZDJhYmUwN2M1ZWRlZDEi", for: newUaa, jsLib: newJsLib)
ok(SourceVariables.varsMap(for: newUaa)["token"] == "eyJpZCI6IjRhZDJhYmUwN2M1ZWRlZDEi",
   "⭐⭐⭐ 双写是幂等的（重复写结果不变）")

// ⑥ ⭐⭐⭐ 空值 ⇒ 不写（清空站方变量不该留下旧 token）
let emptyUaa = "form-gate-#emptyuaa"
SourceVariables.clear(for: emptyUaa)
SourceVariables.mirrorCredentialToVars("", for: emptyUaa, jsLib: newJsLib)
ok(SourceVariables.varsMap(for: emptyUaa)["token"] == nil,
   "⭐⭐⭐ 空凭据 ⇒ 不写进书源变量")

for u in [newUaa, mapUaa, polluteUaa, keepUaa, emptyUaa] { SourceVariables.clear(for: u) }

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
