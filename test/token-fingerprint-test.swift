import Foundation

// ⭐⭐⭐⭐⭐ 门禁：**登录头（token）指纹**（2026-11-24 真机「Token 格式错误」实证）⭐⭐⭐⭐⭐
//
// ⚠️ 判据来自**站方服务器的真实判定表**（沙盒直连实测，不是推测）⭐⭐⭐：
//   · token 缺失/空        → 「非法请求，请先登录」
//   · **token 非 base64**  → 「**Token 格式错误**」⭐⭐⭐（**带引号也算**！）
//   · token 长度不对        → 「Token 长度不正确」
//   · 其余                  → 「Token 无效或已失效」
// ⇒ 所以「Token 格式错误」**只可能**是「发出去的 token 不是合法 base64」⭐⭐⭐
//
// ⭐⭐⭐ **这组门禁钉死的就是那个判据本身** ⇒ 改坏了它 ⇒ 门禁必须红 ⭐⭐⭐

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✓ \(msg)") }
    else { fail += 1; print("  ✗ \(msg)") }
}

// ── ① 站方真实形态的 token（12 字节明文 ⇒ 16 字符 base64）────────
let token = "QUJDREVGR0hJSktM"
ok(TokenFingerprint.isBase64(token), "站方形态的 token 是合法 base64")
ok(TokenFingerprint.describe(token).contains("base64=是"), "describe 说它是 base64")
ok(TokenFingerprint.verdict(token).contains("形态正常"), "verdict 说形态正常")

// ── ② ⭐⭐⭐ **带引号** ⇒ 不是 base64 ⇒ 站方必然回「Token 格式错误」────
let quoted = "\"\(token)\""
ok(!TokenFingerprint.isBase64(quoted), "⭐ 带引号的 token 不是 base64（站方会说「Token 格式错误」）")
ok(TokenFingerprint.describe(quoted).contains("带引号"), "describe 要点出「带引号」")
ok(TokenFingerprint.verdict(quoted).contains("Token 格式错误"), "verdict 要点出站方会回「Token 格式错误」")

// ── ③ JSON 化的 token（存进去时就被 JSON 编码过）───────────────
let jsonWrapped = "{\"token\":\"\(token)\"}"
ok(!TokenFingerprint.isBase64(jsonWrapped), "⭐ JSON 包着的 token 不是 base64")
ok(TokenFingerprint.verdict(jsonWrapped).contains("Token 格式错误"), "verdict 对 JSON 形态也说「Token 格式错误」")

// ── ④ 空 / 站方的 'none' 兜底 ─────────────────────────────────
ok(!TokenFingerprint.isBase64(""), "空串不是 base64")
ok(TokenFingerprint.verdict("").contains("请先登录"), "空 token ⇒ 站方回「请先登录」")
ok(TokenFingerprint.verdict(nil).contains("请先登录"), "nil token ⇒ 站方回「请先登录」")
// ⭐⭐⭐ **实测纠正过的假设**（沙盒直连站方，2026-11-24）：
//   「none」是 4 个字符 ⇒ **能解码** ⇒ 站方回的是「Token 长度不正确」，**不是**「格式错误」⭐⭐⭐
//   ⇒ 所以门禁按**实测**写，不按猜的写 ⭐⭐⭐
ok(TokenFingerprint.isBase64("none"), "⭐「none」能解码 ⇒ 站方回「Token 长度不正确」（实测）")
// ⭐ 但「undefined」是 9 个字符 ⇒ 解不了 ⇒ 站方回「Token 格式错误」⭐⭐⭐
ok(!TokenFingerprint.isBase64("undefined"), "⭐「undefined」解不了 ⇒ 站方回「Token 格式错误」（实测）")
ok(!TokenFingerprint.isBase64("QUJDREVGR0hJSktM="), "⭐ 末尾多一个 = 的 17 字符 ⇒ 解不了（实测）")

// ── ⑤ 空白（JS 的 .trim() 会去掉 ⇒ 容忍）───────────────────────
ok(TokenFingerprint.isBase64("\n\(token)\n"), "首尾空白应被容忍（站方 JS 也 trim）")

// ── ⑥ URL 安全字母表（base64url）──────────────────────────────
let b64url = "a-_b" + "cdefghij"          // 12 字符
ok(TokenFingerprint.isBase64(b64url), "base64url 字母表也算合法")

// ── ⑦ 长度不对的 base64（站方会回「Token 长度不正确」）─────────
let short = "QUJD"                         // 4 字符 ⇒ 能解但长度不对
ok(TokenFingerprint.isBase64(short), "4 字符也是合法 base64（长度问题由站方判）")

// ── ⑧ ⭐ 不泄露内容 ───────────────────────────────────────────
let d = TokenFingerprint.describe(token)
ok(!d.contains(token), "⭐ describe 绝不能把 token 内容写进日志：\(d)")

print(pass > 0 && fail == 0 ? "ALL PASS" : "HAS FAILURE")
exit(fail == 0 ? 0 : 1)
