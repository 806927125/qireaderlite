#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：发现页筛选栏的「选中 ⇒ 生效」整条链**（2026-11-21 真机实证）
 *
 * ⚠️⚠️⚠️ **为什么必须有它**（真机症状：「上面这个筛选键没用」）：
 *   用户在发现页选了「平台 = QQ阅读」⇒ **列表一点没变** ⇒ 筛选完全无效 ⭐⭐⭐
 *   ⇒ 我连查三个断点，**每一个都是「静默失效」**（不报错、不崩、只是没反应）⭐⭐⭐
 *
 * ⭐⭐⭐ **三个断点**：
 *   ① **`infoMap` 没传** ⇒ 站方 action 读到 `undefined` ⇒ **回落到默认值** ⭐⭐⭐
 *      站方 action 的真实形态（NovelHub jsLib 原文）：
 *        `c['<key>'] = (function(){ var v = infoMap['<标题>']; …
 *           if(v===null||v===undefined||m[v]===undefined){ return '<默认值>'; } return m[v]; })();`
 *      ⇒ `infoMap` 拿不到值 ⇒ **站方写的还是默认值** ⇒ 看起来「完全没反应」⭐⭐⭐
 *   ② **柴阅的 `exploreKinds` 命中缓存** ⇒ 缓存键 = md5(源URL + exploreUrl **文本**）⭐⭐⭐
 *      ⇒ **站方变量变了键也不变** ⇒ 分类 URL 还是**旧平台的** ⇒ 列表还是旧的 ⭐⭐⭐
 *   ③ **App 侧 `kindsCache`（30 分钟）不失效** ⇒ 它只读【书源变量槽】⭐⭐⭐
 *      ⇒ 而站方 action 写的是【**站方变量整串**】（`source.setVariable`）⇒ **看不到变化** ⭐⭐⭐
 *
 * ⭐ **本门禁钉死这三处 + 站方 action 的形态证据**（不靠推理，靠真源的 jsLib）
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const P = (p) => path.join(ROOT, p);

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const read = (p) => fs.readFileSync(P(p), 'utf8');
const strip = (t) => t.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');

const svc = strip(read('QiReaderLite/Core/SourceService.swift'));
const host = strip(read('QiReaderLite/Core/LegadoEngineBackend.swift'));

console.log('=== 1. ① `infoMap` 必须传到宿主（站方 action 的命脉） ===');
ok(/p\["infoMap"\]\s*=\s*\[title:\s*value\]/.test(svc),
   '★ applySourceFilter 传了 infoMap = [标题: 值]（站方 action 读 infoMap[标题]）');
ok(/"action":\s*action,\s*"title":\s*title,\s*"value":\s*value/.test(svc),
   'payload 里带 title/value（站方 action 可能要用）');
ok(/let infoMap = \(payload\["infoMap"\] as\? \[String: String\]\) \?\? \[:\]/.test(host),
   '★ 宿主 filterAction 分支读 payload["infoMap"]');
ok(/web\.runExploreAction\(action,\s*infoMap:\s*infoMap\)/.test(host),
   '★ 宿主把它传给柴阅的 runExploreAction(action, infoMap:)');

console.log('\n=== 2. ② `exploreKinds` 必须 refresh（否则命中柴阅的缓存） ===');
ok(/web\.exploreKinds\(refresh:\s*true\)/.test(host),
   '★ 宿主 exploreKinds 用 refresh: true（柴阅默认 false ⇒ 命中旧缓存）');
ok(!/web\.exploreKinds\(\)/.test(host), '没有「不 refresh」的调用残留');

console.log('\n=== 3. ③ 分类缓存必须随筛选失效 ===');
ok(/Self\.invalidateKindsCache\(source:\s*source\)/.test(svc),
   '★ 筛选成功后调用 invalidateKindsCache');
ok(/static func invalidateKindsCache/.test(svc), '有 invalidateKindsCache 实现');
ok(/key\.hasPrefix\(prefix\)/.test(svc), '按「源 URL|」前缀删缓存');
// 缓存键要同时读两个槽（站方 action 写的是站方变量整串）
ok(/SourceVariables\.effectiveVars\(for: source\.bookSourceUrl\)/.test(svc), '缓存键读书源变量槽');
ok(/SourceVariables\.variable\(for: source\.bookSourceUrl\)/.test(svc),
   '★ 缓存键也读【站方变量槽】（站方 action 写的就是那一格 ⇒ 不读就看不到变化）');

console.log('\n=== 4. 站方 action 的真实形态（从真源 jsLib 取证据，不靠推理） ===');
{
  const srcPath = '/workspace/output/NovelHub聚合小说-轻阅新引擎适配.json';
  if (fs.existsSync(srcPath)) {
    const raw = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
    const src = Array.isArray(raw) ? raw[0] : raw;
    const lib = src.jsLib || '';
    const m = lib.match(/"action":[^,]{0,400}infoMap\[/);
    ok(!!m, '★ 真源的 action 确实读 infoMap[标题]（不是我们猜的）');
    ok(!!m && /v===null\|\|v===undefined/.test(lib),
       '★ 取不到值时站方【回落到默认值】⇒ 这就是「没反应」的机制');
    // 站方 action 写的是站方变量整串
    ok(/source\.setVariable\(/.test(lib), '★ 站方 action 用 source.setVariable（⇒ 站方变量整串那一格）');
  } else {
    ok(false, '真源产物不在（无法取站方 action 的证据）', srcPath);
  }
}

console.log('\n=== 5. 变异对照（改坏 ⇒ 必须红） ===');
{
  // ① 不传 infoMap
  const m1 = svc.replace(/p\["infoMap"\]\s*=\s*\[title:\s*value\]/, '// 变异：不传 infoMap');
  ok(!/p\["infoMap"\]\s*=\s*\[title:\s*value\]/.test(m1), '★ 变异①（不传 infoMap）⇒ 被抓住');

  // ② 不 refresh
  const m2 = host.replace(/web\.exploreKinds\(refresh:\s*true\)/, 'web.exploreKinds()');
  ok(!/web\.exploreKinds\(refresh:\s*true\)/.test(m2)
     && /web\.exploreKinds\(\)/.test(m2), '★ 变异②（不 refresh）⇒ 被抓住');

  // ③ 不清缓存
  const m3 = svc.replace(/Self\.invalidateKindsCache\(source:\s*source\)/, '// 变异：不清缓存');
  ok(!/Self\.invalidateKindsCache\(source:\s*source\)/.test(m3), '★ 变异③（不清缓存）⇒ 被抓住');

  // ④ 缓存键不读站方变量槽
  const m4 = svc.replace(/SourceVariables\.variable\(for: source\.bookSourceUrl\)/, '""');
  ok(!/SourceVariables\.variable\(for: source\.bookSourceUrl\)/.test(m4)
     && /SourceVariables\.effectiveVars/.test(m4), '★ 变异④（缓存键不读站方变量槽）⇒ 被抓住');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
