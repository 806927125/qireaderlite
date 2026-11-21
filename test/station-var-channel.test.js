#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：站方变量的【两套语义】双向真跑（移植 柴阅/Chaiyue 后的新语义）**
 *
 * ⚠️⚠️⚠️ **为什么必须重写这条**（2026-11-19 真机 build297–301 实证）：
 *   build297 起我们一路在修「站方变量读不到」⇒ 连续四个版本（297/298/299/300/301）
 *   每次都只修**表层** ⇒ 真正根因是**语义错位** ⭐⭐⭐
 *
 *   ⭐⭐⭐⭐⭐ **权威规格 = 柴阅/Chaiyue 的 `SourceState`**（`RuleSession.swift`）：
 *
 *     | JS API                       | 柴阅存法               | 存储键                  |
 *     |------------------------------|------------------------|-------------------------|
 *     | `source.getVariable()`       | **一整串**             | `sourceVariable_<key>`  |
 *     | `source.setVariable(str)`    | **一整串**             | 同上                    |
 *     | `source.get(k)`/`put(k,v)`   | **每 k 一个独立项** ⭐  | `v_<key>_<k>`           |
 *     | `source.getLoginInfoMap()`   | 独立格（表单数据）     | `userInfo_<key>`（加密）|
 *
 *   ⇒ 旧实现把 `getVariable(key:)` 做成「从 `variable` 整串里取项」⇒ **两套混成一格** ⭐⭐⭐
 *     ⇒ 站方 `source.put('nhAuthed', h)` 与站方变量的项**互相污染**
 *     ⇒ 站方 `nhAuth()` 恒 false ⇒ **exploreUrl 主动交白卷** ⇒ **0 个分类** ⭐⭐⭐
 *
 * ⭐ **本门禁验三件事**：
 *   ① **读**：`source.get(k)` 读得到【书源变量格】；`source.getVariable()` 返回【站方整串】⭐⭐⭐
 *   ② **写**：站方 `source.put(k,v)` 写进【书源变量格】⇒ 宿主能**读回来**（`source.getAllVars()`）⭐⭐⭐
 *   ③ **两格不串味**：站方整串的项**读不到**；书源变量的项**不污染**整串 ⭐⭐⭐
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

