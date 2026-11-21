import Foundation

// ⭐⭐⭐⭐⭐ **筛选变量的「写入 ⇒ 站方读回」真跑验证**（2026-11-21 真机「筛选键没用」/「要通用」）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么必须真跑**：
//   这一轮我连修几次都没生效（第一次只补 `infoMap`；第二次硬编码了 NovelHub 的 `src` ⇒ **大灰狼又坏了**）⭐⭐⭐
//   ⇒ 教训：**静态断言只能证明「我写了」，不能证明「对方读的是这一格」** ⇒ 必须真跑 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **两种源形态都要验**（用户原话：「筛选键我要通用啊，大灰狼不行」）⭐⭐⭐
//   · 🍒NovelHub：action 含 `c['src']=…infoMap['平台']…` ⇒ 键名 = **src** ⭐⭐⭐
//   · 🍅大灰狼：action = `show(infoMap['平台'],'find_source')` ⇒ 键名 = **find_source**（第二个引号参数）⭐⭐⭐
//   ⇒ **同一套代码**必须对两种都生效 ⇒ 这就是「通用」的判定 ⭐⭐⭐
//
// ⭐⭐⭐ **站方的真实读法**（从真 NovelHub 源 jsLib 抄的原文）：
//   var NH_D = {"src":"全部","gender":"全部","status":"不限","sort":"最热","line":"自动"};
//   var _raw = String(source.getVariable()||"").trim();
//   if (_raw !== "") { var _o = JSON.parse(_raw); if (_o && typeof _o==="object") NH_D = _o; }
//   ⇒ 站方读【站方变量整串】里的 **src** ⭐⭐⭐
//
// ⭐⭐⭐ **本文件与 App 同源**（直接编 `QiReaderLite/Core/SourceVariables.swift`）⭐⭐⭐

let SRC = "https://probe.invalid/x"

func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

/// ⭐⭐⭐ **模拟站方 exploreUrl 的读法**（真源 jsLib 原文）⭐⭐⭐
func stationReadSrc() -> String {
    let raw = SourceVariables.variable(for: SRC)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "全部" }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "全部" }
    return (obj["src"] as? String) ?? "全部"
}

/// ⭐⭐⭐ 模拟站方读某个键（通用）
func stationRead(_ key: String) -> String { stationRead(SRC, key) }

/// ⭐⭐⭐ 模拟站方读某个键（指定源）
func stationRead(_ sourceUrl: String, _ key: String) -> String {
    let raw = SourceVariables.variable(for: sourceUrl)
    guard let d = raw.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
    return (o[key] as? String) ?? ""
}

// ⭐⭐⭐⭐⭐ **场景 1：🍒NovelHub 形态**（action 里 `c['src']=…infoMap['平台']…`）⭐⭐⭐
do {
    // 站方变量里已有自己的状态
    SourceVariables.setVariable(#"{"src":"番茄","gender":"男频","status":"连载中","sort":"最热","line":"自动"}"#,
                                for: SRC, origin: .station)

    let action = "(function(){var c={};try{c=JSON.parse(source.getVariable()||'{}');}catch(e){}"
        + "var v=infoMap['平台'];if(v!==null&&v!==undefined){c['src']=v;c['find_source']=String(v);c['find_tab']='小说';"
        + "try{source.setVariable(JSON.stringify(c));}catch(e1){}}})()"

    // 解析出「站方要写的键」（核心：通用性）
    let keys = ExploreKindsNormalizer.filterAssignedKeys(in: action)
    print("SCENARIO1 keys=\(keys)")
    if keys.isEmpty { fail("NovelHub 形态没解析出键名（应含 src）") }
    if !keys.contains("src") { fail("NovelHub 形态应解析出 src，实得 \(keys)") }
    // ⭐⭐⭐ **不该把固定值的那一项（find_tab）算进来** ⭐⭐⭐
    if keys.contains("find_tab") { fail("不该把固定值的 find_tab 算成「用户改的键」") }

    // 模拟 UI 的兜底写入
    var obj: [String: Any] = ["find_source": "QQ阅读", "find_tab": "小说"]
    obj[keys.first ?? "src"] = "QQ阅读"
    let data = try! JSONSerialization.data(withJSONObject: obj)
    SourceVariables.setHostMap(String(data: data, encoding: .utf8)!, for: SRC,
                               stationKeys: keys, stationValue: "QQ阅读")

    print("RAW1=\(SourceVariables.variable(for: SRC))")
    if stationReadSrc() != "QQ阅读" { fail("NovelHub：站方读到的 src = \(stationReadSrc())，期望 QQ阅读") }
    for (k, want) in [("gender", "男频"), ("status", "连载中"), ("sort", "最热"), ("line", "自动")] {
        if stationRead(k) != want { fail("NovelHub：站方变量 \(k) = \(stationRead(k))，期望 \(want)（被覆盖了）") }
    }
    print("SCENARIO1 OK")
}

// ⭐⭐⭐⭐⭐ **场景 2：🍅大灰狼形态**（action = `show(infoMap['平台'],'find_source')`）⭐⭐⭐
do {
    // ⭐⭐⭐ 换源 ⇒ 换 URL（避免两场景共用一个槽）
    let SRC2 = "https://probe.invalid/dlh"
    SourceVariables.setVariable(#"{"find_source":"番茄","gender":"男频"}"#, for: SRC2, origin: .station)

    let action = "show(infoMap['平台'],'find_source')"
    let keys = ExploreKindsNormalizer.filterAssignedKeys(in: action)
    print("SCENARIO2 keys=\(keys)")
    // ⭐⭐⭐ 大灰狼的 action 里没有 `c['k']=` ⇒ 解析为空 ⇒ **退回 paramKey** ⭐⭐⭐
    if !keys.isEmpty { fail("大灰狼形态不该解析出 c['k']（实测 \(keys)）") }
    let paramKey = "find_source"     // ← paramKey 的来源（secondQuotedArg）
    let finalKeys = keys.isEmpty ? [paramKey] : keys

    var obj: [String: Any] = ["find_source": "QQ阅读"]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    SourceVariables.setHostMap(String(data: data, encoding: .utf8)!, for: SRC2,
                               stationKeys: finalKeys, stationValue: "QQ阅读")

    print("RAW2=\(SourceVariables.variable(for: SRC2))")
    if stationRead(SRC2, "find_source") != "QQ阅读" { fail("大灰狼：站方读到的 find_source = \(stationRead(SRC2, "find_source"))，期望 QQ阅读") }
    if stationRead(SRC2, "gender") != "男频" { fail("大灰狼：站方变量 gender 被覆盖了（= \(stationRead(SRC2, "gender"))）") }
    print("SCENARIO2 OK")
}

print("OK")
