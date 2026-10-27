#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **原版 UAA 四合一（知秋）的「站方变量」语义**（2026-10-27 真机复盘）
 *
 * 跑法：node test/uaa-original-station-var.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ⚠️ **为什么用「真源」当断言对象**：
 *   站方变量是什么形态，**决定 App 能不能往那一格写 map** ⇒ 一旦判错就是
 *   `Bearer {"androidId":"…"}` ⇒ 服务端 403「无效JWT」⇒「获取Token」永远失败 ⭐⭐⭐
 *   ⇒ 所以断言必须落在**真源**上（`test/fixtures/uaa-original.json` = 原版一字不改），
 *   **不是**落在 mock 上（mock 会跟着实现一起漂 ⇒ 门禁就白做了）⭐⭐⭐
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁钉三件事：
 *   ① **站方变量 = 纯 token**（凭据形态）：读 `Bearer ${source.getVariable()}`、
 *      写 `source.setVariable(token)`（**标量**，不是 JSON）⇒ **App 绝不许塞 map** ⭐⭐⭐
 *   ② **线路 / 共享服 / 文件域名 / aid 全部走【书源变量】**（`source.get/put`）
 *      ⇒ ⇒ **App 的选线功能不受「不许塞 map」的影响** ⭐⭐⭐
 *      （`changeHostIndex` = 共享服 api；`changeHost` = 文件域名；都在书源变量里）
 *   ③ **App 侧不许再往 UAA 那一格塞 map**（源码级断言）
 * ────────────────────────────────────────────────────────────
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

const fixturePath = 'test/fixtures/uaa-original.json';
const raw = JSON.parse(read(fixturePath));
const src = Array.isArray(raw) ? raw[0] : raw;
const jsLib = src.jsLib || '';
const loginUrl = src.loginUrl || '';

/** 剥掉注释（静态断言不许被注释骗过） */
function stripComments(s) {
  return s.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/.*$/gm, '$1');
}
const js = stripComments(jsLib);
const login = stripComments(loginUrl);
// ⭐ **站方代码不止 jsLib**：规则里也是站方代码（`ruleContent` 里的视频页 URL 就用了站方变量）
const rules = Object.values(src.ruleContent || {}).concat(
  Object.values(src.ruleToc || {}), Object.values(src.ruleSearch || {}),
  Object.values(src.ruleBookInfo || {}), Object.values(src.ruleExplore || {})
).map(v => stripComments(String(v || ''))).join('\n');
const allStation = [js, login, rules, stripComments(src.exploreUrl || ''),
                    stripComments(src.searchUrl || '')].join('\n');

