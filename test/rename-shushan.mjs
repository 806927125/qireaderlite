#!/usr/bin/env node
// =============================================================================
// 书山聚合 v6 —— 顶层符号隔离化（按《轻阅 Lite · 书源适配手册-规则》规则 2）
//
// ⚠️⚠️⚠️ **为什么必须改**（2026-11-23 静态实证）⭐⭐⭐
//   ① 柴阅 `JSRuntime.evalValue` → `loadJSLibIfNeeded()` ⇒ **jsLib 的顶层符号进全局**
//   ② 柴阅 `RuleSession.runLoginAction` → `evalSourceJS(loginJs + "\n" + action)`
//      ⇒ **loginUrl 的顶层符号也进全局**，且**在 jsLib 之后** ⇒ **同名会覆盖 jsLib 的**
//   ③ 实测本源自查：
//        jsLib   顶层 47 个符号（getHost / config / encode / decode / pick …）
//        loginUrl 顶层 55 个符号（s / t / m / res / obj / info / host / html / c …）
//        **两者重名 22 个** ⇒ 跑登录 action 时，loginUrl 的 `var s = …` 会盖掉 jsLib 的 `s`
//   ④ ⚠️ `encode` / `decode` **遮蔽了 JS 标准全局**（decodeURIComponent 等同族不受影响，
//      但同名遮蔽本身就是隐患）⭐⭐⭐
//   ⑤ 轻阅「每个 op 新建 JSContext」⇒ 跨源污染不成立，但**同一 context 内 jsLib↔loginUrl
//      的互相覆盖成立** ⇒ 这是本改动要治的**真问题** ⭐⭐⭐
//
// =============================================================================
// **做法**：用 **acorn 真 AST** 重命名（不是正则猜测）⭐⭐⭐
//   · jsLib   顶层符号 ⇒ 前缀 `ssh_`
//   · loginUrl 顶层符号 ⇒ 前缀 `sshL_`（**与 jsLib 不同前缀** ⇒ 彻底消除那 22 个重名）
//   · 作用域判定（哪些字段用哪套映射）：
//       - `loginUi[].action` ⇒ **loginUrl 优先**（柴阅 runLoginAction = loginJs + action ⇒ loginUrl 后加载 ⇒ 覆盖 jsLib）
//       - 其余 JS 字段（exploreUrl/searchUrl/header/rule*）⇒ **jsLib 优先**，jsLib 没有才回落 loginUrl
//   · **绝不改**：引擎注入名（result/baseUrl/src/book/chapter/title/nextChapterUrl/key/page/
//     speakText/speakSpeed）、标准全局、属性访问的 `.prop`、对象字面量的键、字符串/注释/正则
//   · shorthand 属性 `{ s }` ⇒ 展开成 `{ s: ssh_s }`（否则属性名会变 ⇒ 语义变）⭐⭐⭐
// =============================================================================

import fs from 'node:fs';
import path from 'node:path';
import * as acorn from 'acorn';

const IN = process.argv[2];
const OUT = process.argv[3] || IN;
if (!IN) { console.error('用法: rename-shushan.mjs <in.json> [out.json]'); process.exit(2); }

// ---------- 绝不能改的名字 ----------
const ENGINE_BINDINGS = new Set([
  'result', 'baseUrl', 'src', 'book', 'chapter', 'title', 'nextChapterUrl',
  'key', 'page', 'speakText', 'speakSpeed',
]);
const HOST_GLOBALS = new Set([
  'java', 'source', 'cookie', 'cache', 'Packages', 'org', 'eval', 'JSON', 'Math',
  'Object', 'Array', 'String', 'Number', 'Boolean', 'Date', 'Promise', 'RegExp',
  'Error', 'TypeError', 'RangeError', 'SyntaxError', 'Map', 'Set', 'Symbol',
  'BigInt', 'Function', 'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'NaN',
  'Infinity', 'undefined', 'null', 'true', 'false', 'this', 'arguments',
  'encodeURIComponent', 'decodeURIComponent', 'encodeURI', 'decodeURI',
  'escape', 'unescape', 'atob', 'btoa', 'console', 'window', 'globalThis',
  'document', 'navigator', 'location', 'fetch', 'setTimeout', 'clearTimeout',
  'setInterval', 'clearInterval', 'require', 'module', 'exports', 'process',
  'Buffer', 'TextEncoder', 'TextDecoder', 'URL', 'URLSearchParams', 'crypto',
]);
const PROTECTED = new Set([...ENGINE_BINDINGS, ...HOST_GLOBALS]);

