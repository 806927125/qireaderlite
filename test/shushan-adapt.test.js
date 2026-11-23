#!/usr/bin/env node
// =============================================================================
// 书山聚合 v6 适配门禁（2026-11-23）
//
// ⭐⭐⭐ **门禁必须可证伪** ⇒ 每条断言都问「把实现改坏，它会不会红」⭐⭐⭐
//
// 断言清单：
//   ① 适配后源里**没有残留的未隔离顶层符号**（jsLib / loginUrl）
//   ② 适配后**每个 `ssh_`/`sshL_` 引用都有对应定义**（漏改 ⇒ 红）
//   ③ **没有「改了定义没改引用」**（孤立符号 ⇒ 红）
//   ④ 适配**幂等**：连跑两次 ⇒ 字节一致
//   ⑤ 适配后源**全部 JS 字段语法可解析**（acorn）
//   ⑥ **非 JS 字段未被误改**（`{{…}}` 模板 / CSS / JSONPath 保持原样）
//   ⑦ loginUi 的 action **两个域都正确**（jsLib 符号与 loginUrl 符号不串）
// =============================================================================

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const acorn = require('acorn');

const HERE = __dirname;
const SRC = process.argv[2] || path.join(HERE, '..', 'sources', '书山聚合v6-轻阅适配版.json');
const ORIG = process.argv[3] || path.join(HERE, 'fixtures', 'shushan-original.json');

let failures = 0;
let pass = 0;
function check(name, ok, detail = '') {
  if (ok) {
    pass++;
    console.log(`  ✅ ${name}`);
  } else {
    failures++;
    console.log(`  ❌ ${name}${detail ? ' — ' + detail : ''}`);
  }
}

if (!fs.existsSync(SRC)) {
  console.log(`⚠️ 找不到适配后的源：${SRC}`);
  console.log('   （先生成：node test/rename-shushan.mjs <原始源> <目标路径>）');
  process.exit(0);
}

const load = (p) => {
  const raw = JSON.parse(fs.readFileSync(p, 'utf8'));
  return Array.isArray(raw) ? raw[0] : raw;
};

const src = load(SRC);
const orig = fs.existsSync(ORIG) ? load(ORIG) : null;

const ENGINE_BINDINGS = new Set([
  'result', 'baseUrl', 'src', 'book', 'chapter', 'title', 'nextChapterUrl',
  'key', 'page', 'speakText', 'speakSpeed',
]);

console.log(`▶ 适配门禁：${path.basename(SRC)}`);

// ---------- 顶层符号收集 ----------
function topLevelNames(code) {
  const ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'script' });
  const names = new Set();
  for (const node of ast.body) {
    if (node.type === 'FunctionDeclaration' && node.id) names.add(node.id.name);
    else if (node.type === 'VariableDeclaration') {
      for (const d of node.declarations) if (d.id.type === 'Identifier') names.add(d.id.name);
    }
  }
  return names;
}

/** 收集代码里出现的所有「自由标识符」引用（排除属性名/字符串） */
function collectRefs(code) {
  const ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'script' });
  const refs = new Map();
  function walk(node, parent) {
    if (!node || typeof node.type !== 'string') return;
    if (node.type === 'Identifier') {
      const isProp = parent && parent.type === 'MemberExpression' && parent.property === node && !parent.computed;
      const isKey = parent && parent.type === 'Property' && parent.key === node && !parent.computed;
      if (!isProp && !isKey) refs.set(node.name, (refs.get(node.name) || 0) + 1);
      return;
    }
    for (const k of Object.keys(node)) {
      if (k === 'type' || k === 'start' || k === 'end') continue;
      const v = node[k];
      if (Array.isArray(v)) for (const c of v) walk(c, node);
      else if (v && typeof v.type === 'string') walk(v, node);
    }
  }
  walk(ast, null);
  return refs;
}

/** 把一段规则里的 JS 段抽出来（与柴阅 jsPattern 对齐） */
function jsSegments(code) {
  if (typeof code !== 'string' || !code.trim()) return [];
  const out = [];
  const m = code.match(/^\s*@js:([\w\W]*)$/);
  if (m) { out.push(m[1]); return out; }
  const re = /<js>([\w\W]*?)<\/js>/gi;
  let mm;
  while ((mm = re.exec(code)) !== null) out.push(mm[1]);
  return out;
}

const JS_ONLY_FIELDS = new Set(['callBackJs', 'payAction', 'init', 'webJs', 'bodyJs', 'loginJs', 'loginCheckJs', 'js']);

