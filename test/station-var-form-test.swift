import Foundation

// ============================================================
// ⭐⭐⭐⭐⭐ 站方变量的「形态」与「污染迁移」（2026-10-27 真机复盘）
//
// ────────────────────────────────────────────────────────────
// 背景：✿UAA四合一（知秋）⇒ 点「获取Token」⇒ 服务端 403「无效JWT」
//   ⇒ 请求头是 `authorization: Bearer {"androidId":"b4e6060006b920bc"}`
//   ⇒ 站方变量里躺着的**不是 token，是宿主灌进去的一份 map** ⭐⭐⭐
//
// 本门禁钉四件事（每一条都对应真机上的一个坑）：
//   ① **形态证据不许自证**（2026-10-27 真机复盘挖出来的根因）
//      ⇒ 回传时值**一模一样** ⇒ 那是「宿主灌的污染被原样弹回来」⇒ **不是证据**
//      ⇒ 旧实现拿它当证据 ⇒ 「凭据形态」永远判不出来 ⇒ 污染永远清不掉 ⭐⭐⭐
//   ② **证据的键要带版本**：v1 的证据**已经自证污染了** ⇒ 换键名 ⇒ 旧的直接作废
//   ③ **迁移不许挂在「选线」那条链上**（✿UAA 压根没有线路 ⇒ 那条链永远走不到）
//      ⇒ 迁移必须挂在**每个 op 都要走的**「灌站方变量」这一步 ⭐⭐⭐
//   ④ **形态「不知道」时不许动这一格**
//      ⇒ 大灰狼第一次进来时默认表还没取到 ⇒ 那时候清一下就把它的合法 map 清掉了 ⭐⭐⭐
// ============================================================

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1 } else { fail += 1; print("  ✗ " + msg) }
}

// ⚠️ 用**独立**的源 URL（别撞真实源）⇒ 门禁数据不污染真机
let tag = "station-form-gate-\(ProcessInfo.processInfo.processIdentifier)"
let uaa = "\(tag)#uaa"        // 凭据形态（UAA）：默认表取过 = 空
let dhl = "\(tag)#dahulang"   // map 形态（大灰狼）：默认表非空
let fresh = "\(tag)#fresh"    // 形态还「不知道」：默认表**没取过**
let token = String(repeating: "a", count: 72)
let pollution = "{\"androidId\":\"b4e6060006b920bc\",\"server\":\"https://v1\"}"

// 清理上次可能留下的
for u in [uaa, dhl, fresh] { SourceVariables.clear(for: u) }

print("=== ① 形态判据：三条证据各有各的岗位 ===")
// 前提：三个源都还没取过默认表 ⇒ 形态「不知道」
ok(SourceVariables.form(for: uaa) == .unknown, "默认表没取过 ⇒ 形态 = 不知道（不许动这一格）")
ok(SourceVariables.form(for: fresh) == .unknown, "同上")

// 证据①：**站方自己写过 map** ⇒ map 形态
SourceVariables.setVariable("{\"src\":\"x\"}", for: dhl, origin: .station)
ok(SourceVariables.form(for: dhl) == .map, "⭐ 站方自己写过 map ⇒ map 形态（证据）")

// 证据②：**站方自带默认变量表**（大灰狼）⇒ map 形态
SourceVariables.setDefaultVars(["tab": "小说", "server": "https://v5.langge.uk"], for: uaa)
ok(SourceVariables.form(for: uaa) == .map, "⭐ 站方自带默认表 ⇒ map 形态（大灰狼）")

// 证据③：**默认表取过了、且是空的** ⇒ 凭据形态（UAA）
SourceVariables.setDefaultVars([:], for: fresh)
ok(SourceVariables.form(for: fresh) == .credential,
   "⭐⭐⭐ 默认表取过 + 是空的 ⇒ 凭据形态（UAA：这一格放的是 token）")
ok(!SourceVariables.defaultTableFetched(dhl),
   "（前提）「默认表取过没」是**独立**的标记（dhl 没取过默认表，只是站方写过 map）")

print("\n=== ② 证据不许自证（2026-10-27 真机复盘的根因）===")
// 模拟「回传时值一模一样」⇒ 那是宿主灌的污染被原样弹回来 ⇒ **不是证据**
let pollute = "\(tag)#polluted"
SourceVariables.clear(for: pollute)
SourceVariables.setDefaultVars([:], for: pollute)          // 凭据形态
SourceVariables.setVariable(pollution, for: pollute, origin: .app)   // 宿主灌的污染
ok(SourceVariables.form(for: pollute) == .credential, "（前提）宿主灌的 map 不改变形态（证据只认站方写的）")
// ⭐ 回传：值**没变** ⇒ 落盘时必须按「宿主写的」处理（origin: .app）⇒ 证据不许被刷新
SourceVariables.setVariable(pollution, for: pollute, origin: .app)
ok(SourceVariables.form(for: pollute) == .credential,
   "⭐⭐⭐ 回传（值没变）不许把「凭据形态」刷成「map 形态」（自证 ⇒ 永远修不好）")
