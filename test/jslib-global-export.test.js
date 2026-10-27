#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **jsLib 的顶层 `let`/`const` 必须在规则里可见**（2026-10-27 真机实证）
 *
 * 跑法：node test/jslib-global-export.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **真机症状**：详情「bookUrl 为空」/ 目录「URL 为空」
 *   诊断：规则 `…@js: let type = baseUrl.match(new RegExp(api + '/(\w+)/'))…`
 *   分支 = || 兜底链 失败 = noMatch
 *
 * ⭐⭐⭐ **根因（不是 URL 规则的问题，是【全局可见性】）**：
 *   jsLib 是用**间接 eval** `(0,eval)(code)` 加载的
 *   ⇒ 顶层 `function` / `var` 会进全局，但 **`let` / `const` 是 eval 局部** ⇒ 不是全局 ⭐
 *   ⇒ 站方 jsLib 的 `let api = 'https://…'`（UAA 源用的）**规则里看不见**
 *   ⇒ 规则里的 `@js:` 一调就 ReferenceError ⇒ URL 空 ⇒ bookUrl 空 ⭐⭐⭐
 *   ⚠️ 只有**函数**能摸到它（闭包捕获了 eval 的词法环境）⇒
 *     「jsLib 定义函数 → 规则里调函数」能work，「规则直接引用顶层 let」必挂 ⭐
 *
 * ⚠️ **为什么沙盒全绿、真机全挂**：
 *   引擎的 JSC / Node 后端都有「同段脚本末尾显式导出全局」这步
 *   ⇒ **只有 App 自己的 WebView 后端漏了** ⇒ 手机走 WebView ⇒ 只有手机挂 ⭐⭐⭐
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁做四件事：
 *   ① **活体**：jsLib 里的顶层 `let` ⇒ URL 规则里必须能**直接引用**（用老引擎的加载路径）
 *   ② **变异对照**：把导出改掉 ⇒ 必须红（证明这道门禁有牙齿，不是恒真）
 *   ③ **静态**：App 的 WebView 后端（手机真正跑的那条）必须显式导出
 *   ④ **静态**：引擎侧的实现必须覆盖 `let`/`const`（找到引擎源码时才有 ⇒ 找不到就明说跳过）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const root = path.join(__dirname, '..');
const enginePath = path.join(root, 'QiReaderLite', 'Resources', 'engine', 'engine.js');
const wvPath = path.join(root, 'QiReaderLite', 'Engine', 'WebViewJSExecutor.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  ✗ ' + m + (extra ? '  → ' + extra : '')); }
};

// ⭐⭐⭐ **照抄 UAA 源的形状**：jsLib 里有**顶格 `let`**，规则里**直接引用**它
const JSLIB = [
  "let api = 'https://api.example.com'",
  "let hosts = ['h1.example.com']",
  "function apiPath(p) { return api + p }",
].join('\n');

const SRC = {
  bookSourceUrl: 'https://x.example.com',
  bookSourceName: '顶层let可见性测试',
  jsLib: JSLIB,
  // ⭐ 关键：**直接引用 jsLib 的顶层 `let`**（不是调它的函数 —— 调函数是闭包，闭包摸得到 ⇒ 测不出这个 bug）
  searchUrl: '@js: api + "/search?kw=" + key',
  ruleSearch: {
    bookList: '$.data[*]', name: '$.title', author: '$.author', bookUrl: '$.url',
  },
};

async function runSearch() {
  let seenURL = '';
  const nativeMock = async (fn, args) => {
    if (fn === 'request') {
      seenURL = String(args.url || '');
      return { ok: true, code: 200, url: seenURL, headers: {},
               body: JSON.stringify({ data: [{ id: 'b1', title: '书', author: '作者',
                                              url: 'https://x.example.com/b/1' }] }) };
    }
    if (fn === 'log' || fn === 'toast') return { ok: true };
    if (fn === 'deviceID') return { ok: true, value: 'test-device' };
    return { ok: true, value: '' };
  };
  const { win } = createSandbox({ nativeMock });
  const r = await win.eval('window.__qrInvoke(\'search\', ' + JSON.stringify({
    source: SRC, keyword: '测试', page: 1, cookieSnapshot: {},
  }) + ')');
  return { url: seenURL, result: r };
}

