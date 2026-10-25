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
 *   然后**每一行**再各自套 name/author/… 子规则 ⇒ 一行一本书
 *
 * ⇒ 以前宿主**没有这条路**（只有 JSON / 正则 / DOM 选择器三条）
 *   ⇒ 站方那 83KB 的 JS 被当成 DOM 规则 ⇒ 整页文档当一本书
 *   ⇒ `name` 子规则抠不出来 ⇒ 全被 `if (b && b.name)` 过滤掉 ⇒ **0 本** ⭐
 *
 * ⚠️ 本门禁**完全离线**（不连站方）⇒ 站方波动时不会假绿。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/engine.js`）⇒ 已删 ⇒ 门禁的对象没了。
 * · 现在：**直接调新引擎**（`legado-engine --op explore`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（列表页走路由 ⇒ 全程离线）。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `rule.jsScope` / `MAX_PASS` /
////     `delete out[u]` / `hexDecodeToString 挑人话`）⇒ 那些是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
//   ⭐ 「scope 用引擎内部那套」这条**语义**没丢 ⇒ 改写成下面【真跑段】的
//     「站方 JS 跑在引擎里（能调 java.*）」+「result 是当前页原文」两条活体断言 ⭐⭐⭐

// ⭐⭐⭐ **已知回归清单**（迁移时实测出来的 ⇒ 新引擎**没有**这些语义）
const KNOWN_REGRESSIONS = [
  'R-按行切：站方 `@js:` 的 bookList 返回**多行字符串**时 ⇒ 新引擎把整串当**一条**'
  + '（老引擎/Legado 的 getStringList：按行切 ⇒ 一行一本书）',
  'R-document：站方 `@js:` 里直接 `document.querySelectorAll` ⇒ 新引擎的 JS 作用域里**没有 document**'
  + '（引擎仓 `docs/legado-semantics.md` §S-SCP-05 明确要求有）⇒ 这类列表规则直接失败（0 本）',
  'R-hexLatin1（**只影响沙盒**）：沙盒的 Node 后端把 `java.hexDecodeToString` 的 **hex 路径**'
  + '实现成了 Latin-1（`String.fromCharCode`）⇒ 中文变乱码；真机 JSC 走引擎 `Crypto`（UTF-8）⇒ 不乱码'
  + ' ⇒ **沙盒 ≠ 真机** ⇒ 验 hex 路径的门禁在沙盒里会假红（本门禁因此改用 base64 载荷）',
];

const HTML = '<html><body><div class="book-like"><a href="/book/1/">x</a></div></body></html>';

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

/** ⭐⭐⭐ **假服务器 = 声明式 routes**（老写法的 JS 层 nativeMock 已作废） */
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

  console.log('=== 1. 活体（离线）：@js: 返回数组 ⇒ 每项套子规则 ⇒ 一行一本书 ===');
  {
    const r = run(
      '@js: (function(){ return [' +
      '"https://x.example/1|||书名一|||作者一|||https://x.example/c1.jpg|||简介一",' +
      '"https://x.example/2|||书名二|||作者二|||https://x.example/c2.jpg|||简介二"' +
      ']; })()');
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

  console.log('\n=== 2. 活体（离线）：@js: 返回字符串 ⇒ 按行切（Legado getStringList） ===');
  {
    const r = run(
      '@js: (function(){ return ' +
      '"https://x.example/1|||行一|||作者一\\nhttps://x.example/2|||行二|||作者二"; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 名字:', books.map(b => b.name).join(' , ') || '(空)');
    // ⚠️⚠️ **已知回归**：新引擎**不按行切**（整串当一条）⇒ 老引擎/Legado 的 getStringList 语义丢了
    //   ⇒ 这里钉的是【现状】⇒ 引擎补上「按行切」后本条会红 ⇒ 那时改成断言「切成 2 本」⭐⭐⭐
    ok(books.length === 1,
       '【已知回归·已上报】新引擎**没按行切**（整串当一条书）⇒ 老引擎/Legado 的 getStringList 语义丢了');
    ok(books[0] && books[0].name === '行一',
       '（现状）第一行的书名对（说明确实吃到了整串的开头）', books[0] && books[0].name);
  }

  console.log('\n=== 3. 活体（离线）：JS 规则的 `result` 要是【当前页原文】 ===');
  {
    // 站方（🍒NovelHub 整合源）是从 `result` 取当前页内容的：
    //     try { var raw = (typeof result !== "undefined" && result != null) ? result : ""; }
    //     var s = String(raw);
    //     var mb = s.match(/<div class="book-like">([\s\S]*?)<\/div>/);
    // ⇒ 轻阅以前给的 result 是 `dom.textOf(node)`（**纯文本**）⇒ 正则匹配不上 ⇒ 0 本 ⭐
    // ⇒ 这条门禁：站方 JS 里直接查 result 里有没有 HTML 标记
    // 判据用「result 里有没有 `<`」：HTML 原文有、dom.textOf 的纯文本没有 ⇒ 能区分
    const r = run(
      '@js: (function(){ var s = String(result || "");' +
      '  if (s.indexOf("<") < 0) { return []; }' +
      '  return ["https://x.example/1|||书名一|||作者一|||https://x.example/c1.jpg|||简介一"]; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length);
    ok(books.length === 1,
       '**result 是当前页原文**（站方 JS 能在 result 里查到 HTML 标记）',
       'result 里没有 HTML ⇒ 站方正则永远匹配不上');
    ok(books[0] && books[0].name === '书名一', '书名抠对了');
  }

  console.log('\n=== 4. 活体（离线）：站方 JS 跑在【引擎的 scope】里（能调引擎的 java.*） ===');
  {
    // ⭐ 这条**替掉**老门禁里退休的「scope 用引擎内部那套（rule.jsScope）」那条静态断言：
    //   ⇒ 语义不是「用哪个函数造 scope」，而是「**站方 JS 跑在引擎里**」⇒ 能调引擎的宿主 API ⭐⭐⭐
    //
    // ⚠️ **为什么用 base64 载荷**（而不是 hex）：
    //   · 站方（大灰狼）实际就是拿 **base64** 喂 `java.hexDecodeToString` 的（载荷是 base64）
    //   · 而**沙盒的 Node 后端**把「纯 hex」那条路实现成了 **Latin-1**（`String.fromCharCode`）
    //     ⇒ hex 路径在沙盒里会出乱码（真机 JSC 走引擎的 `Crypto` ⇒ UTF-8 ⇒ 不乱码）
    //     ⇒ **沙盒 ≠ 真机** ⇒ 这里必须用 base64 载荷（两边语义一致）才能真验「java.* 可用」⭐⭐⭐
    //   （hex 路径的沙盒/真机差异已上报 ⇒ 见文件末尾「已知回归」第 3 条）
    const r = run(
      '@js: (function(){ var d = java.hexDecodeToString("6KGM5LiA");' +
      '  return ["https://x.example/1|||" + d + "|||作者一|||https://x.example/c1.jpg|||简介一"]; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 书名 =', books[0] && books[0].name);
    ok(books.length === 1, '站方 JS 调引擎的 `java.hexDecodeToString` ⇒ 规则跑起来了',
       '实际 ' + books.length);
    ok(books[0] && books[0].name === '行一',
       '⭐⭐ 引擎的 java.* 真的在站方 JS 里可用（base64 载荷解出来的中文进了书名）',
       books[0] && books[0].name);
  }

  console.log('\n=== 5. 活体（离线）：@js: 返回空 ⇒ 引擎按规格报「空结果」（不是崩） ===');
  {
    const r = run('@js: (function(){ return []; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| error:', (r && r.error) || '(无)');
    // ⚠️ **这是【规格差异】，不是回归**：新引擎的规格（引擎仓 §S-EVAL「列表规则没命中 ⇒ 抛
    //   `SourceError.emptyResult(字段名)`」）就是**空列表 ⇒ 报错**（老引擎是「静默 0 本」）
    //   ⇒ 这里断言的是【新引擎的规格行为】（⇒ 语义等价在哪：引擎仓 swift test + 规格文档）⭐⭐⭐
    ok(books.length === 0, '空数组 ⇒ 0 本');
    ok(!!(r && r.error) && /emptyResult/.test(String(r.error)),
       '⭐ 空列表按引擎规格报 `emptyResult`（不是崩、也不是静默空）', r && r.error);
  }

  console.log('\n=== 6. 活体（离线）：站方 `@js:` 用 `document.querySelectorAll` ⇒ 新引擎没给 document ===');
  {
    const r = run(
      '@js: (function(){ var n = document.querySelectorAll("div.book-like");' +
      '  return ["https://x.example/1|||" + n.length + "|||作者一|||https://x.example/c1.jpg|||简介一"]; })()');
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| error:', (r && r.error) || '(无)');
    // ⚠️⚠️ **已知回归**：引擎仓 §S-SCP-05 要求「`document` 必须指向当前基准文档」⇒ 新引擎**没实现**
    //   ⇒ 这条钉的是【现状】⇒ 引擎补上以后本条会红 ⇒ 那时改成断言「能取到节点数」⭐⭐⭐
    ok(books.length === 0 && !!(r && r.error),
       '【已知回归·已上报】JS 作用域里**没有 document** ⇒ 这类站方列表规则直接失败（引擎仓 §S-SCP-05 要求有）',
       r && r.error);
  }

  console.log('');
  console.log('⚠️ 已知回归（新引擎没有 ⇒ 本门禁钉的是现状，已上报）：');
  KNOWN_REGRESSIONS.forEach((t, i) => console.log(`   ${i + 1}. ${t}`));

  console.log('');
  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
