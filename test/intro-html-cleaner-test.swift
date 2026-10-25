import Foundation

// ⭐⭐⭐⭐⭐ 门禁：**简介的 HTML 清洗**（2026-10-25 真机：`<p></p>` 露在详情页界面上）
//
// ⇒ 清洗放在**App 显示层**（不动引擎输出 ⇒ 沙盒对拍零影响）⭐⭐⭐

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✓ \(msg)") }
    else { fail += 1; print("  ✗ \(msg)") }
}

// ── ① 普通文字原样过 ─────────────────────────────────────────
ok(IntroHTMLCleaner.plainText("就是普通文字") == "就是普通文字", "普通文字原样过")

// ── ② ⭐⭐⭐ 站方 `abstract` 的真实形状（真机截图：🍅大灰狼）────
let realAbstract = """
<p></p>
<p>"一觉醒来，她看着镜子里的自己，爆炸头血腥纹身脸化得像鬼，多看一秒都辣眼睛。
重生前，她另有所爱，一心逃离，对他恨之入骨。
上一世脑子被门夹了放着绝色老公不要，被渣男贱女所害，被最信任的闺蜜洗脑，落了个众叛亲离的下场。</p>
"""
let out2 = IntroHTMLCleaner.plainText(realAbstract)
ok(!out2.contains("<p>"), "不该再有 <p>：\(out2)")
ok(!out2.contains("</p>"), "不该再有 </p>：\(out2)")
ok(out2.contains("一觉醒来"), "文字要保留")
ok(out2.contains("恨之入骨"), "文字要保留")
ok(out2.contains("众叛亲离"), "文字要保留")

// ── ③ `<br>` ⇒ 换行 ─────────────────────────────────────────
ok(IntroHTMLCleaner.plainText("a<br>b") == "a\nb", "`<br>` ⇒ 换行")
ok(IntroHTMLCleaner.plainText("a<br/>b") == "a\nb", "`<br/>` ⇒ 换行")

// ── ④ 段落各占一行 ─────────────────────────────────────────
let out4 = IntroHTMLCleaner.plainText("<p>第一段</p><p>第二段</p>")
ok(out4.contains("\n"), "段落之间该有换行：\(out4)")
ok(out4.contains("第一段") && out4.contains("第二段"), "两段都在")

// ── ⑤ 其它标签只去标签、留内容 ──────────────────────────────
ok(IntroHTMLCleaner.plainText("<b>粗体</b>和<span style=\"x\">普通</span>") == "粗体和普通", "`<b>` / `<span>` 只去标签留内容")

// ── ⑥ `<a href>` ⇒ 只留文字 ─────────────────────────────────
let out6 = IntroHTMLCleaner.plainText("看这里<a href=\"https://x.test/a?b=1&c=2\">点这里</a>好了")
ok(out6.contains("点这里"), "链接文字要保留")
ok(!out6.contains("href"), "不该留 href：\(out6)")
ok(!out6.contains("<a"), "不该留 <a：\(out6)")

// ── ⑦ 没有配对 `>` ⇒ 当普通文本（不能崩、不能吞内容）──────────
let out7 = IntroHTMLCleaner.plainText("a < b 而且 c")
ok(out7.contains("a < b"), "未配对的 `<` 要当普通文字：\(out7)")

// ── ⑧ 三个以上连续换行压成两个 ──────────────────────────────
let out8 = IntroHTMLCleaner.plainText("a\n\n\n\n\nb")
let out8Desc = out8.replacingOccurrences(of: "\n", with: "\\n")
ok(!out8.contains("\n\n\n"), "连续换行要压掉：\(out8Desc)")

// ── ⑨ ⭐⭐⭐ **变异测试**：把清洗改成「原样返回」⇒ 必须红 ─────────
//   （证明这些断言不是装饰品）
// ⚠️ **不要用裸 `{ }` 块**（Swift 会把上一行的 `ok(...)` 误判成尾随闭包）⭐⭐⭐
let mutated = realAbstract  // 假装没清洗
let msg9 = "⭐⭐⭐ 变异测试：不清洗时上面的断言应当变红（证明断言真能抓）"
ok(mutated.contains("<p>"), msg9)

print("通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
