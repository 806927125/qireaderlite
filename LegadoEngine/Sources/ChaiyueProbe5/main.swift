import Foundation
import ChaiyueModels
import ChaiyueEngine
import LegadoEngine

// =============================================================================
// 探针 5：**发现页筛选 action 真跑**（2026-11-24 真机「切平台无效」实证）⭐⭐⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **为什么要有这个探针** ⭐⭐⭐⭐⭐
//   真机症状（书山聚合 v6）：**筛选栏里选「QQ 阅读」⇒ 分类和发现还在番茄** ⭐⭐⭐
//   ⇒ 读代码 + 实测才发现的根因：⭐⭐⭐⭐⭐
//     · 站方的**筛选 action 是一段字符串**：
//         `action: "(function(){ … setConfig.call(this,{source:v}); java.refreshExplore(); })()"`
//     · 「顶层符号隔离化」（改名）**只按 AST 的标识符**改名 ⭐⭐⭐
//       ⇒ **AST 看不见字符串里的标识符** ⇒ **`setConfig` 没被改名** ⭐⭐⭐
//     · 而 jsLib 里它已经叫 `ssh_setConfig` ⇒ 引擎里 `setConfig` **未定义** ⭐⭐⭐
//     ⇒ ⇒ **ReferenceError** ⇒ ⇒ 筛选 action **静默失败** ⭐⭐⭐⭐⭐
//     ⇒ 宿主见 action 失败 ⇒ 走「兜底自己写变量」⇒ 书山的 paramKey 是空的 ⇒ **什么都不写** ⭐⭐⭐
//     ⇒ ⇒ 平台没切 ⇒ ⇒ 分类还在番茄 ⇒ ⇒ **界面上零报错** ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **大灰狼为什么能切** ⭐⭐⭐⭐⭐
//   大灰狼的 action 是**自包含**的（自己写变量 + `java.refreshExplore()`）⇒ 不依赖 jsLib 的符号
//   ⇒ ⇒ 改名不影响它 ⇒ ⇒ 「大灰狼能切、书山不能切」⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **本探针要证明的事**（真引擎 + 真源 + 真站方）⭐⭐⭐⭐⭐
//   ① 「源站」筛选项**存在**，且**带 action** ⭐⭐⭐
//   ② ⭐⭐⭐ **那个 action 真能跑**（不抛错）⭐⭐⭐
//   ③ ⭐⭐⭐⭐⭐ **跑完站方变量真的变了**（`source.getVariable()` 里含新平台名）⭐⭐⭐⭐⭐
//   ④ ⭐⭐⭐ **重跑 exploreUrl ⇒ 分类跟着变**（分类项里出现新平台）⭐⭐⭐
//   ⇒ ⇒ 任何「action 里引用了改名后的符号却漏改」的回归 ⇒ **本探针必红** ⭐⭐⭐
// =============================================================================

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/ChaiyueProbe5
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // LegadoEngine
    .deletingLastPathComponent()   // 仓库根

let fixturePath = repoRoot.appendingPathComponent("test/fixtures/shushan-adapted.json").path

print("=== 探针 5 · 发现页筛选 action 真跑（真引擎 + 真源 + 真站方）===")

var failures = 0
func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✅ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failures += 1; print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}

// ─────────────────────────────────────────────────────────────────────────────
// 宿主同款 store 接线（内存版，与 ChaiyueRuntime 的槽语义一致）⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
final class FilterHostSlots {
    var stationVariable: [String: String] = [:]
    var sourceVars: [String: [String: String]] = [:]
    var loginInfo: [String: String] = [:]
    var loginHeader: [String: String] = [:]
    var deviceID: String?
    var plain: [String: String] = [:]
}

let slots = FilterHostSlots()
let store = ChaiyueKeyValueStore(
    readSlot: { slot in
        switch slot {
        case .stationVariable(let k): let v = slots.stationVariable[k] ?? ""; return v.isEmpty ? nil : v
        case .sourceVar(let k, let n): let v = slots.sourceVars[k]?[n] ?? ""; return v.isEmpty ? nil : v
        case .loginInfo(let k): let v = slots.loginInfo[k] ?? ""; return v.isEmpty ? nil : v
        case .loginHeader(let k): let v = slots.loginHeader[k] ?? ""; return v.isEmpty ? nil : v
        case .deviceID: return slots.deviceID
        case .plainCache(let k), .opaque(let k): return slots.plain[k]
        }
    },
    writeSlot: { slot, value in
        switch slot {
        case .stationVariable(let k): slots.stationVariable[k] = value ?? ""
        case .sourceVar(let k, let n):
            var m = slots.sourceVars[k] ?? [:]
            if let value, !value.isEmpty { m[n] = value } else { m.removeValue(forKey: n) }
            slots.sourceVars[k] = m
        case .loginInfo(let k): slots.loginInfo[k] = value ?? ""
        case .loginHeader(let k): slots.loginHeader[k] = value ?? ""
        case .deviceID: slots.deviceID = value
        case .plainCache(let k), .opaque(let k): slots.plain[k] = value ?? ""
        }
    },
    listAllSourceVars: {
        var out: [(sourceKey: String, name: String)] = []
        for (k, m) in slots.sourceVars { for n in m.keys { out.append((sourceKey: k, name: n)) } }
        return out
    },
    listPlainCacheKeys: { _ in [] },
    loginInfoToChaiyue: { $0 },
    loginInfoFromChaiyue: { $0 }
)

