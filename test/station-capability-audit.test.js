#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **站方能力面体检**（通用性的地基 · 2026-10-27）
 *
 * 跑法：node test/station-capability-audit.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **用户的要求（2026-10-27）**：
 *   「以后这种源能直接用，别只有这几个源能用」
 *   ⇒ ⇒ **不能靠逐源适配**（那是一辈子打补丁）⇒ ⇒ 要做的是：
 *   **① 拿真实语料（125 源 + 聚合源）扫出「站方用到的 API 面」**
 *   **② 跟「轻阅实际实现的 API 面」对账**
 *   **③ 缺口按【能力】补进引擎**（一类能力修一次 ⇒ 所有源受益）⭐⭐⭐
 *   **④ 缺口清单当门禁钉住** ⇒ 以后新增源 ⇒ 缺口自动暴露 ⇒ **不用人肉适配** ⭐
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁做三件事：
 *   ① 扫语料 ⇒ 站方用到的 `java.*` / `source.*` / `cookie.*` / `cache.*` / `book.*`
 *   ② 扫实现 ⇒ 轻阅**老引擎 JS**（登录那条链）+ **新引擎 Swift**（搜索/详情/目录/正文那条链）
 *   ③ 对账 ⇒ 缺口必须**全部登记在册**（带原因）⇒ 出现未登记的缺口 ⇒ **红** ⭐
 *      （例外：站方自造的 API（try/catch 包着）/ 防御式调用 ⇒ 登记为「有意不实现」）
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

/** ⭐ 已登记的缺口（= 有意不实现的）—— **每条都要写清原因** ⭐ */
const REGISTERED = {
  'java.qread': '站方自造（🍅大灰狼自己那套聚合协议）· 站方 try/catch 包着 ⇒ 缺了不影响',
  'java.upUiData': '站方自造的 UI 钩子（NovelHub）· try/catch 包着 ⇒ 缺了不影响',
  'java.reUiView': '站方自造的 UI 钩子（NovelHub）· try/catch 包着 ⇒ 缺了不影响',
  'java.upLoginData': '站方自造的 UI 钩子（NovelHub）· try/catch 包着 ⇒ 缺了不影响',
  'java.ajaxTestAll': '站方自造（NovelHub 的批量测速）· try/catch 包着',
  'java.openVideoPlayer': '轻阅没有站方那种内嵌视频页 ⇒ 站方 try/catch 包着 ⇒ 降级到网页播放',
  'source.putVariable': '站方防御式调用（`typeof fqS_.putVariable === "function"` 才调）· 缺了没事',
  // ⚠️⚠️ **下面这几条是【已排期的真缺口】** —— 不是「有意不实现」⇒
  //   通用性体检**每次都会报出来** ⇒ 修完一条就删一条 ⭐
  'java.copyText': '【待补】复制到剪贴板（125 源 32 处）· 宿主实现 UIPasteboard 即可',
  'java.digestHex': '【待补】按算法取摘要（SHA-1/MD5）（125 源 3 处）· 引擎 Crypto 有 md5/sha1',
  'cache.putMemory': '【待补】内存缓存写（🍅大灰狼 12 处）· 引擎侧一个内存字典即可',
  'cache.getFromMemory': '【待补】内存缓存读（🍅大灰狼 6 处）· 同上',
  'source.putLoginInfoMap': '【待补】整份写登录信息 map（125 源 3 处）· source-api + 引擎都要',
  'book.putVariable': '【待补】写书籍变量（125 源 12 处）· 需要「书籍变量回写」链路（引擎 + 宿主）',
  'book.setUseReplaceRule': '【待补】书籍净化开关（🍅大灰狼 3 处）· 防御式调用，缺了不致命',
  'cache.reduce': '误报（正则把 `Object.keys(…).sort().reduce(…)` 当成了 cache.reduce）· 不修',
};

function walkStrings(o, out = []) {
  if (typeof o === 'string') out.push(o);
  else if (Array.isArray(o)) o.forEach(v => walkStrings(v, out));
  else if (o && typeof o === 'object') Object.values(o).forEach(v => walkStrings(v, out));
  return out;
}

function members(file, re) {
  if (!fs.existsSync(file)) return new Set();
  const txt = fs.readFileSync(file, 'utf8');
  return new Set([...txt.matchAll(re)].map(m => m[1]));
}

console.log('=== 1. 扫语料：站方用到的 API 面 ===');
const srcDir = path.join(root, 'sources');
const used = new Map();          // "ns.fn" -> {count, files:Set}
if (!fs.existsSync(srcDir)) {
  console.log('  ✗ 没有 sources/ 目录 ⇒ 门禁必须失败（不许跳过）');
  process.exit(1);
}
for (const f of fs.readdirSync(srcDir).filter(x => x.endsWith('.json'))) {
  let data;
  try { data = JSON.parse(fs.readFileSync(path.join(srcDir, f), 'utf8')); }
  catch (e) { continue; }
  const list = Array.isArray(data) ? data : [data];
  for (const s of list) {
    const blob = walkStrings(s).join('\n');
    const re = /\b(java|source|cookie|cache|book)\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
    let m;
    while ((m = re.exec(blob)) !== null) {
      const k = `${m[1]}.${m[2]}`;
      if (!used.has(k)) used.set(k, { count: 0, files: new Set() });
      const e = used.get(k);
      e.count++; e.files.add(f);
    }
  }
}
console.log(`  语料用到的 API：${used.size} 个`);

