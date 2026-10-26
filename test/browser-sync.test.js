#!/usr/bin/env node
/**
 * **站方 `java.startBrowser` 必须同步返回**（不能把 Promise 塞进 URL）
 *
 * 起因（真机 2026-10-21，测书源报告实测）：
 *   站方把 `java.startBrowser(...)` 直接写在 URL 模板里：
 *     "url": '{java.startBrowser("https://fanqienovel.com/","番茄登录");}'
 *   轻阅**稍后**再解析这个 URL 模板时，**已经不在两遍跑上下文里**
 *   ⇒ `QR.__qrAjaxRecord` 不存在 ⇒ 走 `openBrowser` 直连 ⇒ **返回 Promise**
 *   ⇒ 那个 Promise 被字符串化塞进 URL ⇒ 变成 **`[object Promise]`**
 *   ⇒ explore 拿它当 URL 去请求 ⇒「URL 非法: [object Promise]」
 *   ⇒ **整个发现功能直接挂掉**（真机：40 秒白等，最后 ❌）
 *
 *   站方（Legado/栖阅）的 `java.startBrowser` 是**同步**的
 *   ⇒ 轻阅也必须同步返回（空串即可：那个 kind 本来就是「纯动作项」）
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };
const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

(async () => {
  const ja = read('QiReaderLite/Resources/engine/java-api.js');

  console.log('=== ① startBrowser 不能返回 Promise ===');
  // 取 startBrowser 的函数体
  const m = ja.match(/startBrowser: function \(url, title\) \{[\s\S]*?\n {4}\},/);
  ok(!!m, '找到 startBrowser 的定义');
  if (m) {
    const body = m[0];
    ok(!/return\s+java\.openBrowser\(/.test(body),
       'startBrowser 不再 `return java.openBrowser(...)`（那是 Promise）');
    ok(!/return\s+java\.openBrowser/.test(body), '同上（宽松匹配）');
    ok(/return\s*'';/.test(body), 'startBrowser 同步返回空串');
    ok(/QR\.__qrAjaxRecord/.test(body),
       '两遍跑上下文里仍然走录制分支（登录流程不受影响）');
  }

  console.log('\n=== ② showBrowser 必须走 startBrowser ===');
  const sm = ja.match(/showBrowser: function \(url, content, title\) \{[\s\S]*?\n {4}\},/);
  ok(!!sm, '找到 showBrowser 的定义');
  if (sm) {
    ok(/return\s+java\.startBrowser\(/.test(sm[0]),
       'showBrowser 转给 startBrowser（共享同步语义）');
  }

  console.log('\n=== ③ 浏览器类调用都要有同步兜底 ===');
  ok(!/startBrowserAwait[\s\S]{0,400}?return\s+java\.openBrowser/.test(ja),
     'startBrowserAwait 没在无两遍跑上下文时裸返回 Promise');
  ok(/mkBrowserLike/.test(ja), '有 mkBrowserLike 造 browser-like 对象');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
