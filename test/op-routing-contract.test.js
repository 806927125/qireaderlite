#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **op 分流契约**（2026-11-10 更新 · 按「阅读2.0（YueduReader）」的架构重做引擎）
 *
 * 跑法：node test/op-routing-contract.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ⚠️⚠️ **为什么要有这个门禁（真机血的教训）**：
 *   2026-10-29 把 `login` / `filterAction` 从老引擎切到新引擎 ⇒
 *   **发现页整个空了**（用户报「发现都没了」）⭐⭐⭐
 *   根因：引擎的 `runLoginAction` / `runFilterAction` 构造求值上下文时
 *   **没传 `source:`** ⇒ `ctx.source == nil` ⇒ 全局 `source` 没有宿主方法
 *   ⇒ 站方 action 里的 `source.setVariable(token)` / `source.put('order', 2)` **全部失效**
 *   ⇒ 症状：**发现页「筛选栏 0 个」** + explore 的 `order_type` 取旧值 ⇒ **HTTP 500**
 *
 * ⭐⭐⭐ **2026-11-10 的方向变更（用户决定）**：
 *   引擎换成**阅读2.0 同款架构** ⇒ **WebView 引擎（`RuleSandbox` + `Resources/engine/*.js`）成为主引擎**
 *   （Swift 宿主 + WebView 内规则求值 + 原生只过字符串 ⇒ 站方 JS 跑在独立进程 ⇒ 对 jetsam 更友好）
 *   ⇒ 自研 Swift 引擎（legado-engine）**降为回退**，可用【自检面板】一键切回 ⭐⭐⭐
 *   ⇒ **本门禁随之翻过来钉新契约**（旧版钉的是「主链路必须走新引擎」）⭐
 *
 * ⭐⭐⭐ **判据（不是「新引擎更好」，而是「站方要不要写变量」）**：
 *   · **要写变量的 op**（`login` / `filterAction`）⇒ **必须走 RuleSandbox 通路**
 *     （它的 op 会把 `g.source` 挂到全局 ⇒ 站方写变量才有效）⭐
 *   · **只读的 op** + **主链路 op** ⇒ 走**统一入口** `invokeEngine(...)`
 *     ⇒ 入口内部按 `EngineMode` 分流（默认 WebView 引擎 = 阅读2.0 同款）⭐⭐⭐
 *
 * ⚠️ **这个门禁是「契约」，不是「实现」** ⇒ 将来再切引擎，
 *    把它改成新契约是**允许的**，但**必须同时改这个门禁**（⇒ 变更可见、可追溯）⭐
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const SVC = path.join(root, 'QiReaderLite/Core/SourceService.swift');
const MODE = path.join(root, 'QiReaderLite/Core/EngineMode.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

const svc = fs.readFileSync(SVC, 'utf8');
const mode = fs.existsSync(MODE) ? fs.readFileSync(MODE, 'utf8') : '';

/** 取出某个 op 的调用点上下文（往回找最近的注释块 + 调用行） */
function callSite(op) {
  const lines = svc.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes(`"${op}"`)) {
      const ctx = lines.slice(Math.max(0, i - 12), i + 1).join('\n');
      return { ctx, line: i + 1, text: lines[i] };
    }
  }
  return null;
}

console.log('=== ① 要写变量的 op ⇒ 必须走 RuleSandbox 通路（站方要 source.setVariable / source.put）===');
for (const op of ['login', 'filterAction']) {
  const site = callSite(op);
  if (!site) { ok(false, `找得到「${op}」的调用点`); continue; }
  const usesLegacy = site.ctx.includes(`RuleSandbox.shared.invoke("${op}"`);
  ok(usesLegacy,
     `⭐⭐⭐⭐⭐ 「${op}」走【RuleSandbox 通路】⇒ 站方的 source.setVariable/put 才有效`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
  ok(!site.ctx.includes(`invokeEngine("${op}"`),
     `⭐⭐⭐⭐⭐ 「${op}」**不许**走统一入口（自研引擎的 runXxx 没传 source ⇒ 站方写变量失效 ⇒ 发现页空 + HTTP 500）`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
}

console.log('=== ② 只读的 op ⇒ 走统一入口 invokeEngine（内部按 EngineMode 分流）===');
for (const op of ['loginProbe', 'sourceVars', 'sourceHosts']) {
  const site = callSite(op);
  if (!site) { ok(false, `找得到「${op}」的调用点`); continue; }
  ok(site.ctx.includes(`invokeEngine("${op}"`),
     `⭐⭐⭐ 「${op}」走【统一入口 invokeEngine】（与主链路同一套语义）`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
}

console.log('=== ③ 主链路 op ⇒ 走统一入口（默认 = WebView 引擎 = 阅读2.0 同款架构）===');
for (const op of ['search', 'explore', 'exploreKinds', 'bookInfo', 'toc', 'content']) {
  const site = callSite(op);
  if (!site) { ok(false, `找得到「${op}」的调用点`); continue; }
  const goesUnified = site.ctx.includes('invokeEngine')
    || site.ctx.includes(`call("${op}"`)
    || /case\s+"[a-zA-Z]+":/.test(site.ctx);
  ok(goesUnified,
     `⭐⭐⭐ 「${op}」走【统一入口】（引擎由 EngineMode 决定 ⇒ 可一键切回自研引擎）`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
}

console.log('=== ④ 统一入口里必须按 EngineMode 分流（两条路都在）===');
ok(/EngineMode\.usesWebViewEngine/.test(svc), '⭐⭐⭐ invokeEngine 里按 EngineMode 分流');
ok(/invokeWebViewEngine/.test(svc), '⭐⭐⭐ 有 WebView 引擎通路（阅读2.0 同款）');
ok(/invokeNewEngine/.test(svc), '⭐⭐⭐ 自研 Swift 引擎通路保留（回退用）');
ok(/RuleSandbox\.shared\.invoke\(op, payload, source: source\)/.test(svc),
   '⭐⭐⭐ WebView 通路真的走 RuleSandbox.invoke（规则求值在 WebView 里做）');
ok(/return \.webView/.test(mode), '⭐⭐⭐⭐⭐ 默认引擎 = WebView 引擎（阅读2.0 同款架构）');
ok(/case swiftEngine/.test(mode), '⭐⭐⭐ 自研 Swift 引擎仍可切（回退）');

console.log('=== ⑤ 两条通路的返回契约必须一致（站方变量「改没改」不能自证）===');
ok(/__sourceVariableChanged/.test(svc), '⭐⭐⭐ 回传「站方变量改没改」');
ok(/returned != seeded/.test(svc), '⭐⭐⭐⭐⭐ 「改没改」是与种子比较（否则证据自证 ⇒ 污染清不掉）');
ok(/ServiceError\.engineFailed/.test(svc), '⭐⭐⭐ WebView 通路把 {error:…} 翻译成失败（不被当成成功）');
ok(fs.existsSync(path.join(root, 'QiReaderLite/Core/RuleSandbox.swift'))
   && fs.readFileSync(path.join(root, 'QiReaderLite/Core/RuleSandbox.swift'), 'utf8').includes('class RuleSandbox'),
   "⭐⭐⭐ RuleSandbox 还在（**现在是主引擎** ⇒ 更不能删）");

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
