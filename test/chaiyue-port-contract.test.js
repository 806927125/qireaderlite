#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：柴阅引擎移植契约**（2026-11-21）
 *
 * ⚠️⚠️⚠️ **为什么要有它**：移植不是「换个引擎包」，而是**换了一整套语义** ⭐⭐⭐
 *   ① 站方变量 = **两套**（站方整串 `sourceVariable_` / 书源变量每 k 一项 `v_`）⭐⭐⭐
 *   ② 状态**由引擎自己持久化**（`KeyValueStore`）⇒ 宿主**不再回传**变量 ⭐⭐⭐
 *   ③ 宿主每条主链走柴阅的 **`WebBook`**（不再自建 JS bridge、不再自己 eval `@js:`）⭐⭐⭐
 *   ④ 柴阅的键与轻阅的槽**结构不同** ⇒ 必须有一层映射 ⭐⭐⭐
 *   ⇒ 这四条**每一条都会悄悄回退**（症状是「发现页 0 分类」）⇒ 必须钉死 ⭐⭐⭐
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

const pkg = read('LegadoEngine/Package.swift');
const host = strip(read('QiReaderLite/Core/LegadoEngineBackend.swift'));
const runtime = strip(read('QiReaderLite/Core/ChaiyueRuntime.swift'));
const adapter = strip(read('QiReaderLite/Core/ChaiyueKindsAdapter.swift'));
const mapping = strip(read('LegadoEngine/Sources/ChaiyueEngine/Compat/ChaiyueStoreMapping.swift'));
const state = strip(read('LegadoEngine/Sources/ChaiyueEngine/Engine/RuleSession.swift'));
const pbx = read('QiReaderLite.xcodeproj/project.pbxproj');

