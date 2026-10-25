#!/usr/bin/env node
/**
 * **data: 载荷里缺 book_id ⇒ 站方解不出来 ⇒ 目录 0 章**（2026-10-22 真机「book_id=undefined」）
 *
 * 聚合源（🍅大灰狼）的 bookUrl/tocUrl 是 `data:;base64,<载荷>,{…}`，
 * 载荷里本来该有 book_id/source/tab，站方 init 直接从**载荷**里解构：
 *     let { book_id, source: sources, tab, … } = JSON.parse(java.hexDecodeToString(result));
 * 但载荷里只有 {tab,url} ⇒ book_id=undefined ⇒ 详情/目录请求全废（服务器回 illegal base64）
 * ⇒ 宿主手里**有** book_id（列表接口返回的原始字段）⇒ 要能把它**送到站方手上** ✅
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 * · 老门禁验的是**老引擎的 JS 层**：`nativeMock` 假服务器 + 老引擎的 `toc` op
 *   ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ 覆盖会丢 ⭐⭐⭐
 * · ⇒ 现在：**用新引擎的 `toc` / `explore` op**（`conformance --op`）+ **声明式 routes**（假服务器）⭐⭐⭐
 *
 * ⭐⭐⭐ **「宿主怎么把 book_id 送到站方手上」在新引擎里的机制变了**（语义等价）：
 * | | 老引擎 | 新引擎 |
 * |---|---|---|
 * | 机制 | 宿主把 book_id **补进 data: 载荷**再重编 | 宿主把**列表项的原始字段**（`book_id` 等）<br>交给站方 JS ⇒ **站方自己**拼载荷 |
 * | 落点 | 老 harness 的 JS 层 | `SourceEngine.makeBookObject`（`book.raw` ⇒ `book.book_id`）<br>+ `ListItem.rawFields` |
 * ⇒ **语义等价点**：**站方 JS 拿得到 book_id** ⇒ 载荷里就带 book_id ⇒ 目录请求不再是 `book_id=undefined` ⭐⭐⭐
 */
const { createSandbox, engineAvailable } = require('./new-engine-harness.js');

let pass = 0, fail = 0;
const ok = (c, m, e) => { if (c) { pass++; console.log('  ✓ ' + m); } else { fail++; console.log('  x ' + m + (e ? ' — ' + e : '')); } };

/** ⭐ **解 `data:;base64,<载荷>,{…}` 的载荷**（断言用） */
function payloadOf(dataUrl) {
  const m = /^data:;base64,([^,]*)/i.exec(String(dataUrl || ''));
  if (!m) return null;
  try { return JSON.parse(Buffer.from(m[1], 'base64').toString('utf8')); }
  catch (e) { return null; }
}

if (!engineAvailable()) {
  console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
  console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
  process.exit(0);
}

