/* 最终体检表：对每个「发现页能出书」的源，记录 发现/搜索/目录/正文 四项是否通，
   顺手产出可导入的书源文件。
   跑法：node test/explore-final.js */
const fs = require('fs');
const { createSandbox } = require('./harness');

const IN = '/workspace/发现可用书源.json';
const OUT = '/workspace/发现可用书源.json';
const TABLE = '/workspace/发现可用书源-体检表.json';
const TIMEOUT = 12000;

const list = JSON.parse(fs.readFileSync(IN, 'utf8'));
const det = JSON.parse(fs.readFileSync('/workspace/发现可用书源-清单.json', 'utf8'));
const kw = {};
det.forEach((d) => { kw[d.url] = (d.sample && d.sample[0]) || ''; });

const { win } = createSandbox();
let last = null;
win.webkit.messageHandlers.qr.postMessage = function (m) {
  if (m.fn === 'request') {
    last = { url: m.args.url, code: 0, err: '' };
    fetch(m.args.url, {
      method: m.args.method || 'GET', headers: m.args.headers || {},
      body: m.args.body || undefined, redirect: 'follow',
      signal: AbortSignal.timeout(TIMEOUT)
    }).then(async (r) => {
      last.code = r.status;
      return { ok: true, code: r.status, url: r.url, headers: Object.fromEntries(r.headers), body: await r.text() };
    }).catch((e) => { last.err = String(e.message || e); return { ok: false, error: last.err }; })
      .then((v) => win.__qrResolve(m.id, v));
    return;
  }
  Promise.resolve({ ok: true, value: '' }).then((v) => win.__qrResolve(m.id, v));
};

async function probe(src) {
  const row = { name: src.bookSourceName, url: src.bookSourceUrl, discover: 0, search: 0, toc: 0, content: 0, note: '' };
  // 发现
  const k = await win.__qrInvoke('exploreKinds', { source: src });
  if (k.error || !k.kinds || !k.kinds.length) { row.note = '分类失败'; return row; }
  row.kinds = k.kinds.length;
  for (const kd of k.kinds.slice(0, 4)) {
    if (!kd.url) continue;
    const b = await win.__qrInvoke('explore', { source: src, kindUrl: kd.url, page: 1 });
    if ((b.books || []).length) { row.discover = b.books.length; row.sample = b.books.slice(0, 2).map((x) => x.name); break; }
  }
  if (!row.discover) { row.note = '发现取不到书'; return row; }
  // 搜索
  const s = await win.__qrInvoke('search', { source: src, keyword: kw[src.bookSourceUrl] || '斗破', page: 1 });
  row.search = (s.books || []).length;
  if (!row.search) {
    row.note = !s.error ? '该源没配搜索规则' : ('搜索失败: ' + String(s.error).slice(0, 30));
    return row;
  }
  const b0 = s.books[0];
  const info = await win.__qrInvoke('bookInfo', { source: src, bookUrl: b0.bookUrl, book: { name: b0.name } });
  if (!info.book || !info.book.name) { row.note = '详情解析不出书名'; return row; }
  row.detail = info.book.name;
  const t = await win.__qrInvoke('toc', {
    source: src, bookUrl: b0.bookUrl, tocUrl: (info.book || {}).tocUrl || b0.bookUrl, maxPages: 3
  });
  row.toc = (t.chapters || []).length;
  if (!row.toc) { row.note = '目录为空'; return row; }
  const c = await win.__qrInvoke('content', { source: src, chapterUrl: t.chapters[0].url });
  row.content = (c.content || '').replace(/\s/g, '').length;
  if (!row.content) { row.note = '正文为空'; return row; }
  row.note = '全通';
  return row;
}

(async () => {
  const rows = [];
  for (const s of list) {
    let r;
    try {
      r = await Promise.race([
        probe(s),
        new Promise((x) => setTimeout(() => x({ name: s.bookSourceName, url: s.bookSourceUrl, discover: 0, search: 0, toc: 0, content: 0, note: '超时' }), 45000))
      ]);
    } catch (e) { r = { name: s.bookSourceName, url: s.bookSourceUrl, discover: 0, search: 0, toc: 0, content: 0, note: '异常' }; }
    rows.push(r);
    console.log(`${r.note === '全通' ? '✓' : '·'} ${r.name} — 发现${r.discover} 搜索${r.search} 目录${r.toc} 正文${r.content} ${r.note}`);
  }
  const st = {};
  rows.forEach((r) => { st[r.note] = (st[r.note] || 0) + 1; });
  console.log('\n=== 汇总 ===');
  Object.entries(st).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${String(v).padStart(3)}  ${k}`));
  fs.writeFileSync(OUT, JSON.stringify(list, null, 2), 'utf8');
  fs.writeFileSync(TABLE, JSON.stringify(rows, null, 2), 'utf8');
  console.log(`\n书源文件 → ${OUT}\n体检表 → ${TABLE}`);
})();
