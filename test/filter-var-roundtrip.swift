import Foundation

// ⭐⭐⭐⭐⭐ **筛选变量的「写入 ⇒ 站方读回」真跑验证**（2026-11-21 真机「筛选键没用」二次实证）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么必须真跑**：
//   这一轮我连修两次都没生效（第一次只补了 `infoMap`，但 UI 走的是**另一条路**）⭐⭐⭐
//   ⇒ 教训：**光断言「代码里写了某个键」不够** ⇒ 必须把整条链真跑一遍 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **站方的真实读法**（从真 NovelHub 源的 jsLib 里抄的原文）：
//   var NH_D = {"src":"全部","gender":"全部","status":"不限","sort":"最热","line":"自动"};
//   var _raw = String(source.getVariable() || "").trim();
//   if (_raw !== "") { var _o = JSON.parse(_raw); if (_o && typeof _o === "object") { NH_D = _o; } }
//   ⇒ 站方读的是【**站方变量整串**】里的 **src** ⭐⭐⭐
//   ⇒ 而轻阅抠出来的 paramKey 是 **find_source** ⇒ **键名对不上** ⇒ 站方根本不读 ⭐⭐⭐
//
// ⭐⭐⭐ **站方的约定**（真源 jsLib 原文）：
//   c['src']=v; c['find_source']=String(v); c['find_tab']='小说';
//   ⇒ **src 与 find_source 是同一个平台值的两个键名** ⭐⭐⭐
//
// ⭐⭐⭐ **本文件与 App 同源**（直接编 `QiReaderLite/Core/SourceVariables.swift`）⭐⭐⭐
//   ⇒ 门禁变红 ⇒ App 一定有问题 ⇒ 永不漂 ⭐⭐⭐

let SRC = "https://probe.invalid/x"

/// ⭐⭐⭐ **模拟站方 exploreUrl 的读法**（真源 jsLib 原文）⭐⭐⭐
func stationReadSrc() -> String {
    let raw = SourceVariables.variable(for: SRC)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "全部" }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "全部" }
    return (obj["src"] as? String) ?? "全部"
}

func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

// ⭐⭐⭐ **场景**：站方变量里已有自己的状态（src/gender/status/…）⭐⭐⭐
//   ⇒ 轻阅写一次平台 ⇒ **站方的其它状态必须原样保留** ⭐⭐⭐
let seed = #"{"src":"番茄","gender":"男频","status":"连载中","sort":"最热","line":"自动"}"#
SourceVariables.setVariable(seed, for: SRC, origin: .station)

// ⭐⭐⭐ **模拟 UI 的 ① 路径**：obj = 书源变量 map（含默认表）+ 用户改的 paramKey ⭐⭐⭐
//   ⇒ UI 写的是 obj["find_source"] = "QQ阅读" ⇒ 整份 JSON 交给 setHostMap ⭐⭐⭐
let obj: [String: Any] = ["find_source": "QQ阅读", "find_tab": "小说"]
let data = try! JSONSerialization.data(withJSONObject: obj)
let merged = String(data: data, encoding: .utf8)!
SourceVariables.setHostMap(merged, for: SRC)

// ① 站方读回的平台
let src = stationReadSrc()
print("SRC=\(src)")
// ② 站方的其它状态有没有被冲掉
let raw = SourceVariables.variable(for: SRC)
print("RAW=\(raw)")

// ⭐⭐⭐ **断言 1**：站方读到的平台必须变成新值 ⭐⭐⭐
if src != "QQ阅读" {
    fail("站方读到的 src = \(src)，期望 QQ阅读")
}

// ⭐⭐⭐ **断言 2**：站方其它状态必须保留（整份覆盖会把它们冲掉）⭐⭐⭐
for (k, want) in [("gender", "男频"), ("status", "连载中"), ("sort", "最热"), ("line", "自动")] {
    guard let d = raw.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let got = o[k] as? String else {
        fail("站方变量丢了 \(k)（raw=\(raw)）")
    }
    if got != want {
        fail("站方变量 \(k) = \(got)，期望 \(want)（被整份覆盖了）")
    }
}

// ⭐⭐⭐ **断言 3**：轻阅自己的书源变量槽也要有（那是另一套）⭐⭐⭐
if SourceVariables.varsMap(for: SRC)["find_source"] != "QQ阅读" {
    fail("书源变量槽没有 find_source")
}

// ⭐⭐⭐ **断言 4**：再切一次别的平台 ⇒ 站方读到新的（重复切换也要对）⭐⭐⭐
let obj2: [String: Any] = ["find_source": "番茄", "find_tab": "小说"]
let data2 = try! JSONSerialization.data(withJSONObject: obj2)
SourceVariables.setHostMap(String(data: data2, encoding: .utf8)!, for: SRC)
if stationReadSrc() != "番茄" {
    fail("第二次切换没生效（src = \(stationReadSrc())）")
}

print("OK")
