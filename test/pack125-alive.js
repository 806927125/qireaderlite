/* 125 源包「站点存活」扫描：每个源的主页能不能通
 * 跑法：node test/pack125-alive.js [并发数]
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const ROOT = path.join(__dirname, '..');
const PACK = process.env.PACK125 || path.join(ROOT, 'sources', '配置文件125个-轻阅适配版.json');
const CONC = parseInt(process.argv[2] || '8', 10);
const OUT = process.env.ALIVE_OUT || '/workspace/work/pack125-alive.json';

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
  + '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

function loadSources() {
  const d = JSON.parse(fs.readFileSync(PACK, 'utf8'));
  return (Array.isArray(d) ? d : [d]).filter(s => s && s.bookSourceUrl);
}

function hostOf(u) {
  let s = String(u || '');
  s = s.replace(/^[a-z]+:\/\//i, '');
  s = s.split('/')[0].split('#')[0].split('?')[0];
  return s;
}

async function alive(src) {
  const rec = { name: src.bookSourceName, url: src.bookSourceUrl, host: hostOf(src.bookSourceUrl) };
  const cands = [];
  const base = String(src.bookSourceUrl).replace(/^[a-z]+:\/\//i, '').split('#')[0].split('?')[0];
  cands.push('https://' + base, 'http://' + base);
  // 有些源的真实站点在别处（host 不含路径），再试几个常见前缀
  for (const extra of ['/index.html', '/']) cands.push('https://' + rec.host + extra);
  let best = null;
  for (const u of cands) {
    try {
      const ctl = AbortSignal.timeout(12000);
      const r = await fetch(u, {
        method: 'GET', redirect: 'follow', signal: ctl,
        headers: { 'User-Agent': UA, 'Accept': 'text/html,*/*' }
      });
      const body = await r.text();
      const rec2 = { url: u, code: r.status, len: body.length, ct: r.headers.get('content-type') || '' };
      if (!best || (r.status < 400 && r.status > 0 && rec2.len > 200)) best = rec2;
      if (r.ok && body.length > 200) break;
    } catch (e) {
      if (!best) best = { url: u, code: 0, len: 0, err: String(e.message || e).slice(0, 60) };
    }
  }
  Object.assign(rec, best || {});
  rec.alive = !!(best && best.code > 0 && best.code < 400 && best.len > 200);
  return rec;
}

(async () => {
  const list = loadSources();
  console.log('扫描 ' + list.length + ' 个源（并发 ' + CONC + '）');
  const out = [];
  let idx = 0;
  async function worker() {
    while (idx < list.length) {
      const s = list[idx++];
      let r;
      try { r = await alive(s); } catch (e) { r = { name: s.bookSourceName, url: s.bookSourceUrl, alive: false, err: String(e.message || e) }; }
      out.push(r);
      process.stdout.write(r.alive ? '.' : 'x');
    }
  }
  await Promise.all(Array.from({ length: CONC }, worker));
  console.log('\n');
  const up = out.filter(r => r.alive), down = out.filter(r => !r.alive);
  console.log('===== 站点还活着 (' + up.length + ') =====');
  for (const r of up) console.log('  ' + String(r.name).padEnd(24) + String(r.code).padStart(4) + ' ' + String(r.len).padStart(8) + '  ' + r.host);
  console.log('\n===== 站点没了/打不开 (' + down.length + ') =====');
  for (const r of down) console.log('  ' + String(r.name).padEnd(24) + String(r.code || '-').padStart(4) + '  ' + r.host + '  ' + (r.err || ''));
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
  console.log('\n结果存到', OUT);
})();