(async () => {
  // ⭐⭐⭐ **假服务器 = 声明式 routes**（规范 §1.1）—— 不再用老引擎的 JS 层 `nativeMock`
  const { win, sandbox } = createSandbox({
    routes: [
      // 列表接口：返回带 book_id 的原始字段
      { match: 'fake.example.com/list', status: 200, body: JSON.stringify({
        code: 0,
        data: [{ book_id: 'MTgzNTEy', source: '番茄', tab: '小说', book_name: '测试书名' }],
      }) },
    ],
  });
  // ⭐⭐⭐ **调用新引擎的 op**（规范 §1.2：`win.__qrInvoke(op, payload)` ⇒ `--op` 直调）
  const call = (op, p) => win.__qrInvoke(op, p);

  const payload = Buffer.from(JSON.stringify({ tab: '小说', url: '' }), 'utf8').toString('base64');
  const dataUrl = 'data:;base64,' + payload + ',{"type":"qingtian2"}';
  const src = {
    bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
    ruleToc: {
      chapterList: '@js: (function(){ var res = JSON.parse(java.hexDecodeToString(result)); var bid=res.book_id; var tab=res.tab; if(!bid){return [];} return ["https://x/"+bid+"/1.html|||"+tab+" 第1章|||"]; })()',
      chapterName: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
      chapterUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
    }
  };

  console.log('=== ① 载荷缺 book_id ⇒ 0 章（站方解不出来）===');
  const r1 = await call('toc', {
    source: src, bookUrl: 'https://x/1', tocUrl: dataUrl, book: { bookUrl: 'https://x/1' },
  });
  ok((r1.chapters || []).length === 0, '没有 book_id ⇒ 0 章（站方解不出来）',
    JSON.stringify(r1).slice(0, 160));

  console.log('\n=== ② 载荷有 book_id ⇒ 目录出来了 ===');
  const payload2 = Buffer.from(JSON.stringify({ book_id: 'MTgzNTEy', tab: '小说' }), 'utf8').toString('base64');
  const dataUrl2 = 'data:;base64,' + payload2 + ',{"type":"qingtian2"}';
  const r2 = await call('toc', {
    source: src, bookUrl: 'https://x/1', tocUrl: dataUrl2,
    book: { bookUrl: 'https://x/1', book_id: 'MTgzNTEy', source: '番茄', tab: '小说' },
  });
  console.log('  章节数 =', (r2.chapters || []).length, JSON.stringify((r2.chapters || [])[0] || {}).slice(0, 120));
  ok((r2.chapters || []).length === 1, '**载荷里有 book_id ⇒ 目录出来了**',
    JSON.stringify(r2).slice(0, 160));
  ok(!!(r2.chapters[0] && r2.chapters[0].title), '章节名对');
  ok(!!(r2.chapters[0] && /MTgzNTEy/.test(String(r2.chapters[0].url || ''))),
    '章节 URL 里的 book_id 是载荷里那个', JSON.stringify(r2.chapters[0] || {}));

  console.log('\n=== ③ 宿主的等价机制：列表项的原始字段要送到站方 JS 手上 ===');
  // ⭐⭐⭐ **新引擎的落点**：**条目级基准**（§S-RES-01）
  //   ⇒ 列表项是 JSON 对象时，`result` = **那个对象本身**（不是页原文、也不是纯文本）
  //   ⇒ 站方 JS 读得到 `result.book_id` / `result.tab` / `result.source` ⇒ 原始字段**没丢** ⭐⭐⭐
  //   ⇒ 站方于是能**自己**拼出「带 book_id 的 data: 载荷」⇒ 详情/目录请求不再 book_id=undefined ⭐⭐⭐
  const src2 = {
    bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
    ruleExplore: {
      exploreUrl: 'https://fake.example.com/list',
      bookList: '$.data[*]',
      name: '$.book_name',
      author: '$.author',
      // ⭐ 站方常见的写法：**用列表项的原始字段**拼 data: 载荷
      bookUrl: '@js: "data:;base64," + java.base64Encode(JSON.stringify({book_id: result.book_id, source: result.source, tab: result.tab})) + ",{}"',
    },
  };
  const r3 = await call('explore', {
    source: src2, kindUrl: 'https://fake.example.com/list', page: 1,
  });
  const books = r3.books || [];
  console.log('  出书 =', books.length, '| bookUrl =', String((books[0] || {}).bookUrl || '').slice(0, 80));
  const pl = books[0] ? payloadOf(books[0].bookUrl) : null;
  console.log('  载荷 =', JSON.stringify(pl));
  ok(books.length === 1, '列表页出了一本书', JSON.stringify(r3).slice(0, 160));
  ok(!!pl, '站方拼出来的 data: 载荷能解');
  ok(pl && pl.book_id === 'MTgzNTEy',
     '**站方 JS 读得到 result.book_id ⇒ 载荷里带 book_id**（宿主没丢原始字段）', JSON.stringify(pl));
  ok(pl && pl.tab === '小说', '载荷里也有 tab', JSON.stringify(pl));
  ok(pl && pl.source === '番茄', '载荷里也有 source', JSON.stringify(pl));

  console.log('\n=== ④ 请求记录（引擎真的发请求了吗）===');
  // ⭐ 请求记录从 `sandbox.__requests` 取（规范 §1.1）
  const reqs = sandbox.__requests || [];
  console.log('  请求数 =', reqs.length, reqs.map(u => String(u).slice(0, 60)).join(' | '));
  ok(reqs.length > 0, '引擎真的发了请求（假服务器被命中了）');

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
