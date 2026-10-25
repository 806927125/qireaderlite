#!/usr/bin/env node
/**
 * **纯 `<js>` 规则（没有尾部选择器）也要出列表/章节**（2026-10-22 轻阅实证）
 *
 * 跑法：node test/js-no-tail.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **症状**：🍒NovelHub 整合源（用户自己把十几个源合一个的）
 *   · 发现页 ✅ 分类 799、列表 124 本
 *   · 详情页 ✅ 书名/简介/书号都对
 *   · **目录 ❌ 全平台 0 章**、正文 ❌
 *
 * **根因**：站方的 `ruleToc.chapterList` 是**纯 `<js>…</js>`**（结尾 `})()`，
 * **没有 `$.data` 之类尾部选择器**），返回的是 `["url|||name|||", …]` 这样的字符串数组。
 * 而老宿主的 `getJsonList` 里有：
 *     if (!jt.sel) return Promise.resolve([]);   // ← ★★★ 没有尾部 ⇒ 直接返回空
 * ⇒ **目录直接空** ⇒ 全平台 0 章 ⭐
 *
 * ⇒ **Legado 语义**：JS 自己返回列表 ⇒ **结果就是列表本身**（有尾部才走选择器）
 *
 * ⭐ 同一个根因也影响**任何「纯 @js: 返回数组」的站方规则**（跨项目通用）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/engine.js`）⇒ 已删 ⇒ 门禁的对象没了。
 * · 现在：**直接调新引擎**（`legado-engine --op explore` / `--op toc`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（列表页 / 目录页走路由 ⇒ 全程离线）。
 */
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `getJsonList` / `jt.sel` /
//     `MAX_PASS` / `delete out[u]`）⇒ 那些是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

const PAGE_HTML = '<html><body><div class="book-like">x</div></body></html>';

/** ⭐⭐⭐ **假服务器 = 声明式 routes**（老写法的 JS 层 nativeMock 已作废） */
function sandbox() {
  return createSandbox({
    routes: [
      { match: 'fake.example.com', status: 200, body: PAGE_HTML },   // 列表页
      { match: 'x.example', status: 200, body: PAGE_HTML },           // 目录页 / 书籍页
    ],
  });
}

