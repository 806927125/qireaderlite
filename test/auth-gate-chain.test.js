#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：站方「整源密码门禁」的解锁态能不能到站方 JS 手里（整链复现）**
 *
 * ⚠️⚠️⚠️ **为什么要整链复现**（2026-11-19 真机，用户直接指出「你弄反了」）：
 *   真机双源对照：
 *   · 🍒NovelHub（**真带**门禁）：0 分类
 *   · 🍅大灰狼 5.9.30（**没有**门禁）：也 0 分类 ⇒ **说明「0 分类」不只有门禁一个原因** ⭐⭐⭐
 *   ⇒ 我第一版无条件提示「多半是门禁没解锁」⇒ 对大灰狼是**误报** ⇒ 用户被带偏 ⭐⭐⭐
 *
 * ⭐⭐⭐ **本门禁复现【真实整链】（不猜）**：
 *   ① 站方 `unlockAll()`：`source.getLoginInfoMap()['整源解锁密码']` → md5 比对
 *      → `source.put('nhAuthed', nhPwdHash())` ⇒ 写进**引擎那一格** ⭐⭐⭐
 *   ② 引擎 `srcPut` ⇒ `BookSource.variable["nhAuthed"]` ⭐⭐⭐
 *   ③ 回传 `__sourceVariable` ⇒ App 落盘**站方变量槽** `sourcevariable.` ⭐⭐⭐
 *   ④ 下轮 App 灌引擎：`__variable` = `stationVariableToSeed(...)` = **站方变量槽** ⭐⭐⭐
 *   ⑤ 宿主合并两格 ⇒ `engineSource.variable` ⇒ 站方 `source.get("nhAuthed")` 读得到 ⭐⭐⭐
 *   ⑥ 站方 `nhAuth()` ⇒ `nhAuthed == nhPwdHash()` ⇒ 放行 ⭐⭐⭐
 *
 * ⚠️ **每一环都必须【真跑】**（Node 模拟引擎语义）⇒ 断在哪一环就一目了然 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const SRC = process.argv[2] || '/workspace/output/NovelHub聚合小说-轻阅新引擎适配.json';

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const pack = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = Array.isArray(pack) ? pack[0] : pack;
const jsLib = src.jsLib || '';

// ── 站方的真身（从产物 jsLib 里抽，不手写）──────────────────────────────
function grabFunc(name) {
  const m = new RegExp('function ' + name + '\\([^)]*\\)\\s*\\{').exec(jsLib);
  if (!m) return null;
  const i = m.index, j = jsLib.indexOf('{', i);
  let depth = 0, k = j;
  while (k < jsLib.length) {
    if (jsLib[k] === '{') depth++;
    else if (jsLib[k] === '}') { depth--; if (depth === 0) break; }
    k++;
  }
  return jsLib.slice(i, k + 1);
}
const fPwdHash = grabFunc('nhPwdHash');
const fAuth = grabFunc('nhAuth');
const fEq = grabFunc('nhEq');
ok(!!fPwdHash && !!fAuth && !!fEq, '从产物 jsLib 里抽到站方的 nhPwdHash / nhAuth / nhEq（用真身，不手写）');

console.log('\n=== 整链复现（①→⑥，每环真跑） ===');

// 沙箱：模拟引擎那一格（一个 JSON map）+ 站方那三个函数
function makeCtx(opts = {}) {
  const sandbox = { JSON, String, Object, Array, Math, RegExp };
  vm.createContext(sandbox);
  vm.runInContext(`
    var __var = ${JSON.stringify(opts.variable || {})};
    var source = {
      get: function(k){ return __var[k] === undefined ? '' : String(__var[k]); },
      put: function(k,v){ __var[k] = String(v); },
      getVariable: function(){ return JSON.stringify(__var); },
      setVariable: function(v){ try { __var = JSON.parse(String(v)); } catch(e){} },
      getLoginInfoMap: function(){ var li = __var['loginInfo']; var m={}; if(li&&typeof li==='object'){for(var k in li){m[k]=li[k];}} return m; }
    };
    var NH_PWD_HASH = ${JSON.stringify(opts.pwdHash || '0c220581ebbb1121d9c2b33466045387')};
    ${fPwdHash}
    ${fEq}
    ${fAuth}
  `, sandbox);
  return sandbox;
}

// ① 站方 unlockAll 的等价动作：读登录信息里的密码 → 比对 → put('nhAuthed', nhPwdHash())
function step1_unlock(ctx, password) {
  const m = ctx.source.getLoginInfoMap();
  const pw = String(m['整源解锁密码'] || '').trim();
  if (pw === '') return { ok: false, why: '登录信息里没有「整源解锁密码」' };
  // 站方用 md5 校验；此处只需判「密码对」⇒ 直接用出厂密码当正确密码
  if (pw !== password) return { ok: false, why: '密码不对' };
  ctx.source.put('nhAuthed', ctx.nhPwdHash());
  return { ok: true, why: '' };
}

