#!/usr/bin/env node
/**
 * **JS 引擎 ↔ Swift 引擎的 URL 规则一致性门禁**（2026-10-21）
 *
 * 为什么要有这道门：
 *   栖阅的 URL 规则是**原生 Swift**；轻阅 ALSO 有一份 Swift 实现
 *   （`QiReaderLite/Core/AnalyzeUrl.swift`）。
 *   ⚠️ **但真正跑请求的是 JS 那份**（engine.js · analyzeUrl）——
 *   两份实现一旦各走各的，就会出现「Swift 测的全绿、真机跑的是另一套」的假绿。
 *   ⇒ 这道门禁用**同一份 fixture**（test/fixtures/analyze-url-cases.json），
 *     让 JS 和 Swift 算出**同一个 URL**，对不上就红。
 *
 * fixture 里的 expected 是 **Swift 实现算出来的**（Core 是纯 Foundation，
 * 沙盒 swiftc 能真编真跑），Swift 侧也对着它断言 ⇒ 两边锁死在同一份语义上。
 *
 * ⚠️ 这道门禁的价值在于**防漂移**：以后谁改了其中一份，另一份立刻红。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const CASES = path.join(__dirname, 'fixtures', 'analyze-url-cases.json');
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  const cases = JSON.parse(fs.readFileSync(CASES, 'utf8'));
  const { win } = createSandbox({});

  console.log('=== JS 侧 analyzeUrl 对齐 fixture（= Swift 算出的同一份语义）===');
  for (const c of cases) {
    const r = await win.eval(`(function(){
      var t = QR.analyzeUrl(${JSON.stringify(c.raw)}, { baseUrl: ${JSON.stringify(c.base)} });
      return JSON.stringify({
        url: t.url, method: t.method, body: t.body,
        contentType: t.headers['Content-Type'] || t.headers['content-type'] || ''
      });
    })()`);
    const got = JSON.parse(r);
    const e = c.expected;
    console.log(`\n· ${c.name}`);
    console.log(`    url = ${got.url}`);
    ok(got.url === e.url, `URL 一致\n      期望: ${e.url}\n      实际: ${got.url}`);
    ok(got.method === e.method, `方法一致（${got.method} vs ${e.method}）`);
    ok(got.body === e.body, `body 一致（${got.body} vs ${e.body}）`);
    ok(got.contentType === e.contentType, `Content-Type 一致（${got.contentType} vs ${e.contentType}）`);
  }

  console.log('\n=== 关键几条单独点名（这是踩过的坑）===');
  const byName = (n) => cases.find(c => c.name.indexOf(n) >= 0);
  {
    const c = byName("'+'");
    const r = await win.eval(`(function(){
      var t = QR.analyzeUrl(${JSON.stringify(c.raw)}, { baseUrl: '' });
      return t.url;
    })()`);
    ok(r.indexOf('%2B') >= 0, "query 里的 '+' 编码成 %2B（base64 book_id 不被服务器解成空格）");
  }
  {
    const c = byName('大灰狼详情请求');
    const r = await win.eval(`(function(){
      var t = QR.analyzeUrl(${JSON.stringify(c.raw)}, { baseUrl: '' });
      return JSON.stringify({ url: t.url, body: t.body, ct: t.headers['Content-Type'] || '' });
    })()`);
    const o = JSON.parse(r);
    ok(o.url.indexOf('%E7%95%AA%E8%8C%84') >= 0, '裸中文做了百分号编码（iOS 的 URL(string:) 才不会判非法）');
    ok(o.url.indexOf('{') < 0, '裸花括号做了百分号编码');
    ok(o.body === '{"html":""}', '对象 body 是正规 JSON（不是 [object Object]）');
    ok(/application\/json/.test(o.ct), 'JSON body 补了 application/json');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
