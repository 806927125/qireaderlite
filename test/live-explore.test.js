#!/usr/bin/env node
/**
 * 发现页**真机联调**（真网络 + 真聚合源）
 *
 * 跑法：node test/live-explore.test.js
 *
 * 背景：用户真机「发现页没有书」，而 App 里的「发现页诊断」说：
 *     状态码 200 / 响应字节 5877 / 正文开头 {"code":0,...,"data":[{...}]}
 *     规则命中元素: 0 / 结论: 规则只命中 0 个元素 —— 书单页结构跟规则对不上
 *
 * ⚠️ 但那条诊断（explain op）**自己就按 HTML 解析**去数 CSS 节点
 *    → 对 JSON 接口源来说**结论必然是「命中 0 个」** → **它是误导**。
 *    真正的 explore 路径有 JSON 分支（ctx.isJSON → jsonpath）。
 *
 * 这个测试跑**真正的 explore op**，看真实结果。
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 * · 老门禁用 **JS 层**的 `nativeMock`（自己发真请求）⇒ 老引擎删了 ⇒ 门禁的对象没了 ⭐⭐⭐
 * · ⇒ 现在：**门禁自己真抓**（Node 的 fetch）⇒ 把**真响应**喂给新引擎的**声明式 routes**
 *   （规范 §1.1）⇒ **真网络 ✓ + 真引擎 ✓** 两条都在 ⭐⭐⭐
 * · ⇒ 收敛机制见 `test/live-helpers.js` 的 `LiveProxy`（多轮：引擎报 URL → 真抓 → 再跑）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { engineAvailable } = require('./new-engine-harness.js');
const { LiveProxy, looksServerSide, skipServerSide } = require('./live-helpers');

// ⭐⭐⭐ **不许「跳过」**（2026-10-24 真机教训）
//   跳过 = 这条链路**一次都没被验过** ⇒ 真机炸了沙盒还全绿 ⭐⭐⭐
//   ⇒ 回退到**仓库里的源文件副本** ⇒ 干净克隆也能跑 ⇒ 门禁永远在跑 ⭐
const CANDIDATES = [
  process.env.SRC_OUT,
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json',
  path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'),
  path.join(__dirname, '..', 'sources', 'dahlang-v2.json'),
].filter(Boolean);
const SRC = CANDIDATES.find(p => fs.existsSync(p));
if (!SRC) {
  console.log('❌ 找不到大灰狼源文件（连仓库副本都没有）⇒ 门禁必须失败，不许跳过');
  process.exit(1);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.ruleExplore) || list[0];

/** ⭐⭐⭐ **站方的服务器地址（在 jsLib 的 `host[]` 里）** */
function hostsOf(source) {
  const lib = String(source.jsLib || '');
  const m = /var\s+host\s*=\s*(\[[\s\S]*?\])/.exec(lib);
  if (!m) return [];
  try { return JSON.parse(m[1].replace(/'/g, '"')); } catch (e) { return []; }
}

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
    console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
    process.exit(0);
  }

  const hosts = hostsOf(src);
  console.log('=== ⓪ 真网络连通性（站方服务器）===');
  const proxy = new LiveProxy({ timeout: 15000, maxRounds: 6 });
  const probeHost = hosts[0] || 'https://v5.langge.uk';
  const probe = await proxy.probe(probeHost + '/discovestyle');
  if (!probe.ok || probe.status !== 200) {
    // ⭐⭐⭐ **显式 SKIP**：网络不通 ⇒ **没验到 ≠ 验过了没问题** ⇒ 绝不假绿 ⭐⭐⭐
    console.log('  ⏭️  跳过：站方服务器不通（' + (probe.error || probe.status) + '）');
    console.log('      ⇒ 本门禁**没验到**（**不等于通过**）⇒ 等网络恢复 / 真机再验');
    console.log('\n✅ 通过 0 / 失败 0（网络不通 ⇒ 显式跳过）');
    process.exit(0);
  }
  ok(true, `站方可达（${probeHost}，${probe.body.length} 字节）`);

  /* ── 跑 op（把真响应喂给引擎）── */
  const { createSandbox } = require('./new-engine-harness.js');
  const runOp = (op, payload) => {
    const { win } = createSandbox({ routes: proxy.routes() });
    return win.__qrInvoke(op, payload);
  };
  const live = (op, payload) => proxy.converge((routes) => {
    const { win } = createSandbox({ routes });
    return win.__qrInvoke(op, payload);
  });

  console.log('\n=== ① exploreKinds（分类）===');
  const kindsRes = await live('exploreKinds', { source: src, jsLib: src.jsLib });
  const kinds = kindsRes.kinds || [];
  console.log('  分类数:', kinds.length);
  console.log('  前 3 个:', kinds.slice(0, 3).map(k => k.title).join(' / '));
  ok(kinds.length > 0, '发现页分类出来了');
  ok(kinds.every(k => !!k.url), '每个分类都有 url（组标题行不混进分类列表）',
    `${kinds.filter(k => !k.url).length} 个空 url`);
  ok(kinds.some(k => String(k.group || '').length > 0),
    '分类有**分组**（站方的组标题行 ⇒ 组名）');
  ok(kinds.some(k => String(k.url).indexOf('{{page}}') >= 0),
    '分类 url 里的 {{page}} 原样保留（到 explore 阶段才插值）');

  console.log('\n=== ② explore（真跑发现页列表）===');
  // ⚠️ 前几个 kind 是**分组标题**（线路/模式/频道…）没有 url ⇒ 要挑有 url 的真分类
  // ⚠️ 只挑**真分类**（URL 是 get_discover…）——
  //    有些分类是「动作按钮」（URL 是 {{java.startBrowser(...)}}），不是列表页
  const picked = kinds.find(k => /get_discover/.test(String(k.url || '')));
  const kindUrl = (picked && picked.url) || '';
  console.log('  用分类:', picked && picked.title, '→', kindUrl ? kindUrl.slice(0, 90) : '(无)');
  const r = await live('explore', { source: src, jsLib: src.jsLib, kindUrl, page: 1 });

  console.log('  error  :', r.error || '(无)');
  console.log('  total  :', r.total);
  console.log('  books  :', (r.books || []).length);
  for (const b of (r.books || []).slice(0, 3)) {
    console.log(`    · ${b.name}  | ${b.author} | ${b.bookUrl ? '有URL' : '★无URL'}`);
  }

  console.log('\n=== ③ 真网络抓取记录 ===');
  console.log(`   真抓到 ${proxy.fetched.length} 条 URL，失败 ${proxy.failed.length} 条`);
  for (const f of proxy.fetched.slice(0, 6)) {
    console.log(`   ✓ ${f.status} ${String(f.len).padStart(7)} 字节  ${f.url.slice(0, 96)}`);
  }
  for (const f of proxy.failed.slice(0, 3)) {
    console.log(`   ✗ 抓不到 ${f.url.slice(0, 96)}（${f.error}）`);
  }

  console.log('\n=== 判定 ===');
  ok(proxy.fetched.length > 0, '门禁**真的联网抓了站方接口**（不是假服务器自娱自乐）');
  ok(!r.error, 'explore 没报错' + (r.error ? '：' + r.error : ''));
  ok((r.books || []).length > 0, `explore 出书了（现在 ${(r.books || []).length} 本）`);
  ok((r.books || []).every(b => b.name), '每本书都有名字');
  ok((r.books || []).some(b => b.bookUrl), '至少一本有 bookUrl（点进去要能开）');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
