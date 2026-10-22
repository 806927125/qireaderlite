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
 * 而宿主的 `getJsonList` 里有：
 *     if (!jt.sel) return Promise.resolve([]);   // ← ★★★ 没有尾部 ⇒ 直接返回空
 * ⇒ **目录直接空** ⇒ 全平台 0 章 ⭐
 *
 * ⇒ **Legado 语义**：JS 自己返回列表 ⇒ **结果就是列表本身**（有尾部才走选择器）
 *
 * ⭐ 同一个根因也影响**任何「纯 @js: 返回数组」的站方规则**（跨项目通用）
 */
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    return { ok: true, code: 200, url: String(args.url || ''), headers: {}, body: '<html><body>x</body></html>' };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};

(async () => {
const { win } = createSandbox({ nativeMock });
const call = (op, p) => win.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");

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

console.log('=== 1. 纯 @js: 的 bookList（无尾部）⇒ 列表要出来 ===');
const ex = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
const books = (ex && ex.books) || [];
console.log('  出书 =', books.length, '| 第一本 =', JSON.stringify(books[0] || {}).slice(0, 140));
ok(books.length === 2, '**两本书都出来了**（纯 @js: 无尾部 ⇒ 结果就是列表）',
   '实际 ' + books.length);
ok(!!(books[0] && books[0].name), '书名抠对了（子规则从 ||| 串里抠）', books[0] && books[0].name);

console.log('\n=== 2. 纯 @js: 的 chapterList（无尾部）⇒ 目录要出来（NovelHub 的根因） ===');
const toc = await call('toc', {
  source: src, bookUrl: 'https://x.example/1', tocUrl: 'https://x.example/1',
  book: books[0] || { bookUrl: 'https://x.example/1' }
});
const chs = (toc && toc.chapters) || [];
console.log('  章节数 =', chs.length, '|', JSON.stringify(chs.slice(0, 2)).slice(0, 160));
ok(chs.length === 2,
   '**两章都出来了**（`if (!jt.sel) return []` 那句把站方的目录全毙了）',
   '实际 ' + chs.length);
ok(!!(chs[0] && chs[0].title), '章节名对', chs[0] && chs[0].title);
ok(!!(chs[0] && chs[0].url), '章节 URL 对', chs[0] && chs[0].url);

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
