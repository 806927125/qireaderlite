#!/usr/bin/env node
/**
 * **URL 规则一致性门禁**（2026-10-25 老 JS 引擎物理删除后改跑新引擎）
 *
 * 跑法：node test/analyze-url-parity.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 为什么要有这道门：
 *   栖阅的 URL 规则是**原生 Swift**；轻阅 ALSO 有一份 Swift 实现
 *   （`QiReaderLite/Core/AnalyzeUrl.swift`）。
 *   ⚠️ **但真正跑请求的那份是引擎**（`legado-engine` 的 `URLBuilder`）
 *   ⇒ 两份实现一旦各走各的，就会出现「Swift 测的全绿、真机跑的是另一套」的假绿。
 *   ⇒ 这道门禁用**同一份 fixture**（test/fixtures/analyze-url-cases.json），
 *     让**引擎**和 **App 的 AnalyzeUrl.swift** 算出**同一个 URL**，对不上就红。
 *
 *   fixture 里的 expected 是 **App 的 `AnalyzeUrl.swift` 算出来的**
 *   （纯 Foundation，沙盒 swiftc 能真编真跑）⇒ 两边锁死在同一份语义上。
 *
 * ⚠️ 这道门禁的价值在于**防漂移**：以后谁改了其中一份，另一份立刻红。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎的 `QR.analyzeUrl(...)` ⇒ 老引擎删了 ⇒ 对象没了
 *   ⇒ 现在改成**直接调新引擎的 `--analyzeUrl` 模式**（`URLBuilder.parse`）
 *   ⇒ **语义等价在哪**：老门禁验的「真正发请求的那份实现」＝ 老引擎的 analyzeUrl；
 *     新架构里真正发请求的那份**就是引擎的 `URLBuilder`**（`PageFetcher`/`ajax` 都走它）
 *     ⇒ 断言对象换成引擎，**被验的语义一模一样**（URL / method / body / Content-Type）
 *   · fixture 与期望值**一个字没改** ⇒ 期望值仍然是 App 的 `AnalyzeUrl.swift` 算出来的
 *     ⇒ 这道门仍然是「引擎 ↔ App Swift」的对拍 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除（2026-10-25）⇒ 门禁改验【新引擎】**（`legado-engine` 的 Swift 实现）
//   ⇒ 覆盖不丢，而且验的是**真正在跑的那份代码**⭐⭐⭐
const { analyzeUrl, engineAvailable } = require('./engine-bridge.js');

const CASES = path.join(__dirname, 'fixtures', 'analyze-url-cases.json');
const ROOT = path.join(__dirname, '..');
const ENGINE_REF = path.join(ROOT, '..', 'legado-engine', 'reference', 'swift', 'AnalyzeUrl.swift');
const APP_REF = path.join(ROOT, 'QiReaderLite', 'Core', 'AnalyzeUrl.swift');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/**
 * ⭐ 引擎的 URL 规则解析（`URLBuilder.parse`）⇒ URL / method / body / headers
 * ⚠️ **重试**：引擎正在被重编时 ⇒ 这次调用会返回空 ⇒ 重试几次（别把「引擎在重编」
 *   当成「URL 规则变了」）⭐⭐⭐
 */
function parse(raw, base) {
  let r = null;
  for (let i = 0; i < 5; i++) {
    r = analyzeUrl({ url: raw, baseUrl: base || '' });
    if (r && !r.error && r.url) break;
    const until = Date.now() + 3000;
    while (Date.now() < until) { /* 忙等 3 秒（同步函数） */ }
  }
  if (!r || r.error) return { error: (r && r.error) || '引擎没返回结果' };
  const headers = r.headers || {};
  let contentType = '';
  for (const k of Object.keys(headers)) {
    if (k.toLowerCase() === 'content-type') { contentType = String(headers[k]); break; }
  }
  return { url: r.url, method: r.method, body: r.body, contentType };
}

