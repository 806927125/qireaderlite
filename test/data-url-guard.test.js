#!/usr/bin/env node
/**
 * **`data:` 伪 URL 绝不能真去 fetch**（2026-10-22 真机「illegal base64 data at input byte 9」）
 *
 * 跑法：node test/data-url-guard.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **症状**：用户真机上弹一个黑色 toast「illegal base64 data at input byte 9」，
 * 🍅大灰狼的目录 0 章。
 *
 * **根因**：聚合源的 bookUrl / tocUrl / chapterUrl 全是**伪 URL**：
 *     data:;base64,<载荷>,{"type":"qingtian2"}
 * ⇒ 宿主把它当**真 URL** 交给原生（URLSession）去 fetch
 * ⇒ Foundation 去解这个 data: URL 的 base64
 * ⇒ 载荷**不是合法 base64**（它其实是 hex / 已被 URL 编码过）
 * ⇒ 抛「**illegal base64 data at input byte 9**」
 * ⇒ 还会**冒成一个 toast** ⇒ 规则整条挂掉 ⭐
 *
 * ⇒ 站方的语义是「**data: 伪 URL 的载荷 = 页面内容**」
 *    ⇒ 宿主**不该发请求**，直接把载荷当响应体返回 ✅
 *
 * ⚠️ 这个门禁**完全离线**（不发任何网络请求）⇒ 也能守住「data: 不发请求」这条契约。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

const root = path.join(__dirname, '..');
const engineSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'engine.js'), 'utf8');
const javaSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'java-api.js'), 'utf8');
const sandboxSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Core', 'RuleSandbox.swift'), 'utf8');

(async () => {
console.log('=== 1. 源码：两层都要拦 data: 伪 URL ===');
ok(/indexOf\('data:'\) === 0/.test(javaSrc),
   '**JS rawRequest 拦 data:**（站方 java.ajax 拿到的是载荷，不是错误页）');
ok(/hasPrefix\("data:"\)/.test(sandboxSrc),
   '**Swift nativeRequest 拦 data:**（最后一道防线：原生绝不真去 fetch）');
ok(/indexOf\('data:'\) === 0/.test(engineSrc),
   "engine.fetchPage 拦 data:（把载荷当页面内容）");

let reqCount = 0;
const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    reqCount++;
    return { ok: true, code: 200, url: String(args.url || ''), headers: {}, body: '<html></html>' };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};
const { win } = createSandbox({ nativeMock });

console.log('\n=== 2. 活体（离线）：data: 伪 URL ⇒ 不发请求 + 载荷当内容 ===');
{

  // 载荷 = 一段 HTML（站方把详情/目录/正文塞在 data: 伪 URL 里）
  const payload = '<html><body><div class="book-like"><a href="/book/1/">x</a></div></body></html>';
  const dataUrl = 'data:;base64,' + Buffer.from(payload, 'utf8').toString('base64')
    + ',{"type":"qingtian2"}';

  const src = {
    bookSourceUrl: 'https://fake.example.com/',
    bookSourceName: '假源',
    enabled: true,
    ruleExplore: {
      // 站方拿到的是**载荷原文**（base64 串），不是 HTML —— 站方自己会解
      bookList: '@js: (function(){ var s = String(result || "");' +
        '  if (s.length < 10) { return []; }' +
        '  if (s.indexOf("<html") >= 0) { return []; }' +
        '  return ["https://x.example/1|||书名一|||作者一|||https://x.example/c1.jpg|||简介一"]; })()',
      name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
      author: '##^[^|]*\\|\\|\\|[\\s\\S]*?\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
      bookUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
    }
  };
  const r = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
    source: src, kindUrl: dataUrl, page: 1
  }) + ")");
  const books = (r && r.books) || [];
  console.log('  出书 =', books.length, '| 原生请求数 =', reqCount);
  ok(reqCount === 0,
     '**一个原生请求都没发**（data: 伪 URL 不该走网络）',
     '发了 ' + reqCount + ' 次');
  ok(books.length === 1,
     '**载荷被当成页面内容**（站方 JS 在 result 里读到了它）',
     '出 ' + books.length + ' 本');
  ok(books[0] && books[0].name === '书名一', '书名对');
}

console.log('\n=== 3. 活体（离线）：解不了 base64 就【明确失败】，不能解出乱码 ===');
{
  // ⚠️⚠️ 以前非法字符被 `manualB64ToBytes` **静默跳过** ⇒ 返回**乱码**
  //   ⇒ 站方 `JSON.parse(java.hexDecodeToString(result))` 拿到乱码 ⇒ 炸
  //   ⇒ 🍅大灰狼**目录 0 章** ⭐
  //   ⇒ 现在：不是合法 base64 ⇒ 明确失败（空串）⇒ 上层改走 hex 分支 ✅
  const bad = win.eval("java.hexDecodeToString('这不是base64!!!')");
  console.log('  非法 base64 解出 =', JSON.stringify(String(bad)).slice(0, 60));
  ok(typeof bad === 'string' && bad.length < 20,
     '**非法 base64 解出的是空/极短串**（不是乱码）',
     '实际 ' + JSON.stringify(String(bad)).slice(0, 60));

  const hex = Buffer.from('{"a":1}', 'utf8').toString('hex');
  const good = win.eval("java.hexDecodeToString('" + hex + "')");
  ok(String(good).indexOf('{"a":1}') >= 0,
     '合法 hex 仍能正确解出原文（别把好路也堵了）',
     '实际 ' + JSON.stringify(String(good)).slice(0, 60));
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
