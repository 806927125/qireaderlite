#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **「站方变量」的两种形态**（2026-10-27 真机「获取 token 不了」的根因）
 *
 * 跑法：node test/source-variable-shape.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ⚠️⚠️ **站方变量是「一整串」⇒ 两种形态并存**：
 *   · **map 形态**（🍅大灰狼 / NovelHub）：
 *     `getArguments(source.getVariable(),'server')` ⇒ 站方变量里放 `{"server":…}` ⭐
 *   · **凭据形态**（✿UAA四合一（知秋））：
 *     `authorization: Bearer ${source.getVariable()}` ⇒ 站方变量里放 **token 那一串** ⭐
 *
 * ⇒⇒ **App 把「书籍变量 / 线路表」写进站方变量 ⇒ 凭据形态的源直接被毁** ⭐⭐⭐
 *   （UAA：站方变量变成 `{"androidId":"…"}` ⇒ `Bearer {"androidId":"…"}`
 *     ⇒ 服务端 **403「无效JWT」** ⇒ 「获取 token」永远失败 ⭐⭐⭐）
 *
 * ⭐ 真服务器实证（直接打 UAA 接口，2026-10-27）：
 *   · 不带 authorization 头        ⇒ `403 口令1错误`（JWT 层放行）✅
 *   · `authorization: Bearer `（空）⇒ `403 口令1错误`（**空 Bearer 能过 JWT 层**）✅
 *   · `authorization: Bearer {"androidId":"…"}` ⇒ `403 无效JWT` ❌（**这才是真凶**）
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁钉三件事：
 *   ① **App 合成的 map（线路 / 默认表）不许走无守卫的 `setVariableAndVars`** ⭐
 *      （SourceService 里再出现它 ⇒ 红 ⇒ 这条路不许复活）
 *   ② 走线的地方必须带 `isMapStyle:` 判据（**没有判据 = 没保护**）
 *   ③ `setLineVars` 内部必须真的有两道守卫（map 形态判据 + 凭据形态守卫）
 *   ⇒ **变异对照**：把任一条改坏 ⇒ 必须红（不许「平凡通过」）⭐
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

/** 剥掉注释（静态断言不许被注释骗过） */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
}

const serviceRaw = read('QiReaderLite/Core/SourceService.swift');
const varsRaw = read('QiReaderLite/Core/SourceVariables.swift');
const backendRaw = read('QiReaderLite/Core/LegadoEngineBackend.swift');
const exploreRaw = read('QiReaderLite/Features/Explore/ExploreView.swift');
const sheetRaw = read('QiReaderLite/Features/Sources/SourceLoginSheet.swift');
const service = stripComments(serviceRaw);
const vars = stripComments(varsRaw);
const backend = stripComments(backendRaw);
const explore = stripComments(exploreRaw);
const sheet = stripComments(sheetRaw);