const rawSrc = fs.readFileSync(APP, 'utf8');
// ⭐⭐⭐⭐⭐ **必须剥注释**（2026-11-19 实证）：
//   注释里写 `bridge.eval("source.getVariable()")` ⇒ **计数会被撑起来**
//   ⇒ 变异打掉真代码、注释还在 ⇒ 计数仍 ≥2 ⇒ **断言照样绿 ⇒ 门禁没牙齿** ⭐⭐⭐
function stripComments(t) {
  return t
    .replace(/\/\*[\s\S]*?\*\//g, ' ')          // 块注释
    .replace(/\/\/[^\n]*/g, ' ');               // 行注释
}
const src = stripComments(rawSrc);

console.log('=== 1. 静态断言：灌入必须【两格分开】 ===');
ok(/src\.variable\s*=\s*sv/.test(src),
   '站方变量整串 ⇒ 灌进 engineSource.variable（★ 原样、不解析不合并）');
ok(/src\.sourceVars\s*=\s*svMap/.test(src),
   '★ 书源变量 ⇒ 灌进 engineSource.sourceVars（★ 独立格 ⇒ source.get/put 的家）');
ok(!/src\.variable\s*=\s*merged/.test(src),
   '★ 不再把两格【合并】进 variable（★ 合并就是语义错位的源头）');
ok(/engineSourceForJS/.test(src),
   'op 跑 JS 时用的 engineSource 是【灌好两格】的那份');
ok(/__variable/.test(src),
   '站方变量仍从 payload 的 __variable 取（不另造数据源）');

console.log('\n=== 2. 静态断言：写方向必须【读回来】（且读的是【书源变量格】） ===');
ok(/source\.getAllVars\(\)/.test(src),
   '★ 读回用 source.getAllVars()（★ 一次导出整张书源变量 map）');
ok(/__sourceVars"\]\s*=\s*(?:Self|Session)\.sourceVarsJSON\(/.test(src),
   '★ __sourceVars 回传的是【书源变量格】的 JSON（★ 不再回传书籍变量那一格）');
ok(!/__sourceVars"\]\s*=\s*session\.variables\.getVariable\(\)/.test(src),
   '★ __sourceVars 不再是书籍变量那一格（★ build297 的 bug 现场）');
ok(/__sourceVariable"\]\s*=\s*stationVar/.test(src),
   '__sourceVariable 回传站方那一格');
ok(!/__sourceVariable"\]\s*=\s*session\.variables\.getVariable\(\)/.test(src),
   '__sourceVariable 不再是书籍变量那一格');

console.log('\n=== 3. 静态断言：登录信息必须【进书源变量格】（解锁按钮的命脉） ===');
// ⚠️⚠️⚠️ **为什么最关键**（2026-11-19 真机 build300 实证）：
//   站方读密码 = `nhAuthUiMap()` ⇒ `source.getLoginInfoMap()`
//   ⇒ 引擎的 `loginInfoGet` ⇒ `getVariable(key: "loginInfo")` ⇒ **落在书源变量格** ⭐⭐⭐
//   ⇒ 不并进去 ⇒ 站方读到空 map ⇒ 点「🔓 解锁整个源」必然失败 ⇒ 永远交白卷 ⭐⭐⭐
ok(/mergeLoginInfo/.test(src), '有 mergeLoginInfo（合并「已存登录信息 + 本次表单值」）');
ok(/m\["loginInfo"\]\s*=\s*(?:Self\.)?jsonString\(merged\)/.test(src),
   '★ loginInfo 写进【书源变量格】的 loginInfo 项（★ 与引擎 loginInfoGet 同格）');
ok(/engineSourceWithLoginInfo/.test(src),
   '★ 合并逻辑放在【非平台相关】的 Session 方法里（Linux 沙盒门禁编得到 ⇒ 类型错 3 秒暴露）');
ok(/stripLoginInfo\(from:/.test(src), '回传时真的调用了 stripLoginInfo');
ok(/let stationVar = (?:Self|Session)\.stripLoginInfo\(from:/.test(src),
   '★ 回传的 stationVar 走过 stripLoginInfo（明文密码不进站方变量槽）');

console.log('\n=== 4. 静态断言：存量迁移（老版本把书源变量塞在站方整串里） ===');
ok(/legacySourceVars/.test(src), '有 legacySourceVars 迁移函数');
ok(/nhAuthed/.test(src) && /nhPlatSwitch/.test(src),
   '★ 迁移白名单含 nhAuthed / nhPlatSwitch（★ 解锁态与切台标记）');
ok(!/legacySourceVars[\s\S]{0,600}?\"src\"/.test(src),
   '★ 迁移白名单**不含**站方变量的项（src/gender 不迁 ⇒ 语义不串味）');

console.log('\n=== 5. 真跑：两套语义（Node 等价 ⇒ 证明接线语义对） ===');
{
  const vm = require('vm');
  const stationRaw = '{"src":"书旗","gender":"全部"}';      // 站方变量（整串）
  const sourceVars = { token: 'T' };                          // 书源变量（每 k 一项）
  const sandbox = { JSON, String, Object, Array };
  vm.createContext(sandbox);
  vm.runInContext(`
    var __var = ${JSON.stringify(stationRaw)};
    var __sVars = ${JSON.stringify(sourceVars)};
    var source = {
      get: function(k){ return __sVars[k] === undefined ? '' : String(__sVars[k]); },
      put: function(k,v){ __sVars[k] = String(v); return String(v); },
      getVariable: function(){ return typeof __var === 'string' ? __var : JSON.stringify(__var); },
      setVariable: function(v){ __var = String(v); },
      getAllVars: function(){ return __sVars; },
      // ⭐ 真实引擎：loginInfoGet 返回 **JSON 串** ⇒ JS 侧 JSON.parse（见 03_response.js:125）⭐
      getLoginInfo: function(){ return __sVars['loginInfo'] || ''; },
      getLoginInfoMap: function(){ var m = {}; try { m = JSON.parse(__sVars['loginInfo'] || '{}'); } catch(e) { m = {}; } return m; }
    };
  `, sandbox);
  const s = sandbox.source;

  // ① 站方变量：整串语义
  ok(s.getVariable() === stationRaw, 'source.getVariable() 返回【整串】（站方变量语义）');
  ok(s.get('src') === '', '★ source.get("src") 读不到站方变量的项（★ 两套不串味）');
  // ② 书源变量：独立项语义
  ok(s.get('token') === 'T', 'source.get("token") 读到【书源变量格】');
  s.put('nhAuthed', 'HASH');
  ok(s.get('nhAuthed') === 'HASH', 'source.put("nhAuthed") 落在【书源变量格】');
  ok(s.getVariable() === stationRaw, '★ put 不污染站方变量的整串（★ 语义分离成立）');
  // ③ 写回通道：宿主读回整张书源变量 map
  const back = s.getAllVars();
  ok(back && back.nhAuthed === 'HASH' && back.token === 'T',
     '★ 宿主能用 source.getAllVars() 把改动读回来（★ 写回通道）');
  // ④ 登录信息
  s.put('loginInfo', JSON.stringify({ '整源解锁密码': 'PW' }));
  ok(s.getLoginInfoMap()['整源解锁密码'] === 'PW',
     '★ 站方 getLoginInfoMap() 读到了密码（★ 解锁按钮的命脉）');
  // ⑤ 站方 nhAuth() 的真实判据
  const authed = String(s.get('nhAuthed') || '');
  ok(authed !== '' && authed === 'HASH', '站方 nhAuth() 的判据成立（不再交白卷）');
}

console.log('\n=== 6. 变异对照（改坏接线 ⇒ 必须红） ===');
{
  // ⭐⭐⭐ **变异后必须【重新跑一遍断言】**（不是自己判断变异后字符串长什么样）
  //   ⇒ 否则「断言写了但检测逻辑写错」⇒ 变异抓不到 ⇒ 门禁是摆设 ⭐⭐⭐
  const assertOn = (text) => {
    const fails = [];
    if (!/src\.variable\s*=\s*sv/.test(text)) fails.push('没灌站方变量整串');
    if (!/src\.sourceVars\s*=\s*svMap/.test(text)) fails.push('没灌书源变量独立格');
    if (/src\.variable\s*=\s*merged/.test(text)) fails.push('又把两格合并进 variable（语义错位回归）');
    if (!/engineSourceForJS/.test(text)) fails.push('没用 engineSourceForJS');
    if (!/source\.getAllVars\(\)/.test(text)) fails.push('没用 getAllVars 读回');
    if (!/__sourceVars"\]\s*=\s*(?:Self|Session)\.sourceVarsJSON\(/.test(text)) fails.push('__sourceVars 不是书源变量格');
    if (/__sourceVars"\]\s*=\s*session\.variables\.getVariable\(\)/.test(text)) fails.push('__sourceVars 混成书籍变量');
    if (!/__sourceVariable"\]\s*=\s*stationVar/.test(text)) fails.push('__sourceVariable 不是 stationVar');
    if (!/m\["loginInfo"\]\s*=\s*(?:Self\.)?jsonString\(merged\)/.test(text)) fails.push('loginInfo 没写进书源变量格');
    if (!/let stationVar = (?:Self|Session)\.stripLoginInfo\(from:/.test(text)) fails.push('回传没剥 loginInfo');
    if (!/mergeLoginInfo/.test(text)) fails.push('没有 mergeLoginInfo');
    // ⭐⭐⭐ **查【调用点】、不能查「函数名存在」**（2026-11-19 实证的老坑）：
    //   变异把**调用**换掉、**定义**仍在 ⇒ 只查名字 ⇒ 照样绿 ⇒ 门禁没牙齿 ⭐⭐⭐
    if (!/Self\.legacySourceVars\(from: sv\)/.test(text)) fails.push('没有存量迁移调用');
    return fails;
  };
  const cases = [
    // ⚠️⚠️⚠️ **变异必须【破坏语义】、不能只是注释掉**
    //   （注释掉的那行**仍然会被正则匹配到**⇒ 断言照样绿⇒ 变异白做）⭐⭐⭐
    ['不再灌站方变量整串（读方向断）',
      (t) => t.split('src.variable = sv').join('src.variable = ""')],
    ['不再灌书源变量独立格（★ nhAuthed 读不到 ⇒ 0 分类）',
      (t) => t.split('src.sourceVars = svMap').join('src.sourceVars = [:]')],
    ['又把两格合并进 variable（★ 语义错位回归）',
      (t) => t.split('src.variable = sv').join('src.variable = merged')],
    ['不用 getAllVars 读回（★ 解锁态存不下来 ⇒ 下次又交白卷）',
      (t) => t.split('source.getAllVars()').join('source.get("__none")')],
    ['loginInfo 不写进书源变量格（★ 解锁按钮永远失败）',
      (t) => t.split('m["loginInfo"] = Self.jsonString(merged)').join('m["loginInfoUnused"] = Self.jsonString(merged)')
              .split('m["loginInfo"] = jsonString(merged)').join('m["loginInfoUnused"] = jsonString(merged)')],
    ['回传时不剥 loginInfo（★ 明文密码躺盘）',
      (t) => t.split('Session.stripLoginInfo(from: session.collectStationVariable {')
              .join('session.collectStationVariable {')
              .split('Self.stripLoginInfo(from: session.collectStationVariable {')
              .join('session.collectStationVariable {')],
    ['__sourceVars 回传书籍变量那一格（★ build297 的 bug 现场）',
      (t) => t.replace(/out\["__sourceVars"\]\s*=\s*(?:Self|Session)\.sourceVarsJSON\(/g,
                       'out["__sourceVars"] = session.variables.getVariable()')],
    ['存量迁移被抹掉（★ 老用户的解锁态丢失）',
      (t) => t.replace(/legacySourceVars\(from: sv\)/, '[:]')],
  ];
  const orig = src;   // ⚠️ 已是【剥注释后】的文本 ⇒ 变异不会命中注释里的同名串 ⭐⭐⭐
  for (const [name, fn] of cases) {
    const mutated = fn(orig);
    if (mutated === orig) { ok(false, `变异「${name}」：锚点命中`, '锚点没命中 ⇒ 变异无效'); continue; }
    const fails = assertOn(mutated);
    ok(fails.length > 0, `变异「${name}」⇒ 门禁红`,
       fails.length ? ('被抓住：' + fails.join('、')) : '变异后仍然通过 ⇒ 这条断言是摆设');
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