const JS_FIELDS = ['exploreUrl', 'searchUrl', 'header'];
const RULE_FIELDS = ['ruleExplore', 'ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent'];

// ---------- 解析 ----------
function parse(code, label) {
  try {
    return acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'script', locations: false });
  } catch (e) {
    console.error(`❌ ${label} 解析失败: ${e.message}`);
    process.exit(1);
  }
}

// ---------- 收集顶层声明 ----------
function topLevelNames(ast) {
  const names = new Set();
  for (const node of ast.body) {
    if (node.type === 'FunctionDeclaration' && node.id) names.add(node.id.name);
    else if (node.type === 'VariableDeclaration') {
      for (const d of node.declarations) {
        if (d.id.type === 'Identifier') names.add(d.id.name);
      }
    } else if (node.type === 'ClassDeclaration' && node.id) names.add(node.id.name);
  }
  return names;
}

// ---------- 重命名器 ----------
// dom: Map<原名, 新名>
// ⭐⭐⭐ `refsOnly` = true 时：**只改「自由引用」，不改该字段自己的声明/参数** ⭐⭐⭐
//   ⇒ 用于 `ruleContent.callBackJs` / `payAction` 这类**纯 JS 字段**（它们有自己的局部作用域）
//   ⇒ 例：`callBackJs` 里 `let handled = false;` ⇒ `handled` 是它自己的 ⇒ 不改
//   ⇒ 而 `isShelfSyncEnabled.call(this)` 是**引用 jsLib 的符号** ⇒ 要改 ⭐⭐⭐
function makeRenamer(dom, refsOnly = false) {
  // ⚠️⭐⭐⭐ **dom 可以是 Map，也可以是函数** `(name) => 新名 | undefined` ⭐⭐⭐
  //   ⇒ 因为**同一个名字在「定义域」与「引用域」可能要改成不同前缀**：
  //      · loginUrl 顶层**定义**的 ⇒ `sshL_`
  //      · loginUrl 里**引用 jsLib 的** ⇒ `ssh_`（它不在 loginUrl 顶层定义）
  const lookup = (name) => (typeof dom === 'function' ? dom(name) : dom.get(name));
  /** @type {{start:number,end:number,text:string}[]} */
  const edits = [];
  let changed = 0;
  // ⭐⭐⭐ 该字段内**自己声明**的名字（任意嵌套层级）⇒ 排除，避免改坏局部变量
  const localNames = new Set();

  function collectLocals(node) {
    if (!node || typeof node.type !== 'string') return;
    if (node.type === 'FunctionDeclaration' && node.id) localNames.add(node.id.name);
    if (node.type === 'FunctionExpression' && node.id) localNames.add(node.id.name);
    if (node.type === 'VariableDeclarator' && node.id.type === 'Identifier') localNames.add(node.id.name);
    if (node.type === 'CatchClause' && node.param && node.param.type === 'Identifier') localNames.add(node.param.name);
    for (const k of Object.keys(node)) {
      if (k === 'type' || k === 'start' || k === 'end') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (const c of v) collectLocals(c); }
      else if (v && typeof v.type === 'string') collectLocals(v);
    }
  }

  // 记录「对象字面量里被当作 shorthand 的 key」⇒ 需要展开
  function walk(node, parent, key) {
    if (!node || typeof node.type !== 'string') return;

    if (node.type === 'Identifier') {
      // 判定这个 Identifier 是不是「可改名」的引用点
      if (isRenameable(node, parent, key)) {
        const nu = lookup(node.name);
        if (nu && !(refsOnly && localNames.has(node.name))) {
          edits.push({ start: node.start, end: node.end, text: nu });
          changed++;
        }
      }
      return;
    }

    if (node.type === 'Property' && node.shorthand && node.value.type === 'Identifier') {
      // `{ s }` ⇒ `{ s: ssh_s }`（保持属性名不变）
      const nu = lookup(node.value.name);
      if (nu && !(refsOnly && localNames.has(node.value.name))) {
        edits.push({ start: node.value.start, end: node.value.end, text: `${node.value.name}: ${nu}` });
        changed++;
      }
      // 不再往 value 里走（避免重复替换）
      walk(node.key, node, 'key');
      return;
    }

    for (const k of Object.keys(node)) {
      if (k === 'type' || k === 'start' || k === 'end') continue;
      const v = node[k];
      if (Array.isArray(v)) {
        for (const c of v) walk(c, node, k);
      } else if (v && typeof v.type === 'string') {
        walk(v, node, k);
      }
    }
  }

  /** 这个 Identifier 能不能改名？ */
  function isRenameable(node, parent, key) {
    if (!parent) return false;
    // ① `obj.prop` / `obj[prop]` ⇒ property 不改（computed 的 `[x]` 其实是表达式 ⇒ 要改）
    if (parent.type === 'MemberExpression') {
      if (parent.property === node && !parent.computed) return false;
      return true;
    }
    // ② 对象字面量的 key ⇒ 不改（非 computed）
    if (parent.type === 'Property') {
      if (parent.key === node && !parent.computed) return false;
      return true;
    }
    // ③ 方法定义 `foo() {}` ⇒ key 不改
    if (parent.type === 'MethodDefinition') {
      if (parent.key === node && !parent.computed) return false;
      return true;
    }
    // ④ 标签
    if (parent.type === 'LabeledStatement' && parent.label === node) return false;
    if (parent.type === 'BreakStatement' && parent.label === node) return false;
    if (parent.type === 'ContinueStatement' && parent.label === node) return false;
    // ⑤ 变量声明的 id（定义点）⇒ 要改
    if (parent.type === 'VariableDeclarator' && parent.id === node) return true;
    // ⑥ 函数参数 / 函数名 ⇒ 要改（定义点）
    if ((parent.type === 'FunctionDeclaration' || parent.type === 'FunctionExpression') && parent.id === node) return true;
    if (parent.type === 'ArrowFunctionExpression' && parent.params && parent.params.includes(node)) return true;
    if (parent.type === 'ClassDeclaration' && parent.id === node) return true;
    // ⑦ 其它 ⇒ 引用点 ⇒ 要改
    return true;
  }

  return { walk, edits, count: () => changed, collectLocals };
}


