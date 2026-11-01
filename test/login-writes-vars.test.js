#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **登录 op 的【行为】门禁**：站方 `source.put` / `setVariable` 必须落盘（2026-10-29 真机回归）
 *
 * 跑法：node test/login-writes-vars.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ⚠️⚠️ **为什么要有这个门禁（真机血的教训）**：
 *   2026-10-29 把 `login` 从老引擎切到新引擎 ⇒ **发现页整个空了** ⭐⭐⭐
 *
 *   真机症状：
 *     失败 URL：/novel/search?category=…&order_type=2&**aid=0** ⇒ HTTP 500
 *     日志：「分类 581 个 / **筛选栏 0 个**」
 *
 *   根因链（三环，缺一不可）：
 *     ① 站方登录成功后写 `source.put('aid', 账号id)` + `source.put('account_id', …)`
 *        ⇒ **`aid` 存在「书源变量」里** ⇒ explore 的 URL 才有 `aid=<账号id>`
 *     ② 引擎的 `runLoginAction` 构造求值上下文时**没传 `source:`**
 *        ⇒ `ctx.source == nil` ⇒ 全局 `source` 没有宿主方法
 *        ⇒ **站方 `source.put(...)` 静默失效** ⇒ `aid` 写不进去 ⭐⭐⭐
 *     ③ `aid` 一直是 `0` ⇒ 服务端 500 ⇒ 发现页全空
 *
 *   ⇒ 老引擎的 login op **会把 `g.source` 挂到全局** ⇒ 站方写变量才有效 ⭐
 *
 * ⭐⭐⭐ **本门禁是【行为级】的**（真跑一遍 login op，看回传的变量），
 *   不是静态匹配源码 ⇒ **比「op 分流契约」门禁更硬**（它证明的是「真的能写」）⭐⭐⭐
 */
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

/**
 * 极简源：jsLib/loginUrl 只用 `source.put` / `source.setVariable`
 * ⚠️ **刻意不用 ajax** ⇒ 不受「两遍跑」影响 ⇒ 一次就出结果（门禁要快且确定）⭐
 */
const SRC = {
  bookSourceUrl: 'https://test.example.com/',
  bookSourceName: '门禁用源',
  jsLib: 'function helper(){ return 1; }',
  loginUrl: "function login(){"
    + "  source.put('aid','ACC123');"
    + "  source.put('account_id','ACC123');"
    + "  source.setVariable('TOKEN-XYZ');"
    + "  return 'ok';"
    + "}",
  loginUi: JSON.stringify([{ title: '登录', action: 'login()', type: 'edit', hint: '账号' }]),
};

async function nativeMock(fn) {
  switch (fn) {
    case 'toast': return { ok: true };
    case 'log': return { ok: true };
    case 'deviceID': return { ok: true, value: 'dev' };
    case 'getString': return { ok: true, value: '' };
    case 'getStringArray': return { ok: true, value: [] };
    default: return { ok: true, value: '' };
  }
}

(async () => {
  const { win } = createSandbox({ nativeMock });
  const r = await win.eval(`window.__qrInvoke('login', ${JSON.stringify({
    source: Object.assign({}, SRC, { __variables: '', __variable: '', __loginInfo: {} }),
    cookieSnapshot: {},
    action: 'login()',
    formValues: {},
  })})`);

  console.log('=== 跑一次 login op（老引擎）===');
  ok(r.ok === true, 'login op 成功', String(r.error || ''));

  console.log('\n=== ① 站方 source.put 的项 ⇒ 必须落进「书源变量」（__sourceVars）===');
  let vars = {};
  try { vars = JSON.parse(r.__sourceVars || '{}'); } catch (e) { /* 解析失败 ⇒ 空 */ }
  ok(vars.aid === 'ACC123',
     '⭐⭐⭐⭐⭐ 站方 source.put(\'aid\', …) 落进书源变量了 ⇒ explore 的 URL 才有 aid=<账号id>',
     `__sourceVars = ${String(r.__sourceVars)}`);
  ok(vars.account_id === 'ACC123',
     '⭐⭐⭐⭐⭐ 站方 source.put(\'account_id\', …) 也落进书源变量了',
     `__sourceVars = ${String(r.__sourceVars)}`);

  console.log('\n=== ② 站方 source.setVariable ⇒ 必须落进「站方变量」（__sourceVariable）===');
  ok(r.__sourceVariable === 'TOKEN-XYZ',
     '⭐⭐⭐⭐⭐ 站方 source.setVariable(token) 落进站方变量了',
     `__sourceVariable = ${String(r.__sourceVariable)}`);

  console.log('\n=== ③ 两套变量必须是【分开的】（Legado 语义）===');
  ok(vars.aid !== r.__sourceVariable,
     '⭐⭐⭐ 站方变量与书源变量是两套（aid 在书源变量、token 在站方变量 ⇒ 互不冲掉）');

  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
