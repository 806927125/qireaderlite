/* 发现页真站实测：指定几个源，跑 exploreKinds + explore，看能不能真出书
 *   跑法：node test/explore-live.js
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';
const WANT = process.env.WANT
  ? process.env.WANT.split(',')
  : ['xuanhuange.net', 'xs5.la', '35xss.com', 'xiaoshuowu.com', 'xuanyge.com', 'xhwx3.com', 'xuankuge.com'];

function loadAll() {
  const out = [];
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8'));
      for (const s of (Array.isArray(d) ? d : [d])) {
        if (s && typeof s === 'object' && s.exploreUrl) out.push(s);
      }
    } catch (e) { /* 跳过 */ }
  }
  return out;
}

function runner() {
  const { QR, win } = createSandbox();
  const reqs = [];
  win.webkit.messageHandlers.qr.postMessage = function (m) {
    if (m.fn === 'request') {
      reqs.push(m.args.url);
      fetch(m.args.url, {
        method: m.args.method || 'GET', headers: m.args.headers || {},
        body: m.args.body || undefined, redirect: 'follow',
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
  return { QR, win, reqs };
}

(async () => {
  const all = loadAll();
  const picked = all.filter((s) => WANT.some((w) => String(s.bookSourceUrl || '').includes(w)));
  // 同一个站只留第一个
  const seen = new Set(); const list = [];
  for (const s of picked) {
    const k = String(s.bookSourceUrl || '').replace(/\/+$/, '');
    if (seen.has(k)) continue;
    seen.add(k); list.push(s);
  }
  console.log('待测 ' + list.length + ' 个站\n');

  let ok = 0;
  for (const src of list) {
    const { win, reqs } = runner();
    const head = `${src.bookSourceName} (${src.bookSourceUrl})`;
    try {
      const kr = await win.__qrInvoke('exploreKinds', { source: src });
      if (kr.error) { console.log(`✗ ${head}\n    分类失败: ${kr.error.slice(0, 90)}`); continue; }
      if (!kr.kinds.length) { console.log(`✗ ${head}\n    没解析出分类`); continue; }
      let best = null;
      for (const k of kr.kinds.slice(0, 3)) {
        const b = await win.__qrInvoke('explore', { source: src, kindUrl: k.url, page: 1 });
        const n = (b.books || []).length;
        if (n > 0) { best = { k, n, b, req: reqs[reqs.length - 1] }; break; }
      }
      if (!best) {
        console.log(`✗ ${head}\n    分类 ${kr.kinds.length} 个，但取不到书（请求 ${reqs[reqs.length - 1] || '无'}）`);
        continue;
      }
      ok++;
      console.log(`✓ ${head}`);
      console.log(`    分类 ${kr.kinds.length} 个，首个「${kr.kinds[0].title}」→ ${best.k.title}`);
      console.log(`    出书 ${best.n} 本，请求 ${best.req}`);
      console.log(`    首本: ${JSON.stringify(best.b.books[0]).slice(0, 200)}`);
    } catch (e) {
      console.log(`✗ ${head}\n    异常: ${String(e.message || e).slice(0, 100)}`);
    }
  }
  console.log(`\n真站能出书的: ${ok}/${list.length}`);
})();
