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

console.log('=== ① 两个后端的源码都在吗 ===');
const jsc = read(jscPath);
const node = read(nodePath);
ok(jsc !== null, 'JSCExecutor.swift 在（' + jscPath + '）');
ok(node !== null, 'NodeJSExecutor.swift 在（' + nodePath + '）');

if (jsc && node) {
  console.log('');
  console.log('=== ② 形态选择：静态选形态（不许「跑到有值为止」）===');
  for (const [name, src] of [['JSC', jsc], ['Node', node]]) {
    ok(/isObjectLiteral/.test(src), `${name}：有「对象字面量」判定（isObjectLiteral）`);
    ok(/hasPrefix\("\{"\)/.test(src) || /charAt\(0\) === '\{'/.test(src),
       `${name}：对象字面量判定用的是首字符 '{'`);
  }

  console.log('');
  console.log('=== ③ 对象字面量 ⇒ 整段当表达式 ===');
  // ⭐⭐⭐ 两个后端写法不同（JSC 用 attempts 数组，Node 用 attempts = [...]）
  //   ⇒ 判据只看「有没有 ( trimmed ) 这种整段当表达式的形态」
  for (const [name, src] of [['JSC', jsc], ['Node', node]]) {
    ok(/["']\( ["']?\s*\+?\s*trimmed/.test(src) || /\(\s*["']?\s*\+\s*trimmed/.test(src)
       || /trimmed\s*\+\s*["']\n\)["']/.test(src),
       `${name}：有「整段当表达式」形态（( trimmed )）`);
  }

  console.log('');
  console.log('=== ④ 执行成功就返回（不许因 undefined 再跑一遍）===');
  // ⭐⭐⭐ 关键判据：循环体里**不许**有「undefined ⇒ continue / 试下一种形态」
  for (const [name, src] of [['JSC', jsc], ['Node', node]]) {
    const fn = name === 'JSC'
      ? (src.match(/for src in attempts \{[\s\S]{0,2500}?\n\s{8}\}/) || [''])[0]
      : (src.match(/for \(let i = 0; i < attempts\.length; i\+\+\) \{[\s\S]{0,2500}?\n\s{2}\}/) || [''])[0];
    ok(fn.length > 0, `${name}：找到形态尝试循环`);
    ok(!/isUndefined[\s\S]{0,200}?continue/.test(fn) && !/undefined[\s\S]{0,200}?continue/.test(fn),
       `${name}：循环体里不许「undefined ⇒ continue」（那会重复执行站方 JS）`);
    ok(/break/.test(fn) || /return v/.test(fn) || /return null/.test(fn),
       `${name}：执行成功会 break/return（只跑一次）`);
    // ⭐⭐⭐⭐⭐ **最关键的一条**：旧写法是「**没值就换下一种形态**」
    //   ⇒ 特征就是「判 undefined / isUndefined 后才 break」
    //   ⇒ 直接禁掉这个特征 ⇒ 变异测试立刻红 ⭐⭐⭐
    ok(!/isUndefined/.test(fn),
       `${name}：循环体里不许出现 isUndefined（旧写法：没值就换形态 ⇒ 重复执行站方 JS）`);
    if (name === 'Node') {
      ok(!/v === undefined[\s\S]{0,160}?continue/.test(fn),
         `Node：循环体里不许「v === undefined ⇒ continue」（重复执行站方 JS）`);
      // ⭐ Node 的正确写法：undefined 时 **不再跑下一种形态** ⇒ 直接返回
      //   （形态 2 已经试过了 ⇒ undefined 就该结束 ⇒ 不许再试）
      const undefBlock = (fn.match(/if \(v === undefined \|\| v === null\) \{[\s\S]{0,1400}?\n\s{4}\}/) || [''])[0];
      ok(undefBlock.length > 0, 'Node：找到 undefined 分支');
      ok(!/for \(let i = 0/.test(undefBlock) && !/attempts\[i\]/.test(undefBlock),
         'Node：undefined 分支里不许再执行下一种形态（那会重复执行站方 JS）');
      // ⭐⭐⭐ **最狠的一条**：undefined 分支里**任何**再执行都不许（不管用哪种写法）
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