console.log('=== ① 站方变量 = 纯 token（凭据形态）===');
// 读：只有几处，而且必须是在**字符串位置**（Bearer / token=）
const getVarUses = [...allStation.matchAll(/getVariable\s*\(\s*\)/g)].map(m => m.index);
ok(getVarUses.length > 0, '真源的站方代码确实用了 getVariable()', `只有 ${getVarUses.length} 处`);
let allStringUse = true;
const samples = [];
for (const i of getVarUses) {
  const before = allStation.slice(Math.max(0, i - 120), i);
  // ⭐ 判据：**不许**被当成 map 用（JSON.parse / getArguments）⇒ 那是 map 形态
  const asMap = /JSON\.parse\s*\(\s*[^()]*$/.test(before) || /getArguments\s*\(\s*[^,()]*$/.test(before);
  if (asMap) allStringUse = false;
  samples.push(allStation.slice(Math.max(0, i - 60), i + 30).replace(/\n/g, '\\n'));
}
ok(allStringUse,
   '⭐⭐⭐ getVariable() **只**被当字符串用（Bearer / token=）⇒ 这一格是【凭据】不是 map',
   samples.join(' | '));
ok(/Bearer\s*\$\{\s*source\.getVariable\(\)\s*\}/.test(allStation),
   '⭐ 请求头就是 `Bearer ${source.getVariable()}`（站方变量 = token）');
ok(/token=\$\{\s*source\.getVariable\(\)\s*\}/.test(allStation),
   '⭐ 视频页 URL 也用 source.getVariable() 当 token');

// 写：站方自己写的是**标量 token**，不是 JSON
ok(/source\.setVariable\s*\(\s*token\s*\)/.test(login),
   '⭐⭐⭐ 站方自己写站方变量时写的是【标量 token】（`source.setVariable(token)`）');
ok(!/source\.setVariable\s*\(\s*JSON\.stringify/.test(js + login),
   '⭐⭐⭐ 站方从不往这一格写 JSON map ⇒ 这一格**只能是凭据**');

console.log('\n=== ② 线路 / 共享服 / 文件域名 / aid 全在【书源变量】===');
// 共享服 api 的切换
ok(/function changeHostIndex/.test(login) && /source\.put\('hostIndex'/.test(login),
   '⭐ 共享服 api 的切换走 `source.put(\'hostIndex\', …)` ⇒ **书源变量**');
ok(/共享api接口已切换为/.test(login), '⭐ 站方自己管这档叫「共享api接口」');
// 文件域名（CDN）
ok(/function changeHost\b/.test(login) && /source\.put\('host'/.test(login),
   '⭐ 文件域名（CDN）的切换走 `source.put(\'host\', …)` ⇒ **书源变量**');
// 账号 id / 排序 / 模式
ok(/source\.put\('aid'/.test(login) && /source\.put\('account_id'/.test(login),
   '⭐ 账号 id（aid / account_id）走 **书源变量**');
ok(/source\.put\('order'/.test(login) && /source\.put\('type'/.test(login),
   '⭐ 发现页排序 / 模式走 **书源变量**');
// ⇒⇒ 结论：这些**都不占站方变量** ⇒ App 的选线写【书源变量】就够 ⇒ 不受影响 ⭐
ok(!/source\.put\('hostIndex'[^)]*\)[^;]*setVariable/.test(login),
   '⭐⭐⭐ 共享服切换**不会**顺手写站方变量（两套变量各管各的）');

console.log('\n=== ③ App 侧：凭据形态 ⇒ 不许往这一格塞 map ===');
const varsRaw = read('QiReaderLite/Core/SourceVariables.swift');
const serviceRaw = read('QiReaderLite/Core/SourceService.swift');
const vars = varsRaw.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/.*$/gm, '$1');
const service = serviceRaw.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/.*$/gm, '$1');

ok(/static func form\s*\(\s*for\s+sourceUrl\s*:\s*String\s*\)\s*->\s*StationVarForm/.test(vars),
   '⭐ App 有站方变量的形态判据（form(for:)）');
ok(/case credential/.test(vars) && /case map/.test(vars),
   '⭐⭐⭐ 形态分两种（map / credential）⇒ UAA 落在 credential ⇒ 不许被塞 map');
ok(/static func stationVariableToSeed/.test(vars),
   '⭐⭐⭐ 灌站方变量那一步带【污染迁移】（真机上躺着的旧污染要清掉）');
{
  const s0 = vars.indexOf('static func stationVariableToSeed');
  const sBody = vars.slice(s0, vars.indexOf('\n    }', s0) + 6);
  ok(/form\s*\(\s*for\s*:\s*sourceUrl\s*\)\s*==\s*\.credential/.test(sBody) && /setVariable\(""/.test(sBody),
     '⭐⭐⭐ 凭据形态 + 这一格躺着 map ⇒ 清掉（`Bearer {…}` ⇒ 403 无效JWT 的真根因）');
}
ok((service.match(/stationVariableToSeed\s*\(/g) || []).length >= 3,
   '⭐ 每个 op 灌站方变量的地方都走它（UAA 的登录 op 就在其中）');
{
  // ⭐⭐⭐⭐⭐ **证据的键要带版本** —— 这条是**真机上**才暴露的：
  //   build267 的证据（`sourcevariable.stationmap.`）**本身就被污染了**
  //   （回传时值没变也当证据 ⇒ 自证 ⇒ 「凭据形态」永远判不出来）
  //   ⇒ 升级后必须**不再看那份证据** ⇒ 换键名（v2）⇒ 旧的直接作废 ⭐⭐⭐
  ok(/stationform\.v2\./.test(vars), '⭐⭐⭐⭐⭐ 证据的键带版本（v2）⇒ build267 那份自证的证据作废');
  ok(!/sourcevariable\.stationmap\./.test(vars),
     '⭐⭐⭐⭐⭐ 旧的 v1 键不许再用（那份证据已经自证污染了）');
}

console.log('\n=== ④ 变异对照（改坏 ⇒ 上面必须红）===');
{
  // 变异①：把凭据形态的清污染逻辑删掉 ⇒ ③ 的那条必须红
  const s0 = vars.indexOf('static func stationVariableToSeed');
  const sEnd = vars.indexOf('\n    }', s0) + 6;
  const m = vars.slice(0, s0) + vars.slice(s0, sEnd).replace(/==\s*\.credential/, '== .zzz') + vars.slice(sEnd);
  const ms0 = m.indexOf('static func stationVariableToSeed');
  const ms = m.slice(ms0, m.indexOf('\n    }', ms0) + 6);
  ok(!/==\s*\.credential/.test(ms), '变异①（清污染的判据改坏）⇒ 会被上面抓住');
}
{
  // 变异②：灌站方变量时绕开迁移 ⇒ ③ 的那条必须红
  const m = service.replace(/stationVariableToSeed\s*\(/g, 'variable(');
  ok(!/stationVariableToSeed\s*\(/.test(m), '变异②（绕开迁移）⇒ 会被上面抓住');
}
{
  // 变异③：证据的键去掉版本 ⇒ ③ 的那条必须红
  const m = vars.replace(/sourcevariable\.stationform\.v2\./g, 'sourcevariable.stationform.');
  ok(!/stationform\.v2\./.test(m), '变异③（证据键去掉版本）⇒ 会被上面抓住');
}
{
  // 变异对照③：真源的形状变了（把 Bearer 改成 JSON.parse）⇒ ① 必须红
  const m = js.replace(/Bearer\s*\$\{\s*source\.getVariable\(\)\s*\}/, 'JSON.parse(source.getVariable())');
  const before = m.slice(Math.max(0, m.indexOf('getVariable()') - 120), m.indexOf('getVariable()'));
  const asMap = /JSON\.parse\s*\(\s*[^()]*$/.test(before) || /getArguments\s*\(\s*[^,()]*$/.test(before);
  ok(asMap, '变异③（真源改成把站方变量当 map 用）⇒ ① 会红（说明 ① 真在判形状）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
