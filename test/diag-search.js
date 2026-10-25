/* 快速诊断：某个源的搜索为什么搜不到 */
const fs = require('fs');
const { createSandbox } = require('./new-engine-harness');

const list = JSON.parse(fs.readFileSync('/workspace/发现可用书源.json', 'utf8'));
const det = JSON.parse(fs.readFileSync('/workspace/发现可用书源-清单.json', 'utf8'));

const { win } = createSandbox();
win.webkit.messageHandlers.qr.postMessage = function (m) {
  if (m.fn === 'request') {
    console.log('   → 请求', m.args.url);
    fetch(m.args.url, {
      method: m.args.method || 'GET', headers: m.args.headers || {},
      body: m.args.body || undefined, redirect: 'follow',
      signal: AbortSignal.timeout(10000)
    }).then(async (r) => ({
      ok: true, code: r.status, url: r.url,
      headers: Object.fromEntries(r.headers), body: await r.text()
    })).catch((e) => ({ ok: false, error: String(e.message || e) }))
      .then((v) => win.__qrResolve(m.id, v));
    return;
  }
  Promise.resolve({ ok: true, value: '' }).then((v) => win.__qrResolve(m.id, v));
};

(async () => {
  const N = parseInt(process.argv[2] || '4', 10);
  for (const s of list.slice(0, N)) {
    const d = det.find((x) => x.url === s.bookSourceUrl);
    console.log('==', s.bookSourceName, s.bookSourceUrl,
      '| searchUrl:', s.searchUrl ? String(s.searchUrl).slice(0, 80) : '(无)',
      '| 规则里 searchUrl:', (s.ruleSearch || {}).searchUrl ? '有' : '无');
    const r = await win.__qrInvoke('search', { source: s, keyword: (d && d.sample && d.sample[0]) || '斗破', page: 1 });
    console.log('   books=', (r.books || []).length, 'err=', r.error);
  }
})();
