// 引擎脚本的「顶层完成值」必须是 undefined
// 跑法：node test/engine-script-toplevel.test.js
//
// 为什么必须有这个门禁（2026-10-18 真机踩出来的）：
//   RuleSandbox 用 `evaluateJavaScript(code)` 注入引擎脚本，
//   而 WebKit 会把脚本的**完成值**桥接回 Swift。
//   普通 JS 对象 / 函数 / Symbol 桥接不了 → 抛
//   WKError.resultTypeIsUnsupported → 轻阅报「引擎脚本 X 执行出错」
//   → **整个引擎起不来**，所有书源全部不可用。
//
//   真机实测：packages_stub.js 的顶层完成值是 `function`（一个 JS 函数对象），
//   于是 9 个脚本注入到第 7 个就炸，书源页直接报「引擎未就绪」。
//
//   ⚠️ 这个 bug 在 jsdom 里**测不出来**：jsdom 的 runInContext 会老老实实
//      返回完成值，不会去桥接，所以原有 134 项门禁全绿、真机照样死。
//
//   断言必须直接测「加载这个文件的顶层完成值」，而不是测任何间接行为。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const ENGINE_DIR = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');
// 顺序必须与 RuleSandbox.swift 的 ResourceLocator.scripts 一致
const SCRIPTS = [
  'jsoup-compat.js',
  'sextant-filter.js', // 栖阅同款 Sextant 过滤表达式（必须在 jsonpath.js 前）
  'jsonpath.js',
  'org-jsoup.js',
  'sha1.js',
  'java-api.js',
  'packages-native.js',
  'packages_stub.js',
  'source-api.js',
  'rule-analyzer.js',
  'engine.js',
];

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

console.log('=== 1. 每个脚本的顶层完成值必须是 undefined ===');
(function () {
  for (const f of SCRIPTS) {
    const p = path.join(ENGINE_DIR, f);
    if (!fs.existsSync(p)) { check(`${f} 存在`, false, '文件不存在'); continue; }
    // 每个脚本用**全新的** context，避免互相污染
    const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>',
      { url: 'https://book.example.com/', runScripts: 'outside-only', pretendToBeVisual: true });
    const ctx = dom.getInternalVMContext();
    dom.window.webkit = { messageHandlers: { qr: { postMessage() {} } } };
    let top;
    try {
      top = vm.runInContext(fs.readFileSync(p, 'utf8'), ctx, { filename: f });
    } catch (e) {
      check(`${f} 顶层完成值 undefined`, false, '抛错: ' + e.message);
      continue;
    }
    const t = top === undefined ? 'undefined' : (top === null ? 'null' : typeof top);
    check(`${f} 顶层完成值 undefined`, top === undefined, `实际是 ${t}`);
  }
})();

console.log('\n=== 2. 模拟真机注入方式：包一层 void 0 后完成值必须是 undefined ===');
(function () {
  // 这就是 RuleSandbox 现在的做法。jsdom 侧验证它确实把任意完成值压成 undefined。
  const dom = new JSDOM('<!doctype html><html><body></body></html>',
    { url: 'https://book.example.com/', runScripts: 'outside-only' });
  const ctx = dom.getInternalVMContext();
  const code = 'function f(){}\nf;';                       // 顶层完成值是 function
  const raw = vm.runInContext(code, ctx);
  check('未包 void 时完成值是 function（复现真机炸的那个条件）', typeof raw === 'function', typeof raw);
  const dom2 = new JSDOM('<!doctype html><html><body></body></html>',
    { url: 'https://book.example.com/', runScripts: 'outside-only' });
  const ctx2 = dom2.getInternalVMContext();
  const wrapped = vm.runInContext(code + '\n;void 0;', ctx2);
  check('包上 "\\n;void 0;" 后完成值是 undefined', wrapped === undefined, typeof wrapped);
})();

console.log('\n=== 3. 包一层之后，脚本功能不受影响（真机可用）===');
(function () {
  const { createSandbox } = require('./harness');
  const { win } = createSandbox();
  const ok = win.eval("typeof Packages === 'object' && typeof Packages.javax.crypto.Cipher === 'object'")
    && typeof win.eval("typeof signFree !== 'undefined'") !== 'undefined';
  check('包 void 0 之后 Packages 仍可用', !!ok);
  check('包 void 0 之后 __qrInvoke 仍可调', typeof win.__qrInvoke === 'function');
})();

console.log('\n' + '═'.repeat(52));
console.log(`  通过 ${passed}  失败 ${failed}`);
console.log('═'.repeat(52));
process.exit(failed === 0 ? 0 : 1);
