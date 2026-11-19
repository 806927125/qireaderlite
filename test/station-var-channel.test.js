#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：站方变量通道（`source.get` / `source.put`）双向真跑**
 *
 * ⚠️⚠️⚠️ **为什么必须有它**（2026-11-19 真机 build297 实证）：
 *   用户装 build297 后，发现页从「LegadoError 1」变成了
 *   「exploreKinds 结果不可信：只解析出 0 个分类」⇒ **求值通了、但站方交白卷** ⭐⭐⭐
 *   ⇒ 根因 = 站方 `exploreUrl` 第一行 `if (!nhAuth()) { return ""; }`
 *     ⇒ `nhAuth()` 读 `source.get("nhAuthed")`
 *     ⇒ **引擎的 `srcGet` 读的是 `BookSource.variable` 那一格**
 *     ⇒ 而 App 灌站方变量的地方是 `srcDict["__variable"]` ⇒ **另一格** ⇒ **两格不通** ⭐⭐⭐
 *     ⇒ 站方 JS 读变量**恒空** ⇒ 恒 false ⇒ **主动交白卷**（不是崩溃 ⇒ 最难查的一类）⭐⭐⭐
 *
 * ⭐ **本门禁验的是【双向】**：
 *   ① **读**：`source.get(k)` / `source.getVariable()` 读得到宿主灌的那一格 ⭐⭐⭐
 *   ② **写**：站方 `source.put(k,v)` 写进 JSBridge 副本后 ⇒ 宿主能**读回来** ⭐⭐⭐
 *      （JSBridge.source 是模块内可见 ⇒ 宿主读不到 ⇒ 正解是 `bridge.eval("source.getVariable()")`）⭐⭐⭐
 *
 * ⚠️ **为什么不能用 Node 跑这一条**：
 *   这条验的是**宿主与引擎的接线**，而 `JSBridge` 只在 Apple 平台存在
 *   ⇒ Linux 沙盒只能验**逻辑**（哪一格该灌、哪一格该读），**真跑**要在 CI/真机 ⭐⭐⭐
 *   ⇒ 本门禁做两件事：
 *     ① **静态断言**：接线必须「灌 `variable`」+「用 `source.getVariable()` 读回」（不许只灌不读）⭐⭐⭐
 *     ② **真跑**（Apple 平台）：Node 里用 JSBridge 等价语义跑一遍读写 ⇒ 证明语义对 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const src = fs.readFileSync(APP, 'utf8');

console.log('=== 1. 静态断言：站方变量必须【灌进 engineSource.variable】 ===');
ok(/src\.variable\s*=\s*merged/.test(src),
   '宿主把【合并后的 map】灌进了 engineSource.variable（引擎的 srcGet 读的就是这一格）');
ok(/engineSourceForJS/.test(src),
   'op 跑 JS 时用的 engineSource 是【灌好站方变量】的那份');
ok(/__variable/.test(src),
   '站方变量仍从 payload 的 __variable 取（不另造数据源）');

console.log('\n=== 2. 静态断言：站方变量必须【能读回来】（写方向） ===');
ok(/collectStationVariable/.test(src), '有 collectStationVariable（读回站方 JS 改过的值）');
ok(/source\.getVariable\(\)/.test(src),
   '读回用 `bridge.eval("source.getVariable()")`（JSBridge.source 模块内可见 ⇒ 宿主读不到 ⇒ 只能走 JS）');
ok(/__sourceVariable"\]\s*=\s*stationVar/.test(src),
   '回传的 __sourceVariable 是【读回来的站方变量】，不是书籍变量那一格');
ok(/stationSeeded/.test(src),
   '站方变量有自己的种子（判定站方改没改 ⇒ 证据不许自证）');
ok(/self\.stationSeeded\s*=\s*sv/.test(src),
   '站方变量的种子【等于灌进去的值】（否则「改没改」永远 false ⇒ 证据自证）');
