#!/usr/bin/env node
/**
 * **栖阅语义对账门禁**（2026-10-21）
 *
 * 背景：用户发来《栖阅引擎反推》材料（从栖阅 2027.01.01 二进制逆向出来的
 *      规则引擎规格：符号表 + 字面量 + 随包 JS）。
 *      这份材料能当**行为规格书**用 —— 轻阅的引擎要跟它对齐。
 *
 * 本门禁钉死**已经对账过、且踩过坑**的三条：
 *   ① URL 的 query 重新编码**对所有方法**（不只 GET）
 *      —— 站方 POST 的 query 带裸中文/裸 JSON → iOS 的 URL(string:) 判非法
 *         → 请求根本没发出去 → 引擎吞成空串 → 站方 JSON.parse('') 报天书错
 *      —— 栖阅侧证据：AnalyzeUrl+Request 有 smartPercentEncode / shouldUseSmartPercentEncode，
 *         字符集 `…-._~:/?#[]@!$&'()*+,;=` 与我们 Swift 侧写的一致
 *   ② body 是**对象**时必须 JSON 序列化（不能 `String(obj)` → "[object Object]"）
 *      —— 栖阅侧证据：`application/json; charset=utf-8` + buildRequest
 *   ③ JS 语法错 → **整段当表达式再试一次**（栖阅 cstring 原文：
 *      `Function("return (" + __script + ");")`）
 *      —— 像 `@js:{a:1}` 这种对象字面量规则，当脚本跑是语法错
 *
 * ⚠️ 断言要作用在**行为**上（跑出来是什么），不是复述实现意图。
 */
const fs = require('fs');
const path = require('path');

const ENGINE = path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore');
const { engineSwiftSrc, engineSwiftRaw } = require('./engine-gate-helpers.js');
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  console.log('=== ① query 编码对所有方法 ===');
  {
    // ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除** ⇒ 改用【新引擎】的 `URLBuilder`（Swift）⭐⭐⭐
    const { analyzeUrl, engineAvailable } = require('./engine-gate-helpers.js');
    if (!engineAvailable()) {
      console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
    } else {
      const o = analyzeUrl({
        url: 'https://x.com/a?source=番茄&variable={"custom":""},{"method":"POST","body":{"html":""}}',
        baseUrl: '',
      }) || {};
      console.log('  →', o.url);
      console.log('  → body =', o.body, '| Content-Type =', (o.headers || {})['Content-Type']);
      ok(o.method === 'POST', '方法还是 POST', JSON.stringify(o));
      ok(!/[一-龥]/.test(o.url || ''), 'query 里没有裸中文', o.url);
      ok(!/[{}[\]"']/.test(o.url || ''), 'query 里没有裸花括号/引号', o.url);
      ok(/%[0-9A-Fa-f]{2}/.test(o.url || ''), 'query 做过百分号编码', o.url);

      console.log('\n=== ② body 是对象 → JSON 序列化 + JSON Content-Type ===');
      const o2 = analyzeUrl({
        url: 'https://x.com/a,{"method":"POST","body":{"html":"<b>x</b>"}}',
        baseUrl: '',
      }) || {};
      console.log('  → body =', o2.body, '| Content-Type =', (o2.headers || {})['Content-Type']);
      ok(String(o2.body).indexOf('[object Object]') < 0, 'body 不是 "[object Object]"', JSON.stringify(o2));
      // ⭐ JSON 序列化会转义 `<` / `>`（`\/`）⇒ 不能比**逐字** ⇒ 比「能 parse + 含 html」⭐
      let parsedBody = null;
      try { parsedBody = JSON.parse(o2.body); } catch (e) { parsedBody = null; }
      ok(parsedBody && parsedBody.html === '<b>x</b>',
         'body 是正规 JSON 字符串（parse 出来 html 对得上）', JSON.stringify(o2));
      ok(/application\/json/i.test((o2.headers || {})['Content-Type'] || ''),
         'Content-Type 是 application/json', JSON.stringify(o2));
    }
  }

  console.log('\n=== ③ JS 语法错 → 整段当表达式再试（栖阅语义）===');
  {
    const { evalRule, engineAvailable } = require('./engine-gate-helpers.js');
    if (!engineAvailable()) {
      console.log('  ⏭️  跳过：没编译 legado-engine');
    } else {
      const r3 = evalRule('@js:{a:1, b:"x"}', { baseType: 'page', isJSON: false, base: '' });
      console.log('  →', r3 && r3.text, '| 失败 =', r3 && r3.failure);
      ok(r3 && !r3.failure, '对象字面量规则不再直接失败', r3 && r3.failure);
      // ⭐⭐ **对象要看 `value`，不是 `text`**（`text` 对对象是空串 ⇒ 2026-10-25 踩过）⭐⭐
      const v3 = r3 && r3.value;
      ok(v3 && typeof v3 === 'object' && v3.a === 1,
         '拿到了对象字面量的值', JSON.stringify(r3));
    }
  }


  console.log('\n=== ④ 源码里要有这些钩子 ===');
  {
    // ⭐⭐⭐⭐⭐ **老 JS 引擎已于 2026-10-25 物理删除** ⇒ 改验**新引擎**（Swift）⭐⭐⭐
    const { engineSwiftSrc } = require('./engine-gate-helpers.js');
    const engCode = engineSwiftSrc('Host/URLBuilder.swift')
      + engineSwiftSrc('Evaluator/Evaluator.swift');
    // ⭐ analyzeUrl：对象 body ⇒ JSON.stringify；JSON body ⇒ 补 Content-Type
    ok(/JSON\.stringify/.test(engCode) || /application\/json/.test(engCode),
       'analyzeUrl 对对象 body 做 JSON.stringify / 补 Content-Type');
    // ⭐ runJs 认 SyntaxError + 「整段当表达式」的兜底（**顶层 return 也要支持** ⇒ 2026-10-25 修）
    ok(/SyntaxError/.test(engineSwiftRaw('Evaluator/Evaluator.swift'))
       || /jsError/.test(engineSwiftRaw('Evaluator/Evaluator.swift')),
       'JS 报错会报出来（jsError / SyntaxError）');
    const hostApiSrc = engineSwiftRaw('JS/JSHostAPI.swift');
    ok(/programPair|asFunction/.test(hostApiSrc),
       'runJs 有「顶层 return 也支持」的兜底（programPair）');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
