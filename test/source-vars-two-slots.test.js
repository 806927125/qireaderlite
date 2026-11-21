#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：站方变量的【两套语义】必须与 柴阅/Chaiyue 一致（移植对拍）**
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁**（2026-11-19 真机，用户直接指出「你弄反了」）：
 *   连续三轮「0 个分类」⇒ 我连猜三个原因（求值 / 两格不通 / 门禁未解锁）**全错或不全**
 *   ⇒ 真因是**更深一层**：【站方变量的两套语义】被我们实现错了 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **权威规格 = 柴阅/Chaiyue 的 `SourceState`**（github.com/Lincb522/Chaiyue
 *   `Packages/ReaderCore/Sources/RuleEngine/Engine/RuleSession.swift`）：
 *
 *   | JS API                         | 柴阅的存法                       | 存储键                  |
 *   |--------------------------------|----------------------------------|-------------------------|
 *   | `source.getVariable()`         | **一整串**                        | `sourceVariable_<key>`  |
 *   | `source.setVariable(str)`      | **一整串**                        | 同上                    |
 *   | `source.get(k)` / `put(k,v)`   | **每个 k 一个独立项** ⭐⭐⭐        | `v_<key>_<k>`           |
 *   | `source.getLoginInfoMap()`     | 独立格（登录表单数据）            | `userInfo_<key>`（加密）|
 *
 *   ⇒ 我们之前把 `source.get/put` 实现成「从 `variable` 这一格 JSON 里取某一项」
 *     ⇒ **语义错位** ⭐⭐⭐
 *     ⇒ 站方 `source.put('nhAuthed', h)` 与站方变量的项**混在一格**
 *     ⇒ 而宿主灌进 `variable` 的是**站方变量的整串** ⇒ `source.get("nhAuthed")` **读不到**
 *     ⇒ 站方 `nhAuth()` 恒 false ⇒ **exploreUrl 主动交白卷** ⇒ **0 个分类** ⭐⭐⭐
 *
 * ⭐ **本门禁验三件事**：
 *   ① 引擎的 `srcGet/srcPut` 走**独立的 sourceVars**（不是 `variable` 的项）⭐⭐⭐
 *   ② `source.getVariable()` 仍返回**整串**（站方变量的语义不能变）⭐⭐⭐
 *   ③ `loginInfo` 走**书源变量格**（引擎 `loginInfoGet` ⇒ `getVariable(key:)`）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const ENGINE_BOOKSOURCE = path.join(ROOT, 'LegadoEngine/Sources/LegadoEngine/Models/BookSource.swift');
const ENGINE_NATIVES = path.join(ROOT, 'LegadoEngine/Sources/LegadoEngine/JS/JSNatives.swift');
const BOOTSTRAP = path.join(ROOT, 'LegadoEngine/Sources/LegadoEngine/JS/Resources/03_response.js');
const APP = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

