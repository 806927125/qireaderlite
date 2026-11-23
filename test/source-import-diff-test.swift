import Foundation

// =============================================================================
// 书源导入「新增 / 更新 / 未变」判定的**真跑**测试（2026-11-23）
//
// ⚠️⚠️ **为什么要有这个**（用户原话）：
//   「导入书源时候**同个要看有没有变化**，**有变化就是要更新书源**，
//     现在是**有书源的情况下导不进去**」⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **两个真因**：
//   ① **提示误导**：旧版 `importSources` 只返回**「新增条数」**
//      ⇒ 已有同 URL 书源时返回 **0** ⇒ Toast「导入 0 个书源」
//      ⇒ **但源其实已被替换** ⇒ **用户以为没导进去** ⭐⭐⭐
//   ② **判不出变化**：`parse` 里就 `archiveRaw` 覆盖了存档
//      ⇒ ⇒ 「上次导入的内容」被本次覆盖 ⇒ ⇒ **必须「先比后存」** ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **本测试直接编 `Core/SourceImportDiff.swift` 真跑** ⭐⭐⭐
//   ⇒ 纯 Foundation ⇒ **Linux 沙盒能编能跑** ⇒ **当天就能验**，不用等 CI ⭐⭐⭐
//   ⇒ 逻辑若放在 `Store.swift`（import SwiftUI）⇒ **沙盒编不到 ⇒ 等于没有门禁** ⭐⭐⭐
// =============================================================================

import Foundation

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond { pass += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { fail += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

// ---------- 造源 ----------
func mkSource(url: String, name: String, enabled: Bool = true, jsLib: String = "lib-v1") -> BookSource {
    // ⚠️ 轻阅自己的 `BookSource` 只有 `init()`（没有带参 init）⭐⭐⭐
    var s = BookSource()
    s.bookSourceUrl = url
    s.bookSourceName = name
    s.enabled = enabled
    s.jsLib = jsLib
    return s
}
func raw(_ url: String, _ name: String, _ jsLib: String) -> [String: Any] {
    ["bookSourceUrl": url, "bookSourceName": name, "jsLib": jsLib, "enabled": true]
}

print("=== 书源导入判定 · 真跑测试 ===")

// ---------- ① 新增 ----------
do {
    let existing = [mkSource(url: "u-existing", name: "旧源")]
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u-new", name: "新源"), raw: raw("u-new", "新源", "lib-v1"))],
        oldRaw: { _ in nil }
    )
    ok(plan.stats.added == 1, "① 新 URL ⇒ 判「新增」", "added=\(plan.stats.added)")
    ok(plan.stats.updated == 0 && plan.stats.unchanged == 0, "① 新增时不误判", plan.stats.summary)
}

// ---------- ② 有变化 ⇒ 更新 ----------
do {
    let existing = [mkSource(url: "u1", name: "源A", jsLib: "lib-v1")]
    // ⚠️ 上次存档 = lib-v1；这次导入 = lib-v2 ⇒ **有变化** ⇒ 该更新
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", jsLib: "lib-v2"), raw: raw("u1", "源A", "lib-v2"))],
        oldRaw: { $0 == "u1" ? raw("u1", "源A", "lib-v1") : nil }
    )
    ok(plan.stats.updated == 1, "② 内容有变化 ⇒ 判「更新」", "updated=\(plan.stats.updated)")
    ok(plan.stats.unchanged == 0, "② 不误判成未变")
    ok(plan.updated.first?.jsLib == "lib-v2", "② 更新后内容是新的", plan.updated.first?.jsLib ?? "nil")
}

// ---------- ③ 无变化 ⇒ 未变（且**不动**它）----------
do {
    let existing = [mkSource(url: "u1", name: "源A", jsLib: "lib-v1")]
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", jsLib: "lib-v1"), raw: raw("u1", "源A", "lib-v1"))],
        oldRaw: { $0 == "u1" ? raw("u1", "源A", "lib-v1") : nil }
    )
    ok(plan.stats.unchanged == 1, "③ 内容一样 ⇒ 判「未变」", "unchanged=\(plan.stats.unchanged)")
    ok(plan.updated.isEmpty, "③ 未变 ⇒ 不进「更新」（不覆盖）")
}