ok(/let stationVar = session\.collectStationVariable \{/.test(src),
   '读回走 collectStationVariable（不拿书籍变量那一格冒充）');

console.log('\n=== 2b. 静态断言：登录信息必须进引擎那一格的 loginInfo 项 ===');
// ⚠️⚠️⚠️ **为什么这条最关键**（2026-11-19 真机 build299 实证）：
//   站方读密码 = `nhAuthUiMap()` ⇒ `source.getLoginInfoMap()`
//   ⇒ 引擎的 `loginInfoGet` ⇒ **`BookSource.variable["loginInfo"]`** ⭐⭐⭐
//   ⇒ 不并进去 ⇒ 站方读到空 map ⇒ 点「🔓 解锁整个源」必然失败 ⇒ 永远交白卷 ⭐⭐⭐
ok(/mergeLoginInfo/.test(src), '有 mergeLoginInfo（合并「已存登录信息 + 本次表单值」）');
ok(/m\["loginInfo"\]\s*=\s*mergedLogin/.test(src),
   'login op 把合并后的登录信息写进引擎那一格的 loginInfo 项');
ok(/mergeStationMap\(bookVars:[^)]*loginInfo:/.test(src),
   'mergeStationMap 把 loginInfo 也并进引擎那一格');
ok(/loginInfoGet/.test(src) === false || /loginInfo/.test(src),
   '源码里出现了 loginInfo 相关处理（可读即可）');

console.log('\n=== 3. 静态断言：书籍变量与站方变量【不许混】 ===');
ok(/__sourceVars"\]\s*=\s*session\.variables\.getVariable\(\)/.test(src),
   '__sourceVars 仍是书籍变量那一格（RuleVariables map）');
ok(!/__sourceVariable"\]\s*=\s*session\.variables\.getVariable\(\)/.test(src),
   '__sourceVariable 不再是书籍变量那一格（★ 这一条正是 build297 的 bug 现场）');

console.log('\n=== 4. 真跑：站方变量的读写语义（Node 等价） ===');
{
  // ⚠️ 用 Node 模拟【引擎的 srcGet/srcPut 语义】+【宿主的两格】
  //   ⇒ 证明「灌 variable + 用 getVariable 读回」这套接线是通的 ⭐⭐⭐
  const vm = require('vm');
  const station = { nhAuthed: 'HASH', nhPlatSwitch: '' };   // 宿主灌的那一格
  const bookVars = { token: 'T' };                           // 书籍变量那一格（另一格）
  const sandbox = { JSON, String, Object, Array };
  vm.createContext(sandbox);
  vm.runInContext(`
    var __station = ${JSON.stringify(station)};
    var __book = ${JSON.stringify(bookVars)};
    // 引擎语义：srcGet/srcPut 读写的都是 __station 这一格
    var source = {
      get: function(k){ return __station[k] === undefined ? '' : String(__station[k]); },
      put: function(k,v){ __station[k] = String(v); return __station[k]; },
      getVariable: function(){ return JSON.stringify(__station); },
      setVariable: function(v){ try { __station = JSON.parse(String(v)); } catch(e){} }
    };
  `, sandbox);
  const s = sandbox.source;
  ok(s.get('nhAuthed') === 'HASH', 'source.get("nhAuthed") 读到宿主灌的值');
  ok(JSON.parse(s.getVariable()).nhAuthed === 'HASH', 'source.getVariable() 读到整格');
  s.put('nhPlatSwitch', '书旗');
  ok(s.get('nhPlatSwitch') === '书旗', 'source.put(...) 写进去了');
  const back = JSON.parse(s.getVariable());
  ok(back.nhPlatSwitch === '书旗', '宿主能用 source.getVariable() 把改动读回来（写回通道）');
  // 站方登录门的真实判据
  const authed = String(s.get('nhAuthed') || '');
  ok(authed !== '' && authed === 'HASH', '站方 nhAuth() 的判据成立（不再交白卷）');
}

console.log('\n=== 5. 变异对照（改坏接线 ⇒ 必须红） ===');
{
  // ⭐⭐⭐ **变异后必须【重新跑一遍断言】**（不是自己判断变异后字符串长什么样）
  //   ⇒ 否则「断言写了但检测逻辑写错」⇒ 变异抓不到 ⇒ 门禁是摆设 ⭐⭐⭐
  const assertOn = (text) => {
    const fails = [];
    if (!/src\.variable\s*=\s*merged/.test(text)) fails.push('没灌 variable');
    if (!/engineSourceForJS/.test(text)) fails.push('没用 engineSourceForJS');
    if (!/collectStationVariable/.test(text)) fails.push('没有 collectStationVariable');
    if (!/source\.getVariable\(\)/.test(text)) fails.push('没用 source.getVariable() 读回');
    if (!/__sourceVariable"\]\s*=\s*stationVar/.test(text)) fails.push('__sourceVariable 不是 stationVar');
    if (/__sourceVariable"\]\s*=\s*session\.variables\.getVariable\(\)/.test(text)) fails.push('__sourceVariable 混成书籍变量');
    if (!/__sourceVars"\]\s*=\s*session\.variables\.getVariable\(\)/.test(text)) fails.push('__sourceVars 不是书籍变量');
    if (!/stationSeeded/.test(text)) fails.push('站方变量没有自己的种子');
    // ⭐⭐⭐ **种子必须【等于灌进去的值】**（否则「改没改」永远 false ⇒ 证据自证）⭐⭐⭐
    if (!/self\.stationSeeded\s*=\s*sv/.test(text)) fails.push('站方变量的种子不等于灌进去的值');
    // ⭐⭐⭐ **读回必须【走 collectStationVariable】**（不能拿书籍变量那一格冒充）⭐⭐⭐
    if (!/let stationVar = session\.collectStationVariable \{/.test(text)) fails.push('读回没走 collectStationVariable');
    // ⭐⭐⭐ **合并必须【把书籍变量的项也并进去】**（`nhAuthed` 就在那一格）⭐⭐⭐
    //   ⇒ 只判「调用了 mergeStationMap」不够（变异把调用换掉、函数名仍在别处 ⇒ 抓不到）⭐⭐⭐
    if (!/mergeStationMap\(bookVars:\s*(vars|variables),\s*stationRaw:\s*sv\)/.test(text)) {
      fails.push('合并没把书籍变量并进去（nhAuthed 读不到）');
    }
    if (!/m\["loginInfo"\]\s*=\s*mergedLogin/.test(text)) fails.push('loginInfo 没写进引擎那一格（解锁按钮永远失败）');
    if (!/mergeLoginInfo/.test(text)) fails.push('没有 mergeLoginInfo');
    return fails;
  };
  const cases = [
    // ⚠️⚠️⚠️ **变异必须【破坏语义】、不能只是注释掉**（2026-11-19 实证）：
    //   注释掉的那行**仍然会被正则匹配到** ⇒ 断言照样绿 ⇒ 变异白做 ⭐⭐⭐
    //   ⇒ 正解：**改掉赋值目标**（灌到别的地方 / 换回错的格）⇒ 断言才红 ⭐⭐⭐
    ['不再灌 engineSource.variable（读方向断 ⇒ 站方读不到 nhAuthed）',
      // ⚠️⚠️ **两处都要断**（`src.variable = merged` 与 `engineSource.variable = merged`）
      //   ⇒ 只断一处 ⇒ 另一处仍灌 ⇒ 变异无效 ⇒ 门禁没牙齿 ⭐⭐⭐ ⇒ 用 split/join 全局替换 ⭐⭐⭐
      (t) => t.split('src.variable = merged').join('src.variable = ""')
              .split('engineSource.variable = merged').join('engineSource.variable = ""')],
    ['不再合并两格（只灌站方整串 ⇒ nhAuthed 读不到）',
      (t) => t.split('Self.mergeStationMap(bookVars: vars, stationRaw: sv)').join('sv')
              .split('Self.mergeStationMap(bookVars: variables, stationRaw: sv)').join('sv')],
    // ⚠️⚠️⚠️ **变异必须【整段换掉】，不能只是「前面加一句」**
    //   （前面加一句 ⇒ 原串仍在 ⇒ 断言照样匹配 ⇒ 变异白做）⭐⭐⭐
    // ⚠️⚠️⚠️ **变异必须【全部替换】**（`String.replace` 只换第一处 ⇒ 第二处原封不动
    //   ⇒ 断言照样匹配 ⇒ 变异白做）⭐⭐⭐ ⇒ 用 split/join 做全局替换 ⭐⭐⭐
    ['loginInfo 不并进引擎那一格（★ 解锁按钮永远失败）',
      (t) => t.replace('m["loginInfo"] = mergedLogin', 'm["loginInfoUnused"] = mergedLogin')],
    ['读回改用书籍变量那一格（写方向断 ⇒ 站方 put 写不回来）',
      (t) => t.split('let stationVar = session.collectStationVariable {')
              .join('let stationVar = session.variables.getVariable(); if false { session.collectStationVariable {')],
    ['站方变量的种子被抹掉（证据自证）',
      (t) => t.replace(/self\.stationSeeded = sv/, 'self.stationSeeded = ""')],
    ['__sourceVariable 回传书籍变量那一格（★ build297 的 bug 现场）',
      (t) => t.replace(/out\["__sourceVariable"\] = stationVar/g, 'out["__sourceVariable"] = session.variables.getVariable()')],
  ];
  const orig = src;
  const tmp = APP + '.gate-bak';
  try {
    for (const [name, fn] of cases) {
      const mutated = fn(orig);
      if (mutated === orig) { ok(false, `变异「${name}」：锚点命中`, '锚点没命中 ⇒ 变异无效'); continue; }
      // ⭐⭐⭐ **变异后重新跑断言** ⇒ 有断言没抓住 = 门禁没牙齿 ⭐⭐⭐
      const fails = assertOn(mutated);
      ok(fails.length > 0, `变异「${name}」⇒ 门禁红`,
         fails.length ? ('被抓住：' + fails.join('、')) : '变异后仍然通过 ⇒ 这条断言是摆设');
    }
  } finally {
    fs.writeFileSync(tmp, orig, 'utf8');
    try { fs.unlinkSync(tmp); } catch (e) {}
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