(async () => {
  console.log('=== 1. 活体：jsLib 的顶层 `let` ⇒ URL 规则里必须能直接引用 ===');
  const good = await runSearch();
  ok(good.url.indexOf('https://api.example.com/search?kw=') === 0,
     '⭐⭐⭐ 规则里能直接引用 jsLib 的顶层 `let api` ⇒ URL 用的是站方自己的 API 域名',
     '实际请求 URL = ' + JSON.stringify(good.url));
  ok((good.result && good.result.books || []).length === 1,
     '并且能出书（这条链路整条通）',
     JSON.stringify(good.result || {}).slice(0, 200));

  console.log('\n=== 2. 变异对照：把「显式导出」改掉 ⇒ 必须红（证明门禁有牙齿）===');
  const bak = fs.readFileSync(enginePath, 'utf8');
  try {
    fs.writeFileSync(enginePath, bak.replace('__exp(__code)', '__code'), 'utf8');
    const bad = await runSearch();
    ok(bad.url.indexOf('https://api.example.com') !== 0,
       '变异版（去掉导出）拿不到顶层 `let` ⇒ 这道门禁抓得住这个 bug',
       '变异版实际请求 URL = ' + JSON.stringify(bad.url));
  } finally {
    fs.writeFileSync(enginePath, bak, 'utf8');
  }

  console.log('\n=== 3. 静态：App 的 WebView 后端（手机真正跑的那条）必须显式导出 ===');
  const wv = fs.readFileSync(wvPath, 'utf8');
  const start = wv.indexOf('func runGlobal');
  ok(start >= 0, 'WebViewJSExecutor 里有 runGlobal（jsLib 的加载入口）');
  const body = start >= 0 ? wv.slice(start, start + 3000) : '';
  ok(/JSScopeBuilder\.withExplicitGlobalExport/.test(body),
     '⭐⭐⭐ runGlobal 里用了 JSScopeBuilder.withExplicitGlobalExport（与 JSC/Node 后端同款）');
  ok(/withExplicitGlobalExport\(code\)/.test(body) && /jsonLiteral\(exported\)/.test(body),
     '⭐⭐⭐ 求值的正是【导出后】的代码（不是原始 code ⇒ 导出码进不了同一个 eval 就白搭）');
  ok(/let exported = JSScopeBuilder\.withExplicitGlobalExport\(code\)/.test(body),
     '导出码与原代码在**同一个 eval**里（才能看见 eval 局部的 let）');

  console.log('\n=== 4. 静态：引擎侧的实现必须覆盖 `let`/`const` ===');
  const engineCandidates = [
    '/workspace/legado-engine-git',
    '/workspace/legado-engine-main',
  ];
  // macOS CI：SPM 的 checkout 目录
  const dd = path.join(process.env.HOME || '', 'Library/Developer/Xcode/DerivedData');
  if (fs.existsSync(dd)) {
    try {
      for (const d of fs.readdirSync(dd)) {
        engineCandidates.push(path.join(dd, d, 'SourcePackages', 'checkouts', 'legado-engine'));
      }
    } catch (e) { /* 忽略 */ }
  }
  const engineDir = engineCandidates.find(p =>
    fs.existsSync(path.join(p, 'Sources', 'LegadoCore', 'JS', 'JSHostAPI.swift')));
  if (!engineDir) {
    console.log('  ⏭ 跳过：找不到引擎源码（' + engineCandidates.join(' / ') + '）'
                + ' ⇒ 引擎侧那一条**没验到**（不是通过）');
  } else {
    const src = fs.readFileSync(
      path.join(engineDir, 'Sources', 'LegadoCore', 'JS', 'JSHostAPI.swift'), 'utf8');
    const i = src.indexOf('public static func withExplicitGlobalExport');
    ok(i >= 0, '引擎侧有 withExplicitGlobalExport（public）');
    // ⚠️ 扫描名字的正则在**另一个函数**里（topLevelDeclaredNames）⇒ 别只截一段窗口
    const j = src.indexOf('public static func topLevelDeclaredNames');
    const fn = i >= 0 ? src.slice(i, i + 2200) : '';
    const namesFn = j >= 0 ? src.slice(j, j + 2200) : '';
    ok(/let/.test(fn) && /const/.test(namesFn) && /var/.test(namesFn),
       '⭐⭐⭐ 引擎侧的导出覆盖 `let`/`const`（不只是 function/var）');
    ok(/globalThis/.test(fn) && /this/.test(fn),
       '引擎侧写两个对象（globalThis + this）⇒ 与「基线取并集」口径一致');
    ok(/topLevelDeclaredNames/.test(src),
       '引擎侧只导**顶格**声明（函数体内的局部变量不导 ⇒ 不污染全局 ⇒ 不串源）');
  }

  console.log('\n通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