// 站方风格：**纯 @js:**（无尾部），返回 `url|||name|||` 这样的字符串数组
const src = {
  bookSourceUrl: 'https://fake.example.com/',
  bookSourceName: '假源',
  enabled: true,
  exploreUrl: 'https://fake.example.com/list',
  ruleExplore: {
    bookList: '@js: (function(){ return ["https://x.example/1|||书名一|||作者一|||", "https://x.example/2|||书名二|||作者二|||"]; })()',
    name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
    author: '##^[^|]*\\|\\|\\|[\\s\\S]*?\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
    bookUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
  },
  ruleToc: {
    chapterList: '@js: (function(){ return ["https://x.example/1/1.html|||第1章 起始|||", "https://x.example/1/2.html|||第2章 继续|||"]; })()',
    chapterName: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
    chapterUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
  }
};

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  console.log('=== 1. 纯 @js: 的 bookList（无尾部）⇒ 列表要出来 ===');
  let books = [];
  {
    const { win } = sandbox();
    const ex = win.__qrInvoke('explore', {
      source: src, kindUrl: 'https://fake.example.com/list', page: 1,
    });
    books = (ex && ex.books) || [];
    console.log('  出书 =', books.length, '| 第一本 =', JSON.stringify(books[0] || {}).slice(0, 140));
    if (ex && ex.error) console.log('  engine error:', ex.error);
    ok(books.length === 2, '**两本书都出来了**（纯 @js: 无尾部 ⇒ 结果就是列表）',
       '实际 ' + books.length);
    ok(!!(books[0] && books[0].name), '书名抠对了（子规则从 ||| 串里抠）', books[0] && books[0].name);
    ok(books[0] && books[0].bookUrl === 'https://x.example/1',
       '详情 URL 抠对了', books[0] && books[0].bookUrl);
  }

  console.log('\n=== 2. 纯 @js: 的 chapterList（无尾部）⇒ 目录要出来（NovelHub 的根因） ===');
  {
    const { win } = sandbox();
    const toc = win.__qrInvoke('toc', {
      source: src, bookUrl: 'https://x.example/1', tocUrl: 'https://x.example/1',
      book: books[0] || { bookUrl: 'https://x.example/1' },
    });
    const chs = (toc && toc.chapters) || [];
    console.log('  章节数 =', chs.length, '|', JSON.stringify(chs.slice(0, 2)).slice(0, 160));
    if (toc && toc.error) console.log('  engine error:', toc.error);
    ok(chs.length === 2,
       '**两章都出来了**（没有尾部选择器时，JS 的返回值就是列表本身）',
       '实际 ' + chs.length);
    ok(!!(chs[0] && chs[0].title), '章节名对', chs[0] && chs[0].title);
    ok(!!(chs[0] && chs[0].url), '章节 URL 对', chs[0] && chs[0].url);
  }

  console.log('\n=== 3. 纯 @js: 返回【对象数组】⇒ 每项就是一本书（站方另一种常见形态） ===');
  {
    const { win } = sandbox();
    const ex = win.__qrInvoke('explore', {
      source: Object.assign({}, src, {
        ruleExplore: {
          bookList: '@js: (function(){ return [{name:"书名一",author:"作者一",bookUrl:"https://x.example/1"},'
            + '{name:"书名二",author:"作者二",bookUrl:"https://x.example/2"}]; })()',
          name: '$.name', author: '$.author', bookUrl: '$.bookUrl',
        },
      }),
      kindUrl: 'https://fake.example.com/list', page: 1,
    });
    const bs = (ex && ex.books) || [];
    console.log('  出书 =', bs.length, '| 第一本 =', JSON.stringify(bs[0] || {}).slice(0, 140));
    if (ex && ex.error) console.log('  engine error:', ex.error);
    ok(bs.length === 2, '**两本书都出来了**（对象数组 ⇒ 每项一本）', '实际 ' + bs.length);
    ok(bs[0] && bs[0].name === '书名一', '书名对（对象字段规则逐项求值）', bs[0] && bs[0].name);
    ok(bs[0] && bs[0].bookUrl === 'https://x.example/1', '详情 URL 对', bs[0] && bs[0].bookUrl);
  }

  console.log('\n=== 4. 有尾部的复合规则（`<js>…</js>$.data`）⇒ 尾部选择器照常生效 ===');
  {
    // ⭐ 对照项：**有**尾部 ⇒ JS 的返回值要先过尾部选择器（老引擎同款语义）
    const { win } = sandbox();
    const toc = win.__qrInvoke('toc', {
      source: {
        bookSourceUrl: 'https://fake.example.com/',
        bookSourceName: '假源',
        enabled: true,
        ruleToc: {
          chapterList: '<js> var d = \'{"data":[{"title":"第1章","url":"https://x.example/1"},'
            + '{"title":"第2章","url":"https://x.example/2"}]}\'; d;</js>$.data',
          chapterName: '$.title', chapterUrl: '$.url',
        },
      },
      bookUrl: 'https://x.example/1', tocUrl: 'https://x.example/1',
    });
    const chs = (toc && toc.chapters) || [];
    console.log('  章节数 =', chs.length, '|', JSON.stringify(chs.slice(0, 2)).slice(0, 160));
    if (toc && toc.error) console.log('  engine error:', toc.error);
    ok(chs.length === 2, '**尾部 `$.data` 选中了数组**（有尾部 ≠ 不选）', '实际 ' + chs.length);
    ok(chs[0] && chs[0].title === '第1章', '章节名对', chs[0] && chs[0].title);
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
