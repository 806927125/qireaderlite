#!/usr/bin/env node
/**
 * **书对象必须带【列表项的原始字段】**（2026-10-22 真机「详情页和目录都出不来」）
 *
 * 跑法：node test/book-raw.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **真机日志**：
 * ```
 * [详情] https://v5.langge.uk/detail?book_id=undefined&source=undefined&tab=小说&...
 * [最后响应] 状态=200 开头={"code":-1,"msg":"illegal base64 data at input byte 9",...}
 * [data:载荷] 解出来 = {"tab":"小说","url":""}
 * ```
 * ⇒ 站方 jsLib 生成 `data:;base64,<载荷>` 时要读 **book.book_id** 之类
 * ⇒ 宿主原先只把 name/author/… 九个字段送给站方 ⇒ **book_id 压根没传过去**
 * ⇒ 载荷只有 `{tab,url}` ⇒ 详情/目录请求全是 **book_id=undefined**
 * ⇒ 服务器解 undefined 失败 ⇒ 回「illegal base64 data at input byte 9」⇒ 整本书崩 ⭐
 *
 * ⇒ **修法**：列表项的原始 item 字段一路带到站方（引擎 JSON 路径 + Swift 的 BookDTO/Book/rawJSON）
 *
 * 另外这一门禁还钉住 **base64 解码必须按 UTF-8**（我自己引入过的回归）：
 *   `atob` 返回的是 **Latin-1** ⇒ 直接返回就是「小说」变「å°è¯´」⭐
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
    const url = String(args.url || '');
    // 列表页返回 JSON（含 book_id —— 站方生成 data: 载荷时要靠它）
    if (url.indexOf('/list') >= 0) {
      return {
        ok: true, code: 200, url, headers: {},
        body: JSON.stringify({
          data: [
            { book_id: 'MTgzNTEy', name: '武炼巅峰', author: '莫默', bookUrl: 'https://x.example/1' },
            { book_id: 'OTk5OTk5', name: '第二本', author: '作者乙', bookUrl: 'https://x.example/2' }
          ]
        })
      };
    }
    return { ok: true, code: 200, url, headers: {}, body: '{"name":"武炼巅峰","author":"莫默"}' };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};

(async () => {
const { win } = createSandbox({ nativeMock });
const call = (op, p) => win.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");

console.log('=== 1. 活体（离线）：站方能从 book 对象里拿到 book_id ===');
const src = {
  bookSourceUrl: 'https://fake.example.com/',
  bookSourceName: '假源',
  enabled: true,
  exploreUrl: 'https://fake.example.com/list',
  ruleExplore: {
    bookList: '$.data[*]',
    name: '$.name',
    author: '$.author',
    bookUrl: '$.bookUrl'
  },
  ruleBookInfo: { name: '$.name', author: '$.author' }
};

const ex = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
const books = (ex && ex.books) || [];
console.log('  出书 =', books.length, '| 第一本 =', JSON.stringify(books[0] || {}).slice(0, 160));
ok(books.length === 2, '出书 2 本');
ok(!!(books[0] && books[0].book_id),
   '**book 对象里带上了原始字段 book_id**（站方生成 data: 载荷靠它）',
   JSON.stringify(books[0] || {}).slice(0, 160));

const bi = await call('bookInfo', {
  source: src, bookUrl: 'https://x.example/1', book: books[0]
});
const biBook = (bi && bi.book) || {};
console.log('  详情返回的 book =', JSON.stringify(biBook).slice(0, 160));
ok(!!biBook.book_id,
   '**详情返回的 book 也带着 book_id**（p.book 的原始字段要合并过去）',
   JSON.stringify(biBook).slice(0, 160));

console.log('\n=== 2. 活体（离线）：base64 解码必须按 UTF-8（不能是 Latin-1） ===');
{
  // 「小说」⇒ base64 ⇒ 解出来必须还是「小说」，不是「å°è¯´」
  const b64 = Buffer.from(JSON.stringify({ tab: '小说', url: '' }), 'utf8').toString('base64');
  const out = win.eval("java.hexDecodeToString('" + b64 + "')");
  console.log('  解出来 =', JSON.stringify(String(out)).slice(0, 120));
  ok(String(out).indexOf('小说') >= 0,
     '**中文按 UTF-8 解对了**（atob 返回 Latin-1 ⇒ 会变成「å°è¯´」）',
     JSON.stringify(String(out)).slice(0, 120));
  ok(String(out).indexOf('å°') < 0, '没有出现 Latin-1 乱码');
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