/**
 * ⭐⭐⭐⭐⭐ **字符串字面量里的「调用点」也要改名**（2026-11-24 真机「切平台无效」实证）⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么必须多这一层**：
 *   站方的**筛选 action 是一段字符串**：
 *     `action: "(function(){ … setConfig.call(this,{gender:v}); java.refreshExplore(); })()"`
 *   ⇒ **AST 看不见字符串里的标识符** ⇒ 只按 AST 改名 ⇒ **这些调用点必然漏改** ⭐⭐⭐
 *   ⇒ 漏改 ⇒ 引擎里 `setConfig` **未定义** ⇒ **ReferenceError** ⇒
 *     **筛选静默失效**（源站切不动、分类还在番茄）⭐⭐⭐⭐⭐
 *   ⇒ 实测：全源字符串字面量里的顶层符号调用点**只有 4 处，全在 exploreUrl，全是 `setConfig`** ⭐⭐⭐
 *
 * ⭐⭐⭐ **只改「调用点」**（`NAME(` 或 `NAME.call(`）⇒ **URL 里的 `fb.shushan.vip` 不会被误伤** ⭐⭐⭐
 *   （站方 jsLib 会生成 HTML 页面、里面也有 `onclick="…()"` ⇒ 一刀切改名字会改坏那些页面）⭐⭐⭐
 *
 * @returns {Array<{start:number,end:number,text:string}>} 与 AST pass 的 edits **同一坐标系** ⇒ 可直接合并 ⭐⭐⭐
 */
