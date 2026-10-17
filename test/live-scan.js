/* 批量实测：把语料里的书源逐个拿真站试，看哪些现在还能出书
   跑法：node test/live-scan.js [并发数] */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';
const CONC = parseInt(process.argv[2] || '6', 10);
const LIMIT = parseInt(process.argv[3] || '120', 10);
const OFFSET = parseInt(process.argv[4] || '0', 10);

function loadAll() {
  const out = [];
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8'));
      for (const s of (Array.isArray(d) ? d : [d])) {
        if (s && typeof s === 'object' && s.ruleSearch && s.ruleToc && s.ruleContent
            && !s.loginUrl) out.push(s);
      }
    } catch (e) { /* 跳过 */ }
  }
  return out;
}

/** 每个源一个独立沙盒，避免状态串味 */
async function trySource(src) {
  const { QR, win } = createSandbox();
  win.webkit.messageHandlers.qr.postMessage = function (m) {
    if (m.fn === 'request') {
      const { url, method, headers, body } = m.args;
      fetch(url, {
        method: method || 'GET',
        headers: headers || {},
        body: body || undefined,
        redirect: 'follow',
        signal: AbortSignal.timeout(15000)
      }).then(async (r) => ({
        ok: true, code: r.status, url: r.url,
        headers: Object.fromEntries(r.headers), body: await r.text()
      })).catch((e) => ({ ok: false, error: String(e.message || e) }))
        .then((v) => win.__qrResolve(m.id, v));
      return;
    }
    Promise.resolve({ ok: true, value: '' }).then((v) => win.__qrResolve(m.id, v));
  };
  const t0 = Date.now();
  try {
    const r = await win.__qrInvoke('search', { source: src, keyword: '斗破苍穹', page: 1 });
    const books = r.books || [];
    if (!books.length) return { ok: false, why: r.error || '无结果', src };
    const b = books[0];
    // 名字像章节名的基本是解析错位
    const junk = ['搜索', '作品名称', '更多', '首页', '下一', '上一', 'book', 'novel'];
    const nameBad = !b.name || b.name.length < 2 || junk.some((j) => b.name.trim() === j)
      || /^[\s0-9零〇一二三四五六七八九十百千万]*$/.test(b.name)
      || /^\s*第[\s0-9零〇一二三四五六七八九十百千万]*[章节回卷话集篇]/.test(b.name)
      || /[\uFFFD]/.test(b.name);
    return { ok: !nameBad, n: books.length, src, first: b, ms: Date.now() - t0 };
  } catch (e) {
    return { ok: false, why: String(e.message || e), src };
  }
}

(async () => {
  const all = loadAll();
  // 先按站点去重，同一站只测一个源，省时间
  const bySite = new Map();
  for (const s of all) {
    const k = String(s.bookSourceUrl || '').replace(/\/+$/, '');
    if (!bySite.has(k)) bySite.set(k, s);
  }
  const list = [...bySite.values()].slice(OFFSET, OFFSET + LIMIT);
  console.log('待测站点 ' + list.length + ' 个，并发 ' + CONC + '\n');

  const good = [], bad = [];
  let idx = 0;
  async function worker() {
    while (idx < list.length) {
      const s = list[idx++];
      const r = await trySource(s);
      (r.ok ? good : bad).push(r);
      process.stdout.write(r.ok ? '.' : 'x');
    }
  }
  await Promise.all(Array.from({ length: CONC }, worker));
  process.stdout.write('\n\n');

  good.sort((a, b) => (b.first?.name || '').length - (a.first?.name || '').length);
  console.log('===== 能出书且书名正常的 (' + good.length + ') =====');
  for (const g of good) {
    console.log('  ' + String(g.src.bookSourceName).padEnd(22) +
      String(g.n).padStart(4) + ' 本  ' + JSON.stringify(g.first.name).slice(0, 26) +
      '  ' + String(g.first.author || '').slice(0, 12));
  }
  console.log('\n===== 失败分布 (前 12 类原因) =====');
  const reasons = {};
  for (const b of bad) {
    const k = String(b.why).replace(/https?:\/\/\S+/, 'URL').slice(0, 60);
    reasons[k] = (reasons[k] || 0) + 1;
  }
  Object.entries(reasons).sort((a, b) => b[1] - a[1]).slice(0, 12)
    .forEach(([k, v]) => console.log('  ' + String(v).padStart(4) + '  ' + k));
  fs.writeFileSync('/tmp/live-good.json', JSON.stringify(good.map((g) => g.src), null, 1));
  console.log('\n可用的源已存到 /tmp/live-good.json');
})();
