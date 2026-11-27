#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：老引擎的残留不许回来**（2026-11-26 · 用户「引擎侧是不是除了柴阅的引擎的，还有老的引擎代码，有的话全给我删了」）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **背景** ⭐⭐⭐：
 *   本仓库现在**只有柴阅（Chaiyue）一套引擎**。历史上还有两条，都已退役：
 *     ① **老 JS 引擎**（WKWebView + `Resources/engine/*.js`）⇒ 2026-10-25 物理删除 ⭐⭐⭐
 *     ② **自研 Swift 引擎**（从「六阅 LegadoR」二进制逆向重建，模块前缀 `LegadoR`）⇒ 已物理删除 ⭐⭐⭐
 *   ⇒ 但**遗留物**还在仓库里：
 *     · `LegadoEngine/Reference/` —— ② 的逆向产物（5 个 blob JS + `engine_api.txt` + `engine_properties.txt` + `node_bridge_test.js`）⭐⭐⭐
 *     · `LegadoEngine/README.md` —— 整份是 ② 的说明书（讲的目录/API/测试**全都不存在了**）⭐⭐⭐
 *   ⇒ 这两条门禁把「删干净」变成**可持续**的 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据（四条）**⭐⭐⭐⭐⭐：
 *   ① `LegadoEngine/Reference/` 目录**不许存在**（老引擎逆向产物）⭐⭐⭐
 *   ② `LegadoEngine/README.md` **不许提**老引擎的路径/API（`JSNatives` / `node_bridge_test` / `RuleTests` / `JSBridge` / `JSHost` / `RuleVariables` / `Sources/LegadoEngine/Models`…）⭐⭐⭐
 *   ③ **源码里不许出现** `LegadoR.` 前缀（老引擎模块前缀）⭐⭐⭐
 *   ④ `LegadoEngine/Sources/LegadoEngine/`（宿主门面模块，**同名但不是老引擎**）
 *      ⇒ 只许有门面那两个文件 ⇒ **老引擎代码不许混进这个同名目录** ⭐⭐⭐
 *
 * ⚠️⚠️ **别误伤**（2026-11-26 实证）⭐⭐⭐：
 *   · `QiReaderLite/Core/LegadoCompat.swift` —— 名字像老引擎，其实是**宿主给站方 JS 的原生能力**
 *     （`java.timeFormat` 等）⇒ **当前链路的一部分，必须留** ⭐⭐⭐
 *   · `QiReaderLite/Core/LegadoEngineProbe.swift` —— 名字像老引擎，其实是**柴阅的接入探针** ⭐⭐⭐
 *   · `Sources/LegadoEngine/`（模块名保留）—— **宿主门面**，宿主 App 全靠它 ⇒ 不能删 ⭐⭐⭐
 *   · `docs/` 下的历史交接文档 —— **历史记录，不改** ⇒ 门禁只扫 `LegadoEngine/` 与 `Sources/` ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENGINE = path.join(ROOT, 'LegadoEngine');
const SRC = path.join(ENGINE, 'Sources');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

console.log('\n── ① 老引擎的逆向产物目录不许存在 ──');
{
  const ref = path.join(ENGINE, 'Reference');
  ok(!fs.existsSync(ref),
     '① `LegadoEngine/Reference/` 不存在（老引擎 LegadoR 的逆向产物已删）',
     '它又出现了 ⇒ 里面是「六阅 LegadoR」的 blob JS / 接口清单');
}

console.log('\n── ② README 不得再讲老引擎 ──');
{
  const readme = fs.existsSync(path.join(ENGINE, 'README.md'))
    ? fs.readFileSync(path.join(ENGINE, 'README.md'), 'utf8') : '';
  ok(readme.length > 0, '② LegadoEngine/README.md 在');
  // ⚠️ **只禁「教人用不存在的东西」的 API/路径名** ⭐⭐⭐
  //   「六阅 / LegadoR 已物理删除」这种**历史说明**是允许的（甚至是必要的）⭐⭐⭐
  const legacyAPI = ['JSNatives', 'node_bridge_test', 'RuleTests.swift', 'JSBridge', 'JSHost',
                     'RuleVariables', 'Sources/LegadoEngine/Models', 'Sources/LegadoEngine/Core',
                     'Sources/LegadoEngine/JS', 'Sources/LegadoEngine/Net', 'Sources/LegadoEngine/Analyzers'];
  const hits = legacyAPI.filter(k => readme.includes(k));
  ok(hits.length === 0,
     '② README 不再教人用老引擎的 API/路径（那些东西早就不存在了 ⇒ 留着会误导人）',
     hits.join(' / '));
  ok(readme.includes('柴阅') || readme.includes('Chaiyue'),
     '② README 写的是柴阅（当前唯一的引擎）');
}

console.log('\n── ③ 源码里不许出现老引擎的模块前缀 ──');
{
  const files = [];
  const walk = (d) => {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (_) { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.swift')) files.push(p);
    }
  };
  walk(SRC);
  const hits = [];
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    if (/\bLegadoR\./.test(src)) hits.push(path.relative(ROOT, f));
  }
  ok(hits.length === 0, `③ 柴阅引擎源码里没有 \`LegadoR.\` 前缀（扫了 ${files.length} 个文件）`,
     hits.slice(0, 5).join(' / '));
}

console.log('\n── ④ 宿主门面模块里不许混进老引擎代码 ──');
{
  const facade = path.join(SRC, 'LegadoEngine');
  const files = fs.existsSync(facade) ? fs.readdirSync(facade).filter(n => n.endsWith('.swift')) : [];
  // ⭐⭐⭐⭐⭐ **改成【白名单】而不是【数个数】**（2026-11-27 修正）⭐⭐⭐⭐⭐
  //   原来写死「只剩 2 个文件」⇒ build333 加了 `ChaiyueBrowserOverlayBridge`、
  //   build334 加了 `ChaiyueLoginFormBridge` ⇒ 判据过时 ⇒ 门禁一直红（基线欠账）⭐⭐⭐
  //   ⇒ 白名单更严：**多一个没登记的文件就红**（谁把老引擎代码搬进来 ⇒ 必红）⭐⭐⭐
  const ALLOWED = [
    'LegadoEngineHost.swift',          // 宿主适配入口（typealias 门面）
    'ChaiyueKeyValueStore.swift',      // 柴阅的持久化后端接线
    'ChaiyueBrowserOverlayBridge.swift',// 段评浮层浏览器转发（build333）
    'ChaiyueLoginFormBridge.swift',    // 柴阅登录表单转发（build334）
  ];
  const extra = files.filter(f => !ALLOWED.includes(f));
  ok(extra.length === 0,
     '④ `Sources/LegadoEngine/` 只剩登记过的宿主门面文件（不许混进老引擎代码）',
     `多出：${extra.join(', ')}（现有 ${files.length} 个）`);
  const missing = ALLOWED.filter(f => !files.includes(f));
  ok(missing.length === 0,
     '④ 四个宿主门面文件都在（别名 / 持久化 / 浏览器转发 / 登录表单转发）',
     `缺：${missing.join(', ')}`);
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