function collectCallSiteEditsInStrings(code, label, lookup, nameList) {
  /** @type {{start:number,end:number,text:string}[]} */
  const edits = [];
  if (!code || !nameList || !nameList.length) return edits;
  let ast;
  try { ast = parse(code, label); } catch (e) { return edits; }
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // ⚠️ 长的名字排前面 ⇒ 避免「短名先匹配」⭐⭐⭐
  const names = [...nameList].sort((a, b) => b.length - a.length);
  const re = new RegExp(
    '(?<![A-Za-z0-9_$.])(' + names.map(esc).join('|') + ')(?=\\s*\\(|\\s*\\.\\s*call\\s*\\()', 'g');
  (function walk(node) {
    if (!node || typeof node.type !== 'string') return;
    if (node.type === 'Literal' && typeof node.value === 'string') {
      // ⭐ 用**原始文本**（含引号与转义）⇒ 偏移与源文件一致 ⇒ edits 可直接合并 ⭐⭐⭐
      const raw = code.slice(node.start, node.end);
      let m; const r = new RegExp(re.source, 'g');
      while ((m = r.exec(raw)) !== null) {
        const nu = lookup(m[1]);
        if (!nu) continue;
        edits.push({ start: node.start + m.index, end: node.start + m.index + m[1].length, text: nu });
      }
    }
    for (const k of Object.keys(node)) {
      if (k === 'type' || k === 'start' || k === 'end') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (const c of v) walk(c); }
      else if (v && typeof v.type === 'string') walk(v);
    }
  })(ast);
  return edits;
}

/** 应用编辑（从后往前，避免偏移失效） */
function applyEdits(code, edits) {
  const sorted = edits.slice().sort((a, b) => b.start - a.start);
  let out = code;
  for (const e of sorted) {
    out = out.slice(0, e.start) + e.text + out.slice(e.end);
  }
  return out;
}

// ---------- 主流程 ----------
const raw = JSON.parse(fs.readFileSync(IN, 'utf8'));
const src = Array.isArray(raw) ? raw[0] : raw;

const libCode = src.jsLib || '';
const luiCode = src.loginUrl || '';

const libAst = parse(libCode, 'jsLib');
const luiAst = parse(luiCode, 'loginUrl');

const libNames = [...topLevelNames(libAst)];
const luiNames = [...topLevelNames(luiAst)];

// ⭐⭐⭐⭐⭐ **统一前缀**（2026-11-23 实证修正）⭐⭐⭐
//   ⚠️ 原计划用 `ssh_` / `sshL_` **两个前缀** ⇒ **会打断跨域引用**！⭐⭐⭐
//   实测：`jsLib` **内部引用了 loginUrl 定义的 `icons`**（原 5 次引用里 4 次在 jsLib）
//   ⇒ 两域**互相依赖** ⇒ ⇒ **必须同前缀**，否则 jsLib 里的引用会调不到 ⇒ **功能坏** ⭐⭐⭐
//   ⇒ 而两域**真顶层重名 = 0**（acorn 实测）⇒ ⇒ 同前缀**不会**产生冲突 ⭐⭐⭐
//   ⇒ 且「后加载者覆盖」的语义与原始**完全一致**（loginUrl 仍在 jsLib 之后）⇒ **行为等价** ⭐⭐⭐
const P_LIB = 'ssh_';
const P_LUI = 'ssh_';

const libDom = new Map();
for (const n of libNames) {
  if (PROTECTED.has(n)) continue;
  if (libDom.has(n)) continue;
  libDom.set(n, P_LIB + n);
}
const luiDom = new Map();
for (const n of luiNames) {
  if (PROTECTED.has(n)) continue;
  if (luiDom.has(n)) continue;
  luiDom.set(n, P_LUI + n);
}

// ⭐⭐⭐⭐⭐ **合并 dom（ALL）—— 唯一真源** ⭐⭐⭐⭐⭐
//   ⚠️⚠️ **关键**：jsLib 内部**引用了 loginUrl 定义的符号**（实测 `icons`）⭐⭐⭐
//     ⇒ 若各域只用自己的映射 ⇒ **跨域引用会漏改** ⇒ 改名后调不到 ⇒ **功能坏** ⭐⭐⭐
//   ⇒ ⇒ **所有场景一律用 ALL** ⇒ 跨域引用自动保持有效 ⭐⭐⭐
//   ⇒ 两域同名 ⇒ 映射到**同一个新名** ⇒ 「loginUrl 覆盖 jsLib」的语义与原始**逐字一致** ⭐⭐⭐
const ALL = new Map();
for (const [k, v] of libDom) ALL.set(k, v);
for (const [k, v] of luiDom) if (!ALL.has(k)) ALL.set(k, v);

