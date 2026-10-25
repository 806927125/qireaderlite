/* 用真实站点验证书源：直接调引擎的 search，看能不能出书
   跑法：node test/real-sources.js */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';

// 挑出来的候选：覆盖不同规则风格
const WANT = [
  '话本小说', '17K 小说', '168小说天堂', '七猫小说', '追书神器',
  '食在广州书网', '快书读', '优四小说网', '就爱文学', '番茄小说'
];

function loadAll() {
  const out = [];
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8'));
      for (const s of (Array.isArray(d) ? d : [d])) {
        if (s && typeof s === 'object' && s.ruleSearch) out.push(s);
      }
    } catch (e) { /* 跳过 */ }
  }
  return out;
}

/** 引擎里跑一次真实搜索 */
function makeRunner() {
  const { QR, win } = createSandbox();
  const log = [];
  win.webkit.messageHandlers.qr.postMessage = function (m) {
    if (m.fn === 'request') {
      const { url, method, headers, body } = m.args;
      log.push({ url, method });
      fetch(url, {
        method: method || 'GET',
        headers: headers || {},
        body: body || undefined,
        redirect: 'follow',
        signal: AbortSignal.timeout(15000)
      }).then(async (r) => ({
        ok: true, code: r.status, url: r.url, headers: Object.fromEntries(r.headers),
        body: await r.text()
      })).catch((e) => ({ ok: false, error: String(e.message || e) }))
        .then((v) => win.__qrResolve(m.id, v));
      return;
    }
    Promise.resolve({ ok: true, value: '' }).then((v) => win.__qrResolve(m.id, v));
  };
  return { QR, win, log };
}

(async () => {
  const all = loadAll();
  const picked = [];
  for (const w of WANT) {
    const hit = all.find((s) => String(s.bookSourceName || '').includes(w));
    if (hit && !picked.some((p) => p.bookSourceUrl === hit.bookSourceUrl)) picked.push(hit);
  }
  console.log('待测书源: ' + picked.map((p) => p.bookSourceName).join(' / ') + '\n');

  for (const src of picked) {
    const { QR, win, log } = makeRunner();
    const t0 = Date.now();
    let res;
    try {
      res = await win.__qrInvoke('search', { source: src, keyword: '斗破苍穹', page: 1 });
    } catch (e) {
      res = { books: [], error: String(e.message || e) };
    }
    const ms = Date.now() - t0;
    const n = (res.books || []).length;
    const first = n ? res.books[0] : null;
    const firstReq = log[0] || {};
    console.log(
      (n ? '✓' : '✗') + ' ' + String(src.bookSourceName).padEnd(16) +
      ' 书=' + String(n).padStart(3) +
      '  ' + String(ms) + 'ms' +
      (res.error ? '  err=' + String(res.error).slice(0, 60) : '') +
      (first ? '  首条=' + JSON.stringify(first.name).slice(0, 24) : '')
    );
    if (n) {
      console.log('    请求: ' + String(firstReq.method || 'GET') + ' ' + String(firstReq.url).slice(0, 90));
    }
  }
})();