// ⭐ 站方**真改过** ⇒ 那才是证据
SourceVariables.setVariable(token, for: pollute, origin: .station)
ok(SourceVariables.form(for: pollute) == .credential, "站方改过（写了 token）⇒ 凭据形态 ⇒ 证据成立")

print("\n=== ③ 证据的键带版本：v1 那份「自证的证据」直接作废 ===")
let legacy = "\(tag)#legacy"
SourceVariables.clear(for: legacy)
SourceVariables.setDefaultVars([:], for: legacy)     // 凭据形态
// ⚠️ 模拟旧版本（build267）留下的**自证证据**：v1 键 = true
UserDefaults.standard.set(true, forKey: "sourcevariable.stationmap." + legacy)
ok(SourceVariables.form(for: legacy) == .credential,
   "⭐⭐⭐ v1 的「自证证据」被无视（换键名 ⇒ 旧的直接作废）")

print("\n=== ④ 迁移：污染要清掉，但**必须挂在每个 op 都走的链上**===")
let mig = "\(tag)#migrate"
SourceVariables.clear(for: mig)
SourceVariables.setDefaultVars([:], for: mig)                    // 凭据形态（UAA）
SourceVariables.setVariable(pollution, for: mig, origin: .app)   // 真机上躺着的旧污染
ok(SourceVariables.isMapStyleVariable(SourceVariables.variable(for: mig)), "（前提）站方变量里躺着一份 map")
// ⭐ 关键：**不进选线那条链**（UAA 压根没有线路 ⇒ 选线永远走不到）
let seeded = SourceVariables.stationVariableToSeed(for: mig)
ok(seeded.isEmpty, "⭐⭐⭐ 灌站方变量这一步就把污染清掉了（不靠选线）")
ok(SourceVariables.variable(for: mig).isEmpty, "落盘的那一格也清空了")
ok(SourceVariables.vars(for: mig).isEmpty, "（顺带确认）书源变量没被动")

print("\n=== ⑤ 迁移不许误伤：map 形态的源、形态未知的源 ⇒ 一个字都不能动 ===")
let keepMap = "\(tag)#keepmap"
SourceVariables.clear(for: keepMap)
SourceVariables.setDefaultVars(["tab": "小说"], for: keepMap)   // map 形态（大灰狼）
SourceVariables.setVariable(pollution, for: keepMap, origin: .app)
ok(SourceVariables.stationVariableToSeed(for: keepMap) == pollution,
   "⭐ map 形态的源 ⇒ 迁移**不许**清（大灰狼的合法 map）")
let keepUnknown = "\(tag)#keepunknown"
SourceVariables.clear(for: keepUnknown)                        // 默认表**没取过**⇒ 不知道
SourceVariables.setVariable(pollution, for: keepUnknown, origin: .app)
ok(SourceVariables.stationVariableToSeed(for: keepUnknown) == pollution,
   "⭐⭐⭐ 形态还「不知道」⇒ **不许**清（大灰狼第一次进来时会把它的 map 清掉）")

print("\n=== ⑥ 凭据形态 ⇒ 宿主不许往这一格塞 map ===")
let host = "\(tag)#host"
SourceVariables.clear(for: host)
SourceVariables.setDefaultVars([:], for: host)      // 凭据形态
SourceVariables.setHostMap(pollution, for: host)
ok(SourceVariables.variable(for: host).isEmpty, "⭐⭐⭐ 宿主写 map ⇒ 凭据形态的源**没被**塞进去")
ok(SourceVariables.vars(for: host).contains("androidId"), "书源变量照写（那是宿主自己的变量表）")
// map 形态的源 ⇒ 照旧写进去
SourceVariables.setHostMap(pollution, for: keepMap)
ok(SourceVariables.variable(for: keepMap) == pollution, "map 形态的源 ⇒ 宿主写 map 照旧生效（不能回归）")

print("\n=== ⑦ 凭据形态 + 站方写了 token ⇒ token 不许被 map 覆盖 ===")
SourceVariables.setVariable(token, for: host, origin: .station)
SourceVariables.setLineVars(pollution, for: host, isMapStyle: true)
ok(SourceVariables.variable(for: host) == token,
   "⭐ 站方变量是 token ⇒ 即使 isMapStyle=true 也不许被 map 覆盖")

// 清理（别把门禁数据留在盘上）
for u in [uaa, dhl, fresh, pollute, legacy, mig, keepMap, keepUnknown, host] {
    SourceVariables.clear(for: u)
}
ok(SourceVariables.variable(for: mig).isEmpty, "clear() 把站方变量也清了")
ok(!SourceVariables.defaultTableFetched(mig), "clear() 把「默认表取过」的标记也清了")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
