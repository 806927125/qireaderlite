#!/usr/bin/env node
/**
 * 引擎脚本**静态检查**（eslint no-undef）
 *
 * 跑法：node test/engine-lint.test.js
 *
 * ## 为什么必须有这个（一次真实事故）
 *
 * 踩过：`mergedHosts` **用了但没声明**（漏了 `var`）。
 * 后果不是「某个功能不好用」，而是：
 *   `__qrInstallCookieSnapshot` 每个 op 开头都执行 `mergedHosts = {}`
 *   → 严格模式下 → **ReferenceError: Can't find variable: mergedHosts**
 *   → **每个 op 都失败** → 引擎等于废了 → 用户看到「登录都点不了了」
 *
 * ## 为什么 jsdom 抓不到
 *
 * ① **node 的 vm 上下文用 Proxy 拦全局对象** → `"use strict"` 对未声明变量赋值
 *    **根本不抛**（`has` 陷阱一律返回 true）→ jsdom 永远测不出来
 *    （实测：vm.runInContext 里严格模式赋值未声明变量 → 不抛）
 * ② 而且 WKWebView 里的行为**只在真机**复现 → 只能靠**静态检查**
 *
 * ⇒ 所以这条门禁用 eslint 的 `no-undef`。
 *
 * ## 假阳性怎么办
 *
 * 引擎里**合法**引用了站方 jsLib 定义的全局（host / getArgument / setArgument /
 * getKey / putLoginInfo / isVips …）—— 那些是**运行时**才有的。
 * ⇒ 把**站方自己声明的名字**抽出来当白名单（从聚合源文件的 jsLib/loginUrl 里抽），
 *   剩下的「用了没声明」才是真 bug。
 * ⚠️ 聚合源文件不在本机时 → 跳过这一条（跟其它依赖本机文件的门禁一样）。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENGINE = path.join(ROOT, 'QiReaderLite', 'Resources', 'engine');
const SRC = process.env.SRC_OUT ||
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json';

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// 浏览器/引擎内建的全局（不属于站方）
const BUILTIN = [
  'window', 'document', 'console', 'self', 'globalThis', 'global',
  'JSON', 'Math', 'Date', 'Object', 'Array', 'String', 'Number', 'Boolean',
  'RegExp', 'Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError',
  'EvalError', 'URIError', 'Promise', 'Symbol', 'Proxy', 'Reflect', 'Map', 'Set',
  'WeakMap', 'WeakSet', 'ArrayBuffer', 'DataView', 'Uint8Array', 'Int8Array',
  'Uint8ClampedArray', 'Uint16Array', 'Int16Array', 'Uint32Array', 'Int32Array',
  'Float32Array', 'Float64Array', 'BigInt', 'BigInt64Array', 'BigUint64Array',
  'URL', 'URLSearchParams', 'TextDecoder', 'TextEncoder', 'atob', 'btoa',
  'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'encodeURI',
  'encodeURIComponent', 'decodeURI', 'decodeURIComponent', 'escape', 'unescape',
  'undefined', 'NaN', 'Infinity', 'eval', 'Function', 'arguments',
  'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
  'requestAnimationFrame', 'cancelAnimationFrame', 'queueMicrotask',
  'structuredClone', 'fetch', 'Headers', 'Request', 'Response', 'FormData',
  'Blob', 'File', 'FileReader', 'Image', 'performance', 'navigator', 'location',
  'crypto', 'XMLHttpRequest', 'DOMParser', 'Node', 'Element', 'HTMLElement',
  'Event', 'CustomEvent', 'MutationObserver',
  // CommonJS（sha1.js 里有几处兜底）
  'process', 'module', 'require', 'define',
  // Java 兼容层
  'Packages', 'org', 'java', 'XPathResult', 'XPathExpression', 'XPathNSResolver',
  // JavaImporter / importPackage：packages_stub.js 在**非严格模式**下赋值的全局（合法）
  'JavaImporter', 'importPackage',
];

(async () => {
  // ── 1. 抽站方自己声明的全局（白名单）──
  let station = [];
  if (fs.existsSync(SRC)) {
    const raw = JSON.parse(fs.readFileSync(SRC, 'utf8'));
    const s = Array.isArray(raw) ? raw[0] : raw;
    const blob = (s.jsLib || '') + '\n' + (s.loginUrl || '');
    const m = blob.match(/\b(?:function|var|let|const)\s+([A-Za-z_$][\w$]*)/g) || [];
    station = [...new Set(m.map(x => x.replace(/^\s*\w+\s+/, '')))];
    console.log(`ℹ️  站方声明的全局：${station.length} 个（当白名单）`);
  } else {
    console.log('ℹ️  聚合源文件不在本机 → 站方白名单为空（可能有假阳性）');
  }

  // ── 2. 跑 eslint no-undef ──
  let ESLint;
  try {
    ({ ESLint } = require('eslint'));
  } catch (e) {
    console.log('ℹ️  没装 eslint → 跳过（npm i eslint --registry=https://registry.npmmirror.com）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(0);
  }

  // ── 逐文件算白名单 ──
  // ⚠️ 关键：**别的引擎文件里声明的**也算合法（跨文件引用，
  //    比如 packages_stub.js 用 packages-native.js 定义的 _native* ）；
  //    但**自己文件里没声明**的 → 就是真 bug（mergedHosts 就是这么漏的）。
  const fileNames = fs.readdirSync(ENGINE).filter(f => f.endsWith('.js'));
  const declOf = {};
  for (const f of fileNames) {
    const code = fs.readFileSync(path.join(ENGINE, f), 'utf8');
    const m = code.match(/\b(?:function|var|let|const)\s+([A-Za-z_$][\w$]*)/g) || [];
    const set = new Set(m.map(x => x.replace(/^\s*\w+\s+/, '')));
    // ⚠️ 还有**属性赋值**形式：packages-native.js 里是 `W._nativeBase64Encode = function…`
    //    （不是 var/function 声明）→ 正则也要覆盖，否则全是假阳性
    const asg = code.match(/\.\s*([A-Za-z_$][\w$]*)\s*=\s*(?:function|\(|[A-Za-z_$])/g) || [];
    for (const a of asg) set.add(a.replace(/^\.\s*/, '').replace(/\s*=.*$/, ''));
    declOf[f] = set;
  }

  const problems = [];
  for (const f of fileNames) {
    const others = new Set();
    for (const g of fileNames) {
      if (g === f) continue;                 // ← 自己文件的声明**不算**白名单
      for (const n of declOf[g]) others.add(n);
    }
    const globals = {};
    for (const g of BUILTIN.concat(station).concat([...others])) globals[g] = 'readonly';

    const eslint = new ESLint({
      overrideConfigFile: true,
      overrideConfig: [{
        files: ['**/*.js'],
        languageOptions: { ecmaVersion: 2021, sourceType: 'script', globals },
        rules: { 'no-undef': 'error' },
      }],
    });
    const results = await eslint.lintFiles([path.join(ENGINE, f)]);
    for (const r of results) {
      for (const m of r.messages) {
        if (m.ruleId === 'no-undef') {
          problems.push(`${f}:${m.line}:${m.column}  '${m.message}'`);
        }
      }
    }
  }

  console.log('\n=== 引擎脚本 no-undef（用了没声明 = 真 bug）===');
  if (problems.length === 0) {
    pass++;
    console.log('  ✓ 没有「用了没声明」的变量');
  } else {
    fail++;
    console.log(`  ✗ 发现 ${problems.length} 处未声明的变量：`);
    for (const p of problems) console.log('      ' + p);
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
