#!/usr/bin/env node
/**
 * **JS 规则的 `result` 语义要分「页面级 / 条目级」**（2026-10-22 真机栽在这）
 *
 * 跑法：node test/result-semantics.test.js
 *
 * ────────────────────────────────────────────────────────────
 * Legado 的语义：`result` = **当前被分析的那个东西**。
 *
 *   · 页面级规则（bookList / chapterList / init / content）
 *       基准 = 当前页 ⇒ result = **当前页原文**（HTML 源码）
 *       站方（🍒NovelHub）这么取：
 *           var s = String(result); s.match(/<div class="book-like">…/)
 *
 *   · 条目级规则（name / author / **bookUrl** / coverUrl / chapterName / chapterUrl…）
 *       基准 = 那一条记录 ⇒ result = **那个对象本身**
 *       站方（🍅大灰狼）的 bookUrl / tocUrl 规则就是这么写的：
 *           let book_id = result.book_id;   let sources = result.source;
 *
 * ⚠️⚠️ **build206 的回归**：我把 `result` **一律**换成「当前页原文」
 *   ⇒ 条目级规则的 `result.book_id` 恒 undefined
 *   ⇒ 站方只生成了 `{"tab":"小说","url":""}`（JSON.stringify 把 undefined 丢了）
 *   ⇒ 详情/目录请求全是 book_id=undefined
 *   ⇒ 服务器回「illegal base64 data at input byte 9」⇒ 整本书崩 ⭐
 *
 * ⇒ 这个门禁**必须**能在 build206 那种代码上红（否则就是假门禁）。
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
const RULE_SRC = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'rule-analyzer.js'), 'utf8');

/** 解 `data:;base64,<载荷>,{…}` 的载荷 */
function payloadOf(dataUrl) {
  const m = /^data:;base64,([^,]*)/i.exec(String(dataUrl || ''));
  if (!m) return null;
  try { return JSON.parse(Buffer.from(m[1], 'base64').toString('utf8')); }
  catch (e) { return null; }
}

/** 大灰狼的列表接口返回（原字段都在） */
const LIST_JSON = JSON.stringify({
  code: 0, msg: 'ok',
  data: [{
    book_id: 'MTgzNTEy', source: '番茄', tab: '小说', toc_url: '',
    book_name: '终极：我雷婷他哥', author: '未知', thumb_url: 'https://x/c.jpg',
    abstract: '简介', category: '都市', score: '9.0', status: '连载', tags: '爽文',
    last_chapter_title: '第1章', last_update_time: '2026-10-22 12:00:00',
    word_number: '100万'
  }]
});

const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    const url = String(args.url || '');
    // 「htmlpage」这个地址回 HTML（页面级规则要看到源码），别的回列表 JSON
    const body = url.indexOf('htmlpage') >= 0
      ? '<html><body><div class="book-like">书名一</div></body></html>'
      : LIST_JSON;
    return { ok: true, code: 200, url, headers: {}, body };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};

