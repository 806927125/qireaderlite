#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **JS 后端语义一致性门禁**（2026-10-26 真机回归实证）
 *
 * ────────────────────────────────────────────────────────────
 * 事故
 * ────────────────────────────────────────────────────────────
 *   Node 后端（Linux 沙盒跑）先修好了「站方 JS 只执行一次」
 *   ⇒ **但 JSC 后端（真机跑）漏了** ⇒ 真机上站方 JS 仍被执行 2~3 次
 *   ⇒ ⇒ `java.ajax` 调 2~3 次（限流打爆）· 日志写 2~3 倍（写盘翻倍）
 *   ⇒ ⇒ 站方 JS 副作用重复执行 ⇒ **「以前能加载、换引擎后不行」** ⭐⭐⭐
 *
 *   ⇒ **根因：两个后端的「求值形态选择」各写各的 ⇒ 必然漂移**
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁钉住：两个后端的形态选择**必须一致**
 * ────────────────────────────────────────────────────────────
 *   ① 都必须「静态选形态」（不是「跑到有值为止」）
 *   ② 对象字面量 ⇒ 整段当表达式
 *   ③ 其它 ⇒ Script 形态优先，**只有语法错**才换函数体形态
 *   ④ 都必须「执行成功就返回」（不因 undefined 再跑一遍）
 *   ⑤ 都**不许**静态判断「有没有顶层 return」
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENGINE_DIR = process.env.ENGINE_DIR || path.join(ROOT, '..', 'legado-engine');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const read = (p) => {
  try { return fs.readFileSync(p, 'utf8'); } catch (e) { return null; }
};

const jscPath = path.join(ENGINE_DIR, 'Sources', 'LegadoCore', 'JS', 'JSCExecutor.swift');
const nodePath = path.join(ENGINE_DIR, 'Sources', 'LegadoCore', 'JS', 'NodeJSExecutor.swift');
// ⭐⭐⭐ **形态的单一真相**（2026-10-26 重构）⇒ 两个后端都调它 ⇒ 不可能漂移
const shapePath = path.join(ENGINE_DIR, 'Sources', 'LegadoCore', 'JS', 'JSEvalShape.swift');

console.log('=== ① 两个后端的源码都在吗 ===');
const jsc = read(jscPath);
const node = read(nodePath);
const shape = read(shapePath);
ok(jsc !== null, 'JSCExecutor.swift 在（' + jscPath + '）');
ok(node !== null, 'NodeJSExecutor.swift 在（' + nodePath + '）');
ok(shape !== null, 'JSEvalShape.swift 在（形态的单一真相：' + shapePath + '）');

