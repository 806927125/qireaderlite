#!/usr/bin/env node
/**
 * **同名全局被别的源覆盖 ⇒ 切源后必须还原**（2026-10-22 真机「导入另一个源后大灰狼目录 0 章」）
 *
 * 跑法：node test/global-restore.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **症状**：用户导入 🍒NovelHub 聚合源之后，🍅大灰狼的目录就 0 章了（之前正常）。
 *
 * **机制**：站方 jsLib 是**间接 eval** 加载 ⇒ `var host = [...]` / `function getArguments(){}`
 * **进全局作用域** ⇒ 两个源**同名**的全局 ⇒ **后加载的赢**：
 *   · 大灰狼：`var host = ['https://v5.langge.uk', ...]`（**线路数组**）
 *             `getArguments(vars, "server")` ⇒ 决定 `/catalog` 请求打到哪个服务器
 *   · NovelHub：`var host = NH_UAA_HOSTS[0]`（**单个字符串**）+ 自己的 `getArguments`
 * ⇒ 大灰狼的 `base_url` 取错 ⇒ `/catalog` 打到错的服务器 ⇒ **返回空 ⇒ 目录 0 章** ⭐
 *
 * ⇒ 光「删掉新增的全局」**不够**（同名覆盖是**改值**不是新增）⇒ 必须**把原值还原**
 *   （= 栖阅的 `restoreMutatedBaseGlobals`）
 * ⇒ 而且 **jsLib 抛异常时也要记账**（否则已定义的全局清不掉 ⇒ 污染永久留下）⭐
 */
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

/** 造一个只有 jsLib 的假书源 */
function fakeSource(name, jsLib) {
  return {
    bookSourceUrl: 'https://' + name + '.example.com/',
    bookSourceName: name,
    enabled: true,
    jsLib,
    exploreUrl: '@js: (function(){ return [{ title: "t", url: "https://' + name + '.example.com/x" }]; })()',
    ruleExplore: { bookList: '@js: (function(){ return []; })()' }
  };
}

const A = fakeSource('源A', "var host = ['A1','A2','A3']; function getArguments(v,k){ return 'A-SERVER'; }");
const B = fakeSource('源B', "var host = 'B-HOST'; function getArguments(v,k){ return 'B-SERVER'; }");
// 源C：jsLib **抛异常**（但前面已经定义了全局 ⇒ 残留必须能被清掉）
const C = fakeSource('源C', "var host = ['C1','C2']; function getArguments(v,k){ return 'C-SERVER'; } throw new Error('boom');");

const nativeMock = async (fn, args) => {
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};

const { win } = createSandbox({ nativeMock });
const call = (src) => win.eval("window.__qrInvoke('exploreKinds', " + JSON.stringify({
  source: src, cookieSnapshot: {}
}) + ")");
const probe = () => { const r = win.eval(`(function(){
  try {
    return JSON.stringify({
      hostIsArray: Array.isArray(host),
      hostLen: (host && host.length !== undefined) ? host.length : -1,
      hostFirst: Array.isArray(host) ? host[0] : String(host).slice(0, 40),
      server: (typeof getArguments === 'function') ? getArguments('', 'server') : '(no getArguments)'
    });
  } catch (e) { return JSON.stringify({ err: String(e && e.message || e) }); }
})()`);
  try { return JSON.parse(r); } catch (e) { return { err: 'probe: ' + String(r).slice(0,120) }; }
};

(async () => {
console.log('=== 1. 同名全局：A → B → A，A 的值必须回来 ===');
await call(A);
console.log('  载完 A →', JSON.stringify(probe()));
ok(probe().hostIsArray === true, 'A 的 host 是数组');

await call(B);
console.log('  切到 B →', JSON.stringify(probe()));
ok(probe().server === 'B-SERVER', 'B 的 getArguments 生效（B 赢）');

await call(A);
const back = probe();
console.log('  切回 A →', JSON.stringify(back));
ok(back.hostIsArray === true && back.hostLen === 3,
   '**切回 A 后 host 还原成数组**（同名覆盖被还原）',
   JSON.stringify(back));
ok(back.server === 'A-SERVER',
   '**切回 A 后 getArguments 还原成 A 的版本**',
   '实际 ' + back.server);

console.log('\n=== 2. jsLib 抛异常 ⇒ 它定义的全局也必须能被清掉 ===');
await call(C);
console.log('  载完 C →', JSON.stringify(probe()));
const afterC = probe();
ok(afterC.hostIsArray === true, 'C 的 host 已定义（jsLib 前半段执行了）');

await call(A);   // 切走
const afterSwitch = probe();
console.log('  切走 C 后 →', JSON.stringify(afterSwitch));
ok(afterSwitch.hostIsArray === true && afterSwitch.hostLen === 3,
   '**C 的残留（同名 host）被清/还原了**（jsLib 抛异常也要记账）',
   JSON.stringify(afterSwitch));
ok(afterSwitch.server === 'A-SERVER', 'getArguments 也是 A 的版本');

console.log('\n=== 3. 切回 C ⇒ 它自己的 jsLib 会重载（同名一定被覆盖回去） ===');
await call(C);
const c2 = probe();
console.log('  切回 C →', JSON.stringify(c2));
ok(c2.hostIsArray === true, 'C 的 host 回来了');
ok(c2.server === 'C-SERVER', 'C 的 getArguments 回来了', '实际 ' + c2.server);

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
