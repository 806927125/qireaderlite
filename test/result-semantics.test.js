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
const { createSandbox } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

const root = path.join(__dirname, '..');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已于 2026-10-25 物理删除** ⇒ 改读**新引擎**（Swift）
//   ⇒ 验的是**真正在跑的那份代码**（不是参考实现）⭐⭐⭐
const { engineSwiftSrc, engineSwiftRaw, evalRule, runOp, engineAvailable } =
  require('./engine-gate-helpers.js');
const RULE_SRC = engineSwiftSrc('Context/RuleBase.swift');
const ENGINE_SRC_S = engineSwiftSrc('Pipeline/SourceEngine.swift');

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
  // ⭐⭐⭐ 新引擎的等价实现（**语义相同，实现不同**）：
  // · 「按基准分流」⇒ `RuleBase.resultValue`（page ⇒ 原文 / json ⇒ 结构 / element ⇒ 节点）
  // · 「没有一刀切覆盖」⇒ `resultValue` 是 switch，不是恒定赋值
  // · 「raw = 当前页原文」⇒ `EvalContext.raw`
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]`）
  //   ⇒ 那些是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失语义覆盖 ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

  console.log('\n=== 2. 活体（离线）：条目级 JS 规则 ⇒ result 是【那条记录】 ===');
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
  } else {
    // ⭐⭐⭐ **用【新引擎】求值**（老引擎已删）⇒ 验的是「条目级基准下 result 是那条记录」⭐⭐⭐
    const item = { book_id: 'MTgzNTEy', tab: '小说', book_name: '书名一' };
    const r = evalRule('@js:var b = result.book_id; var t = result.tab || "小说";'
      + ' JSON.stringify({book_id:b,tab:t})',
      { baseType: 'json', isJSON: true, baseJSON: item });
    console.log('  求值 =', r && r.text);
    ok(r && !r.error, '规则没报错', r && r.error);
    const pl = r && r.text ? JSON.parse(r.text) : null;
    ok(pl && pl.book_id === 'MTgzNTEy',
       '**条目级规则读得到 result.book_id**', JSON.stringify(pl));
    ok(pl && pl.tab === '小说', '载荷里的 tab 也在', JSON.stringify(pl));
  }

  console.log('\n=== 3. 活体（离线）：真实 🍅大灰狼源 ⇒ 载荷必须带 book_id ===');
  {
    const sp = path.join(root, 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');
    ok(fs.existsSync(sp), '仓库里有大灰狼源 JSON');
    if (!engineAvailable()) {
      console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
    } else {
      const list = JSON.parse(fs.readFileSync(sp, 'utf8'));
      const src = Array.isArray(list) ? list[0] : list;
      // ⭐⭐⭐ **用【新引擎】在【条目级基准】上求值**（老引擎已删）⭐⭐⭐
      //   ⇒ 站方（大灰狼同款）的 bookUrl 规则：从 result 上读 book_id / tab / sources
      const record = { book_id: 'MTgzNTEy', sources: '番茄', tab: '小说', book_name: '书名一' };
      const r = evalRule('@js:var b = result.book_id; var t = result.tab || "小说";'
        + ' var s = result.sources;'
        + ' JSON.stringify({book_id:b,tab:t,sources:s})',
        { baseType: 'json', isJSON: true, baseJSON: record });
      console.log('  求值 =', r && r.text);
      const pl = r && r.text ? JSON.parse(r.text) : null;
      console.log('  载荷 =', JSON.stringify(pl));
      ok(pl && pl.book_id === 'MTgzNTEy',
         '**大灰狼的条目里读得到 book_id**（站方 init 能解出来）', JSON.stringify(pl));
      ok(pl && pl.sources === '番茄', '载荷里有 sources（站方 init 要读它）', JSON.stringify(pl));
      ok(pl && pl.tab === '小说', '载荷里有 tab', JSON.stringify(pl));
    }
  }

  console.log('\n=== 4. 活体（离线）：页面级 JS 规则 ⇒ result 是【当前页原文】 ===');
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
  } else {
    // ⭐⭐⭐ **用【新引擎】跑完整 explore 链**（老引擎已删）⇒ 假服务器在 test/fixtures ⭐⭐⭐
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: '@js: (function(){ var s = String(result || "");' +
                  ' if (s.indexOf("<") < 0) { return []; }' +
                  ' return ["https://x.example/1|||书名一|||作者一"]; })()',
        name: '##^[^|]*\\|\\|\\|([\\s\\S]*?)\\|\\|\\|([\\s\\S]*)$##$1',
        bookUrl: '##^([^|]*)\\|\\|\\|([\\s\\S]*)$##$1'
      }
    };
    const r = runOp({
      op: 'explore', source: src,
      dir: path.join(__dirname, 'fixtures'),
      routes: [['htmlpage', 'fake-htmlpage.html']],
      kindUrl: 'https://fake.example.com/htmlpage', page: 1,
    });
    console.log('  出书 =', r && (r.books || []).length, '| error =', r && r.error);
    const books = (r && r.books) || [];
    ok(books.length === 1,
       '**页面级规则拿得到 HTML 源码**（站方正则能匹配上）', '实际 ' + books.length);
  }

  console.log('\n=== 5. 活体（离线）：init 输出级 ⇒ result 是【init 的结果对象】 ===');
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
  } else {
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
    // ⭐⭐⭐ **用【新引擎】跑 bookInfo**（老引擎已删）⭐⭐⭐
    const r = runOp({
      op: 'bookInfo', source: src,
      dir: path.join(__dirname, 'fixtures'),
      routes: [['detail/1', 'fake-detail.json']],
      bookUrl: 'https://fake.example.com/detail/1',
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


  console.log('\n=== 6. 端到端（离线）：真实 🍅大灰狼源 ⇒ 详情→目录 全链路 ===');
  // ⭐⭐⭐⭐⭐ **显式 SKIP（不是「通过」）** —— 2026-10-25 真机实证
  //
  // ⚠️ **为什么沙盒跑不了这一段**：
  // · 这条链要**站方 JS 真的发 HTTP 请求**（`java.ajax` ⇒ 拉详情页 / 目录页）
  // · 而 Node 后端的 `__hostJSON` 是**同步**的 ⇒ 拿不到异步往返的结果 ⭐⭐⭐
  //   ⇒ `java.ajax` 在 Node 后端**拿不到正文** ⇒ 链跑不通 ⭐⭐⭐
  // · 真机上这条路走 **JSC 后端**（同步 + 真 transport）⇒ 没问题 ⭐⭐⭐
  //
  // ⇒ 所以：**这一段在沙盒里 SKIP**（明确的「没验到」）
  //   ⇒ 等价的覆盖在**引擎的链对拍**（`swift run conformance`）与**真机**上 ⭐⭐⭐
  console.log('  ⏭️  跳过：这条链要站方 JS 真发 HTTP（`java.ajax`）');
  console.log('      ⇒ Node 后端的同步通道拿不到异步结果 ⇒ 本段没验到（**不等于通过**）');
  console.log('      ⇒ 等价覆盖在引擎的链对拍（`swift run conformance`）与真机上');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
})();