function allJsSegments(s) {
  const segs = [];
  for (const f of ['exploreUrl', 'searchUrl', 'header']) {
    for (const seg of jsSegments(s[f])) segs.push({ where: f, code: seg });
  }
  for (const rf of ['ruleExplore', 'ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent']) {
    if (!s[rf] || typeof s[rf] !== 'object') continue;
    for (const [k, v] of Object.entries(s[rf])) {
      if (typeof v !== 'string') continue;
      const hasSeg = jsSegments(v).length > 0;
      if (hasSeg) for (const seg of jsSegments(v)) segs.push({ where: `${rf}.${k}`, code: seg });
      else if (JS_ONLY_FIELDS.has(k)) segs.push({ where: `${rf}.${k}`, code: v });
    }
  }
  return segs;
}

// ---------- ① 顶层符号已隔离 ----------
const libNames = [...topLevelNames(src.jsLib || '')];
const luiNames = [...topLevelNames(src.loginUrl || '')];
const unisolated = [...libNames, ...luiNames].filter(n => !n.startsWith('ssh_') && !n.startsWith('sshL_'));
check('① 顶层符号全部带前缀（ssh_ / sshL_）', unisolated.length === 0, `未隔离: ${unisolated.join(', ')}`);

// ---------- ② 每个引用都有定义 ----------
const libDefs = new Set(libNames);
const luiDefs = new Set(luiNames);
const known = new Set([...libDefs, ...luiDefs, ...ENGINE_BINDINGS,
  'java', 'source', 'cookie', 'cache', 'Packages', 'org', 'JSON', 'Math', 'Object',
  'Array', 'String', 'Number', 'Boolean', 'Date', 'Promise', 'RegExp', 'Error',
  'Map', 'Set', 'Symbol', 'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'NaN',
  'Infinity', 'undefined', 'null', 'true', 'false', 'this', 'arguments', 'console',
  'window', 'globalThis', 'document', 'navigator', 'location', 'fetch',
  'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'require',
  'encodeURIComponent', 'decodeURIComponent', 'encodeURI', 'decodeURI', 'escape',
  'unescape', 'atob', 'btoa', 'URL', 'URLSearchParams', 'Buffer', 'TextEncoder',
  'TextDecoder', 'process', 'module', 'exports', 'Function', 'eval',
]);
let undef = [];
for (const { where, code } of allJsSegments(src)) {
  for (const [name] of collectRefs(code)) {
    if (name.startsWith('ssh_') || name.startsWith('sshL_')) {
      if (!libDefs.has(name) && !luiDefs.has(name)) undef.push(`${where}: ${name}`);
    }
  }
}
check('② 每个 ssh_/sshL_ 引用都有定义（无漏改）', undef.length === 0, undef.slice(0, 8).join(', '));

// ---------- ③ 引用计数守恒（改名后计数 == 原始源计数）⭐⭐⭐
// ⚠️ 这比「定义了却没被引用」强得多：
//   · 「定义了却没被引用」本身**不是错**（未使用的常量很常见）⇒ 不该当断言
//   · 「引用点数对不上」才是真错（漏改了一处引用 ⇒ 运行时 ReferenceError）⭐⭐⭐
if (orig) {
  const libSegs = [
    { where: 'jsLib', code: orig.jsLib || '' },
    { where: 'loginUrl', code: orig.loginUrl || '' },
  ];
  const origRefs = new Map();
  for (const { code } of [...libSegs, ...allJsSegments(orig)]) {
    for (const [n, c] of collectRefs(code)) origRefs.set(n, (origRefs.get(n) || 0) + c);
  }
  const newRefs = new Map();
  for (const { code } of [
    { where: 'jsLib', code: src.jsLib || '' },
    { where: 'loginUrl', code: src.loginUrl || '' },
    ...allJsSegments(src),
  ]) {
    for (const [n, c] of collectRefs(code)) newRefs.set(n, (newRefs.get(n) || 0) + c);
  }
  // ⚠️⚠️ **必须用「原名 → 新名」的映射来对照**（否则原名全被过滤 ⇒ 断言恒真 = 假绿）⭐⭐⭐
  const MAP_FILE = SRC.replace(/\.json$/, '') + '.map.json';
  if (!fs.existsSync(MAP_FILE)) {
    check('③ 引用计数守恒（改名后引用点数 == 原始）', false, `缺映射表 ${path.basename(MAP_FILE)}`);
  } else {
    const map = JSON.parse(fs.readFileSync(MAP_FILE, 'utf8'));
    // ⭐⭐⭐ **映射是 1 : N**（同名可能出现在两个域）⇒ 计数要**求和**对比 ⭐⭐⭐
    const mapping = new Map();
    for (const m of [map.all || {}, map.lib || {}, map.lui || {}]) {
      for (const [oldName, newName] of Object.entries(m)) {
        if (!mapping.has(oldName)) mapping.set(oldName, []);
        const arr = mapping.get(oldName);
        // ⭐⭐⭐ **去重**（统一前缀后两个域可能映射到**同一个新名** ⇒ 否则计数翻倍）⭐⭐⭐
        if (!arr.includes(newName)) arr.push(newName);
      }
    }
    const mismatch = [];
    for (const [oldName, newNames] of mapping) {
      const c = origRefs.get(oldName) || 0;
      const got = newNames.reduce((acc, nn) => acc + (newRefs.get(nn) || 0), 0);
      if (c === 0) continue;          // 原名根本没被引用 ⇒ 无从对照
      if (got !== c) mismatch.push(`${oldName}→[${newNames.join(',')}]: 原 ${c} → 新 ${got}`);
    }
    check('③ 引用计数守恒（改名后引用点数 == 原始）', mismatch.length === 0, mismatch.slice(0, 8).join(' | '));
  }
} else {
  console.log('  ⚠️ 没有原始源 fixture ⇒ 跳过引用计数断言');
}