if (jsc && node) {
  console.log('');
  console.log('=== ② 形态脚本文本【只有一处生成】（2026-10-26 重构后）===');
  // ⭐⭐⭐⭐⭐ **最强的不变量**：两个后端**不各写各的** ⇒ 形态文本只存在于 `JSEvalShape.swift`
  //   ⇒ JSC 直接跑那份脚本文本；Node 把同一份脚本文本发给 harness
  //   ⇒ ⇒ **形态不可能漂移**（老架构下两边各拼各的 ⇒ 必然漂移）⭐⭐⭐
  ok(shape !== null, 'JSEvalShape.swift 在（形态的单一真相）');
  if (shape) {
    ok(/public static func scripts\(for code: String, scope: String\)/.test(shape),
       'JSEvalShape.scripts(for:scope:) 在（两个后端共用的入口）');
    ok(/JSEvalShape\.scripts\(for: code, scope: scope\)/.test(jsc),
       'JSC 后端调 JSEvalShape.scripts（不许自己拼脚本）');
    ok(/JSEvalShape\.scripts\(for: code, scope: scope\)/.test(node),
       'Node 后端调 JSEvalShape.scripts（不许自己拼脚本）');
    // ⭐⭐⭐ **形态链 = 老引擎（轻阅 rule-analyzer.js）同款三形态，且顺序不变**
    const idxEval = shape.indexOf('jsonLiteral(code)');
    const idxExpr = shape.indexOf('jsonLiteral("(" + code + ")")');
    const idxBody = shape.indexOf('jsonLiteral("(function(){" + code');
    ok(idxEval > 0, '形态①：直接 eval（老引擎同款）');
    ok(idxExpr > 0, '形态②：整段当表达式（对象字面量规则）');
    ok(idxBody > 0, '形态③：整段当函数体（顶层 return）');
    ok(idxEval > 0 && idxExpr > idxEval && idxBody > idxExpr,
       '三个形态的顺序必须是 ①直接eval → ②表达式 → ③函数体（老引擎同款）');
  }

  console.log('');
  console.log('=== ③ 只有【语法错】才换下一种形态（运行时错误直接抛）===');
  // ⭐⭐⭐⭐⭐ **这是「站方 JS 只执行一次」的生命线**（2026-10-25 真机回归的根因）
  //   · 语法错 ⇒ 代码**根本没跑** ⇒ 换形态**不重复副作用** ✅
  //   · 运行时错 ⇒ 代码**已经跑过** ⇒ 换形态**副作用重复**（java.ajax 重复发 ⇒ 限流打爆）❌
  ok(/isSyntaxError/.test(jsc), 'JSC：有「是不是语法错」的判定');
  ok(/if !Self\.isSyntaxError\(msg\)/.test(jsc),
     'JSC：非语法错 ⇒ 直接抛（不许换形态重跑）');
  const jscLoop = (jsc.match(/for \(i, src\) in attempts\.enumerated\(\) \{[\s\S]{0,3000}?\n        \}/) || [''])[0];
  ok(jscLoop.length > 0, 'JSC：找到形态尝试循环');
  ok(/break/.test(jscLoop), 'JSC：执行成功就 break（只跑一次）');
  ok(!/isUndefined[\s\S]{0,200}?continue/.test(jscLoop),
     'JSC：循环体里不许「undefined ⇒ continue」（那会重复执行站方 JS）');
  ok(/isSyntax/.test(node), 'Node：harness 里有「是不是语法错」的判定');
  ok(/if \(!isSyntax\) throw err;/.test(node),
     'Node：非语法错 ⇒ 直接抛（不许换形态重跑）');

  console.log('');
  console.log('=== ④ 执行成功就返回（不许因 undefined 再跑一遍）===');
  for (const [name, src] of [['JSC', jsc], ['Node', node]]) {
    const fn = name === 'JSC'
      ? jscLoop
      : (src.match(/function runEval\(attempts\) \{[\s\S]{0,2500}?\n\}/) || [''])[0];
    ok(fn.length > 0, `${name}：找到形态尝试循环`);
    ok(!/undefined[\s\S]{0,200}?continue/.test(fn),
       `${name}：循环体里不许「undefined ⇒ continue」（那会重复执行站方 JS）`);
    ok(/break/.test(fn) || /return v/.test(fn) || /return null/.test(fn),
       `${name}：执行成功会 break/return（只跑一次）`);
    if (name === 'Node') {
      // ⭐ Node 的正确写法：undefined 时 **不再跑下一种形态** ⇒ 直接返回
      const undefBlock = (fn.match(/if \(v === undefined \|\| v === null\) \{[\s\S]{0,1400}?\n\s{4}\}/) || [''])[0];
      ok(undefBlock.length > 0, 'Node：找到 undefined 分支');
      ok(!/for \(let i = 0/.test(undefBlock) && !/attempts\[i\]/.test(undefBlock),
         'Node：undefined 分支里不许再执行下一种形态（那会重复执行站方 JS）');
      ok(!/runInContext/.test(undefBlock),
         'Node：undefined 分支里不许再 runInContext（重复执行站方 JS ⇒ 限流打爆 / 写盘翻倍）');
      ok(/return null/.test(undefBlock) || /throw new Error/.test(undefBlock),
         'Node：undefined 时直接 return null / 抛真错（不再试下一种形态）');
    }
  }

  console.log('');
  console.log('=== ⑤ 不许静态判断「有没有顶层 return」（会误判函数体内的 return）===');
  for (const [name, src] of [['JSC', jsc], ['Node', node]]) {
    ok(!/hasTopLevelReturn/.test(src),
       `${name}：不许有 hasTopLevelReturn（(function(){return [];})() 会被误判）`);
  }

  console.log('');
  console.log('=== ⑥ 非 Linux stub 必须有 Conformance 用到的【全部】成员 ===');
  // ⭐⭐⭐⭐⭐ **2026-10-26 macOS CI 编译失败两次的根因**
  //   加 `#if os(Linux)` 平台闸门时 ⇒ NodeJSExecutor 的真身只在 Linux 编译
  //   ⇒ 但 `Conformance/main.swift` 调了 `setRoutes` / `recordedRequests` / ...
  //   ⇒ **macOS 上这些方法不存在** ⇒ 编译失败 ⇒ **JSC 后端 job 整个挂掉**
  //   ⇒ ⇒ **JSC 路径的验证从来没跑成**（而那正是今天要找真凶的地方）⭐⭐⭐
  const conf = read(path.join(ENGINE_DIR, 'Sources', 'Conformance', 'main.swift')) || '';
  // ⭐⭐⭐ **只扫【确实是 NodeJSExecutor 的变量】** ⇒ `if let node = ev.js as? NodeJSExecutor` 那种
  //   ⇒ 别把 `n.node`（DOM 节点）也算进来 ⭐⭐⭐
  const used = new Set();
  const declRe = /(?:if|guard)\s+let\s+(\w+)\s*=\s*[^\n]*as\?\s*NodeJSExecutor/g;
  let m2;
  while ((m2 = declRe.exec(conf)) !== null) {
    const v = m2[1];
    // ⭐⭐⭐ **词边界**：`(n.node).queryAll` 里的 `node` 不是那个变量 ⇒ 用「前面不是 . 或字母」来排
    const re = new RegExp('(?<![.\\w])' + v + '\\.([a-zA-Z_][A-Za-z0-9_]*)\\s*\\(', 'g');
    let m3;
    while ((m3 = re.exec(conf)) !== null) used.add(m3[1]);
  }
  // 找 stub 段（#else 分支之后）
  const stubStart = node.indexOf('#else   // ⭐⭐⭐ 非 Linux');
  const stub = stubStart >= 0 ? node.slice(stubStart) : '';
  ok(stubStart >= 0, '找得到非 Linux 的 stub 段（#else 之后）');
  for (const m of used) {
    const has = new RegExp('func\\s+' + m + '\\s*\\(').test(stub)
             || new RegExp('var\\s+' + m + '\\b').test(stub);
    ok(has, `非 Linux stub 里必须有 \`${m}()\`（Conformance 用到了 ⇒ 缺了 macOS 编译失败）`);
  }
  ok(used.size > 0, `Conformance 确实用到了 Node 专属成员（扫到 ${used.size} 个：${[...used].join(', ')}）`);

  console.log('');
  console.log('=== ⑦ JSC 侧要有专属门禁（Linux 沙盒没有 JSC ⇒ 只能靠 macOS CI）===');
  const jscTest = read(path.join(ENGINE_DIR, 'Tests', 'LegadoCoreTests', 'JSCExecutionShapeTests.swift'));
  ok(jscTest !== null, '有 JSCExecutionShapeTests.swift');
  if (jscTest) {
    ok(/canImport\(JavaScriptCore\)/.test(jscTest), '用 #if canImport(JavaScriptCore) 包住');
    ok(/只执行一次|只调一次|OnlyOnce/.test(jscTest), '有「只执行一次 / ajax 只调一次」的断言');
    ok(/没验到/.test(jscTest), 'Linux 上明确标注「没验到（不等于通过）」');
  }
}

console.log('');
console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