guard let data = FileManager.default.contents(atPath: fixturePath) else {
    print("FAIL: 读不到 fixture：\(fixturePath)"); exit(2)
}
let source: BookSource
do {
    let obj = try JSONSerialization.jsonObject(with: data)
    let dict: [String: Any] = (obj as? [[String: Any]])?.first ?? (obj as? [String: Any]) ?? [:]
    source = try JSONDecoder().decode(BookSource.self, from: try JSONSerialization.data(withJSONObject: dict))
    print("  书源：\(source.bookSourceName)")
} catch {
    print("FAIL: 解码失败：\(error)"); exit(2)
}

let env = SourceEnvironment(store: store, deviceID: "probe-device-0001")
let web = WebBook(source: source, environment: env)

// ── ① 求值 exploreUrl ⇒ 拿筛选项 ─────────────────────────────────────────
print("\n[①] 求值 exploreUrl（拿筛选栏）")
var kinds: [ExploreKind] = []
do {
    kinds = try await web.exploreKinds(refresh: true)
    print("  分类项数 = \(kinds.count)")
} catch {
    expect(false, "exploreUrl 求值", "\(error)")
}
for k in kinds where (k.type ?? "") == "select" {
    print("    · 筛选项「\(k.title)」 可选值=\(k.chars ?? []) action=\((k.action ?? "").prefix(60))…")
}

// ── ② 找「源站」筛选项 ───────────────────────────────────────────────────
print("\n[②] 找「源站」筛选项")
let sourceFilter = kinds.first { $0.title == "源站" && $0.type == "select" }
guard let filter = sourceFilter, let action = filter.action, !action.isEmpty else {
    expect(false, "「源站」筛选项存在且带 action")
    print("\n=== 探针 5 结束：失败 \(failures + 1) 项 ===")
    exit(1)
}
expect(true, "「源站」筛选项存在且带 action", "action 长度=\(action.count)")

// ── ③ 取一个真实平台名（优先带 QQ 的；站方叫「QQ阅读」之类）⭐⭐⭐
print("\n[③] 取站方真实平台列表")
var platformName = ""
if let raw = try? await web.evalJS("JSON.stringify((ssh_getSourceList.call(this)||[]).map(function(s){return s.name;}))"),
   let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] {
    print("  平台数 = \(arr.count)  前几个=\(arr.prefix(6))")
    platformName = arr.first(where: { $0.contains("QQ") }) ?? arr.first(where: { $0 != "☁️聚合搜索" }) ?? ""
}
if platformName.isEmpty {
    // 站方不可达时，退回用筛选项自己的可选值（只要 action 能跑，变量就该变）
    platformName = (filter.chars ?? []).first(where: { $0.contains("QQ") }) ?? (filter.chars ?? []).first ?? ""
}
expect(!platformName.isEmpty, "拿到一个平台名", platformName)

// ── ④ ⭐⭐⭐⭐⭐ **真跑那个 action**（这才是关键）⭐⭐⭐⭐⭐
print("\n[④] 真跑筛选 action（infoMap[\"源站\"] = \(platformName)）")
var actionError: String = ""
do {
    try await web.runExploreAction(action, infoMap: ["源站": platformName])
    print("  action 执行完成（没抛错）")
} catch {
    actionError = String(describing: error)
    print("  ⚠️ action 抛错：\(actionError)")
}
expect(actionError.isEmpty, "⭐⭐⭐ 筛选 action **不抛错**（改名后 jsLib 的符号能调到）", actionError)

// ── ⑤ ⭐⭐⭐⭐⭐ **站方变量真的变了**（这才是「切平台生效」的判据）⭐⭐⭐⭐⭐
print("\n[⑤] 站方变量（source.getVariable()）")
let varRaw = (try? await web.evalJS("String(source.getVariable() || '')")) ?? ""
print("  变量串 = \(varRaw.prefix(220))")
expect(varRaw.contains(platformName),
       "⭐⭐⭐⭐⭐ **站方变量里出现了新平台**（= 平台真的切了）",
       platformName.isEmpty ? "（没拿到平台名，跳过）" : "含「\(platformName)」？ \(varRaw.contains(platformName))")

// ── ⑥ ⭐⭐⭐ 重跑 exploreUrl ⇒ 分类跟着变 ──────────────────────────────────
print("\n[⑥] 重跑 exploreUrl（分类应跟着切）")
do {
    let kinds2 = try await web.exploreKinds(refresh: true)
    print("  分类项数 = \(kinds2.count)")
    for k in kinds2.prefix(10) { print("    · \(k.title)  type=\(k.type ?? "url")") }
    let hasPlatform = kinds2.contains { $0.title.contains(platformName) }
    expect(hasPlatform || kinds2.count != kinds.count,
           "⭐⭐⭐ 分类**跟着平台变了**（含新平台，或分类项数变了）",
           "含「\(platformName)」？ \(hasPlatform)")
} catch {
    expect(false, "重跑 exploreUrl", "\(error)")
}

print("\n=== 探针 5 结束：失败 \(failures) 项 ===")
exit(failures == 0 ? 0 : 1)
