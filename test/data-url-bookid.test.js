#!/usr/bin/env node
/**
 * **data: 载荷里缺 book_id ⇒ 宿主要能补上**（2026-10-22 真机「book_id=undefined」）
 *
 * 聚合源（🍅大灰狼）的 bookUrl/tocUrl 是 `data:;base64,<载荷>,{…}`，
 * 载荷里本来该有 book_id/source/tab，站方 init 直接从**载荷**里解构：
 *     let { book_id, source: sources, tab, … } = JSON.parse(java.hexDecodeToString(result));
 * 但载荷里只有 {tab,url} ⇒ book_id=undefined ⇒ 详情/目录请求全废（服务器回 illegal base64）
 * ⇒ 宿主手里**有** book_id（列表接口返回的原始字段）⇒ 补进载荷再重编 ✅
 */
const path = require('path');
const { createSandbox } = require('./harness');
let pass = 0, fail = 0;
const ok = (c, m, e) => { if (c) { pass++; console.log('  ✓ ' + m); } else { fail++; console.log('  x ' + m + (e ? ' — ' + e : '')); } };
(async () => {
  const nativeMock = async (fn) => {
    if (fn === 'request') return { ok: true, code: 200, url: '', headers: {}, body: '<html>x</html>' };
    if (fn === 'log' || fn === 'toast') return { ok: true };
    return { ok: true, value: '' };
  };
  const { win } = createSandbox({ nativeMock });
  const call = (op, p) => win.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");
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
  console.log('=== 载荷缺 book_id ⇒ 宿主补上 ⇒ 目录出章节 ===');
  const r1 = await call('toc', { source: src, bookUrl: 'https://x/1', tocUrl: dataUrl, book: { bookUrl: 'https://x/1' } });
  ok((r1.chapters || []).length === 0, '没有 book_id ⇒ 0 章（站方解不出来）');
  const r2 = await call('toc', { source: src, bookUrl: 'https://x/1', tocUrl: dataUrl,
    book: { bookUrl: 'https://x/1', book_id: 'MTgzNTEy', source: '番茄', tab: '小说' } });
  console.log('  章节数 =', (r2.chapters || []).length, JSON.stringify((r2.chapters || [])[0] || {}).slice(0, 120));
  ok((r2.chapters || []).length === 1, '**宿主把 book_id 补进载荷 ⇒ 目录出来了**');
  ok(!!(r2.chapters[0] && r2.chapters[0].title), '章节名对');
  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
