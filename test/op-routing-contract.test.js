#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **op 分流契约**：哪些 op 走老引擎、哪些走新引擎（2026-10-29 真机回归实证）
 *
 * 跑法：node test/op-routing-contract.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ⚠️⚠️ **为什么要有这个门禁（真机血的教训）**：
 *   2026-10-29 把 `login` / `filterAction` 从老引擎切到新引擎 ⇒
 *   **发现页整个空了**（用户报「发现都没了」）⭐⭐⭐
 *
 *   根因：引擎的 `runLoginAction` / `runFilterAction` 构造求值上下文时
 *   **没传 `source:`** ⇒ `ctx.source == nil`
 *   ⇒ **全局 `source` 对象没有宿主方法**
 *   ⇒ 站方 action 里的 `source.setVariable(token)` / `source.put('order', 2)` **全部失效**
 *   ⇒ 症状：**发现页「筛选栏 0 个」** + explore 的 `order_type` 取旧值 ⇒ **HTTP 500**
 *
 * ⭐⭐⭐ **判据（不是「新引擎更好」，而是「站方要不要写变量」）**：
 *   · **要写变量的 op**（`login` / `filterAction`）⇒ **必须走老引擎**
 *     （老引擎的 op 会把 `g.source` 挂到全局 ⇒ 站方写变量才有效）⭐
 *   · **只读的 op**（`loginProbe` / `sourceVars` / `sourceHosts`）⇒ 可以走新引擎
 *     （它们只读全局 `getArguments` / `host`，不需要 `source` 对象）⭐
 *
 * ⚠️ **这个门禁是「契约」，不是「实现」** ⇒ 将来引擎修好了（`ctx` 传上 `source`），
 *    把它改成走新引擎是**允许的**，但**必须同时改这个门禁**（⇒ 变更可见、可追溯）⭐
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const SVC = path.join(root, 'QiReaderLite/Core/SourceService.swift');
const ENGINE_DIR = process.env.ENGINE_DIR || path.join(root, '..', 'legado-engine');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

const svc = fs.readFileSync(SVC, 'utf8');

/** 取出某个 op 的调用点上下文（往回找最近的注释块 + 调用行） */
function callSite(op) {
  const lines = svc.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes(`"${op}"`)) {
      // 往上找 12 行做上下文
      const ctx = lines.slice(Math.max(0, i - 12), i + 1).join('\n');
      return { ctx, line: i + 1, text: lines[i] };
    }
  }
  return null;
}

console.log('=== ① 要写变量的 op ⇒ 必须走老引擎（站方要 source.setVariable / source.put）===');
for (const op of ['login', 'filterAction']) {
  const site = callSite(op);
  if (!site) { ok(false, `找得到「${op}」的调用点`); continue; }
  const usesLegacy = site.ctx.includes(`RuleSandbox.shared.invoke("${op}"`);
  const usesNew = site.ctx.includes(`invokeEngine("${op}"`);
  ok(usesLegacy,
     `⭐⭐⭐⭐⭐ 「${op}」走【老引擎】⇒ 站方的 source.setVariable/put 才有效`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
  ok(!usesNew,
     `⭐⭐⭐⭐⭐ 「${op}」**不许**走新引擎（引擎的 runXxx 没传 source ⇒ 站方写变量失效 ⇒ 发现页空 + HTTP 500）`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
}

console.log('\n=== ② 只读的 op ⇒ 走新引擎（只读全局 getArguments / host，不需要 source）===');
for (const op of ['loginProbe', 'sourceVars', 'sourceHosts']) {
  const site = callSite(op);
  if (!site) { ok(false, `找得到「${op}」的调用点`); continue; }
  const usesNew = site.ctx.includes(`invokeEngine("${op}"`);
  ok(usesNew,
     `⭐⭐⭐ 「${op}」走【新引擎】（与主链路同一套语义）`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
}

console.log('\n=== ③ 主链路 op ⇒ 必须走新引擎（老引擎已退役）===');
// 主链路走的是通用的 call() → invokeEngine() ⇒ 判「这个 op 的调用点附近有 invokeEngine / call」
for (const op of ['search', 'explore', 'exploreKinds', 'bookInfo', 'toc', 'content']) {
  const site = callSite(op);
  if (!site) { ok(false, `找得到「${op}」的调用点`); continue; }
  const goesNew = site.ctx.includes('invokeEngine')
    || site.ctx.includes(`call("${op}"`)
    || /case\s+"[a-zA-Z]+":/.test(site.ctx);
  ok(goesNew,
     `⭐⭐⭐ 「${op}」走【新引擎】（主链路）`,
     `第 ${site.line} 行：${site.text.trim().slice(0, 80)}`);
}

console.log('\n=== ④ 引擎侧：runLoginAction / runFilterAction 的 ctx 传了 source 吗？（还没传 ⇒ 所以 App 必须走老引擎）===');
const engineFile = path.join(ENGINE_DIR, 'Sources/LegadoCore/Pipeline/SourceEngine.swift');
if (fs.existsSync(engineFile)) {
  const eng = fs.readFileSync(engineFile, 'utf8');
  for (const fn of ['runLoginAction', 'runFilterAction']) {
    const i = eng.indexOf(`func ${fn}`);
    if (i < 0) { ok(false, `引擎里有 ${fn}`); continue; }
    const seg = eng.slice(i, i + 2600);
    const hasSource = /source:\s*sourceObject/.test(seg);
    if (hasSource) {
      ok(true, `⭐ 引擎的 ${fn} **已经传了 source** ⇒ 可以切到新引擎了（记得同步改本门禁）`);
    } else {
      ok(true, `⭐⭐⭐ 引擎的 ${fn} **还没传 source** ⇒ App 侧必须走老引擎（这正是本门禁钉住的原因）`);
    }
  }
} else {
  console.log(`  ⚠️ 跳过：没找到引擎源码（${engineFile}）`);
  console.log('     ⇒ 这部分**没验到**（不影响主判定）');
}

console.log('\n=== ⑤ 老引擎必须保留（诊断面板 + 这两个写变量的 op 还在用）===');
ok(svc.includes('RuleSandbox.shared.invoke("login"'),
   "⭐⭐⭐ 老引擎的 login 入口还在（诊断面板也在用它 ⇒ 不能整体删）");
ok(fs.readFileSync(path.join(root, 'QiReaderLite/Core/RuleSandbox.swift'), 'utf8').includes('class RuleSandbox'),
   "⭐⭐⭐ 老引擎 RuleSandbox 还在（不是退役状态 ⇒ 只是主链路不用了）");

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