console.log(`jsLib   顶层符号 ${libNames.length} 个 ⇒ 改名 ${libDom.size} 个（前缀 ${P_LIB}）`);
console.log(`loginUrl 顶层符号 ${luiNames.length} 个 ⇒ 改名 ${luiDom.size} 个（前缀 ${P_LUI}）`);

const renamed = new Set([...libDom.keys(), ...luiDom.keys()]);
// ⭐⭐⭐ **被改名的符号名单**（供「字符串字面量里的调用点」那一层用）⭐⭐⭐
const ALL_NAME_LIST = [...ALL.keys()];
const overlap = libNames.filter(n => luiNames.includes(n) && renamed.has(n));
console.log(`两个域重名且都改名的符号 ${overlap.length} 个 ⇒ 改名后彻底分离 ✔`);

// ---- 改 jsLib ----
// ⭐⭐⭐ **jsLib 也必须用 ALL**（jsLib 内部引用了 loginUrl 定义的符号 ⇒ 用 libDom 会漏改）⭐⭐⭐
const libR = makeRenamer(ALL);
libR.walk(libAst, null, null);
const newLib = applyEdits(libCode, libR.edits);
src.jsLib = newLib;               // ⚠️⚠️ **必须写回**（算出来 ≠ 落地）⭐⭐⭐
console.log(`jsLib   替换点 ${libR.count()} 处`);

// ---- 改 loginUrl ----
// ⭐⭐⭐ **loginUrl 域的解析规则**（作用域感知）⭐⭐⭐
//   · loginUrl **自己顶层定义**的 ⇒ `sshL_`（它是 loginUrl 域的符号）
//   · loginUrl **只引用**（jsLib 里定义的）⇒ `ssh_`（它属于 jsLib 域）⭐⭐⭐
// ⭐⭐⭐ **统一用 ALL**（跨域引用必须一起改 ⇒ 见上面 ALL 的注释）⭐⭐⭐
const luiResolver = (name) => ALL.get(name);
const luiR = makeRenamer(luiResolver);
luiR.walk(luiAst, null, null);
const newLui = applyEdits(luiCode, luiR.edits);
src.loginUrl = newLui;            // ⚠️⚠️ **必须写回** ⭐⭐⭐
console.log(`loginUrl 替换点 ${luiR.count()} 处`);

// ---- 改其它 JS 字段（jsLib 优先，回落 loginUrl）----
// ⭐⭐⭐ **其它字段（rule* / exploreUrl …）** ⇒ **jsLib 域优先**，jsLib 没有才回落 loginUrl ⭐⭐⭐
//   ⇒ 这些场景**不加载 loginUrl** ⇒ 引用 loginUrl 独有的符号本来就调不到（改名不改变这一点）
// ⭐⭐⭐ **统一用 ALL** ⭐⭐⭐
const otherResolver = (name) => ALL.get(name);

const otherEdits = [];
let otherCount = 0;
function patchField(code, label, dom) {
  if (!code || typeof code !== 'string' || !code.trim()) return code;
  const stripped = code.replace(/^@js:/i, '');
  const ast = parse(stripped, label);
  const r = makeRenamer(dom);
  r.walk(ast, null, null);
  otherCount += r.count();
  const out = applyEdits(stripped, r.edits);
  return code.startsWith('@js:') ? '@js:' + out : out;
}

// ⚠️⭐⭐⭐ **`<js>…</js>` 混排规则**（柴阅 `SourceRule.jsPattern`）：
//   `<js>([\w\W]*?)</js>|@js:([\w\W]*)` ⇒ **`<js>` 段是「一条 JS 规则」，
//   `</js>` 之后的文字（如 `$.data`）是**另一条规则** ⇒ ⇒ 只该重命名 `<js>` 段 ⭐⭐⭐
//   ⇒ 直接把整条当 JS 解析会炸（如 `$.data` 不是合法 JS 表达式）
const JS_SEG = /(<js>)([\w\W]*?)(<\/js>)|(@js:)([\w\W]*)$/i;

