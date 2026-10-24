import Foundation

// ⭐⭐⭐ 门禁：**源字典缓存**（2026-10-24 真机「app 死机」的真凶）
//
// ⚠️⚠️ 崩溃日志（`0x8BADF00D` watchdog）逐帧对上：
//   · 后台线程：LegadoEngineBackend.invoke → seedVars → Foundation _NSJSONReader parseData
//     （**持有 malloc 锁**）
//   · 主线程：_xzm_malloc_tc（**拿不到 malloc 锁**）⇒ UI 全冻 ⇒ iOS 杀进程
// ⇒ 根因：**每个 op 都把整个源（🍅大灰狼 158KB）编码 + Foundation 解析一遍**
// ⇒ 只有大灰狼出事（别的源小）⭐

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✓ \(msg)") }
    else { fail += 1; print("  ✗ \(msg)") }
}

// ── 造一个「大灰狼级」的源：jsLib 32KB + 大段规则 ─────────────
func makeBigSource(url: String, size: Int) -> BookSource {
    var s = BookSource()
    s.bookSourceUrl = url
    s.bookSourceName = "大源"
    s.jsLib = String(repeating: "var x = 1; // 站方 jsLib\n", count: max(1, size / 25))
    s.loginUi = #"[{"name":"邮箱","type":"text"}]"#
    s.ruleExplore.bookList = .text(String(repeating: "$.data[*]##正则##$1##\n", count: 400))
    s.ruleToc.chapterList = .text(String(repeating: "<js>let a = 1;</js>$.data\n", count: 200))
    return s
}

print("=== ① 同一个源只编码一次 ===")
let big = makeBigSource(url: "https://big.example", size: 32_000)
let enc0 = SourceDictCache.encodes

let t0 = Date()
let d1 = SourceDictCache.dict(for: big)
let first = Date().timeIntervalSince(t0)
let enc1 = SourceDictCache.encodes
ok(enc1 == enc0 + 1, "第一次：编码+解析了 1 次（实际 \(enc1 - enc0)）")

let t1 = Date()
let d2 = SourceDictCache.dict(for: big)
let second = Date().timeIntervalSince(t1)
let enc2 = SourceDictCache.encodes
ok(enc2 == enc1, "第二次：**没有再编码**（encodes 不变）⭐")
ok(second < max(0.002, first * 0.2),
   "第二次几乎是免费的（首次 \(String(format: "%.1f", first * 1000))ms → 命中 \(String(format: "%.2f", second * 1000))ms）")
ok(d1["bookSourceUrl"] as? String == "https://big.example", "字典内容对")
ok(d1["jsLib"] as? String == big.jsLib, "jsLib 没丢")
ok(d2.count == d1.count, "两次拿到的是同一份内容")

print("\n=== ② 缓存命中时返回的是【值语义】副本 ⇒ 调用方改它不会污染缓存 ===")
var mutated = SourceDictCache.dict(for: big)
mutated["__variables"] = "改了"
let after = SourceDictCache.dict(for: big)
ok(after["__variables"] == nil, "缓存没被调用方改脏 ⭐")

print("\n=== ③ 源变了 ⇒ invalidate ⇒ 重新算 ===")
SourceDictCache.invalidate()
let encBefore = SourceDictCache.encodes
_ = SourceDictCache.dict(for: big)
ok(SourceDictCache.encodes == encBefore + 1, "invalidate 之后重新编码了 ⭐")

print("\n=== ④ 不同的源各算各的 ===")
let small = makeBigSource(url: "https://small.example", size: 100)
let encBefore2 = SourceDictCache.encodes
let _ = SourceDictCache.dict(for: small)
ok(SourceDictCache.encodes == encBefore2 + 1, "另一个源单独算一次")
ok(SourceDictCache.dict(for: small)["bookSourceUrl"] as? String == "https://small.example", "小源的字典对")

print("\n=== ⑤ ⭐ 真实量级：100 个 op（旧做法 vs 缓存后）===")
let real = makeBigSource(url: "https://real.example", size: 32_000)
// 旧做法：每个 op 编码 + 解析
var oldCost: Double = 0
for _ in 0..<20 {
    let t = Date()
    let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
    if let data = try? enc.encode(real),
       let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        oldCost += Date().timeIntervalSince(t)
    }
}
// 新做法：缓存
SourceDictCache.invalidate()
var newCost: Double = 0
for _ in 0..<20 {
    let t = Date()
    _ = SourceDictCache.dict(for: real)
    newCost += Date().timeIntervalSince(t)
}
print(String(format: "  旧做法（每 op 编码+解析）20 次 = %.0f ms", oldCost * 1000))
print(String(format: "  新做法（缓存）        20 次 = %.0f ms", newCost * 1000))
ok(newCost < oldCost * 0.5,
   String(format: "缓存后至少快 2 倍（实测 %.1f×）", oldCost / max(newCost, 0.000001)))
ok(oldCost > 0.01, "旧做法的开销确实是真实存在的（\(String(format: "%.0f", oldCost * 1000))ms / 20 次）")

print("\n✅ 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