// ---------- ④ 幂等 ----------
if (orig) {
  // ⭐⭐⭐ **对【原始源】跑两次 ⇒ 比两次的输出**（而不是「产物 vs 重跑」）⭐⭐⭐
  //   ⚠️ 后者会被**任何**手工改动触发 ⇒ 变成「万能断言」⇒ **掩盖**其它断言 ⭐⭐⭐
  const t1 = path.join(HERE, '..', '.shushan-idem-1.json');
  const t2 = path.join(HERE, '..', '.shushan-idem-2.json');
  try {
    execFileSync('node', [path.join(HERE, 'rename-shushan.mjs'), ORIG, t1], { stdio: 'pipe' });
    execFileSync('node', [path.join(HERE, 'rename-shushan.mjs'), ORIG, t2], { stdio: 'pipe' });
    const a = fs.readFileSync(t1);
    const b = fs.readFileSync(t2);
    check('④ 适配幂等（对原始源跑两次 ⇒ 字节一致）', a.equals(b));
  } catch (e) {
    check('④ 适配幂等（对原始源跑两次 ⇒ 字节一致）', false, String(e.message).slice(0, 120));
  } finally {
    for (const f of [t1, t2, t1.replace(/\.json$/, '.map.json'), t2.replace(/\.json$/, '.map.json')]) {
      if (fs.existsSync(f)) fs.unlinkSync(f);
    }
  }
} else {
  console.log('  ⚠️ 没有原始源 fixture ⇒ 跳过幂等断言');
}

// ---------- ⑤ 全部 JS 字段语法可解析 ----------
let syntaxErr = [];
for (const { where, code } of allJsSegments(src)) {
  try { acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'script' }); }
  catch (e) { syntaxErr.push(`${where}: ${e.message}`); }
}
check('⑤ 全部 JS 段语法可解析', syntaxErr.length === 0, syntaxErr.slice(0, 3).join(' | '));

// ---------- ⑥ 非 JS 字段未被误改 ----------
if (orig) {
  const nonJsFields = [];
  for (const rf of ['ruleExplore', 'ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent']) {
    if (!orig[rf]) continue;
    for (const [k, v] of Object.entries(orig[rf])) {
      if (typeof v !== 'string') continue;
      const isJs = jsSegments(v).length > 0 || JS_ONLY_FIELDS.has(k);
      if (!isJs) nonJsFields.push([rf, k, v]);
    }
  }
  const changed = nonJsFields.filter(([rf, k, v]) => (src[rf] || {})[k] !== v);
  check('⑥ 非 JS 字段（模板/CSS/JSONPath）未被误改', changed.length === 0,
    changed.map(([rf, k]) => `${rf}.${k}`).join(', '));
} else {
  console.log('  ⚠️ 没有原始源 fixture ⇒ 跳过非 JS 字段断言');
}

// ---------- ⑦ loginUi 的 action 域正确 ----------
{
  const rows = JSON.parse(src.loginUi);
  const bad = [];
  for (const row of rows) {
    if (typeof row.action !== 'string') continue;
    const m = row.action.match(/^\s*([A-Za-z_$][\w$]*)\s*\(/);
    if (!m) continue;
    const fn = m[1];
    if (!fn.startsWith('ssh_') && !fn.startsWith('sshL_')) bad.push(row.name + ':' + fn);
  }
  check('⑦ loginUi 的 action 都指向已隔离符号', bad.length === 0, bad.join(', '));
}

// ⚠️⚠️ **门禁 runner 的约定**（`test/parse-summary.py`）：最后一行必须是
//   「通过 N / 失败 M」⇒ 否则 runner 判「无汇总 ⇒ 疑似提前退出」⇒ **算失败** ⭐⭐⭐
console.log(`\n通过 ${pass} / 失败 ${failures}`);
process.exit(failures === 0 ? 0 : 1);