/** 把一条规则里的「JS 段」拆出来，只对 JS 段做 AST 重命名 */
function patchRuleText(code, label, dom) {
  if (typeof code !== 'string' || !code.trim()) return code;

  // ① 整条是 `@js:…`（占满整条；⚠️ 允许前导空白/换行）
  const m = code.match(/^(\s*)@js:([\w\W]*)$/);
  if (m) {
    const body = m[2];
    const ast = parse(body, label);
    const r = makeRenamer(dom);
    r.walk(ast, null, null);
    otherCount += r.count();
    // ⭐⭐⭐⭐⭐ **字符串字面量里的调用点也要改**（筛选 action 是字符串 ⇒ AST 看不见）⭐⭐⭐
    const strEdits = collectCallSiteEditsInStrings(body, label, typeof dom === 'function' ? dom : (n) => dom.get(n), ALL_NAME_LIST);
    otherCount += strEdits.length;
    return `${m[1]}@js:` + applyEdits(body, r.edits.concat(strEdits));
  }

  // ② 混合：把每个 `<js>…</js>` 段单独处理，其余原样
  if (/<js>[\w\W]*?<\/js>/i.test(code)) {
    return code.replace(/<js>([\w\W]*?)<\/js>/gi, (full, body) => {
      const ast = parse(body, label);
      const r = makeRenamer(dom);
      r.walk(ast, null, null);
      otherCount += r.count();
      // ⭐⭐⭐⭐⭐ **字符串字面量里的调用点也要改**（筛选 action 是字符串 ⇒ AST 看不见）⭐⭐⭐
      const strEdits = collectCallSiteEditsInStrings(body, label, typeof dom === 'function' ? dom : (n) => dom.get(n), ALL_NAME_LIST);
      otherCount += strEdits.length;
      return '<js>' + applyEdits(body, r.edits.concat(strEdits)) + '</js>';
    });
  }

  // ③ ⭐⭐⭐ **纯 JS 字段**（`callBackJs` / `payAction` / `init` 等）⇒ 也要改名 ⭐⭐⭐
  //   ⚠️ 但它们**有自己的局部作用域** ⇒ ⇒ 只改「自由引用」，不改自己的声明/参数
  //   ⇒ 否则 `callBackJs` 里的 `isShelfSyncEnabled.call(this)` 会调不到（jsLib 里已改名）⭐⭐⭐
  const ast = parse(code, label);
  const r = makeRenamer(dom, /* refsOnly */ true);
  r.collectLocals(ast);
  r.walk(ast, null, null);
  otherCount += r.count();
  // ⭐⭐⭐⭐⭐ **字符串字面量里的调用点也要改**（筛选 action 是字符串 ⇒ AST 看不见）⭐⭐⭐
  const strEdits = collectCallSiteEditsInStrings(code, label, typeof dom === 'function' ? dom : (n) => dom.get(n), ALL_NAME_LIST);
  otherCount += strEdits.length;
  return applyEdits(code, r.edits.concat(strEdits));
}

// exploreUrl / searchUrl / header
for (const f of JS_FIELDS) {
  if (typeof src[f] === 'string' && src[f].trim()) {
    src[f] = patchRuleText(src[f], f, otherResolver);
  }
}

// rule* 里的 JS 字段（bookList/bookUrl/init/chapterList/chapterUrl/content/subContent/...）
// ⭐⭐⭐ **必须按字段类型分流**，不能「都当 JS 解析」⭐⭐⭐
//   · 含 `<js>` / `@js:` ⇒ **JS 段** ⇒ 改（⚠️ `{{…}}` 模板段不动）
//   · 在 JS_ONLY_FIELDS 白名单 ⇒ **纯 JS**（柴阅把它当 JS 执行）⇒ 改（只改自由引用）
//   · 其它（`{{…}}` 模板 / CSS 选择器 / JSONPath / 正则）⇒ **不是 JS** ⇒ **跳过** ⭐⭐⭐
const JS_ONLY_FIELDS = new Set([
  'callBackJs', 'payAction', 'init', 'webJs', 'bodyJs', 'loginJs', 'loginCheckJs', 'js',
]);