// ---------- ③b ⭐⭐⭐⭐⭐ **「未变」时【用户的改动】必须保住**（唯一能区分覆盖与否的信号） ----------
// ⚠️⚠️⚠️ **这一条是「未变也覆盖」那个变异唯一能被抓到的地方** ⭐⭐⭐
//   ⇒ 「未变」的定义就是**内容一样** ⇒ ⇒ 新旧数据**必然相同** ⇒
//   ⇒ ⇒ 从 jsLib/name 上**根本测不出**「覆盖了没有」⇒ ⇒ **假绿** ⭐⭐⭐
//   ⇒ ⇒ 唯一能区分的是**用户自己改过的字段**（这里用 `enabled`）⭐⭐⭐
//   ⇒ 用户手动禁用了源 ⇒ 导入一份**内容完全相同**的书源 ⇒ ⇒ **不该把用户的「停用」改回去** ⭐⭐⭐
do {
    let existing = [mkSource(url: "u1", name: "源A", enabled: false, jsLib: "lib-v1")]
    let sameRaw = raw("u1", "源A", "lib-v1")          // ⚠️ 站方 JSON 里 enabled=true
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", enabled: true, jsLib: "lib-v1"), raw: sameRaw)],
        oldRaw: { _ in sameRaw }
    )
    ok(plan.stats.unchanged == 1, "③b 内容一样 ⇒ 判「未变」", "unchanged=\(plan.stats.unchanged)")
    ok(plan.unchanged.first?.enabled == false,
       "③b ⭐ 未变 ⇒ 【用户的停用】保住（没被覆盖）",
       "enabled=\(String(plan.unchanged.first?.enabled ?? true))")
}

// ---------- ④ ⭐⭐⭐ **「没改 lastUpdateTime 但内容变了」⇒ 仍要更新** ----------
// ⚠️⚠️ 这是用户最真实的场景：站方改了 jsLib/规则，但**没改时间戳**
//   ⇒ ⇒ 只比 `lastUpdateTime` 会**漏更新** ⇒ ⇒ 「有变化就要更新」落空 ⭐⭐⭐
do {
    let existing = [mkSource(url: "u1", name: "源A", jsLib: "lib-v1")]
    var old = raw("u1", "源A", "lib-v1")
    old["lastUpdateTime"] = 1700000000
    var newRaw = raw("u1", "源A", "lib-v2")
    newRaw["lastUpdateTime"] = 1700000000        // ⚠️ **时间戳一样**！
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", jsLib: "lib-v2"), raw: newRaw)],
        oldRaw: { _ in old }
    )
    ok(plan.stats.updated == 1, "④ 时间戳没变但内容变了 ⇒ 仍判「更新」", "updated=\(plan.stats.updated)")
}

// ---------- ⑤ 没有旧存档 ⇒ 判「有变化」（保守更新）----------
do {
    let existing = [mkSource(url: "u1", name: "源A", jsLib: "lib-v1")]
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", jsLib: "lib-v1"), raw: raw("u1", "源A", "lib-v1"))],
        oldRaw: { _ in nil }                       // ⚠️ 没有存档
    )
    ok(plan.stats.updated == 1, "⑤ 无旧存档 ⇒ 判「更新」（保守）", "updated=\(plan.stats.updated)")
}

// ---------- ⑥ ⭐⭐⭐ **保留用户的「启用/停用」偏好** ----------
do {
    let existing = [mkSource(url: "u1", name: "源A", enabled: false, jsLib: "lib-v1")]
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", enabled: true, jsLib: "lib-v2"), raw: raw("u1", "源A", "lib-v2"))],
        oldRaw: { _ in raw("u1", "源A", "lib-v1") }
    )
    ok(plan.updated.first?.enabled == false, "⑥ 更新内容时保留用户的「停用」状态",
       "enabled=\(plan.updated.first?.enabled ?? true)")
}

