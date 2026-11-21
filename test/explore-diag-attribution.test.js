#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：explore 的「0 本」必须能【定责】**（2026-11-21 真机实证）
 *
 * ⚠️⚠️⚠️ **真机症状**：「「explore」结果不可信：书单 0 本」⇒ 用户问「书源问题还是引擎问题」⭐⭐⭐
 *   ⇒ 以前轻阅的判定只有「返回 0 本 ⇒ 不可信」⇒ **分不清**三种完全不同的原因 ⭐⭐⭐
 *     ① **站方真的没数据**（源站挂了 / 该分类为空 / 要令牌）⇒ **书源/站方侧** ⭐⭐⭐
 *     ② **站方有数据但规则没匹配上**（站方改版 ⇒ `ruleExplore.bookList` 过时）⇒ **书源侧** ⭐⭐⭐
 *     ③ **URL 错了**（分类 URL 没求值 / 参数错）⇒ **引擎/宿主侧** ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **本门禁钉死**：引擎在【同一次请求】里带回诊断 ⇒ 宿主把它回传 ⇒ UI 的提示带原因 ⭐⭐⭐
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

const api = strip(read('LegadoEngine/Sources/ChaiyueEngine/Compat/LegadoPublicAPI.swift'));
const host = strip(read('QiReaderLite/Core/LegadoEngineBackend.swift'));
const svc = strip(read('QiReaderLite/Core/SourceService.swift'));

console.log('=== 1. 引擎：explore 的诊断出口（一次请求 ⇒ 书单 + 诊断） ===');
ok(/public func exploreBookWithDiagnostics\(url: String, page: Int = 1\)/.test(api),
   '有 exploreBookWithDiagnostics');
ok(/diag\["状态码"\]/.test(api) && /diag\["响应字节"\]/.test(api), '诊断含状态码 + 响应字节');
ok(/diag\["判定"\]/.test(api), '★ 诊断含「判定」（站方没数据 / 规则未匹配 / 正常）');
ok(/diag\["规则是不是JS"\]/.test(api), '诊断含「规则是不是 JS」（区分 URL/规则形态）');
ok(/diag\["规则首段"\]/.test(api), '诊断含规则首段（便于核对规则是否过时）');
ok(/站方返回空内容（源站\/站方问题）/.test(api), '★ 判定文案：站方返回空 ⇒ 源站/站方问题');
ok(/站方有内容但规则未匹配（书源规则过时）/.test(api), '★ 判定文案：有内容但规则未匹配 ⇒ 书源规则过时');
ok(/BookListParser\.analyze/.test(api), '书单与诊断来自**同一次解析**（不是两次请求）');