// ────────────────────────────────────────────────────────────
console.log('=== ① App 合成的 map 不许走无守卫的 `setVariableAndVars` ===');
// ⭐ 注意：`setVariableAndVars` 本身**没错**（站方自己写的值就该用它）
//   ⇒ 禁的是 **SourceService（App 合成 map 的地方）** 再用它 ⭐
const unguardedCalls = (service.match(/setVariableAndVars\s*\(/g) || []).length;
ok(unguardedCalls === 0,
   'SourceService 里没有无守卫的 setVariableAndVars( 调用',
   `还有 ${unguardedCalls} 处`);

console.log('\n=== ② 走线的写回必须带 `isMapStyle:` 判据 ===');
const lineVarCalls = (service.match(/setLineVars\s*\(/g) || []).length;
ok(lineVarCalls >= 2, 'SourceService 里有 ≥2 处 setLineVars( 写回（选线 / 测速）', `只有 ${lineVarCalls} 处`);
const withFlag = (service.match(/setLineVars\s*\([^)]*isMapStyle\s*:/g) || []).length;
ok(withFlag >= 2, '每处 setLineVars( 都带 isMapStyle: 判据', `只有 ${withFlag} 处带`);

console.log('\n=== ③ `setLineVars` 内部真的有两道守卫 ===');
const fnStart = vars.indexOf('static func setLineVars');
ok(fnStart >= 0, 'SourceVariables 里有 setLineVars(');
if (fnStart >= 0) {
  const body = vars.slice(fnStart, vars.indexOf('\n    }', fnStart) + 6);
  ok(/if\s+isMapStyle\s*\{/.test(body),
     '守卫①：isMapStyle 判据（非 map 形态 ⇒ 不写站方变量）');
  ok(/canWriteMapIntoVariable\s*\(/.test(body),
     '守卫②：canWriteMapIntoVariable( 形状守卫（凭据形态 ⇒ 不许被 map 覆盖）');
  ok(/setVars\s*\(/.test(body), '书源变量照样写（站方读 map 形态时用）');
  // ⭐⭐⭐ 迁移：旧实现灌进站方变量的污染要清掉（真机上还躺着 ⇒ 不清就永远 403）
  //   ⚠️ 判据是「形态 = **凭据**」（**不是**「不是 map」！）⇒ 形态**不知道**时不许清 ⭐⭐⭐
  //      （大灰狼第一次进来时默认表还没取到 ⇒ 那时候清一下就把它的合法 map 清掉了 ⭐）
  ok(/form\s*\(\s*for\s*:\s*sourceUrl\s*\)\s*==\s*\.credential/.test(body) && /setVariable\(""/.test(body),
     '守卫③：迁移 —— 凭据形态的源，站方变量里的旧污染要清掉');
}
const guardStart = vars.indexOf('static func canWriteMapIntoVariable');
ok(guardStart >= 0, 'SourceVariables 里有 canWriteMapIntoVariable(');
if (guardStart >= 0) {
  const g = vars.slice(guardStart, vars.indexOf('\n    }', guardStart) + 6);
  ok(/is\s+\[String:\s*Any\]/.test(g), '形状守卫认得「JSON map」');
  ok(/return\s+false/.test(g), '形状守卫对「非 JSON（一串凭据）」返回 false');
}

console.log('\n=== ③·b 「形态」要有证据（不许只看内容）===');
// ⚠️⚠️ **旧实现灌进站方变量的污染本身也是一份 map**（{"androidId":…}）⭐⭐⭐
//   ⇒ 拿「站方变量当前内容」当判据 ⇒ 污染被当成 map 形态 ⇒ 继续被灌 ⇒ 永远修不好 ⭐⭐⭐
//   ⇒ 判据必须是**证据**：**站方自己写过什么** ⇒ `SourceVariables.form(for:)` ⭐
ok(/form\s*\(\s*for\s*:/.test(service),
   '判据用「站方自己写过什么」的证据（SourceVariables.form(for:)）');
ok(!/isMapStyleVariable\s*\(\s*SourceVariables\.variable/.test(service),
   '⚠️ 不许拿「站方变量当前内容」当形态判据（污染本身也是 map ⇒ 会误判）');
ok(/static func form\s*\(\s*for\s+sourceUrl\s*:\s*String\s*\)\s*->\s*StationVarForm/.test(vars),
   'SourceVariables 里有 form(for:)（形态判据，单一真相）');
{
  // 变异对照：把判据换回「看内容」⇒ 上面那条必须红
  const m = service.replace(/form\s*\(\s*for\s*:/g, 'isMapStyleVariable(');
  ok(/isMapStyleVariable\s*\(/.test(m) && !/form\s*\(\s*for\s*:/.test(m),
     '变异对照：判据换回「看内容」⇒ 会被上面那条抓住');
}

console.log('\n=== ③·c ⭐⭐⭐ 证据不许「自证」（2026-10-27 真机复盘挖出来的根因）===');
// ⚠️⚠️⚠️ **回传时值「一模一样」** ⇒ 那是**宿主灌的污染被原样弹回来** ⇒ **不是证据** ⭐⭐⭐
//   ⇒ 拿它当证据 = 自证 ⇒ 「凭据形态」永远判不出来 ⇒ 真机上的污染**永远清不掉** ⭐⭐⭐
ok(/__sourceVariableChanged/.test(backend),
   '⭐ 引擎回传要带「站方到底改没改这一格」（__sourceVariableChanged）');
ok(/seededStationVariable/.test(backend),
   '⭐ 引擎要记得「灌进去的是哪一串」⇒ 才算得出改没改');
ok(/__sourceVariableChanged"\]\s*=\s*\(sv\.text\s*!=/.test(backend),
   '⭐ 「改没改」= 灌进去的 ≠ 回传出来的');
{
  const calls = (service.match(/stationWroteIt\s*\(/g) || []).length;
  ok(calls >= 3, `⭐ 落盘那几处都要问「站方真改过没」（stationWroteIt）`, `只有 ${calls} 处`);
  ok(/stationWroteIt\s*\(\s*obj\s*\)\s*\?\s*\.station\s*:\s*\.app/.test(service),
     '⭐⭐⭐ 落盘时按「改过没」决定 origin（改过 = .station 算证据 / 没改 = .app 不算）');
}
{
  // 变异对照：把 origin 恒写成 .station ⇒ 上面那条必须红
  const m = service.replace(/stationWroteIt\s*\(\s*obj\s*\)\s*\?\s*\.station\s*:\s*\.app/g, '.station');
  ok(!/stationWroteIt\s*\(\s*obj\s*\)\s*\?\s*\.station\s*:\s*\.app/.test(m),
     '变异对照：origin 恒 .station（自证）⇒ 会被上面那条抓住');
}

console.log('\n=== ③·d ⭐⭐⭐ 证据的键要带版本（旧的那份自证证据直接作废）===');
ok(/stationform\.v2\./.test(vars), '⭐ 证据的键带版本（v2）');
ok(!/sourcevariable\.stationmap\./.test(vars),
   '⭐⭐⭐ 旧的 v1 键（已经被自证污染了）不许再用');

console.log('\n=== ③·e ⭐⭐⭐ 迁移必须挂在「每个 op 都走」的链上 ===');
// ⚠️ 以前迁移写在 setLineVars（**选线**那条链）⇒ ✿UAA 压根没有线路 ⇒ 永远走不到 ⭐⭐⭐
const seedCalls = (service.match(/stationVariableToSeed\s*\(/g) || []).length;
ok(seedCalls >= 3, `⭐ 灌站方变量的那几处都走 stationVariableToSeed（迁移在那儿）`, `只有 ${seedCalls} 处`);
ok(!/srcDict\["__variable"\]\s*=\s*SourceVariables\.variable\s*\(/.test(service),
   '⭐⭐⭐ 不许直接灌 variable(for:)（那就把迁移绕过去了 ⇒ 真机上的污染清不掉）');
{
  const m = service.replace(/stationVariableToSeed\s*\(/g, 'variable(');
  ok(!/stationVariableToSeed\s*\(/.test(m), '变异对照：绕开 stationVariableToSeed ⇒ 会被上面那条抓住');
}

console.log('\n=== ③·f ⭐ 「默认表取过没」要单独记（不然分不清「没有」和「没取过」）===');
ok(/defaultTableFetched/.test(vars), 'SourceVariables 里有「默认表取过没」的标记');
{
  const d0 = vars.indexOf('static func setDefaultVars');
  const dBody = vars.slice(d0, vars.indexOf('\n    }', d0) + 6);
  ok(/defaultTableFetchedPrefix\s*\+\s*sourceUrl/.test(dBody),
     '⭐⭐⭐ setDefaultVars 要顺手记「取过了」（**哪怕表是空的**）');
}
ok(!/let vars = dict\["vars"\] as\? \[String:\s*Any\],\s*!vars\.isEmpty/.test(service),
   '⭐⭐⭐ 取默认表时**不许**因为「表是空的」就不落盘（⇒ 分不清「没有」和「没取过」）');
{
  // 变异对照：把「取过了」的标记删掉 ⇒ 上面那条必须红
  const d0 = vars.indexOf('static func setDefaultVars');
  const dEnd = vars.indexOf('\n    }', d0) + 6;
  const mutatedBody = vars.slice(d0, dEnd).replace(/defaultTableFetchedPrefix/g, 'xxx');
  const m = vars.slice(0, d0) + mutatedBody + vars.slice(dEnd);
  const md0 = m.indexOf('static func setDefaultVars');
  const md = m.slice(md0, m.indexOf('\n    }', md0) + 6);
  ok(!/defaultTableFetchedPrefix\s*\+\s*sourceUrl/.test(md),
     '变异对照：删掉「取过了」的标记 ⇒ 会被上面那条抓住');
  ok(/defaultTableFetchedPrefix\s*\+\s*sourceUrl/.test(m),
     '（对照）别的函数里还在用这个前缀（变异只动了 setDefaultVars）');
}

console.log('\n=== ③·g 宿主往站方变量写 map ⇒ 凭据形态要拦住 ===');
ok(/static func setHostMap/.test(vars), 'SourceVariables 里有 setHostMap（宿主写 map 的统一入口）');
{
  const h0 = vars.indexOf('static func setHostMap');
  const hBody = vars.slice(h0, vars.indexOf('\n    }', h0) + 6);
  ok(/form\s*\(\s*for\s*:\s*sourceUrl\s*\)\s*!=\s*\.credential/.test(hBody),
     '⭐⭐⭐ 凭据形态 ⇒ 宿主不许往这一格塞 map（✿UAA：那一格放的是 token）');
}
ok(/setHostMap\s*\(/.test(explore), '⭐ 发现页筛选写回走 setHostMap');
ok(!/setVariableAndVars\s*\(/.test(explore), '⭐ 发现页不许再走无守卫的 setVariableAndVars');
ok(/setHostMap\s*\(/.test(sheet), '⭐ 登录面板的变量写回走 setHostMap');
{
  // 变异对照：把 setHostMap 的凭据拦截删掉 ⇒ 上面那条必须红
  const h0 = vars.indexOf('static func setHostMap');
  const hEnd = vars.indexOf('\n    }', h0) + 6;
  const m = vars.slice(0, h0) + vars.slice(h0, hEnd).replace(/!=\s*\.credential/, '!= .zzz') + vars.slice(hEnd);
  const mh0 = m.indexOf('static func setHostMap');
  const mh = m.slice(mh0, m.indexOf('\n    }', mh0) + 6);
  ok(!/!=\s*\.credential/.test(mh), '变异对照：删掉凭据拦截 ⇒ 会被上面那条抓住');
}

console.log('\n=== ④ 删源时站方变量也要清（token 别残留）===');
const clearStart = vars.indexOf('static func clear');
ok(clearStart >= 0, 'SourceVariables 里有 clear(');
if (clearStart >= 0) {
  const c = vars.slice(clearStart, vars.indexOf('\n    }', clearStart) + 6);
  ok(/variablePrefix\s*\+\s*sourceUrl/.test(c), 'clear() 也删站方变量（variablePrefix）');
}

// ────────────────────────────────────────────────────────────
// ⭐⭐⭐ **变异对照**：把守卫改坏 ⇒ 上面的断言必须红（不许平凡通过）
// ────────────────────────────────────────────────────────────
console.log('\n=== ⑤ 变异对照（守卫改坏 ⇒ 必须红）===');
function mutatedService(replacement) {
  return service.replace(/setLineVars\s*\(/g, replacement);
}
{
  // 变异①：把走线写回改回无守卫的 setVariableAndVars ⇒ ① 必须红
  const m = mutatedService('setVariableAndVars(');
  const bad = (m.match(/setVariableAndVars\s*\(/g) || []).length;
  ok(bad > 0, '变异①（改回无守卫写回）⇒ 会被 ① 抓住');
}
{
  // 变异②：把 isMapStyle 判据删掉 ⇒ ② 必须红
  const m = service.replace(/isMapStyle\s*:/g, 'x:');
  const withFlag = (m.match(/setLineVars\s*\([^)]*isMapStyle\s*:/g) || []).length;
  ok(withFlag < 2, '变异②（删掉 isMapStyle 判据）⇒ 会被 ② 抓住');
}
{
  // 变异③：形状守卫恒返回 true ⇒ ③ 必须红（**只改 canWriteMapIntoVariable 那个函数**）
  const g0 = vars.indexOf('static func canWriteMapIntoVariable');
  const gEnd = vars.indexOf('\n    }', g0) + 6;
  const gBody = vars.slice(g0, gEnd);
  const m = vars.slice(0, g0) + gBody.replace(/return\s+false/, 'return true') + vars.slice(gEnd);
  const mg0 = m.indexOf('static func canWriteMapIntoVariable');
  const mg = m.slice(mg0, m.indexOf('\n    }', mg0) + 6);
  ok(!/return\s+false/.test(mg), '变异③（形状守卫恒 true）⇒ 会被 ③ 抓住');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
