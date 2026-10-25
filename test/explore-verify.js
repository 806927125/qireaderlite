/* 二次验收：发现页能出书的源，再验一遍「搜索→详情→目录→正文」整条链路，
   只把真能读的全链路可用源留下。
   跑法：node test/explore-verify.js [并发数] */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const IN = process.env.IN || '/workspace/发现可用书源.json';
const OUT = process.env.OUT || '/workspace/发现可用书源-全链路.json';
const LIST = process.env.LIST || '/workspace/发现可用书源-清单.json';
const CONC = parseInt(process.argv[2] || '6', 10);
const TIMEOUT = 12000;

let WIN = null;
function win() {
  if (WIN) return WIN;
  const { win: w } = createSandbox();
  w.webkit.messageHandlers.qr.postMessage = function (m) {
    if (m.fn === 'request') {
      fetch(m.args.url, {
        method: m.args.method || 'GET', headers: m.args.headers || {},
        body: m.args.body || undefined, redirect: 'follow',
        signal: AbortSignal.timeout(TIMEOUT)
      }).then(async (r) => ({
        ok: true, code: r.status, url: r.url,
        headers: Object.fromEntries(r.headers), body: await r.text()
      })).catch((e) => ({ ok: false, error: String(e.message || e) }))
        .then((v) => w.__qrResolve(m.id, v));
      return;
    }
    Promise.resolve({ ok: true, value: '' }).then((v) => w.__qrResolve(m.id, v));
  };
  WIN = w;
  return w;
}

async function full(src, keyword) {
  const w = win();
  const r = {};

  const s = await w.__qrInvoke('search', { source: src, keyword: keyword, page: 1 });
  r.search = (s.books || []).length;
  r.searchErr = s.error || '';
  if (!r.search) {
    const e = String(s.error || '');
    if (/没有搜索规则/.test(e)) return { ok: false, why: '本源没有搜索规则(只有发现)', r };
    if (/URL 生成失败/.test(e)) return { ok: false, why: '搜索URL生成失败', r };
    return { ok: false, why: '搜不到', r };
  }
  // 书名得是真书名：不能全都是同一个（多半匹配到了导航/分类）
  const names = (s.books || []).slice(0, 5).map(x => String(x.name || '').trim());
  if (new Set(names).size < Math.min(2, names.length)) return { ok: false, why: '书名重复(规则没对上)', r };
  if (names.some(n => !n || n.length > 40 || /^(result|玄幻|仙侠|都市|言情|历史|返回|更多|title)$/i.test(n)))
    return { ok: false, why: '书名是脏数据', r };

  // 详情
  const b0 = s.books[0];
  const info = await w.__qrInvoke('bookInfo', { source: src, bookUrl: b0.bookUrl, book: { name: b0.name } });
  r.detail = !!(info.book && info.book.name);
  if (!r.detail) return { ok: false, why: '详情解析不出书名', r };

  // 目录
  const t = await w.__qrInvoke('toc', {
    source: src, bookUrl: b0.bookUrl, tocUrl: (info.book || {}).tocUrl || b0.bookUrl, maxPages: 3
  });
  r.toc = (t.chapters || []).length;
  if (!r.toc) return { ok: false, why: '目录为空', r };

  // 正文
  const c = await w.__qrInvoke('content', { source: src, chapterUrl: t.chapters[0].url });
  r.content = (c.content || '').replace(/\s/g, '').length;
  if (!r.content) return { ok: false, why: '正文为空', r };

  return { ok: true, r, name: info.book.name, chapter: t.chapters[0].title, len: r.content };
}

(async () => {
  const list = JSON.parse(fs.readFileSync(IN, 'utf8'));
  const detail = JSON.parse(fs.readFileSync(LIST, 'utf8'));
  const kw = {};
  detail.forEach(d => { kw[d.url] = (d.sample && d.sample[0]) || ''; });
  console.log('待验收 ' + list.length + ' 个源\n');

  const good = [], stat = {};
  const queue = list.slice();
  let done = 0;
  const t0 = Date.now();

  async function worker() {
    while (queue.length) {
      const src = queue.shift();
      let res;
      try {
        // 某些源的请求不返回，必须硬超时，否则整个验收卡死
        res = await Promise.race([
          full(src, kw[src.bookSourceUrl] || '斗破'),
          new Promise(r => setTimeout(() => r({ ok: false, why: '超时' }), 30000))
        ]);
      } catch (e) { res = { ok: false, why: '异常' }; }
      done++;
      const k = res.ok ? '全链路OK' : res.why;
      stat[k] = (stat[k] || 0) + 1;
      if (res.ok) {
        good.push(src);
        console.log(`  ✓ ${src.bookSourceName} (${src.bookSourceUrl})  搜索${res.r.search} 目录${res.r.toc} 正文${res.r.len}字  《${res.name}》`);
      }
      if (done % 20 === 0) console.log(`  … ${done}/${list.length}  用时 ${Math.round((Date.now() - t0) / 1000)}s  通过 ${good.length}`);
    }
  }
  await Promise.all(Array.from({ length: CONC }, worker));

  console.log('\n===== 验收结果 =====');
  Object.entries(stat).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${String(v).padStart(4)}  ${k}`));
  console.log(`\n全链路可用: ${good.length}/${list.length}`);

  fs.writeFileSync(OUT, JSON.stringify(good, null, 2), 'utf8');
  console.log(`→ ${OUT}`);

  const d2 = good.map(g => {
    const d = detail.find(x => x.url === g.bookSourceUrl) || {};
    return { name: g.bookSourceName, url: g.bookSourceUrl, kinds: d.kinds, books: d.books, sample: d.sample };
  });
  fs.writeFileSync('/workspace/发现可用书源-全链路清单.json', JSON.stringify(d2, null, 2), 'utf8');
  console.log('→ /workspace/发现可用书源-全链路清单.json');
})();
