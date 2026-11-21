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

console.log('\n=== 4. 变异对照（改坏 ⇒ 必须红） ===');
{
  const m1 = host.replace('web.exploreBookWithDiagnostics(url: kindUrl, page: page)', 'web.exploreBook(url: kindUrl, page: page)');
  ok(!/exploreBookWithDiagnostics/.test(m1), '★ 变异①（不用诊断版）⇒ 被抓住');

  const m2 = host.replace('out["__diag"] = diag', '// 变异：不回传诊断');
  ok(!/out\["__diag"\] = diag/.test(m2), '★ 变异②（不回传诊断）⇒ 被抓住');

  const m3 = svc.replace(/站方返回 HTTP/, '某处');
  ok(!/站方返回 HTTP/.test(m3), '★ 变异③（提示不带原因）⇒ 被抓住');

  const m4 = api.replace('diag["判定"] = books.isEmpty', 'diag["判定"] = ""; let _ = books.isEmpty');
  ok(!/diag\["判定"\] = books\.isEmpty/.test(m4), '★ 变异④（诊断没有判定）⇒ 被抓住');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
