/* 发现页专项探针：跑真实源的 exploreKinds + explore
   跑法：node test/explore-probe.js */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';

function loadAll() {
  const out = [];
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8'));
      for (const s of (Array.isArray(d) ? d : [d])) {
        // 只要有 exploreUrl 就算 —— ruleExplore 空的源靠回退 ruleSearch 出书
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
  const bySite = new Map();
  for (const s of all) {
    const k = String(s.bookSourceUrl || '').replace(/\/+$/, '');
    if (!bySite.has(k)) bySite.set(k, s);
  }
  const list = [...bySite.values()].slice(0, parseInt(process.argv[2] || '40', 10));
  console.log('待测发现页源 ' + list.length + ' 个\n');

  let kindsOK = 0, listOK = 0;
  const fail = {};
  for (const src of list) {
    const { QR, win } = runner();
    let kinds = [];
    try {
      const r = await win.__qrInvoke('exploreKinds', { source: src });
      kinds = r.kinds || [];
      if (r.error) { fail['kinds:' + r.error.slice(0, 40)] = (fail['kinds:' + r.error.slice(0, 40)] || 0) + 1; continue; }
    } catch (e) { fail['kinds异常'] = (fail['kinds异常'] || 0) + 1; continue; }
    if (!kinds.length) { fail['kinds为空'] = (fail['kinds为空'] || 0) + 1; continue; }
    kindsOK++;

    // 取第一个分类试着出书
    let got = 0;
    for (const k of kinds.slice(0, 2)) {
      try {
        const b = await win.__qrInvoke('explore', { source: src, kindUrl: k.url, page: 1 });
        if ((b.books || []).length) got++;
      } catch (e) { /* 记在下面 */ }
    }
    if (got) listOK++;
    else fail['分类出不了书'] = (fail['分类出不了书'] || 0) + 1;
  }

  console.log('分类解析成功: ' + kindsOK + '/' + list.length);
  console.log('分类能出书  : ' + listOK + '/' + list.length);
  console.log('\n失败分布:');
  Object.entries(fail).sort((a, b) => b[1] - a[1]).slice(0, 10)
    .forEach(([k, v]) => console.log('  ' + String(v).padStart(4) + '  ' + k));

  // 挑一个能出分类的源，打印细节
  for (const src of list.slice(0, 6)) {
    const { QR, win } = runner();
    const r = await win.__qrInvoke('exploreKinds', { source: src });
    if (!r.kinds || !r.kinds.length) continue;
    console.log('\n--- ' + src.bookSourceName + ' ---');
    console.log('  分类数: ' + r.kinds.length + '  首条: ' + JSON.stringify(r.kinds[0]));
    const b = await win.__qrInvoke('explore', { source: src, kindUrl: r.kinds[0].url, page: 1 });
    console.log('  出书: ' + (b.books || []).length + (b.error ? '  err=' + b.error.slice(0, 60) : ''));
    if (b.books && b.books[0]) console.log('  首本: ' + JSON.stringify(b.books[0]).slice(0, 140));
  }
})();