console.log('=== 1. 包结构：引擎 = 柴阅源码 + 适配层 ===');
ok(/name:\s*"LegadoEngine"/.test(pkg), '包名仍是 LegadoEngine（⇒ 宿主 import 不变）');
ok(/\.target\(\s*name:\s*"ChaiyueModels"/.test(pkg), '有 ChaiyueModels target（柴阅的模型层）');
ok(/\.target\(\s*name:\s*"ChaiyueEngine"/.test(pkg), '有 ChaiyueEngine target（柴阅的引擎层）');
ok(/name:\s*"ChaiyueModels",\s*path:\s*"Sources\/ChaiyueModels"/.test(pkg), 'ChaiyueModels 路径对');
ok(/name:\s*"ChaiyueEngine",[\s\S]{0,400}path:\s*"Sources\/ChaiyueEngine"/.test(pkg), 'ChaiyueEngine 路径对');
ok(/SwiftSoup/.test(pkg) && /Kanna/.test(pkg), '依赖 SwiftSoup + Kanna（真 XPath）');
ok(/Sextant/.test(pkg), '★ 依赖 Sextant（柴阅的过滤表达式 ⇒ 比纯正则强）');
ok(fs.existsSync(P('LegadoEngine/Sources/ChaiyueEngine/Engine/WebBook.swift')), '柴阅的 WebBook 在位（引擎门面）');
ok(fs.existsSync(P('LegadoEngine/Sources/ChaiyueEngine/JS/JSRuntime.swift')), '柴阅的 JSRuntime 在位（JS 运行时）');
ok(/XCLocalSwiftPackageReference "LegadoEngine"/.test(pbx), 'pbxproj 里是**本地包** LegadoEngine');
ok(!/legado-engine/.test(pbx), 'pbxproj 里不再有远程 legado-engine 依赖');

console.log('\n=== 2. 柴阅的【两套语义】（权威规格 ⇒ 不可改） ===');
ok(/cache\.get\("sourceVariable_\\\(key\)"\)/.test(state) || /"sourceVariable_\\\("sourceVariable_/.test(state),
   '★ 站方变量 = 整串（键 `sourceVariable_<key>`）');
ok(/func put\(_ k: String, _ value: String\)/.test(state) && /v_\\\(key\)/.test(state),
   '★ 书源变量 = 每 k 一项（键 `v_<key>_<k>`）');
ok(/func get\(_ k: String\)/.test(state), '书源变量有 get(k)');
ok(!/getVariable\(key: String\)[^{]*\{\s*sourceVars\[key\]/.test(state),
   '★ 柴阅没有「两格合并」的错位实现（我们 build302 修的就是那个）');

console.log('\n=== 3. 宿主接线：走柴阅的 WebBook，不再自建 bridge ===');
ok(/LegadoEngineHost\.WebBook\(source: parsed, environment: env\)/.test(host), '主链用 `LegadoEngineHost.WebBook`');
ok(/web\.searchBook\(/.test(host), 'search → web.searchBook');
ok(/web\.exploreKinds\(refresh:\s*true\)/.test(host), '★ exploreKinds → web.exploreKinds(refresh: true)（柴阅原生求值 `@js:`）');
ok(!/web\.exploreKinds\(\)/.test(host), '★ 没有「不 refresh」的调用（★ 默认 false ⇒ 命中旧缓存 ⇒ 筛选无效）');
ok(/web\.exploreBook\(/.test(host), 'explore → web.exploreBook');
ok(/web\.getBookInfo\(/.test(host), 'bookInfo → web.getBookInfo');
ok(/web\.getChapterList\(/.test(host), 'toc → web.getChapterList');
ok(/web\.getContent\(/.test(host), 'content → web.getContent');
ok(/web\.runExploreAction\(/.test(host), 'filterAction → web.runExploreAction');
ok(/web\.runLoginAction\(/.test(host), 'login → web.runLoginAction');
ok(!/LegadoEngineHost\.Bridge\(/.test(host), '★ 不再自建 JS bridge（⇒ 少一层语义风险）');
ok(!/__sourceVars/.test(host) && !/__sourceVariable/.test(host),
   '★ 不再回传站方变量（⇒ 柴阅自己持久化 ⇒ 宿主不再有「回传错格」的机会）');

console.log('\n=== 4. 输出契约（UI 不改 ⇒ 键名一字不改） ===');
for (const k of ['"books"', '"total"', '"nextUrl"', '"book"', '"chapters"', '"rawCount"', '"bookName"', '"content"']) {
  ok(host.includes(k), `返回契约含 ${k}`);
}
ok(/"lastChapter": b\.latestChapterTitle/.test(host), 'lastChapter 取柴阅的 latestChapterTitle（★ 键名不变、取值换源）');
ok(/"updateTime": String\(b\.time\)/.test(host), 'updateTime 取柴阅的 time');
ok(/item\["updateTime"\] = ""/.test(host), '章节的 updateTime 输出空串（柴阅无此字段 ⇒ 不假装有）');

console.log('\n=== 5. 存储映射：柴阅的键 ⇒ 轻阅的槽 ===');
ok(/sourceVarPrefix = "v_"/.test(mapping), '映射表认得书源变量前缀 `v_`');
ok(/stationVariablePrefix = "sourceVariable_"/.test(mapping), '映射表认得站方变量前缀 `sourceVariable_`');
ok(/loginInfoPrefix = "userInfo_"/.test(mapping), '映射表认得登录信息前缀 `userInfo_`');
ok(/deviceIDKey = "__deviceID"/.test(mapping), '映射表认得设备 ID 键（无 cache_ 前缀）');
ok(/case \.stationVariable\(let sourceKey\)/.test(runtime) && /SourceVariables\.variable\(for: sourceKey\)/.test(runtime),
   '站方变量 ⇒ 轻阅的整串槽');
ok(/case \.sourceVar\(let sourceKey, let name\)/.test(runtime) && /SourceVariables\.varsMap\(for: sourceKey\)\[name\]/.test(runtime),
   '★ 书源变量 ⇒ 轻阅 map 的**单项**（不是整串）');
ok(/SourceVariables\.setSourceVarItem\(name, value \?\? ""/.test(runtime),
   '★ 写书源变量只改**一项**（保留其它项 ⇒ 线路表等不丢）');
ok(/loginInfoToChaiyue/.test(runtime) && /loginInfoFromChaiyue/.test(runtime),
   '★ loginInfo 双向转换（柴阅存密文、UI 要明文 ⇒ 必须能互转）');
ok(/listAllSourceVars/.test(runtime) && /allSourceUrls\(\)/.test(runtime),
   '★ 全量枚举书源变量（不从前缀反推源 URL ⇒ 无歧义）');

console.log('\n=== 6. kinds/filters 适配（轻阅 UI 的 DTO） ===');
ok(/ChaiyueKindsAdapter\.normalize\(kinds\)/.test(host), '宿主用 ChaiyueKindsAdapter 归一化');
ok(/ExploreKindsNormalizer\.filterParamKey/.test(adapter), '★ paramKey 复用旧归一化器（已验证过的抽取逻辑）');
ok(/"paramKey"/.test(adapter) && /"chars"/.test(adapter) && /"default"/.test(adapter), 'filter 的键齐（chars/default/paramKey/action）');
ok(/"group"/.test(adapter), 'kind 的键齐（含 group）');

console.log('\n=== 7. 变异对照（改坏 ⇒ 必须红） ===');
{
  const cases = [
    ['宿主不再用 WebBook（改回自建 bridge）',
      () => host.replace('LegadoEngineHost.WebBook(source: parsed, environment: env)', 'LegadoEngineHost.Bridge(source: parsed, environment: env)')],
    ['exploreKinds 不走柴阅（改回静态解析）',
      () => host.replace('web.exploreKinds(refresh: true)', 'LegadoEngineHost.Source.parse("{}")')],
    ['exploreKinds 不 refresh（★ 命中柴阅旧缓存 ⇒ 筛选无效）',
      () => host.replace('web.exploreKinds(refresh: true)', 'web.exploreKinds()')],
    ['宿主又开始回传站方变量（旧坑回归）',
      () => host.replace('return ["books": items, "total": books.count, "nextUrl": ""]',
                         'out["__sourceVars"] = "{}"\n            return ["books": items, "total": books.count, "nextUrl": ""]')],
    ['书源变量写回时整份覆盖（丢掉其它项）',
      () => runtime.replace('SourceVariables.setSourceVarItem(name, value ?? "", for: sourceKey)', 'SourceVariables.setVars("{}", for: sourceKey)')],
    ['站方变量与书源变量混成一格（build302 的老 bug）',
      () => mapping.replace('if name.hasPrefix(stationVariablePrefix) {',
                             'if name.hasPrefix(stationVariablePrefix) || name.hasPrefix(sourceVarPrefix) {')],
    ['loginInfo 不再转换（柴阅的密文直接进明文槽）',
      () => runtime.replace('loginInfoToChaiyue: { plain in loginInfoToChaiyue(plain) }', 'loginInfoToChaiyue: { plain in plain }')],
  ];
  for (const [name, fn] of cases) {
    const mutated = fn();
    ok(mutated !== host && mutated !== runtime && mutated !== mapping,
       `变异「${name}」：锚点命中`);
  }
  // 真·判定：把关键断言拿出来，逐条验证变异会破坏其中一条
  const asserts = [
    (t) => /LegadoEngineHost\.WebBook\(source: parsed, environment: env\)/.test(t),
    (t) => /web\.exploreKinds\(refresh:\s*true\)/.test(t),
    (t) => !/__sourceVars/.test(t),
  ];
  const m1 = host.replace('LegadoEngineHost.WebBook(source: parsed, environment: env)', 'X');
  const m2 = host.replace('web.exploreKinds(refresh: true)', 'Y');
  const m3 = host + '\nout["__sourceVars"] = "{}"';
  ok(asserts[0](m1) === false, '★ 变异「不用 WebBook」⇒ 被抓住');
  ok(asserts[1](m2) === false, '★ 变异「exploreKinds 不走柴阅」⇒ 被抓住');
  const m4 = host.replace('web.exploreKinds(refresh: true)', 'web.exploreKinds()');
  ok(!/web\.exploreKinds\(refresh:\s*true\)/.test(m4) && /web\.exploreKinds\(\)/.test(m4),
     '★ 变异「不 refresh」⇒ 被抓住');
  ok(asserts[2](m3) === false, '★ 变异「又开始回传变量」⇒ 被抓住');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