(async () => {
  console.log('=== 1. 源码：result 的语义要按基准分流（不能一刀切） ===');
  ok(/function jsResultOf/.test(RULE_SRC), 'rule-analyzer.js 里有 jsResultOf（按基准分流）');
  ok(/jsResultOf\(result, ctx\)/.test(RULE_SRC), 'jsScope 的 result 走 jsResultOf');
  ok(!/jsRunScope\.result\s*=\s*ctx\.raw/.test(RULE_SRC),
     '**evalOne 里没有一刀切覆盖**（build206 的回归根因）');
  ok(/ctx\.raw = page\.text/.test(
       fs.readFileSync(path.join(root, 'QiReaderLite', 'Resources', 'engine', 'engine.js'), 'utf8')),
     'ctx.raw = 当前页原文（markContent 里）');

  const { win } = createSandbox({ nativeMock });
  const call = (op, p) => win.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");

  console.log('\n=== 2. 活体（离线）：条目级 JS 规则 ⇒ result 是【那条记录】 ===');
  {
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: '$.data',
        name: '$.book_name',
        // 站方（大灰狼同款）写法：直接从 result 上读 book_id
        bookUrl: '<js> var b = result.book_id; var t = result.tab || "小说";' +
                 ' return "data:;base64," + java.base64Encode(JSON.stringify({book_id:b,tab:t})) + ",{}"; </js>'
      }
    };
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| bookUrl =', books[0] && books[0].bookUrl);
    ok(books.length === 1, '出了一本书', '实际 ' + books.length);
    const pl = books[0] ? payloadOf(books[0].bookUrl) : null;
    console.log('  载荷 =', JSON.stringify(pl));
    ok(pl && pl.book_id === 'MTgzNTEy',
       '**条目级规则读得到 result.book_id**（载荷里有 book_id）', JSON.stringify(pl));
    ok(pl && pl.tab === '小说', '载荷里的 tab 也在');
  }

  console.log('\n=== 3. 活体（离线）：真实 🍅大灰狼源 ⇒ 载荷必须带 book_id ===');
  {
    const sp = path.join(root, 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');
    ok(fs.existsSync(sp), '仓库里有大灰狼源 JSON');
    const list = JSON.parse(fs.readFileSync(sp, 'utf8'));
    const src = Array.isArray(list) ? list[0] : list;
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 书名 =', books[0] && books[0].name);
    console.log('  bookUrl =', books[0] && String(books[0].bookUrl).slice(0, 90));
    ok(books.length === 1, '出了一本书', '实际 ' + books.length + ' / error: ' + ((r && r.error) || '-'));
    const pl = books[0] ? payloadOf(books[0].bookUrl) : null;
    console.log('  载荷 =', JSON.stringify(pl));
    ok(pl && pl.book_id === 'MTgzNTEy',
       '**大灰狼的 data: 载荷里有 book_id**（站方 init 能解出来）', JSON.stringify(pl));
    ok(pl && pl.sources === '番茄', '载荷里有 sources（站方 init 要读它）', JSON.stringify(pl));
    ok(pl && pl.tab === '小说', '载荷里有 tab', JSON.stringify(pl));
  }

  console.log('\n=== 4. 活体（离线）：页面级 JS 规则 ⇒ result 是【当前页原文】 ===');
  {
    // 站方（🍒NovelHub）从 result 里找 HTML 标记 ⇒ 必须是**源码**，不是纯文本
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: '@js: (function(){ var s = String(result || "");' +
                  ' if (s.indexOf("<") < 0) { return []; }' +
                  ' return ["https://x.example/1|||书名一|||作者一"]; })()',
        name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|[\\s\\S]*$##$1',
        bookUrl: '##^([^|]*)\\|\\|\\|[\\s\\S]*$##$1'
      }
    };
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/htmlpage', page: 1 });
    const books = (r && r.books) || [];
    ok(books.length === 1,
       '**页面级规则拿得到 HTML 源码**（站方正则能匹配上）', '实际 ' + books.length);
  }

  console.log('\n=== 5. 活体（离线）：init 输出级 ⇒ result 是【init 的结果对象】 ===');
  {
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleBookInfo: {
        // init 在页面级跑：result = 当前页原文 ⇒ 解出详情对象
        init: '<js> (function(){ return JSON.parse(String(result)).data; })() </js>',
        name: '$.book_name',
        // tocUrl 在 init 的【输出】上跑：result = 那个对象 ⇒ book_id 要读得到
        tocUrl: '<js> var b = result.book_id; var t = result.tab || "小说";' +
                ' return "data:;base64," + java.base64Encode(JSON.stringify({book_id:b,tab:t})) + ",{}"; </js>'
      }
    };
    const r = await call('bookInfo', {
      source: src, bookUrl: 'https://fake.example.com/detail/1',
      book: { bookUrl: 'https://fake.example.com/detail/1' }
    });
    const b = r && r.book;
    console.log('  详情书名 =', b && b.name, '| tocUrl =', b && String(b.tocUrl).slice(0, 90));
    ok(b && b.name === '终极：我雷婷他哥', '详情书名对（init 跑通了）',
       (r && r.error) || JSON.stringify(b || {}).slice(0, 120));
    const pl = b ? payloadOf(b.tocUrl) : null;
    console.log('  目录载荷 =', JSON.stringify(pl));
    ok(pl && pl.book_id === 'MTgzNTEy',
       '**init 输出级规则读得到 result.book_id**（目录载荷有 book_id）', JSON.stringify(pl));
  }

  console.log('\n=== 6. 端到端（离线）：真实 🍅大灰狼源 ⇒ 发现→详情→目录 全链路 ===');
  {
    // 用**仓库里真实的大灰狼源**跑完整条链：
    //   发现（列表 JSON）→ 站方 bookUrl 规则生成 data: 载荷 → 详情（init 解载荷 → ajax /detail）
    //   → 站方 tocUrl 规则生成目录载荷 → 目录（chapterList 解载荷 → ajax /catalog）
    // ⇒ 判据：**请求 URL 里的 book_id 必须是真值**（真机上是 undefined ⇒ 服务器回 illegal base64）
    const sp2 = path.join(root, 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');
    const src2 = JSON.parse(fs.readFileSync(sp2, 'utf8'))[0];
    const urls = [];
    const nativeMock2 = async (fn, args) => {
      if (fn === 'request') {
        const url = String(args.url || '');
        urls.push(url);
        let body = LIST_JSON;
        if (url.indexOf('/detail') >= 0) body = JSON.stringify({ code: 0, data: {
          book_id: 'MTgzNTEy', book_name: '终极：我雷婷他哥', author: '作者',
          abstract: '简介', thumb_url: 'https://x/c.jpg', source: '番茄', tab: '小说' } });
        else if (url.indexOf('/catalog') >= 0) body = JSON.stringify({ code: 0, data: [
          { title: '第1章 开端', item_id: 'i1', first_pass_time: '2026-10-22 10:00:00', tab: '小说', source: '番茄' },
          { title: '第2章 继续', item_id: 'i2', first_pass_time: '2026-10-22 11:00:00', tab: '小说', source: '番茄' }] });
        return { ok: true, code: 200, url, headers: {}, body };
      }
      if (fn === 'log' || fn === 'toast') return { ok: true };
      return { ok: true, value: '' };
    };
    const sb = createSandbox({ nativeMock: nativeMock2 });
    const w = sb.win;
    const c2 = (op, p) => w.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");

    const e1 = await c2('explore', { source: src2, kindUrl: 'https://fake.example.com/list', page: 1 });
    const bk = (e1.books || [])[0];
    ok(!!bk, '发现页出书了', JSON.stringify(e1).slice(0, 200));

    const e2 = await c2('bookInfo', { source: src2, bookUrl: bk.bookUrl, book: bk });
    console.log('  详情书名 =', e2.book && e2.book.name, '| 作者 =', e2.book && e2.book.author);
    ok(e2.book && e2.book.name === '终极：我雷婷他哥', '详情页解出来了（init 解到了载荷）',
       (e2.error || '') + ' ' + JSON.stringify(e2.book || {}).slice(0, 150));

    const detailUrl = urls.filter(u => u.indexOf('/detail') >= 0)[0] || '';
    console.log('  详情请求 =', detailUrl.slice(0, 130));
    ok(detailUrl.indexOf('book_id=MTgzNTEy') >= 0,
       '**详情请求带上了真的 book_id**（不是 undefined）', detailUrl);
    ok(detailUrl.indexOf('book_id=undefined') < 0,
       '**没有 book_id=undefined**（真机就是这个 ⇒ 服务器回 illegal base64）', detailUrl);

    const e3 = await c2('toc', {
      source: src2, bookUrl: bk.bookUrl, tocUrl: e2.book.tocUrl, book: e2.book, maxPages: 1
    });
    console.log('  章节数 =', (e3.chapters || []).length, '| error =', e3.error || '(无)');
    ok((e3.chapters || []).length === 2, '**目录出 2 章**（真机是 0 章）',
       '实际 ' + (e3.chapters || []).length + ' / ' + (e3.error || ''));
    const catUrl = urls.filter(u => u.indexOf('/catalog') >= 0)[0] || '';
    console.log('  目录请求 =', catUrl.slice(0, 130));
    ok(catUrl.indexOf('book_id=MTgzNTEy') >= 0, '**目录请求带上了真的 book_id**', catUrl);
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
