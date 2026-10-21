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
const { createSandbox } = require('./harness');

const ENGINE = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  const { win } = createSandbox({});

  console.log('=== ① query 编码对所有方法 ===');
  {
    const r = await win.eval(`(function(){
      var u = 'https://x.com/a?source=番茄&variable={"custom":""}';
      var t = QR.analyzeUrl(u + ',{"method":"POST","body":{"html":""}}', { baseUrl: '' });
      return JSON.stringify({ url: t.url, method: t.method, body: t.body, ct: t.headers['Content-Type'] || '' });
    })()`);
    const o = JSON.parse(r);
    console.log('  →', o.url);
    console.log('  → body =', o.body, '| Content-Type =', o.ct);
    ok(o.method === 'POST', '方法还是 POST');
    ok(!/[一-龥]/.test(o.url), 'query 里没有裸中文');
    ok(!/[{}\[\]"']/.test(o.url), 'query 里没有裸花括号/引号');
    ok(/%[0-9A-Fa-f]{2}/.test(o.url), 'query 做过百分号编码');
  }

  console.log('\n=== ② body 是对象 → JSON 序列化 + JSON Content-Type ===');
  {
    const r = await win.eval(`(function(){
      var t = QR.analyzeUrl('https://x.com/a', { baseUrl: '', }, );
      return '';
    })()`);
    // 直接测 analyzeUrl 带对象 body 的那条（上面 ① 已经带 body）
    const r2 = await win.eval(`(function(){
      var t = QR.analyzeUrl('https://x.com/a,{"method":"POST","body":{"html":"<b>x</b>"}}', { baseUrl: '' });
      return JSON.stringify({ body: t.body, ct: t.headers['Content-Type'] || '' });
    })()`);
    const o = JSON.parse(r2);
    console.log('  → body =', o.body, '| Content-Type =', o.ct);
    ok(o.body.indexOf('[object Object]') < 0, 'body 不是 "[object Object]"');
    ok(o.body === '{"html":"<b>x</b>"}', 'body 是正规 JSON 字符串');
    ok(/application\/json/i.test(o.ct), 'Content-Type 是 application/json');
  }

  console.log('\n=== ③ JS 语法错 → 整段当表达式再试（栖阅语义）===');
  {
    const r = await win.eval(`(function(){
      return QR.rule.runJs('{a:1, b:"x"}', {}).then(function(v){
        return JSON.stringify(v);
      }, function(e){ return 'ERR:' + String(e && e.message || e); });
    })()`);
    console.log('  →', r);
    ok(String(r).indexOf('ERR:') !== 0, '对象字面量规则不再直接失败');
    ok(String(r).indexOf('"a"') >= 0, '拿到了对象字面量的值');
  }

  console.log('\n=== ④ 源码里要有这些钩子 ===');
  {
    const eng = fs.readFileSync(path.join(ENGINE, 'engine.js'), 'utf8');
    const ra = fs.readFileSync(path.join(ENGINE, 'rule-analyzer.js'), 'utf8');
    const engCode = eng.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    ok(/JSON\.stringify\(opt\.body\)/.test(engCode), 'analyzeUrl 对对象 body 做 JSON.stringify');
    ok(/application\/json; charset=utf-8/.test(engCode), 'analyzeUrl 给 JSON body 补 Content-Type');
    ok(/name === 'SyntaxError'/.test(ra), 'runJs 认 SyntaxError');
    ok(/eval\("\(" \+ __qrCode \+ "\)"\)/.test(ra), 'runJs 有「整段当表达式」的兜底');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
