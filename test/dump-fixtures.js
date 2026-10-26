const fs = require('fs'); const path = require('path');
const { LiveProxy } = require('./live-helpers');
const { createSandbox } = require('./new-engine-harness');
const ROOT = path.join(__dirname, '..');
const raw = JSON.parse(fs.readFileSync(path.join(ROOT, 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'), 'utf8'));
const src = raw[0] || raw;
const OUT = process.argv[2] || '/workspace/fixtures';
fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const proxy = new LiveProxy({ timeout: 20000, maxRounds: 8 });
  const host = (src.jsLib.match(/https?:\/\/[^'"]+/g) || [])[0] || 'https://v5.langge.uk';
  const live = (op, payload) => proxy.converge((routes) => {
    const { win } = createSandbox({ routes }); return win.__qrInvoke(op, payload);
  });
  await live('exploreKinds', { source: src, jsLib: src.jsLib });
  const kinds = (await live('exploreKinds', { source: src, jsLib: src.jsLib })).kinds || [];
  const picked = kinds.find(k => /get_discover/.test(String(k.url || '')));
  await live('explore', { source: src, jsLib: src.jsLib, kindUrl: picked.url, page: 1 });
  let i = 0;
  for (const r of proxy.routes()) {
    const body = r.body || '';
    const f = path.join(OUT, `resp-${i}.txt`);
    fs.writeFileSync(f, typeof body === 'string' ? body : String(body));
    console.log(`  ${f}  ${(typeof body === 'string' ? body.length : 0)} 字节  ← ${String(r.match||'').slice(0,70)}`);
    i++;
  }
})().catch(e => { console.log('出错:', e.message); process.exit(1); });
