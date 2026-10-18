/* 诊断：发现能出书、但搜索搜不到的源，到底是引擎没匹配还是站方挡了 */
const fs = require('fs');
const { createSandbox } = require('./harness');

const list = JSON.parse(fs.readFileSync('/workspace/发现可用书源.json', 'utf8'));
const det = JSON.parse(fs.readFileSync('/workspace/发现可用书源-清单.json', 'utf8'));

const { win } = createSandbox();
let last = null;
win.webkit.messageHandlers.qr.postMessage = function (m) {
  if (m.fn === 'request') {
    last = { url: m.args.url, body: '', code: 0, err: '' };
    fetch(m.args.url, {
      method: m.args.method || 'GET', headers: m.args.headers || {},
      body: m.args.body || undefined, redirect: 'follow',
      signal: AbortSignal.timeout(10000)
    }).then(async (r) => {
      last.code = r.status;
      last.body = await r.text();
      return { ok: true, code: r.status, url: r.url, headers: Object.fromEntries(r.headers), body: last.body };
    }).catch((e) => {
      last.err = String(e.message || e);
      return { ok: false, error: last.err };
    }).then((v) => win.__qrResolve(m.id, v));
    return;
  }
  Promise.resolve({ ok: true, value: '' }).then((v) => win.__qrResolve(m.id, v));
};

(async () => {
  const stat = {};
  const samples = [];
  for (const s of list) {
    const d = det.find((x) => x.url === s.bookSourceUrl);
    const kw = (d && d.sample && d.sample[0]) || '斗破';
    last = null;
    let r;
    try { r = await win.__qrInvoke('search', { source: s, keyword: kw, page: 1 }); }
    catch (e) { r = { books: [], error: '异常' }; }
    const n = (r.books || []).length;
    if (n) { stat['搜到'] = (stat['搜到'] || 0) + 1; continue; }
    let why;
    if (!last) why = '没发请求';
    else if (last.err) why = '网络错误';
    else if (last.code !== 200) why = 'HTTP ' + last.code;
    else if (last.body.indexOf(kw) >= 0) why = '页面里有书名但规则没匹配上';
    else why = '站方返回了但没这本书';
    stat[why] = (stat[why] || 0) + 1;
    if (samples.length < 6) samples.push({ n: s.bookSourceName, url: s.bookSourceUrl, why, req: last && last.url, len: last && last.body.length });
  }
  console.log('=== 搜索失败原因分布 ===');
  Object.entries(stat).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${String(v).padStart(4)}  ${k}`));
  console.log('\n=== 样例 ===');
  samples.forEach((x) => console.log(`  ${x.n} — ${x.why}\n      请求 ${x.req}\n      响应 ${x.len} 字节`));
})();
