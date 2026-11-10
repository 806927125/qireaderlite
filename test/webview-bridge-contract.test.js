#!/usr/bin/env node
/**
 * 新引擎链路（WebViewJSExecutor）的桥接契约门禁
 *
 * ⭐⭐⭐⭐⭐ 背景（2026-11-10 真机）：build285 上「发现功能」直接失败
 *   WebViewJSError(message: "执行JavaScript返回结果的类型不受支持", isSyntaxError: false)
 *   ⇒ sourceVars 与 exploreKinds 两个 op 双双在「形态 #1」挂掉
 *
 * ⭐ 机理：宿主把站方 JS 求值成
 *   JSON.stringify( 间接eval("<scope+形态1>") )
 *   ⇒ 内层值是 **undefined** 时，JSON.stringify 返回的**也是 undefined**
 *   ⇒ 脚本完成值不可桥接 ⇒ WebKit 抛 WKError.resultTypeIsUnsupported ⭐⭐⭐
 *   ⇒ 老链路（Core/RuleSandbox.swift）早有 `v === undefined ? null : v` 兜底
 *   ⇒ **新链路漏了** ⇒ 这就是两边行为不一致的真因
 *
 * ⚠️ jsdom 测不出「返回值桥接」这一步 ⇒ 只能静态钉 + 变异对照
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const ROOT = path.join(__dirname, '..');
const file = path.join(ROOT, 'QiReaderLite', 'Engine', 'WebViewJSExecutor.swift');
const raw = fs.readFileSync(file, 'utf8');

/** ⭐ 剥掉注释再查（注释里写着旧写法 ⇒ 不剥会误报；本仓库已踩过这个坑） */
function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

/** ⭐⭐⭐ **门禁本体**（可对任意文本跑 ⇒ 变异对照能复用） */
function check(text) {
  const code = stripComments(text);
  const problems = [];
  if (!/func bridgeScript/.test(code)) problems.push('缺 bridgeScript（统一包装求值）');
  if (!/__v===undefined\?null:__v/.test(code)) {
    problems.push('bridgeScript 没对 undefined 兜底（JSON.stringify(undefined) 返回 undefined ⇒ 完成值不可桥接）');
  }
  if (!/typeof __v/.test(code)) problems.push('信封没带回 typeof（真机失败看不出值是什么类型）');
  if (/JSON\.stringify\(\(0,eval\)\(/.test(code)) {
    problems.push('还留着旧写法 `JSON.stringify((0,eval)(`（真凶）');
  }
  const runBody = code.slice(code.indexOf('func run(_ code: String'), code.indexOf('func runGlobal'));
  const runGlobalBody = code.slice(code.indexOf('func runGlobal'), code.indexOf('// MARK: - 宿主对象'));
  if (!/Self\.bridgeScript\(/.test(runBody)) problems.push('run() 没走 bridgeScript');
  if (!/Self\.bridgeScript\(/.test(runGlobalBody)) problems.push('runGlobal() 没走 bridgeScript（jsLib 载入同样会 undefined）');
  if (!/parseEnvelope/.test(runBody) || !/parseEnvelope/.test(runGlobalBody)) {
    problems.push('没解信封取值');
  }
  if (!/\[JS形态\]/.test(runBody) || !/code\.count/.test(runBody)) {
    problems.push('形态失败没记代码长度（查不出超长/被截断）');
  }
  if (!/prefix\(60\)|prefix\(80\)|prefix\(40\)/.test(runBody)) {
    problems.push('形态失败没记代码开头（看不出是哪段站方代码）');
  }
  return problems;
}

/* ---------- ① 基线必须全绿 ---------- */

const problems = check(raw);
ok(problems.length === 0, '基线无问题：' + (problems.length ? problems.join(' / ') : 'ok'));
problems.forEach(p => ok(false, p));

/* ---------- ② 变异对照：门禁必须报红（证明有牙齿） ---------- */

const mutations = [
  ['去掉 undefined 兜底', t => t.replace('__v===undefined?null:__v', '__v')],
  ['绕开包装（旧写法回潮）', t => t.replace(/Self\.bridgeScript\(/g, 'JSON.stringify((0,eval)(')],
  ['删掉信封里的 typeof', t => t.replace(/typeof __v/g, '"x"')],
  ['失败日志不再记代码长度', t => t.replace(/code\.count/g, '0')],
];
for (const [name, fn] of mutations) {
  const p = check(fn(raw));
  ok(p.length > 0, `变异「${name}」被门禁抓到（${p.length} 项）`);
}

/* ---------- ③ 老链路的兜底不能被回退 ---------- */

const sandbox = fs.readFileSync(path.join(ROOT, 'QiReaderLite', 'Core', 'RuleSandbox.swift'), 'utf8');
ok(/v === undefined \? null : v/.test(stripComments(sandbox)), '老链路（RuleSandbox）的 undefined 兜底仍在');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