// ---------- ⑦ 键序不同 ⇒ 算「没变化」（规范化比较）----------
do {
    var a: [String: Any] = ["bookSourceUrl": "u1", "jsLib": "lib-v1"]
    var b: [String: Any] = ["jsLib": "lib-v1", "bookSourceUrl": "u1"]   // ⚠️ 键序不同
    let plan = SourceImportDiff.plan(
        existing: [mkSource(url: "u1", name: "源A", jsLib: "lib-v1")],
        incoming: [(source: mkSource(url: "u1", name: "源A", jsLib: "lib-v1"), raw: b)],
        oldRaw: { _ in a }
    )
    ok(plan.stats.unchanged == 1, "⑦ 仅键序不同 ⇒ 判「未变」（规范化比较）", "unchanged=\(plan.stats.unchanged)")
}

// ---------- ⑪ ⭐⭐⭐ **只改一个次要字段 ⇒ 也要算「有变化」** ----------
// ⚠️ 场景：站方把书源**改名**了（别的都没动）⇒ ⇒ 也该更新（用户能看到新名字）⭐⭐⭐
//   ⇒ 若比较只看「几个主要字段」⇒ ⇒ 会漏判 ⇒ ⇒ 这条断言就是钉住「**全字段比**」⭐⭐⭐
do {
    let existing = [mkSource(url: "u1", name: "旧名字", jsLib: "lib-v1")]
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "新名字", jsLib: "lib-v1"),
                    raw: ["bookSourceUrl": "u1", "bookSourceName": "新名字", "jsLib": "lib-v1"])],
        oldRaw: { _ in ["bookSourceUrl": "u1", "bookSourceName": "旧名字", "jsLib": "lib-v1"] }
    )
    ok(plan.stats.updated == 1, "⑪ 只改了书源名 ⇒ 仍判「更新」（全字段比）", "updated=\(plan.stats.updated)")
    ok(plan.updated.first?.bookSourceName == "新名字", "⑪ 更新后是新名字",
       plan.updated.first?.bookSourceName ?? "nil")
}

// ---------- ⑧ 空 URL 的源要跳过 ----------
do {
    let plan = SourceImportDiff.plan(
        existing: [],
        incoming: [(source: mkSource(url: "", name: "空"), raw: nil)],
        oldRaw: { _ in nil }
    )
    ok(plan.stats.added == 0 && plan.stats.updated == 0 && plan.stats.unchanged == 0,
       "⑧ 空 bookSourceUrl ⇒ 跳过")
}

// ---------- ⑨ 统计摘要文案 ----------
do {
    let st = SourceImportDiff.Stats(added: 1, updated: 2, unchanged: 3)
    ok(st.summary == "新增 1，更新 2，未变 3", "⑨ 统计摘要说得清三件事", st.summary)
    let empty = SourceImportDiff.Stats()
    ok(empty.summary == "没有可导入的书源", "⑨ 空统计有兜底文案", empty.summary)
}

// ---------- ⑩ ⭐⭐⭐ **回归：旧 bug「有书源时导不进去」** ----------
//   ⇒ 旧版返回**新增条数** ⇒ 已有源更新时返回 **0** ⇒ 用户以为没导进去 ⭐⭐⭐
//   ⇒ 现在必须返回**含「更新」的非零统计** ⇒ ⇒ 提示不再是「0 个」⭐⭐⭐
do {
    let existing = [mkSource(url: "u1", name: "源A", jsLib: "lib-v1")]
    let plan = SourceImportDiff.plan(
        existing: existing,
        incoming: [(source: mkSource(url: "u1", name: "源A", jsLib: "lib-v2"), raw: raw("u1", "源A", "lib-v2"))],
        oldRaw: { _ in raw("u1", "源A", "lib-v1") }
    )
    ok(plan.stats.added == 0, "⑩ 已有源更新时「新增」确实是 0（这是事实）")
    ok(plan.stats.updated == 1, "⑩ ⭐ 但「更新」是 1 ⇒ 提示不再是「导入 0 个书源」", plan.stats.summary)
}

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
