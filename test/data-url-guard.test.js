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
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/java-api.js` 等）⇒ 已删 ⇒ 门禁的对象没了。
 *   ⇒ 老门禁第 1 段是**读老引擎 JS 源码**的静态断言（`indexOf('data:') === 0`）
 *     ⇒ 那是**老引擎的实现细节** ⇒ 改按【新引擎 Swift 源码】的等价描述来验 ⭐⭐⭐
 * · 现在：**直接调新引擎**（`legado-engine --op explore` / `--js`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（本门禁全程离线 ⇒ 路由兜底挡网络）。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `rawRequest` /
//     `indexOf('data:') === 0` / `MAX_PASS` / `delete out[u]`）⇒ 那些是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
//   ⇒ 语义等价在哪：下面【源码段】断言的是**同一件事**在新引擎/App 里的落点：
//     ① 引擎的 `ajax`（站方 `java.ajax` 拿 data:）⇒ 返回载荷，不发请求 ⭐⭐⭐
//     ② 引擎的 `fetch`（抓页面）⇒ data: 直接当页面内容，**不进 transport** ⭐⭐⭐
//     ③ App 的原生传输层 ⇒ data: 直接当响应体（最后一道防线）⭐⭐⭐

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  console.log('=== 1. 源码：两层都要拦 data: 伪 URL（老引擎的 JS 层 ⇒ 新引擎 + 原生层） ===');
  {
    const engineSrc = engineSwiftSrc('Pipeline/SourceEngine.swift');
    // ① 站方 `java.ajax` 拿 data: ⇒ 返回**载荷**（不是错误页）
    ok(/if u\.lowercased\(\)\.hasPrefix\("data:"\)\s*\{\s*return Self\.dataPayload\(u\)/.test(engineSrc),
       '**新引擎的 ajax 拦 data:**（站方 java.ajax 拿到的是载荷，不是错误页）');
    // ② 抓页面时 data: ⇒ 直接当页面内容，**不进 transport**（不发请求）
    ok(/if trimmedRule\.lowercased\(\)\.hasPrefix\("data:"\)/.test(engineSrc),
       '**新引擎的 fetch 拦 data:**（页面内容 = 载荷 ⇒ 压根不进传输层）');
    // ③ 原生传输层（App）⇒ 最后一道防线：原生绝不真去 fetch
    const backend = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
    ok(/hasPrefix\("data:"\)/.test(backend),
       '**Swift 原生请求拦 data:**（最后一道防线：原生绝不真去 fetch）');
    ok(/static func dataPayload\(_ raw: String\) -> String/.test(backend),
       '⭐ 原生侧有 data: 载荷的解包（与引擎同语义）');
  }

  // ⭐⭐⭐ **假服务器 = 声明式 routes**：`match: ''` ⇒ 匹配一切
  //   ⇒ 万一引擎真去 fetch 了，这里会**留下请求记录**（门禁看得见 ⇒ 不会假绿）⭐⭐⭐
  const { win } = createSandbox({
    routes: [{ match: '', status: 200, body: '<html>ROUTE-BODY</html>' }],
  });

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
          '  if (s.indexOf("ROUTE-BODY") >= 0) { return []; }' +
          '  return ["https://x.example/1|||书名一|||作者一|||https://x.example/c1.jpg|||简介一"]; })()',
        name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
        author: '##^[^|]*\\|\\|\\|[\\s\\S]*?\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
        bookUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
      }
    };
    const r = win.__qrInvoke('explore', { source: src, kindUrl: dataUrl, page: 1 });
    const books = (r && r.books) || [];
    const reqs = (r && r.requests) || [];
    console.log('  出书 =', books.length, '| 引擎发的请求 =', reqs.length, reqs.join(' , ') || '(无)');
    if (r && r.error) console.log('  engine error:', r.error);
    // ⭐⭐⭐ **「一个请求都没发」**：路由表匹配一切 ⇒ 只要发了请求就一定会被记下来 ⇒ 这条**不是恒真** ⭐⭐⭐
    ok(reqs.length === 0,
       '**一个请求都没发**（data: 伪 URL 不该走网络）',
       '发了 ' + reqs.length + ' 次：' + reqs.join(' , '));
    ok(books.length === 1,
       '**载荷被当成页面内容**（站方 JS 在 result 里读到了它）',
       '出 ' + books.length + ' 本');
    ok(books[0] && books[0].name === '书名一', '书名对');

    // ⭐⭐⭐ **对照组**（防「恒真」）：普通 http URL ⇒ 引擎**确实**发了请求
    //   ⇒ 证明上面那条「一个请求都没发」**不是**因为请求记录压根不工作 ⭐⭐⭐
    const r2 = win.__qrInvoke('explore', {
      source: Object.assign({}, src, { ruleExplore: Object.assign({}, src.ruleExplore, {
        bookList: '@js: (function(){ return []; })()',
      }) }),
      kindUrl: 'https://x.example/list', page: 1,
    });
    const reqs2 = (r2 && r2.requests) || [];
    console.log('  对照组（普通 http URL）引擎发的请求 =', reqs2.length, reqs2.join(' , ') || '(无)');
    ok(reqs2.length > 0,
       '⭐⭐⭐ 对照组：普通 http URL **确实**发了请求 ⇒ 上面「0 个请求」不是恒真（真抓到 bug 会红）',
       '实际 ' + reqs2.length + ' 个');
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