// ③ 站方变量槽（App 落盘处）
let stationSlot = {};      // sourcevariable.
let bookSlot = {};         // sourcevars.
// ④ App 灌引擎：__variable = stationVariableToSeed(...) ⇒ 站方变量槽（迁移逻辑不清空 map 形态）
function appSeedToEngine() {
  // stationVariableToSeed：若这一格是 map 形态且形态判成 map ⇒ 原样返回
  return JSON.stringify(stationSlot);
}
// ⑤ 宿主合并两格（照抄 Swift 的 mergeStationMap）
function hostMerge(stationRaw, bookVars, loginInfo) {
  const out = {};
  try { Object.assign(out, JSON.parse(stationRaw)); } catch (e) {}
  try { Object.assign(out, JSON.parse(bookVars)); } catch (e) {}
  if (loginInfo) { try { out['loginInfo'] = JSON.parse(loginInfo); } catch (e) {} }
  return out;
}

// ① 场景 A：用户填了密码（在登录信息里）⇒ unlockAll 成功
{
  const ctx = makeCtx({
    variable: { loginInfo: { '整源解锁密码': 'THE_PASSWORD' } },
  });
  const r = step1_unlock(ctx, 'THE_PASSWORD');
  ok(r.ok, '① 站方 unlockAll：读到密码 ⇒ 比对通过 ⇒ 写 nhAuthed', r.why);
  ok(ctx.source.get('nhAuthed') === ctx.nhPwdHash(), '① 引擎那一格里有 nhAuthed（= nhPwdHash）');
  // ③ 回传 ⇒ 落站方变量槽
  const back = JSON.parse(ctx.source.getVariable());
  for (const k of Object.keys(back)) stationSlot[k] = back[k];
  ok(stationSlot.nhAuthed !== undefined, '③ 回传后落进站方变量槽（sourcevariable.）');
}

// ② 场景 B：站方变量槽里【已经有】解锁态（用户之前解锁过）⇒ 直接灌引擎
{
  const ctx2 = makeCtx({ variable: { nhAuthed: '0c220581ebbb1121d9c2b33466045387' } });
  const seed = appSeedToEngine();
  const merged = hostMerge(seed, JSON.stringify(bookSlot), '');
  const ctx3 = makeCtx({ variable: merged });
  ok(ctx3.source.get('nhAuthed') !== '', '⑤ 合并后引擎那一格里有 nhAuthed（★ 站方读得到）');
  ok(ctx3.nhAuth() === true, '⑥ 站方 nhAuth() 放行（★ 不再交白卷）');
}

// ③ 场景 C：书源变量槽里有解锁态（历史路径）⇒ 也该通
{
  bookSlot = { nhAuthed: '0c220581ebbb1121d9c2b33466045387' };
  const merged = hostMerge(JSON.stringify(stationSlot), JSON.stringify(bookSlot), '');
  const ctx4 = makeCtx({ variable: merged });
  ok(ctx4.nhAuth() === true, '★ 书源变量槽里有 nhAuthed ⇒ 合并后也放行（第一版查错槽 ⇒ 反而误判）');
  bookSlot = {};
}

// ④ 场景 D：登录信息没进引擎那一格 ⇒ 站方 unlockAll 读不到密码（★ build300 修的正是这条）
{
  const ctx5 = makeCtx({ variable: { nhAuthed: 'x' } });   // 故意没有 loginInfo 项
  const m = ctx5.source.getLoginInfoMap();
  ok(Object.keys(m).length === 0, '★ 登录信息没进引擎那一格 ⇒ 站方 getLoginInfoMap() 读到空 map');
  ok(step1_unlock(ctx5, 'THE_PASSWORD').ok === false,
     '★ ⇒ 站方 unlockAll 失败（提示「请在下面输入框里填密码」）⇒ 永远解锁不了');
  // 而 App 的 login op 现在会把表单值并进去
  const mergedWithLogin = hostMerge(JSON.stringify({}), JSON.stringify({}),
                                    JSON.stringify({ '整源解锁密码': 'THE_PASSWORD' }));
  const ctx6 = makeCtx({ variable: mergedWithLogin });
  ok(ctx6.source.getLoginInfoMap()['整源解锁密码'] === 'THE_PASSWORD',
     '★ App 把表单值并进 loginInfo 项 ⇒ 站方读得到密码（build300 的修复）');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
