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
const service = stripComments(serviceRaw);
const vars = stripComments(varsRaw);

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
  ok(/guard\s+isMapStyle\s+else\s*\{/.test(body),
     '守卫①：isMapStyle 判据（非 map 形态 ⇒ 不写站方变量）');
  ok(/canWriteMapIntoVariable\s*\(/.test(body),
     '守卫②：canWriteMapIntoVariable( 形状守卫（凭据形态 ⇒ 不许被 map 覆盖）');
  ok(/setVars\s*\(/.test(body), '书源变量照样写（站方读 map 形态时用）');
}
const guardStart = vars.indexOf('static func canWriteMapIntoVariable');
ok(guardStart >= 0, 'SourceVariables 里有 canWriteMapIntoVariable(');
if (guardStart >= 0) {
  const g = vars.slice(guardStart, vars.indexOf('\n    }', guardStart) + 6);
  ok(/is\s+\[String:\s*Any\]/.test(g), '形状守卫认得「JSON map」');
  ok(/return\s+false/.test(g), '形状守卫对「非 JSON（一串凭据）」返回 false');
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
  // 变异③：形状守卫恒返回 true ⇒ ③ 必须红
  const m = vars.replace(/return\s+false/, 'return true');
  const g0 = m.indexOf('static func canWriteMapIntoVariable');
  const g = m.slice(g0, m.indexOf('\n    }', g0) + 6);
  ok(!/return\s+false/.test(g), '变异③（形状守卫恒 true）⇒ 会被 ③ 抓住');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
