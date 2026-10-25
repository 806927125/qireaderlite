/* ⭐ 125 源包「全量体检」：发现 → 详情 → 目录，逐源跑真站
 *
 * 跑法：node test/pack125-health.js [并发数] [起始下标] [个数]
 *   并发默认 5（别太高，太多并发会被站方限流 ⇒ 假失败）
 * 输出：/workspace/work/pack125-health.json  +  终端分类汇总
 *
 * ⚠️ 这是**诊断脚本**，不是门禁（它连真站 ⇒ 必然有波动）
 *    ⇒ 结论只认「同一类失败复现两次以上」
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const ROOT = path.join(__dirname, '..');
const PACK = process.env.PACK125 || path.join(ROOT, 'sources', '配置文件125个-轻阅适配版.json');
const CONC = parseInt(process.argv[2] || '5', 10);
const OFFSET = parseInt(process.argv[3] || '0', 10);
const LIMIT = parseInt(process.argv[4] || '999', 10);
const OUT = process.env.HEALTH_OUT || '/workspace/work/pack125-health.json';

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
  + '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

function loadSources() {
  const d = JSON.parse(fs.readFileSync(PACK, 'utf8'));
  const arr = Array.isArray(d) ? d : [d];
  return arr.filter(s => s && typeof s === 'object' && s.bookSourceUrl);
}

/** 造一个「真 fetch」的沙盒 */
function makeLiveSandbox() {
  const { win } = createSandbox();
  win.webkit.messageHandlers.qr.postMessage = function (m) {
    if (m.fn === 'request') {
      const { url, method, headers, body } = m.args;
      const H = Object.assign({ 'User-Agent': UA }, headers || {});
      fetch(url, {
        method: method || 'GET', headers: H, body: body || undefined,
        redirect: 'follow', signal: AbortSignal.timeout(20000)
      }).then(async (r) => ({
        ok: true, code: r.status, url: r.url,
        headers: Object.fromEntries(r.headers), body: await r.text()
      })).catch(e => ({ ok: false, error: String(e && e.message || e) }))
        .then(v => win.__qrResolve(m.id, v));
      return;
    }
    if (m.fn === 'log' || m.fn === 'toast') { Promise.resolve({ ok: true }).then(v => win.__qrResolve(m.id, v)); return; }
    Promise.resolve({ ok: true, value: '' }).then(v => win.__qrResolve(m.id, v));
  };
  return win;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

/** 站方侧信号（限流/未登录/线路故障）⇒ 不算引擎的锅 */
const SERVER_SIDE = /免登录访问次数已达上限|今日免登录|次数上限|还未登陆|未登陆|检测登录失败|登录失败|会员已过期|密钥|线路故障|fetch failed|ENOTFOUND|ETIMEDOUT|timeout|Timeout|502|503|504/;

async function healthOne(src) {
  const t0 = Date.now();
  const rec = {
    name: src.bookSourceName, url: src.bookSourceUrl,
    kinds: 0, books: 0, detail: '', toc: 0, tocRaw: 0, where: '', err: '', logs: []
  };
  let win;
  try {
    win = makeLiveSandbox();
    const logs = [];
    win.webkit.messageHandlers.qr.postMessage = ((orig) => function (m) {
      if (m.fn === 'log') { logs.push(String(m.args && (m.args.text || m.args.msg) || '')); }
      return orig.call(this, m);
    })(win.webkit.messageHandlers.qr.postMessage);

    const call = (op, p) => win.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");

    // ① 发现页分类
    let kinds = [];
    try {
      const kr = await call('exploreKinds', { source: src });
      kinds = (kr && (kr.kinds || kr.list || kr.items)) || [];
      if (kr && Array.isArray(kr)) kinds = kr;
    } catch (e) { rec.err += '[kinds] ' + String(e.message || e).slice(0, 120) + ' '; }
    rec.kinds = kinds.length;
    const withUrl = kinds.filter(k => k && (k.url || k.kindUrl));
    if (!withUrl.length) { rec.where = 'kinds'; rec.logs = logs.slice(-6); return rec; }

    // ② 列表（取第一个有 url 的分类）
    let books = [];
    for (const k of withUrl.slice(0, 3)) {
      try {
        const r = await call('explore', { source: src, kindUrl: k.url || k.kindUrl, page: 1 });
        books = (r && r.books) || [];
        if (books.length) break;
        if (r && r.error) rec.err += '[explore] ' + String(r.error).slice(0, 120) + ' ';
      } catch (e) { rec.err += '[explore] ' + String(e.message || e).slice(0, 120) + ' '; }
    }
    rec.books = books.length;
    if (!books.length) { rec.where = 'explore'; rec.logs = logs.slice(-6); return rec; }

    const b = books[0];
    // ③ 详情
    let info = null;
    try {
      const r = await call('bookInfo', { source: src, bookUrl: b.bookUrl, book: b });
      info = r && r.book;
      if (!info) rec.err += '[bookInfo] ' + String((r && r.error) || '无 book').slice(0, 120) + ' ';
    } catch (e) { rec.err += '[bookInfo] ' + String(e.message || e).slice(0, 120) + ' '; }
    if (info) {
      rec.detail = (info.name && info.name !== b.name) ? 'ok' : (info.name ? 'same' : 'empty');
      if (!info.intro) rec.detail += '/no-intro';
      if (!info.author) rec.detail += '/no-author';
      if (!info.tocUrl) rec.detail += '/no-tocUrl';
    } else {
      rec.detail = 'fail';
    }

    // ④ 目录
    const tocUrl = (info && info.tocUrl) || b.tocUrl || b.bookUrl;
    try {
      const r = await call('toc', {
        source: src, bookUrl: b.bookUrl, tocUrl: tocUrl,
        book: info || b, maxPages: 3
      });
      rec.toc = (r && r.chapters || []).length;
      rec.tocRaw = (r && r.rawCount != null) ? r.rawCount : rec.toc;
      if (r && r.error) rec.err += '[toc] ' + String(r.error).slice(0, 120) + ' ';
    } catch (e) { rec.err += '[toc] ' + String(e.message || e).slice(0, 120) + ' '; }
    if (!rec.where) rec.where = 'toc';
    rec.logs = logs.slice(-8);
  } catch (e) {
    rec.err += '[fatal] ' + String(e.message || e).slice(0, 160);
  }
  rec.ms = Date.now() - t0;
  rec.serverSide = SERVER_SIDE.test(rec.err + ' ' + rec.logs.join(' '));
  return rec;
}

(async () => {
  const all = loadSources();
  const list = all.slice(OFFSET, OFFSET + LIMIT);
  console.log(`体检 ${list.length} 个源（并发 ${CONC}）· ${new Date().toLocaleTimeString()}`);
  const out = [];
  let idx = 0, done = 0;
  async function worker() {
    while (idx < list.length) {
      const s = list[idx++];
      let r;
      try { r = await healthOne(s); }
      catch (e) { r = { name: s.bookSourceName, url: s.bookSourceUrl, fatal: String(e.message || e) }; }
      out.push(r); done++;
      const tag = r.fatal ? '!' : (r.kinds ? (r.books ? (r.toc ? '.' : 'c') : 'b') : 'k');
      process.stdout.write(tag);
      if (done % 10 === 0) process.stdout.write(' ' + done + '/' + list.length + '\n');
      await sleep(150);
    }
  }
  await Promise.all(Array.from({ length: CONC }, worker));
  process.stdout.write('\n\n');
  out.sort((a, b) => (a.name || '').localeCompare(b.name || '', 'zh'));
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));

  const groups = { noKinds: [], noBooks: [], noDetail: [], tocLe1: [], allOk: [] };
  for (const r of out) {
    if (r.fatal) groups.noKinds.push(r);
    else if (!r.kinds) groups.noKinds.push(r);
    else if (!r.books) groups.noBooks.push(r);
    else if (r.detail === 'fail') groups.noDetail.push(r);
    else if (r.toc <= 1) groups.tocLe1.push(r);
    else groups.allOk.push(r);
  }
  const P = (title, arr) => {
    console.log(`\n===== ${title} (${arr.length}) =====`);
    for (const r of arr) {
      console.log('  ' + String(r.name).padEnd(24) +
        `k=${r.kinds} b=${r.books} d=${r.detail} t=${r.toc}` +
        (r.serverSide ? ' [站方侧]' : '') +
        (r.err ? '  ' + r.err.slice(0, 110) : ''));
    }
  };
  const LABEL = { noKinds: '① 连分类都没有', noBooks: '② 分类有但没书',
                  noDetail: '③ 有书但没详情', tocLe1: '④ 详情有但目录≤1章', allOk: '⑤ 全通' };
  for (const [k, v] of Object.entries(groups)) P(LABEL[k] || k, v);
  console.log('\n结果存到', OUT);
})();