console.log('\n=== 2. 扫实现：轻阅实际提供的 API 面 ===');
const engineDir = path.join(root, 'QiReaderLite', 'Resources', 'engine');
const javaImpl = members(path.join(engineDir, 'java-api.js'), /^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*function/gm);
const sourceImpl = members(path.join(engineDir, 'source-api.js'), /wrapped\.([A-Za-z_][A-Za-z0-9_]*)\s*=/g);
const cacheImpl = members(path.join(engineDir, 'java-api.js'), /g\.cache\s*=\s*\{([\s\S]{0,4000}?)\n  \};/g);
const cacheMembers = new Set();
if (cacheImpl.size) {
  const txt = fs.readFileSync(path.join(engineDir, 'java-api.js'), 'utf8');
  const i = txt.indexOf('g.cache = {');
  if (i >= 0) {
    const seg = txt.slice(i, i + 3000);
    for (const m of seg.matchAll(/^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*function/gm)) cacheMembers.add(m[1]);
  }
}
// 新引擎（Swift 宿主对象）—— 本机有克隆才扫得到（CI 上扫不到就只报老引擎那一半）
const swiftEng = ['/workspace/legado-engine-git', '/workspace/legado-engine-main']
  .find(p => fs.existsSync(path.join(p, 'Sources')));
let swiftAll = new Set();
if (fs.existsSync(swiftEng)) {
  const walk = d => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (!p.includes('.build')) walk(p); }
      else if (e.name.endsWith('.swift')) {
        const t = fs.readFileSync(p, 'utf8');
        for (const m of t.matchAll(/methods\["([A-Za-z_][A-Za-z0-9_]*)"\]/g)) swiftAll.add(m[1]);
        for (const m of t.matchAll(/properties\["([A-Za-z_][A-Za-z0-9_]*)"\]/g)) swiftAll.add(m[1]);
      }
    }
  };
  walk(path.join(swiftEng, 'Sources'));
  console.log(`  新引擎 Swift 宿主方法：${swiftAll.size} 个`);
}

function implemented(ns, fn) {
  if (ns === 'java') return javaImpl.has(fn) || swiftAll.has(fn);
  if (ns === 'source') return sourceImpl.has(fn) || swiftAll.has(fn);
  if (ns === 'cache') return cacheMembers.has(fn) || swiftAll.has(fn);
  if (ns === 'book') return swiftAll.has(fn);
  if (ns === 'cookie') return true;      // cookie.* 走 source-api.js 的 installCookie
  return false;
}

console.log('\n=== 3. 对账：缺口必须全部登记在册 ===');
const gaps = [];
for (const [k, info] of used) {
  const [ns, fn] = k.split('.');
  if (!implemented(ns, fn)) gaps.push({ k, ...info });
}
gaps.sort((a, b) => b.count - a.count);
for (const g of gaps) {
  const reg = REGISTERED[g.k];
  console.log(`  ${reg ? '📌' : '❓'} ${g.k.padEnd(26)} 语料用了 ${String(g.count).padStart(4)} 次` +
    (reg ? `  登记：${reg}` : `  **未登记 ⇒ 门禁红**`));
}
const unregistered = gaps.filter(g => !REGISTERED[g.k]);
const todo = gaps.filter(g => (REGISTERED[g.k] || '').indexOf('【待补】') >= 0);
ok(unregistered.length === 0,
   `没有「未登记」的缺口（${unregistered.length} 个）⇒ 新出现的站方 API 必须当场定性`,
   unregistered.map(g => g.k).join(', '));
console.log(`  📌 已排期待补的真缺口：${todo.length} 个 ⇒ ${todo.map(g => g.k).join(', ')}`);

console.log('\n=== 4. 关键能力不能退化（通用性的地基）===');
const api = fs.readFileSync(path.join(engineDir, 'java-api.js'), 'utf8');
const src = fs.readFileSync(path.join(engineDir, 'source-api.js'), 'utf8');
const engJs = fs.readFileSync(path.join(engineDir, 'engine.js'), 'utf8');
ok(/analyzeJsInUrl/.test(engJs) && /@js:/.test(engJs), '老引擎支持 URL 里的 @js:');
ok(/getVariable/.test(src) && /hasVariable/.test(src),
   '老引擎的 getVariable/setVariable 走【站方变量】（不是整份书籍变量）⭐');
ok(/putVariableAndVars|setVariable\(/.test(fs.readFileSync(path.join(root, 'QiReaderLite', 'Core', 'SourceVariables.swift'), 'utf8')),
   'App 侧有「站方变量」独立槽位 ⭐');
// 新引擎的 URL @js: 支持（本地有克隆才查得到）
if (fs.existsSync(swiftEng)) {
  const se = fs.readFileSync(path.join(swiftEng, 'Sources/LegadoCore/Pipeline/SourceEngine.swift'), 'utf8');
  ok(/analyzeURLJS/.test(se), '⭐⭐⭐ 新引擎支持 URL 里的 @js:（老引擎事实标准）');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
