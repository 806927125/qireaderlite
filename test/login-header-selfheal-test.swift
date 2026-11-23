import Foundation

// ⭐⭐⭐⭐⭐ 门禁：**`loginHeader` 槽的自愈**（2026-11-24 真机「Token 格式错误」真凶）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **真机链路**（书山聚合 v6 发现页 toast「Token 格式错误」）⭐⭐⭐：
//   ① 站方把 **token 本身** 存进 `loginHeader`（`source.putLoginHeader(token)`）⭐⭐⭐
//   ② 宿主 UI 的「🍅番茄 sessionid」兜底**也**写**同一个槽**（`"Cookie: sessionid=xxx"`）⭐⭐⭐
//   ③ ⇒ **番茄那次写把 token 冲掉** ⇒ ⇒ 站方把整串当 token 发出去 ⭐⭐⭐
//   ④ ⇒ 站方解不出 base64 ⇒ ⇒ 回「**Token 格式错误**」⭐⭐⭐⭐⭐
//
// ⭐⭐⭐ **本门禁验的是「自愈」**：用户的设备上**已经被污染了**（槽里是 `"Cookie: …"`）⭐⭐⭐
//   ⇒ 必须**不用重装源、不用重登**就能自己恢复 ⇒ ⇒ 每个 op 都要清一次 ⭐⭐⭐
//   ⇒ 而**站方自己的 token（裸 base64）绝不能被清掉** ⭐⭐⭐

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✓ \(msg)") }
    else { fail += 1; print("  ✗ \(msg)") }
}

let url = "https://probe.example/source"

// ── ① 宿主旧格式 ⇒ 必须被清掉 ───────────────────────────────────
SourceVariables.setLoginHeader("Cookie: sessionid=746ae55b0ff1d7daf54c9fc1c860a62d", for: url)
ok(SourceVariables.loginHeader(for: url).hasPrefix("Cookie: "), "先放一个宿主旧格式的值")
ok(SourceVariables.isLegacyCookieLoginHeader(SourceVariables.loginHeader(for: url)), "判据说它是旧格式")
ok(SourceVariables.clearLegacyCookieLoginHeader(for: url), "⭐ 自愈：报告「清掉了」")
ok(SourceVariables.loginHeader(for: url).isEmpty, "⭐ 自愈：槽里空了（站方下次拿到的就是空）")

// ── ② ⭐⭐⭐ 站方自己的 token **绝不能**被误清 ────────────────────
let realToken = "QUJDREVGR0hJSktM"
SourceVariables.setLoginHeader(realToken, for: url)
ok(!SourceVariables.clearLegacyCookieLoginHeader(for: url), "⭐ 站方 token 不该被当成旧格式")
ok(SourceVariables.loginHeader(for: url) == realToken, "⭐ 站方 token 原样还在")

// ── ③ 别的形态也不能误判（JSON 形态的 loginHeader 是合法用法）────
let jsonHeader = "{\"Authorization\":\"Bearer abc\"}"
SourceVariables.setLoginHeader(jsonHeader, for: url)
ok(!SourceVariables.clearLegacyCookieLoginHeader(for: url), "⭐ JSON 形态的 loginHeader 不该被清")
ok(SourceVariables.loginHeader(for: url) == jsonHeader, "⭐ JSON 形态原样还在")

// ── ④ 空值不报错 ────────────────────────────────────────────────
SourceVariables.setLoginHeader("", for: url)
ok(!SourceVariables.clearLegacyCookieLoginHeader(for: url), "空值不该报「清掉了」")
ok(SourceVariables.loginHeader(for: url).isEmpty, "空值就是空")

// ── ⑤ ⭐ 清理后，源 URL 为空时也不能崩 ──────────────────────────
ok(!SourceVariables.clearLegacyCookieLoginHeader(for: ""), "空 sourceUrl 不崩、也不报告清理")

print(pass > 0 && fail == 0 ? "ALL PASS" : "HAS FAILURE")
exit(fail == 0 ? 0 : 1)