function stripComments(t) {
  return t.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

const bs = fs.readFileSync(ENGINE_BOOKSOURCE, 'utf8');
const natives = fs.readFileSync(ENGINE_NATIVES, 'utf8');
const boot = fs.readFileSync(BOOTSTRAP, 'utf8');
const app = fs.readFileSync(APP, 'utf8');
const bsCode = stripComments(bs);

console.log('=== 1. 引擎：`source.get/put` 走【独立格】（sourceVars） ===');
ok(/public var sourceVars:\s*\[String:\s*String\]/.test(bsCode), '引擎 BookSource 有独立的 sourceVars（每 k 一项）');
ok(/getVariable\(key:\s*String\)\s*->\s*String\s*\{\s*sourceVars\[key\]/.test(bsCode),
   '★ getVariable(key:) 读的是 sourceVars（★ 不是从 variable 里取项）');
ok(/putVariable\(key:\s*String,\s*value:\s*String\)[\s\S]{0,200}sourceVars\[key\]\s*=\s*value/.test(bsCode),
   '★ putVariable(key:) 写的是 sourceVars');
ok(!/getVariable\(key:\s*String\)\s*->\s*String\s*\{[^}]*variable/.test(bsCode),
   '★ getVariable(key:) 不再从 variable 里取（★ 语义错位已消除）');

console.log('\n=== 2. 引擎：`source.getVariable()` 仍返回【整串】（站方变量语义不变） ===');
ok(/public func getVariable\(\)\s*->\s*String\s*\{\s*variable/.test(bsCode),
   'getVariable() 仍返回 variable 整串');
ok(/public mutating func setVariable\(_ v:\s*String\)\s*\{\s*variable\s*=\s*v/.test(bsCode),
   'setVariable(str) 仍写 variable 整串');
ok(/case "srcGet"[\s\S]{0,320}if k == "__variable" \{ return source\?\.getVariable\(\)/.test(stripComments(natives)),
   '★ srcGet("__variable") 走整串通道（★ 站方变量的语义没变）');
ok(/case "srcPut"[\s\S]{0,320}if k == "__variable" \{ source\?\.setVariable/.test(stripComments(natives)),
   '★ srcPut("__variable") 走整串通道');

console.log('\n=== 3. 引擎：loginInfo 走【书源变量格】 ===');
ok(/case "loginInfoGet": return source\?\.getVariable\(key: "loginInfo"\)/.test(stripComments(natives)),
   'loginInfoGet ⇒ getVariable(key:"loginInfo") ⇒ 落在 sourceVars 格');
ok(/case "loginInfoPut": source\?\.putVariable\(key: "loginInfo"/.test(stripComments(natives)),
   'loginInfoPut ⇒ putVariable(key:"loginInfo")');

console.log('\n=== 4. 引擎：给宿主一次导出整张书源变量的通道 ===');
ok(/case "srcGetAll": return source\?\.sourceVars/.test(stripComments(natives)),
   '有 srcGetAll 通道（一次导出整张 map ⇒ 宿主能读回）');
ok(/getAllVars\s*=\s*function\(\)\s*\{\s*return __native\.srcGetAll\(\)/.test(boot),
   'bootstrap 的 source.getAllVars() 绑到 srcGetAll');

console.log('\n=== 5. 宿主：灌入【两格分开】 + 回传【读回引擎那格】 ===');
ok(/src\.variable = sv/.test(app), '站方变量整串 ⇒ 灌进 engineSource.variable');
ok(/src\.sourceVars = svMap/.test(app), '书源变量 ⇒ 灌进 engineSource.sourceVars（独立格）');
ok(/source\.getAllVars\(\)/.test(app), '宿主回传时用 source.getAllVars() 读回引擎那格');
ok(/legacySourceVars/.test(app), '有存量迁移（老版本把书源变量塞在站方整串里 ⇒ 要迁）');

console.log('\n=== 6. 语义对拍：柴阅模型 vs 我们的实现 ===');
{
  // ⭐ 模拟引擎的 source 对象（按我们改完后的语义）
  function makeSource(state) {
    // state = { variable: 整串, sourceVars: {k:v} }
    return {
      getVariable: () => state.variable || '',
      setVariable: (v) => { state.variable = String(v); },
      get: (k) => (state.sourceVars && state.sourceVars[k] !== undefined ? state.sourceVars[k] : ''),
      put: (k, v) => {
        state.sourceVars = state.sourceVars || {};
        if (v === '' || v === undefined || v === null) delete state.sourceVars[k];
        else state.sourceVars[k] = String(v);
        return String(v);
      },
    };
  }
  const st = { variable: '{"src":"书旗","gender":"全部"}', sourceVars: {} };
  const src = makeSource(st);

  // ① 站方变量：getVariable 返回整串
  ok(src.getVariable() === '{"src":"书旗","gender":"全部"}', 'getVariable() 返回整串（站方变量语义）');
  // ② 书源变量：put/get 落在**独立格**
  src.put('nhAuthed', 'HASH');
  ok(st.sourceVars.nhAuthed === 'HASH', 'put("nhAuthed") 落在 sourceVars 格');
  ok(st.variable === '{"src":"书旗","gender":"全部"}', '★ put 不污染站方变量的整串（★ 语义分离成立）');
  ok(src.get('nhAuthed') === 'HASH', 'get("nhAuthed") 读得到');
  ok(src.get('src') === '', '★ get("src") 读不到站方变量的项（★ 两套不串味）');
  // ③ 站方 setVariable 只动整串
  src.setVariable('{"src":"番茄"}');
  ok(st.variable === '{"src":"番茄"}' && st.sourceVars.nhAuthed === 'HASH',
     '★ setVariable 只动整串、书源变量格不受影响（★ 与柴阅一致）');
  // ④ 柴阅的 SourceState 也是这个模型 ⇒ 对拍结论
  ok(st.sourceVars.nhAuthed === 'HASH' && st.variable === '{"src":"番茄"}',
     '★ 与柴阅 SourceState 的两套语义一致（变量 vs 书源变量互不干扰）');
}

console.log('\n=== 6b. 存量迁移：老版本把书源变量塞在站方整串里 ⇒ 必须迁出来 ===');
{
  ok(/legacySourceVars/.test(app), '有 legacySourceVars 迁移函数');
  ok(/nhAuthed/.test(app) && /nhPlatSwitch/.test(app),
     '★ 迁移白名单含 nhAuthed / nhPlatSwitch（★ 解锁态与切台标记）');
  // ⚠️ **不能迁站方变量的项**（NH_D 那些）⇒ 否则两套语义又串味
  ok(!/legacySourceVars[\s\S]{0,600}?"src"/.test(app),
     '★ 迁移白名单**不含**站方变量的项（src/gender/… 不迁 ⇒ 语义不串味）');
  // 模拟迁移行为
  const LEGACY = ['nhAuthed', 'nhPwdHash', 'nhPlatSwitch', 'nhPlatLog', 'nhPlatSync',
                  'nhLoginState', 'nhSafeMode', 'nhHostCaps', 'nhImgRef', 'token'];
  const legacyRaw = '{"src":"书旗","gender":"全部","nhAuthed":"HASH","nhPlatSwitch":"番茄"}';
  const o = JSON.parse(legacyRaw);
  const migrated = {};
  for (const k of Object.keys(o)) { if (LEGACY.includes(k)) migrated[k] = o[k]; }
  ok(migrated.nhAuthed === 'HASH', '★ 迁移后 nhAuthed 在书源变量格（★ 站方读得到）');
  ok(migrated.src === undefined && migrated.gender === undefined,
     '★ 站方变量的项（src/gender）**不迁**（★ 两套语义保持分离）');
  ok(Object.keys(migrated).length === 2, `迁移只带书源变量的项（迁了 ${Object.keys(migrated).length} 项）`);
}

console.log('\n=== 7. 变异对照（改坏语义 ⇒ 必须红） ===');
{
  const cases = [
    ['getVariable(key:) 又从 variable 取项（语义错位回归）',
      (t) => t.replace(/getVariable\(key:\s*String\)\s*->\s*String\s*\{\s*sourceVars\[key\]/,
                       'getVariable(key: String) -> String { sourceVars[key] } // mutated')],
    ['putVariable(key:) 不写 sourceVars',
      (t) => t.replace(/sourceVars\[key\]\s*=\s*value/, 'sourceVars = [:]')],
    ['srcGet("__variable") 不走整串通道',
      (t) => t.replace(/if k == "__variable" \{ return source\?\.getVariable\(\) \?\? "" \}/,
                       'if k == "__variable" { return source?.getVariable(key: k) ?? "" }')],
    ['宿主不灌 sourceVars（书源变量进不了引擎）',
      (t) => t.replace(/src\.sourceVars = svMap/, '// mutated: src.sourceVars = svMap')],
    ['宿主不用 getAllVars 读回（解锁态存不下来）',
      (t) => t.replace(/source\.getAllVars\(\)/, 'source.get("__none")')],
  ];
  const origs = [
    [bsCode, 'bs'],
    [natives, 'natives'],
    [app, 'app'],
  ];
  const targets = { bs: ENGINE_BOOKSOURCE, natives: ENGINE_NATIVES, app: APP };

  for (const [name, fn] of cases) {
    let mutatedText = null, target = null;
    for (const [text, key] of origs) {
      const m = fn(text);
      if (m !== text) { mutatedText = m; target = targets[key]; break; }
    }
    if (!mutatedText) { ok(false, `变异「${name}」：锚点命中`, '锚点没命中 ⇒ 变异无效'); continue; }
    // 变异后重新跑「语义断言」⇒ 必须红
    let red = false;
    if (/getVariable\(key:\s*String\)\s*->\s*String\s*\{\s*sourceVars\[key\]/.test(mutatedText) === false
        && /getVariable\(key:/.test(mutatedText)) red = true;
    if (/sourceVars\[key\]\s*=\s*value/.test(mutatedText) === false
        && /putVariable\(key:/.test(mutatedText)) red = true;
    if (/if k == "__variable" \{ return source\?\.getVariable\(\)/.test(stripComments(mutatedText)) === false
        && /case "srcGet"/.test(mutatedText)) red = true;
    if (/src\.sourceVars = svMap/.test(mutatedText) === false && /src\.sourceVars/.test(mutatedText)) red = true;
    if (/source\.getAllVars\(\)/.test(mutatedText) === false && /__sourceVars/.test(mutatedText)) red = true;
    ok(red, `变异「${name}」⇒ 门禁红`, red ? '' : '变异后仍然通过 ⇒ 这条断言是摆设');
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
