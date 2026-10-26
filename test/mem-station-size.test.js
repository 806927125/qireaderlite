/**
 * ⭐⭐⭐ 量「站方真实响应有多大」+「引擎吃下它涨多少内存」
 * （2026-10-26 jetsam 6.8GB 追凶）
 *
 * 用 test/live-helpers.js 的 LiveProxy（真网络）+ test/new-engine-harness.js 的真引擎
 * ⇒ 打印：每个真实响应的字节数 + 引擎跑完 explore 后的内存
 */
const fs = require('fs');
const path = require('path');
const { LiveProxy } = require('./live-helpers');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');

(async () => {
  if (!engineAvailable()) { console.log('⏭️ 引擎不可用 ⇒ 跳过'); process.exit(0); }
  const raw = JSON.parse(fs.readFileSync(SRC, 'utf8'));
  const src = raw[0] || raw;
  const hosts = (src.jsLib.match(/https?:\/\/[^'"]+/g) || []);
  const host = hosts[0] || 'https://v5.langge.uk';

  const proxy = new LiveProxy({ timeout: 20000, maxRounds: 8 });
  console.log('=== ⓪ 真网络：站方接口响应体大小 ===');
  const probe = await proxy.probe(host + '/discovestyle');
  console.log('  /discovestyle:', probe.ok ? `${probe.body.length} 字节 (status ${probe.status})` : `失败 ${probe.error || probe.status}`);

  const live = (op, payload) => proxy.converge((routes) => {
    const { win } = createSandbox({ routes });
    return win.__qrInvoke(op, payload);
  });

  console.log('\n=== ① exploreKinds（分类）===');
  const kindsRes = await live('exploreKinds', { source: src, jsLib: src.jsLib });
  const kinds = kindsRes.kinds || [];
  console.log('  分类数:', kinds.length);
  dumpRoutes(proxy, 'exploreKinds 后');

  console.log('\n=== ② explore（真跑发现页列表）===');
  const first = (kinds.find(k => k.url) || {}).url || '';
  if (!first) { console.log('  没有可用的分类 url ⇒ 结束'); return; }
  const url = first.replace(/\{\{page\}\}/g, '1');
  const exRes = await live('explore', { source: src, jsLib: src.jsLib, url });
  const books = exRes.books || exRes.list || [];
  console.log('  书数:', Array.isArray(books) ? books.length : '?');
  dumpRoutes(proxy, 'explore 后');
})().catch(e => { console.log('出错:', e && e.message || e); process.exit(1); });

function dumpRoutes(proxy, when) {
  let total = 0; const rows = [];
  for (const r of (proxy.routes() || [])) {
    const body = r.body || '';
    const n = typeof body === 'string' ? body.length : (body.length || 0);
    total += n;
    rows.push([String(r.match || r.url || '').slice(0, 60), n]);
  }
  rows.sort((a, b) => b[1] - a[1]);
  console.log(`  ---- ${when}：共 ${rows.length} 个响应，合计 ${(total / 1048576).toFixed(2)} MB ----`);
  for (const [u, n] of rows.slice(0, 6)) {
    console.log(`    ${(n / 1048576).toFixed(3)} MB  ${u}`);
  }
}