console.log('\n=== 2. 宿主：explore op 用诊断版并回传 ===');
ok(/web\.exploreBookWithDiagnostics\(url: kindUrl, page: page\)/.test(host), 'explore op 用诊断版');
ok(/out\["__diag"\] = diag/.test(host), '★ 诊断回传给宿主（UI 用它说原因）');
ok(/engineLog\("\[explore\] 0 本/.test(host), '★ 0 本时把诊断写进引擎日志（用户能直接看到）');

console.log('\n=== 3. UI 提示：必须带原因（不是干巴巴一句「书单 0 本」） ===');
ok(/case "explore":/.test(svc) && /__diag/.test(svc), 'explore 的提示读 __diag');
ok(/站方返回 HTTP/.test(svc), '★ 非 2xx ⇒ 明说「站方接口问题」');
ok(/源站\/站方问题/.test(svc), '★ 空内容 ⇒ 明说「源站/站方问题」');
ok(/书源规则过时/.test(svc), '★ 有内容但没匹配 ⇒ 明说「书源规则过时」');

console.log('\n=== 5. ★ 筛选栏为 0 时必须能【分辨：站方没给 vs 适配层丢了】 ===');
{
  const adapter = strip(read('QiReaderLite/Core/ChaiyueKindsAdapter.swift'));
  ok(/byType\["select"\]/.test(host) && /byType\["toggle"\]/.test(host) && /byType\["button"\]/.test(host),
     '★ 统计柴阅原始 kinds 的 type 分布（select/toggle/button）');
  ok(/筛选项总数\(柴阅原始\)/.test(host), '诊断含「柴阅原始筛选项数」');
  ok(/柴阅没返回任何筛选项 ⇒ 站方（书源侧）没输出筛选栏/.test(host),
     '★ 判定文案：柴阅没给 ⇒ 书源侧');
  ok(/柴阅返回了筛选项，但适配层丢了 ⇒ 宿主\/引擎侧/.test(host),
     '★ 判定文案：柴阅给了但丢了 ⇒ 宿主/引擎侧');
  ok(/类型分布/.test(host), '诊断含类型分布（便于核对站方返回的形态）');

  // ⭐⭐⭐ **适配层的判定顺序**：必须【先看 type】再判组标题 ⭐⭐⭐
  //   ⇒ 否则「url 为空但 type=select」的筛选项会被当组标题扔掉 ⇒ 源就没有筛选栏了 ⭐⭐⭐
  const iGroup = adapter.indexOf('if url.isEmpty && (type == "url" || type.isEmpty)');
  const iFilter = adapter.indexOf('if type != "url"');
  ok(iGroup > 0 && iFilter > 0, '适配层有「组标题」与「筛选项」两处判定');
  ok(iGroup < iFilter, '★ 组标题判定在【筛选项判定之前】且带 type 条件（★ url 为空的 select 不会被扔）');
  ok(/url\.isEmpty && \(type == "url" \|\| type\.isEmpty\)/.test(adapter),
     '★ 组标题的判定**同时要求 type 是 url/空**（★ 否则会误吃筛选项）');
}

console.log('\n=== 6. 变异对照（改坏 ⇒ 必须红） ===');

{
  // ⚠️⚠️⚠️ **必须全局替换**（2026-11-22 实证）：自愈代码里**还有第二处调用** ⇒
  //   `String.replace` 只换第一处 ⇒ 变异无效 ⇒ 门禁没牙齿 ⭐⭐⭐
  const m1 = host.split('web.exploreBookWithDiagnostics(url: kindUrl, page: page)')
                  .join('web.exploreBook(url: kindUrl, page: page)');
  ok(!/exploreBookWithDiagnostics/.test(m1), '★ 变异①（不用诊断版）⇒ 被抓住');

  // ⚠️⚠️⚠️ **必须用 split/join 全局替换**（现在有**两处** `__diag` ⇒ `replace` 只换第一处 ⇒ 变异无效）⭐⭐⭐
  const m2 = host.split('out["__diag"] = diag').join('// 变异：不回传诊断');
  ok(!/out\["__diag"\] = diag/.test(m2), '★ 变异②（不回传诊断）⇒ 被抓住');

  const m3 = svc.replace(/站方返回 HTTP/, '某处');
  ok(!/站方返回 HTTP/.test(m3), '★ 变异③（提示不带原因）⇒ 被抓住');

  const m4 = api.replace('diag["判定"] = books.isEmpty', 'diag["判定"] = ""; let _ = books.isEmpty');
  ok(!/diag\["判定"\] = books\.isEmpty/.test(m4), '★ 变异④（诊断没有判定）⇒ 被抓住');

  // ⑤ 适配层：组标题判定去掉 type 条件 ⇒ 会把「url 为空的 select」误当组标题 ⇒ 源没有筛选栏 ⭐⭐⭐
  const adapter = strip(read('QiReaderLite/Core/ChaiyueKindsAdapter.swift'));
  const m5 = adapter.replace('if url.isEmpty && (type == "url" || type.isEmpty) {', 'if url.isEmpty {');
  ok(!/url\.isEmpty && \(type == "url"/.test(m5), '★ 变异⑤（组标题判定漏了 type 条件）⇒ 被抓住');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
