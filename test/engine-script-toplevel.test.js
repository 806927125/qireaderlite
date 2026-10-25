#!/usr/bin/env node
// 引擎的「顶层完成值」不能把引擎搞挂
// 跑法：node test/engine-script-toplevel.test.js
//
// 为什么必须有这个门禁（2026-10-18 真机踩出来的）：
//   老引擎用 `evaluateJavaScript(code)` 注入引擎脚本，
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
//
// ────────────────────────────────────────────────────────────
// ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改验新引擎**（Swift，`legado-engine`）⭐⭐⭐
//
// 迁移要点：
//   ① 「每个 .js 脚本的顶层完成值必须是 undefined」这一段 ⇒ **退休**（规范 §2.1）
//      ⇒ 老引擎那些 `.js`（jsoup-compat / java-api / packages_stub / source-api /
//        rule-analyzer / engine.js …）**已物理删除** ⇒ 新引擎把它们**编进 Swift**
//        （`JavaCompat.swift` / `JSHostAPI.swift` / `SourceEngine.swift`）
//        ⇒ **没有等价物**（不是「文件搬了家」，是**根本没有 JS 文件**了）⭐⭐⭐
//   ② 但这条门禁的**语义**（「顶层完成值不该把引擎搞挂」）**在新架构下依然成立**
//      ⇒ 老引擎的炸法是「完成值是 function ⇒ WebKit 桥接不了」
//      ⇒ 新引擎的对应风险是「站方代码的完成值是函数/对象 ⇒ 引擎自己处理不了」
//      ⇒ **改成真跑**：让引擎求值一个「顶层完成值是函数」的脚本 ⇒ 必须不炸 ⭐⭐⭐
//   ③ 「包一层 void 0」那段 ⇒ **退休**（那是老引擎的注入技巧，新引擎不注入脚本文件）
//      ⇒ 等价语义（「引擎的 JS 装载后，宿主能力仍然可用」）**保留**，改成跑新引擎 ⭐⭐⭐
// ────────────────────────────────────────────────────────────
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

// ⭐⭐⭐ **引擎不可用 ⇒ 显式 SKIP**（规范 §3.4：「没验到」≠「通过」）⭐⭐⭐
if (!engineAvailable()) {
  console.log('⏭ 跳过：新引擎（legado-engine 的 conformance）不在本机 ⇒ 引擎**没验到**');
  console.log('\n' + '═'.repeat(52));
  console.log(`  通过 ${passed}  失败 ${failed}`);
  console.log('═'.repeat(52));
  process.exit(0);
}

console.log('=== 1. ⭐⭐⭐⭐⭐ 老引擎实现细节断言已退休（2026-10-25 老 JS 引擎物理删除）');
console.log('===    ⇒ 以前验的是**老引擎的 .js 文件的顶层完成值**（jsoup-compat / java-api /');
console.log('===      packages_stub / source-api / rule-analyzer / engine.js …）');
console.log('===    ⇒ 那些文件**已物理删除** ⇒ 新引擎把它们**编进 Swift** ⇒ **没有等价物**');
console.log('===    ⇒ 退休**不损失语义覆盖** ⭐⭐⭐');
console.log('===    ⇒ **语义覆盖在下面【新引擎真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐');
console.log('===    ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐');
console.log('=== 2. 新引擎：站方代码的「顶层完成值」不能把引擎搞挂 ===');
{
  const { win } = createSandbox();
  // ⚠️ **老引擎炸的正是这个条件**：顶层完成值是 **function** ⇒ WebKit 桥接不了 ⇒ 引擎起不来
  //   ⇒ 新架构（Swift + JSC/Node）里，完成值由引擎自己转成 JSONValue ⇒ **不许炸** ⭐⭐⭐
  let err = null;
  let val = null;
  try { val = win.eval('function f(){}\nf;'); } catch (e) { err = e; }
  check('顶层完成值是 function 的脚本 ⇒ 引擎不炸', !err,
        err ? String(err.message || err) : undefined);
  check('顶层完成值是 function 的脚本 ⇒ 有值（不是异常）', val !== null && val !== undefined,
        '实际：' + JSON.stringify(val));

  // 对象完成值（老引擎也桥接不了）⇒ 同样不许炸
  err = null;
  try { val = win.eval('({a:1})'); } catch (e) { err = e; }
  check('顶层完成值是对象的脚本 ⇒ 引擎不炸', !err,
        err ? String(err.message || err) : undefined);
  check('顶层完成值是对象的脚本 ⇒ 值拿得到', String(val).indexOf('"a":1') >= 0,
        '实际：' + JSON.stringify(val));
}

console.log('\n=== 3. 引擎的 JS 层装载后，宿主能力仍然可用（真机可用）===');
{
  const { win } = createSandbox();
  // ⭐ 老门禁的等价语义：「包 void 0 之后 Packages 仍可用 / op 入口仍可调」
  //   ⇒ 新架构里没有「包 void 0」这一步（不注入 JS 文件）⇒ 改成「装载后能力仍在」⭐⭐⭐
  const ok = win.eval("typeof Packages === 'object' && typeof Packages.javax.crypto.Cipher === 'object'");
  check('Java 兼容层（Packages）装载后仍可用', ok === 'true', '实际：' + JSON.stringify(ok));

  const ok2 = win.eval("typeof java === 'object' && typeof java.timeFormat === 'function'");
  check('宿主 API（java.*）装载后仍可用', ok2 === 'true', '实际：' + JSON.stringify(ok2));

  // ⭐⭐⭐ **op 入口仍可调**（老门禁断言的是 `typeof win.__qrInvoke === 'function'`
  //   ⇒ 那是**恒真**的（断言的是 harness 自己的对象）⇒ 抓不到任何 bug ⭐⭐⭐
  //   ⇒ 改成**真跑一个 op**（老引擎那段是「恒真 ⇒ 白测」）⭐⭐⭐
  let opErr = null;
  let opRes = null;
  try {
    opRes = win.__qrInvoke('login', {
      source: {
        bookSourceName: '顶层完成值门禁',
        bookSourceUrl: 'https://toplevel.example/',
        loginUrl: "function smoke(){ java.toast('ok'); return 'ok'; }",
      },
      action: 'smoke()',
      formValues: {},
      routes: [{ match: 'toplevel.example', status: 200, body: '{"ok":1}' }],
    });
  } catch (e) { opErr = e; }
  check('op 入口仍可调（真跑一个 op，不是恒真断言）', !opErr && opRes && opRes.ok === true,
        opErr ? String(opErr.message || opErr)
              : ('实际：' + JSON.stringify(opRes && (opRes.error || opRes.ok))));
}

console.log('\n=== 4. 站方 jsLib 装载后不抛（全局作用域那一套还在）===');
{
  const { win } = createSandbox();
  let err = null;
  try {
    // 站方 jsLib 的典型写法：顶层 `var` + 函数声明（间接 eval ⇒ 留在全局）
    win.eval('var __qrTopLevelProbe = 1; function __qrTopLevelFn(){ return 2; }');
  } catch (e) { err = e; }
  check('站方 jsLib 的顶层声明不抛', !err, err ? String(err.message || err) : undefined);
}

console.log('\n' + '═'.repeat(52));
console.log(`  通过 ${passed}  失败 ${failed}`);
console.log('═'.repeat(52));
process.exit(failed === 0 ? 0 : 1);
