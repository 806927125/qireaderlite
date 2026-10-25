/* 发现页批量实测：把语料里所有带 exploreUrl 的源真跑一遍，
   挑出「发现页真能出书」的源，导出成能直接导入的书源文件。
   跑法：node test/explore-sweep.js [并发数] [上限] */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';
const CONC = parseInt(process.argv[2] || '12', 10);
const LIMIT = parseInt(process.argv[3] || '99999', 10);
const OUT = process.env.OUT || '/workspace/发现可用书源.json';
const TIMEOUT = 11000;

/* 垃圾书名：规则没对上时会解析出这种东西 */
const JUNK = /^(title|返回|浏览|更多|首页|下一[页章]|上一[页章]|无|空|null|undefined|点击|书名|名称)$/i;

function loadAll() {
  const out = [], seen = new Set();
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
    let d;
    try { d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8')); } catch (e) { continue; }
    for (const s of (Array.isArray(d) ? d : [d])) {
      if (!s || typeof s !== 'object') continue;
      if (!s.exploreUrl) continue;
      if (s.loginUrl) continue;                       // 要登录的用不了
      const key = String(s.bookSourceUrl || '').replace(/\/+$/, '');
      if (!key || seen.has(key)) continue;
      seen.add(key);
      out.push(s);
    }
  }
  return out;
}

/* 一个沙盒复用到底：每个源都新建 jsdom 太慢 */
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

async function test(src) {
  const w = win();
  const r = await w.__qrInvoke('exploreKinds', { source: src });
  if (r.error || !r.kinds || !r.kinds.length) return { ok: false, why: '分类失败' };
  let best = null, tried = 0;
  for (const k of r.kinds.slice(0, 4)) {
    if (!k.url) continue;
    tried++;
    const b = await w.__qrInvoke('explore', { source: src, kindUrl: k.url, page: 1 });
    const books = (b && b.books) || [];
    if (!books.length) continue;
    // 书名不垃圾才算真的通了
    const good = books.filter(x => x.name && !JUNK.test(String(x.name).trim()));
    if (!good.length) continue;
    if (!best || books.length > best.n) best = { n: books.length, k, b };
    if (best.n >= 3) break;                 // 出几本就够验了，别浪费时间
  }
  if (!best) return { ok: false, why: tried ? '分类出不了书' : '分类URL为空', kinds: r.kinds.length };
  return { ok: true, kinds: r.kinds.length, n: best.n, sample: best.b.books.slice(0, 2) };
}

(async () => {
  const all = loadAll();
  console.log('带发现规则的源 ' + all.length + ' 个（已按站去重、排除要登录的）');
  const list = all.slice(0, LIMIT);
  const good = [];
  const stat = {};
  let done = 0;
  const t0 = Date.now();

  async function worker() {
    while (queue.length) {
      const src = queue.shift();
      let res;
      try { res = await test(src); } catch (e) { res = { ok: false, why: '异常' }; }
      done++;
      stat[res.ok ? 'OK' : res.why] = (stat[res.ok ? 'OK' : res.why] || 0) + 1;
      if (res.ok) {
        good.push({ src, res });
        console.log(`  ✓ ${src.bookSourceName} (${src.bookSourceUrl})  分类${res.kinds} 出书${res.n} 本  例: ${res.sample.map(b => b.name).join(' / ')}`);
      }
      if (done % 50 === 0) console.log(`  … ${done}/${list.length}  用时 ${Math.round((Date.now() - t0) / 1000)}s  可用 ${good.length}`);
    }
  }
  const queue = list.slice();
  await Promise.all(Array.from({ length: CONC }, worker));

  console.log('\n===== 结果 =====');
  Object.entries(stat).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${String(v).padStart(5)}  ${k}`));
  console.log(`\n发现页真能出书: ${good.length}/${list.length}`);

  /* 导出：直接是能导入的书源数组 */
  const out = good.map(g => g.src);
  fs.writeFileSync(OUT, JSON.stringify(out, null, 2), 'utf8');
  console.log(`已导出 ${out.length} 个源 → ${OUT}`);

  const detail = good.map(g => ({
    name: g.src.bookSourceName, url: g.src.bookSourceUrl,
    kinds: g.res.kinds, books: g.res.n, sample: g.res.sample.map(b => b.name)
  }));
  fs.writeFileSync('/workspace/发现可用书源-清单.json', JSON.stringify(detail, null, 2), 'utf8');
  console.log('清单 → /workspace/发现可用书源-清单.json');
})();