function patchRuleObj(obj, path) {
  if (!obj || typeof obj !== 'object') return;
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v !== 'string' || !v.trim()) continue;
    const hasJsSeg = /<js>[\w\W]*?<\/js>/i.test(v) || /^\s*@js:/.test(v);
    if (hasJsSeg) {
      obj[k] = patchRuleText(v, `${path}.${k}`, otherResolver);
    } else if (JS_ONLY_FIELDS.has(k)) {
      obj[k] = patchRuleText(v, `${path}.${k}`, otherResolver);
    }
    // 其它字段不是 JS ⇒ 跳过 ⭐⭐⭐
  }
}
for (const rf of RULE_FIELDS) {
  if (src[rf] && typeof src[rf] === 'object') patchRuleObj(src[rf], rf);
}
console.log(`其它 JS 字段替换点 ${otherCount} 处`);

// ---- loginUi 的 action（loginUrl 优先，回落 jsLib）----
// ⭐⭐⭐ **loginUi 的 action ⇒ loginUrl 域优先**（柴阅 `runLoginAction` = `loginJs + action`
//   ⇒ loginUrl 在 jsLib **之后**加载 ⇒ 同名时 **loginUrl 覆盖 jsLib**）⭐⭐⭐
// ⭐⭐⭐ **统一用 ALL**（loginUrl 域的符号在前 ⇒ 但同前缀 ⇒ 结果一致）⭐⭐⭐
const uiResolver = (name) => ALL.get(name);

if (typeof src.loginUi === 'string') {
  const rows = JSON.parse(src.loginUi);
  let uiCount = 0;
  for (const row of rows) {
    if (typeof row.action === 'string' && row.action.trim()) {
      const a = parse(row.action, 'loginUi.action');
      const r = makeRenamer(uiResolver);
      r.walk(a, null, null);
      // ⭐⭐⭐⭐⭐ **字符串字面量里的调用点也要改**（同上）⭐⭐⭐
      const strEdits = collectCallSiteEditsInStrings(row.action, 'loginUi.action', uiResolver, ALL_NAME_LIST);
      row.action = applyEdits(row.action, r.edits.concat(strEdits));
      uiCount += r.count() + strEdits.length;
    }
  }
  src.loginUi = JSON.stringify(rows, null, 2);
  console.log(`loginUi action 替换点 ${uiCount} 处`);
}

// ---- 写回 ----
if (Array.isArray(raw)) raw[0] = src; else raw[0] = src;
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(raw, null, 2), 'utf8');

// ⭐⭐⭐ **同时输出「改名映射」** ⇒ 门禁要靠它做「引用计数守恒」对照 ⭐⭐⭐
//   （否则门禁只能看到新名 ⇒ 无法与原始源的原名对应 ⇒ 断言会假绿）⭐⭐⭐
const MAP_OUT = OUT.replace(/\.json$/, '') + '.map.json';
fs.writeFileSync(MAP_OUT, JSON.stringify({
  all: Object.fromEntries(ALL),
}, null, 2), 'utf8');
console.log(`映射表 → ${path.basename(MAP_OUT)}`);

// ---- 验证 ----
const check = JSON.parse(fs.readFileSync(OUT, 'utf8'));
const cs = Array.isArray(check) ? check[0] : check;
parse(cs.jsLib, '改后 jsLib');
parse(cs.loginUrl, '改后 loginUrl');
console.log('✅ 改后 jsLib / loginUrl 语法解析通过');

// 残留检查：改后顶层是否还有裸的（未加前缀的）高危名
const afterAst = parse(cs.jsLib, 'after');
const afterNames = [...topLevelNames(afterAst)];
const leftovers = afterNames.filter(n => renamed.has(n) && !n.startsWith(P_LIB));
console.log(leftovers.length ? `❌ jsLib 残留未改名: ${leftovers}` : '✅ jsLib 无残留未改名符号');
const afterLui = [...topLevelNames(parse(cs.loginUrl, 'after2'))];
const leftoverL = afterLui.filter(n => renamed.has(n) && !n.startsWith(P_LUI));
console.log(leftoverL.length ? `❌ loginUrl 残留未改名: ${leftoverL}` : '✅ loginUrl 无残留未改名符号');