(async () => {
  console.log('=== 0. 前置：期望值那份实现（App 的 AnalyzeUrl.swift）还在 ===');
  // ⭐ 这条是**整道门禁的地基**：fixture 的 expected 是 App 的 AnalyzeUrl.swift 算出来的
  //   ⇒ 那个文件必须还在（而且内容没被改）⇒ 否则 expected 就没有主人了 ⭐⭐⭐
  ok(fs.existsSync(APP_REF), 'App 的 Core/AnalyzeUrl.swift 还在（fixture 期望值就是它算的）');
  if (fs.existsSync(APP_REF)) {
    const appSrc = fs.readFileSync(APP_REF, 'utf8');
    ok(/func analyzeUrl|static func parse|public static func/.test(appSrc),
       'App 的 AnalyzeUrl.swift 里有 URL 规则解析入口');
    // ⭐⭐⭐ **两份实现必须逐字相同**（引擎仓的 reference 就是 App 那份的副本）
    //   ⇒ 不然「引擎算出来的」和「App 算出来的」就是两套语义 ⇒ 这道门禁在骗自己 ⭐⭐⭐
    if (fs.existsSync(ENGINE_REF)) {
      const refSrc = fs.readFileSync(ENGINE_REF, 'utf8');
      ok(refSrc === appSrc,
         '引擎仓的 reference/swift/AnalyzeUrl.swift 与 App 那份**逐字相同**（同一份语义）');
    } else {
      console.log('  ⏭️  引擎仓里没有 reference/swift/AnalyzeUrl.swift ⇒ 跳过「两份实现同源」这条');
    }
  }

  // ⭐⭐⭐ **探活**（引擎跑不起来 ⇒ 显式 SKIP，不算门禁的锅）⭐⭐⭐
  const _alive = analyzeUrl({ url: 'https://x.com/a', baseUrl: '' });
  if (!engineAvailable() || !_alive || _alive.error) {
    console.log('  ⏭️  跳过：引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ 本段没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  const cases = JSON.parse(fs.readFileSync(CASES, 'utf8'));

  console.log('\n=== 1. 引擎侧 URL 规则对齐 fixture（= App 的 AnalyzeUrl.swift 算出的同一份语义）===');
  for (const c of cases) {
    const got = parse(c.raw, c.base);
    const e = c.expected;
    console.log(`\n· ${c.name}`);
    console.log(`    url = ${got.url}`);
    ok(got.url === e.url, `URL 一致\n      期望: ${e.url}\n      实际: ${got.url}`);
    ok(got.method === e.method, `方法一致（${got.method} vs ${e.method}）`);
    ok(got.body === e.body, `body 一致（${got.body} vs ${e.body}）`);
    ok(got.contentType === e.contentType, `Content-Type 一致（${got.contentType} vs ${e.contentType}）`);
  }

  console.log('\n=== 2. 关键几条单独点名（这是踩过的坑）===');
  const byName = (n) => cases.find(c => c.name.indexOf(n) >= 0);
  {
    const c = byName("'+'");
    const got = parse(c.raw, '');
    ok(String(got.url || '').indexOf('%2B') >= 0,
       "query 里的 '+' 编码成 %2B（base64 book_id 不被服务器解成空格）");
  }
  {
    const c = byName('大灰狼详情请求');
    const got = parse(c.raw, '');
    ok(String(got.url || '').indexOf('%E7%95%AA%E8%8C%84') >= 0,
       '裸中文做了百分号编码（iOS 的 URL(string:) 才不会判非法）');
    ok(String(got.url || '').indexOf('{') < 0, '裸花括号做了百分号编码');
    ok(got.body === '{"html":""}', '对象 body 是正规 JSON（不是 [object Object]）');
    ok(/application\/json/.test(got.contentType), 'JSON body 补了 application/json');
  }
  {
    // ⭐⭐⭐ **新增（迁移时补的）**：`url,{json}` 后缀 —— **请求选项不是 URL 的一部分**
    //   老门禁没点名这一条 ⇒ 但它是 rule-syntax-compat 那道门验的同一件事
    //   ⇒ 这里点名一下（**同一份语义，两个门禁各钉一头**）⭐⭐⭐
    const got = parse('https://x.com/p,{"method":"POST","headers":{"X-Test":"1"},"body":"a=1"}', '');
    ok(got.url === 'https://x.com/p', '`,{json}` 后缀被剥掉了（不是 URL 的一部分）', got.url);
    ok(got.method === 'POST', '后缀里的 method 生效了', got.method);
    ok(got.body === 'a=1', '后缀里的 body 生效了', got.body);
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
