#!/usr/bin/env node
/**
 * **「bookList 是 `@js:`」这条通路**（2026-10-22 真机「一个平台都出不了书」的根因）
 *
 * 跑法：node test/js-booklist.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 站方（用户自己整合十几个源的那个聚合源）的 `ruleExplore.bookList` 是 **83KB 的 `@js:`**：
 *   站方 JS 自己抓列表页、把十几个平台的 HTML 统一成**同一行**的格式：
 *       url|||name|||author|||coverUrl|||intro
 *   然后 `name` / `author` / `bookUrl` / `coverUrl` 这些**子规则**用 `##正则##` 抠字段：
 *       name: ##^[^|]*\|\|\|([\s\S]*?)\|\|\|[\s\S]*$##$1
 *
 * ⇒ **Legado 的语义**：`bookList` 求值结果 = **字符串列表**（getStringList）
 *   · JS 返回**数组** ⇒ 每项就是一行
 *   · JS 返回**字符串** ⇒ **按行切**
 *   · 然后**每一行**再各自套 name/author/… 子规则 ⇒ 一行一本书
 *
 * ⇒ 以前宿主**没有这条路**（只有 JSON / 正则 / DOM 选择器三条）
 *   ⇒ 站方那 83KB 的 JS 被当成 DOM 规则 ⇒ 整页文档当一本书
 *   ⇒ `name` 子规则抠不出来 ⇒ 全被 `if (b && b.name)` 过滤掉 ⇒ **0 本** ⭐
 *
 * ⚠️ 本门禁**完全离线**（不连站方）⇒ 站方波动时不会假绿。
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

/** 造一个「bookList 是 @js:」的假书源（结构照抄站方整合源） */
function fakeSource(bookListJs) {
  return {
    bookSourceUrl: 'https://fake.example.com/',
    bookSourceName: '假源',
    enabled: true,
    exploreUrl: '@js: (function(){ return [{ title: "分类A", url: "https://fake.example.com/list" }]; })()',
    ruleExplore: {
      bookList: bookListJs,
      name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
      author: '##^[^|]*\\|\\|\\|[\\s\\S]*?\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
      bookUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1',
      coverUrl: '##^[^|]*\\|\\|\\|[\\s\\S]*?\\|\\|\\|[\\s\\S]*?\\|\\|\\|([^|]*?)\\|\\|\\|[\\s\\S]*$##$1'
    }
  };
}

const HTML = '<html><body><div class="book-like"><a href="/book/1/" title="x">'
  + '<img src="https://x/c1.jpg"><h4>书名一</h4><span>作者一</span></a></div></body></html>';
const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    return { ok: true, code: 200, url: String(args.url || ''), headers: {}, body: HTML };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};

(async () => {
console.log('=== 1. 源码：bookList 是 @js: 的通路要存在 ===');
ok(/bookList 是 `@js:`/.test(engineSrc), 'engine.js 里有「bookList 是 @js:」这条通路');
ok(/rule\.jsScope/.test(engineSrc),
   '**scope 用引擎内部那套**（rule.jsScope）——自己造 scope 会漏 document / 包过 API 的 source');
ok(/jsScope: jsScope/.test(
     fs.readFileSync(path.join(root, 'QiReaderLite', 'Resources', 'engine', 'rule-analyzer.js'), 'utf8')),
   'rule-analyzer.js 导出了 jsScope');

const { win } = createSandbox({ nativeMock });

console.log('\n=== 2. 活体（离线）：@js: 返回数组 ⇒ 每项套子规则 ⇒ 一行一本书 ===');
{
  const src = fakeSource(
    '@js: (function(){ return [' +
    '"https://x.example/1|||书名一|||作者一|||https://x.example/c1.jpg|||简介一",' +
    '"https://x.example/2|||书名二|||作者二|||https://x.example/c2.jpg|||简介二"' +
    ']; })()');
  const r = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
    source: src, kindUrl: 'https://fake.example.com/list', page: 1
  }) + ")");
  const books = (r && r.books) || [];
  console.log('  出书 =', books.length, '| error:', (r && r.error) || '(无)');
  ok(books.length === 2, '**两本书都出来了**（@js: 数组 ⇒ 逐项套 name/bookUrl 子规则）',
     '实际 ' + books.length);
  ok(books[0] && books[0].name === '书名一', '书名从 ||| 串里抠对了',
     books[0] && books[0].name);
  ok(books[0] && books[0].author === '作者一', '作者抠对了', books[0] && books[0].author);
  ok(books[0] && books[0].bookUrl === 'https://x.example/1', '详情 URL 抠对了',
     books[0] && books[0].bookUrl);
  ok(books[0] && books[0].coverUrl === 'https://x.example/c1.jpg', '封面抠对了',
     books[0] && books[0].coverUrl);
}

console.log('\n=== 3. 活体（离线）：@js: 返回字符串 ⇒ 按行切（Legado getStringList） ===');
{
  const src = fakeSource(
    '@js: (function(){ return ' +
    '"https://x.example/1|||行一|||作者一\\nhttps://x.example/2|||行二|||作者二"; })()');
  const r = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
    source: src, kindUrl: 'https://fake.example.com/list', page: 1
  }) + ")");
  const books = (r && r.books) || [];
  console.log('  出书 =', books.length);
  ok(books.length === 2, '**按行切成两本书**', '实际 ' + books.length);
  ok(books[0] && books[0].name === '行一', '第一行的书名对', books[0] && books[0].name);
  ok(books[1] && books[1].name === '行二', '第二行的书名对', books[1] && books[1].name);
}

console.log('\n=== 3b. 活体（离线）：JS 规则的 `result` 要是【当前页原文】 ===');
{
  // 站方（🍒NovelHub 整合源）是从 `result` 取当前页内容的：
  //     try { var raw = (typeof result !== "undefined" && result != null) ? result : ""; }
  //     var s = String(raw);
  //     var mb = s.match(/<div class="book-like">([\s\S]*?)<\/div>/);
  // ⇒ 轻阅以前给的 result 是 `dom.textOf(node)`（**纯文本**）⇒ 正则匹配不上 ⇒ 0 本 ⭐
  // ⇒ 这条门禁：站方 JS 里直接查 result 里有沒有 HTML 标记
  // 判据用「result 里有没有 `<`」：HTML 原文有、dom.textOf 的纯文本没有 ⇒ 能区分
  const src = fakeSource(
    '@js: (function(){ var s = String(result || "");' +
    '  if (s.indexOf("<") < 0) { return []; }' +
    '  return ["https://x.example/1|||书名一|||作者一|||https://x.example/c1.jpg|||简介一"]; })()');
  const r = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
    source: src, kindUrl: 'https://fake.example.com/list', page: 1
  }) + ")");
  const books = (r && r.books) || [];
  console.log('  出书 =', books.length);
  ok(books.length === 1,
     '**result 是当前页原文**（站方 JS 能在 result 里查到 HTML 标记）',
     'result 里没有 HTML ⇒ 站方正则永远匹配不上');
  ok(books[0] && books[0].name === '书名一', '书名抠对了');
}

console.log('\n=== 4. 活体（离线）：@js: 返回空 ⇒ 0 本（不是崩） ===');
{
  const src = fakeSource('@js: (function(){ return []; })()');
  const r = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
    source: src, kindUrl: 'https://fake.example.com/list', page: 1
  }) + ")");
  ok((r && (r.books || []).length === 0) && !(r && r.error),
     '空数组 ⇒ 0 本且不报错', r && r.error);
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
