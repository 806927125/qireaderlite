#!/usr/bin/env node
/**
 * **`org.jsoup` 端到端门禁**（2026-10-26）
 *
 * 站方（🍒NovelHub / 🍅大灰狼这类聚合源）的规则代码里 **`org.jsoup.Jsoup.parse` 43 处 / 7 个源**
 * （125 源语料，**剥注释后**统计）⇒ 老引擎（轻阅 WKWebView）上有这能力 ⇒ 新引擎必须补上。
 *
 * ⭐⭐⭐ **为什么这条门禁在轻阅侧**（而不是只在引擎仓）：
 *   · 引擎仓的门禁验的是「`org.jsoup` 这个 API 在不在」
 *   · 这条验的是「**站方那种规则**能不能真出书」⇒ **端到端**（假服务器 → 引擎 → 书单）⭐⭐⭐
 *   ⇒ 缺了 API 会被引擎仓的门禁抓；**API 在但链路断了** ⇒ 只有这条能抓 ⭐⭐⭐
 *
 * ⚠️ **完全离线**（假服务器 ⇒ 不连站方 ⇒ 站方波动不会假绿）
 */
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

// ⭐ 假服务器返回的列表页（2 本书）
const HTML = `<html><body>
  <div class="book-like"><a href="/book/1/">书名一</a><span class="author">作者一</span></div>
  <div class="book-like"><a href="/book/2/">书名二</a><span class="author">作者二</span></div>
</body></html>`;

/** 造一个「bookList 是 @js: 且用 org.jsoup」的假书源（照抄站方正则） */
function fakeSource(bookListJs) {
  return {
    bookSourceUrl: 'https://fake.example.com/',
    bookSourceName: '假源',
    enabled: true,
    exploreUrl: '@js: (function(){ return [{ title: "分类A", url: "https://fake.example.com/list" }]; })()',
    ruleExplore: {
      bookList: bookListJs,
      name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
      bookUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
    }
  };
}

function run(bookListJs) {
  const { win } = createSandbox({
    routes: [{ match: 'fake.example.com', status: 200, body: HTML }],
  });
  return win.__qrInvoke('explore', {
    source: fakeSource(bookListJs), kindUrl: 'https://fake.example.com/list', page: 1,
  });
}

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  console.log('=== 1. 站方正则：`org.jsoup.Jsoup.parse(result).select(...)` ⇒ 必须真出书 ===');
  {
    // ⭐ 站方真写法（JSC/老引擎都这么写）：`result` = 当前页原文
    const r = run(
      '@js: (function(){ var d = org.jsoup.Jsoup.parse(result);' +
      '  var els = d.select("div.book-like"); var out = [];' +
      '  for (var i = 0; i < els.size(); i++) {' +
      '    var a = els.get(i).select("a").first();' +
      // ⭐ 站方的行格式：`url|||name|||author|||coverUrl|||intro`（五段）⭐⭐⭐
      '    var au = els.get(i).select(".author").first().text();' +
      '    out.push(a.attr("href") + "|||" + a.text() + "|||" + au + "|||" + "/c.jpg" + "|||" + "简介"); }' +
      '  return out; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| error:', (r && r.error) || '(无)');
    ok(books.length === 2, '⭐⭐⭐ `org.jsoup` 列表规则必须出 2 本（站方 7 个源靠这个）',
       'books=' + books.length + ' error=' + (r && r.error));
    ok(books[0] && books[0].name === '书名一',
       '⭐⭐⭐ 书名要抠得出来（`a.text()` ⇒ 不是空串）',
       'name=' + JSON.stringify(books[0] && books[0].name));
  }

  console.log('\n=== 2. `org.jsoup` 缺失时必须【明确失败】（不许静默 0 本） ===');
  {
    // 故意用一个不存在的能力 ⇒ 站方通常会 try/catch ⇒ 至少不能崩引擎
    const r = run(
      '@js: (function(){ try { return org.jsoup.Nope.parse(result); }' +
      '  catch (e) { return []; } })()');
    const books = (r && r.books) || [];
    ok(books.length === 0, '未知能力 ⇒ 站方 catch ⇒ 0 本（不崩）', 'books=' + books.length);
  }

  console.log('\n=== 3. `Elements` 必须是【真数组】（站方 `Array.from(els).reverse()`） ===');
  {
    const r = run(
      '@js: (function(){ var d = org.jsoup.Jsoup.parse(result);' +
      '  var els = d.select("div.book-like");' +
      '  var rev = Array.from(els).reverse();' +
      '  var out = []; for (var i = 0; i < rev.length; i++) {' +
      '    var el = rev[i]; var a2 = el.select("a").first();' +
      '    var au2 = el.select(".author").first().text();' +
      '    out.push(a2.attr("href") + "|||" + a2.text() + "|||" + au2 + "|||" + "/c.jpg" + "|||" + "简介"); }' +
      '  return out; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 第一本 =', (books[0] || {}).name);
    ok(books.length === 2 && books[0] && books[0].name === '书名二',
       '⭐⭐⭐ `Array.from(els).reverse()` 要能倒序（Elements 必须是真数组）',
       'books=' + books.length + ' first=' + ((books[0] || {}).name));
  }

  console.log('');
  console.log((fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
