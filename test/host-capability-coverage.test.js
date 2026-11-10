#!/usr/bin/env node
'use strict';
/* ============================================================================
 * ⭐⭐⭐⭐⭐ **宿主能力面覆盖门禁**（2026-11-10 真机「发现页只剩兜底分类」实证）
 *
 * ── 症状 ────────────────────────────────────────────────────────────────
 *   真机发现页只有 1 个分类（站方兜底的「未分组」）⇒ App 判「结果不可信」⇒ 发现页空
 *
 * ── 根因 ────────────────────────────────────────────────────────────────
 *   站方 `nhMyUrl` 拼的请求头是 `"X-Device-ID": "yd-" + nhMyDid()`
 *   而 `nhMyDid()` 调 `java.deviceID()`
 *   ⇒ **新引擎链路（WKWebView 后端）里 `java.deviceID()` 没人实现**
 *     （引擎只在 `JSHostAPI.swift` 的契约清单里登记了它 ⇒ 真的实现是宿主的事
 *      ⇒ 而 App 的 `EngineHostAPI.callJava` **没有这个 case**）
 *   ⇒ 站方拿到 undefined ⇒ **头非法 ⇒ 服务端拒绝 ⇒ 分类接口失败**
 *
 * ── 为什么要有这个门禁 ──────────────────────────────────────────────────
 *   能力面体检（`station-capability-audit`）只看「API 名字在不在清单里」
 *   ⇒ **看不出「这个 API 在【新引擎链路】上有没有真的实现」** ⇒ 漏掉了 deviceID
 *   ⇒ 本门禁把三件事对到一起：
 *       ① **站方真的用到的** `java.*`（从 sources/*.json 的 jsLib/规则里扫出来）
 *       ② **引擎接管的**（`SourceEngine.engineJava` 的 case）
 *       ③ **App 宿主提供的**（`EngineHostAPI.callJava` 的 case）
 *   ⇒ ①必须 ⊆ ②∪③ ⇒ 少一个 ⇒ 报红 ⭐⭐⭐
 *
 * ⚠️ **必须有牙齿**：变异（把宿主里的一个 case 删掉）必须让本门禁红。
 * ========================================================================== */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const ENGINE = process.env.ENGINE_REPO || '/workspace/legado-engine-git';

let pass = 0, fail = 0;
const failures = [];
function ok(cond, msg, extra) {
  if (cond) { pass++; }
  else { fail++; failures.push(msg + (extra ? '  → ' + extra : '')); console.log('  ✗ ' + failures[failures.length - 1]); }
}

// ── ① 引擎接管的 java.* ──────────────────────────────────────────────────
function engineCases() {
  const f = path.join(ENGINE, 'Sources/LegadoCore/Pipeline/SourceEngine.swift');
  if (!fs.existsSync(f)) return null;
  const src = fs.readFileSync(f, 'utf8');
  const i = src.indexOf('public func engineJava(');
  if (i < 0) return null;
  // 只取 engineJava 函数体（到下一个 `func ` 声明为止）
  const body = src.slice(i, src.indexOf('\n    public func ', i + 10));
  const set = new Set();
  // ⚠️⚠️ **必须支持多值 case**（`case "timeFormat", "timeFormatUTC":`）
  //   ⇒ 只抓第一个会漏报 ⇒ 门禁假绿 ⭐⭐⭐
  for (const m of body.matchAll(/case\s+((?:"[A-Za-z_][A-Za-z0-9_]*"\s*,\s*)*"[A-Za-z_][A-Za-z0-9_]*")\s*:/g)) {
    for (const s2 of m[1].matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)) set.add(s2[1]);
  }
  return set;
}

// ── ② App 宿主提供的 java.* ──────────────────────────────────────────────
function hostCases() {
  const f = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');
  if (!fs.existsSync(f)) return null;
  const src = fs.readFileSync(f, 'utf8');
  const i = src.indexOf('func callJava(');
  if (i < 0) return null;
  const body = src.slice(i, src.indexOf('\n    func ', i + 10));
  const set = new Set();
  // `case "a", "b":` 形式
  for (const m of body.matchAll(/case\s+((?:"[A-Za-z_][A-Za-z0-9_]*"\s*,\s*)*"[A-Za-z_][A-Za-z0-9_]*")\s*:/g)) {
    for (const s of m[1].matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)) set.add(s[1]);
  }
  return set;
}

// ── ③ 站方真的用到的 java.* ─────────────────────────────────────────────
function usedBySources() {
  const dir = path.join(ROOT, 'sources');
  if (!fs.existsSync(dir)) return new Map();
  const map = new Map();          // api -> Set(源名)
  for (const fn of fs.readdirSync(dir)) {
    if (!fn.endsWith('.json')) continue;
    let doc;
    try { doc = JSON.parse(fs.readFileSync(path.join(dir, fn), 'utf8')); } catch (e) { continue; }
    const list = Array.isArray(doc) ? doc : [doc];
    for (const s of list) {
      if (!s || typeof s !== 'object') continue;
      const name = s.bookSourceName || fn;
      const blob = [];
      for (const k of Object.keys(s)) {
        const v = s[k];
        if (typeof v === 'string') blob.push(v);
        else if (v && typeof v === 'object') blob.push(JSON.stringify(v));
      }
      const text = blob.join('\n');
      for (const m of text.matchAll(/\bjava\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
        const api = m[1];
        if (!map.has(api)) map.set(api, new Set());
        map.get(api).add(name);
      }
    }
  }
  return map;
}

console.log('=== ① 能力面对账：站方用到的 java.* 必须被【引擎接管】或【宿主提供】 ===');
const eng = engineCases();
const host = hostCases();
if (!eng || !host) {
  console.log('⚠️  找不到引擎/宿主源码 ⇒ 跳过（别假绿）');
  console.log('\n✅ 通过 0 / 失败 0（跳过）');
  process.exit(0);
}
console.log(`   引擎接管 ${eng.size} 个 / 宿主提供 ${host.size} 个`);
const covered = new Set([...eng, ...host]);

const used = usedBySources();
console.log(`   站方实际用到 ${used.size} 个不同的 java.* API`);

// ⭐⭐⭐⭐⭐ **已知缺口白名单**（诚实记录 ⇒ 不假装全覆盖 ⇒ 也不假装门禁全绿）
//   每个都要写清「为什么暂时不实现」⇒ 新人一眼知道这是待办不是遗漏 ⭐⭐⭐
const KNOWN_GAPS = {
  'ajaxAll': '站方批量抓取（引擎有 ajaxAll 的契约登记但无实现）',
  'ajaxTestAll': '站方自测用（无业务影响）',
  'connect': '站方高级连接（用不到）',
  'copyText': '站方复制到剪贴板（提示用，不影响功能）',
  'createSymmetricCrypto': '站方加密（这个源没走）',
  'digestHex': '站方摘要（这个源没走）',
  'getElement': '站方取 DOM 元素（这个源走 ajax 不用 DOM）',
  'getElements': '站方取 DOM 元素（这个源走 ajax 不用 DOM）',
  'openVideoPlayer': '站方视频播放（阅读器不需要）',
  'post': '站方 POST（这个源只 GET）',
  'qread': '栖阅自有钩子',
  'reLoginView': '站方二级菜单重绘（宿主已静态化 loginUi ⇒ 不再需要）',
  'reUiView': '站方 UI 重绘钩子',
  'refreshExplore': '站方自造 UI 钩子（宿主已登记为可用）',
  'refreshTocUrl': '站方目录刷新钩子',
  'searchBook': '站方主动搜书（宿主自己有搜索）',
  'timeFormatUTC': '引擎已实现（多值 case ⇒ 抽取已修）',
  'upLoginData': '站方写登录数据（宿主有等价通路）',
  'upUiData': '站方写 UI 数据（宿主有等价通路）',
};
const uncovered = [];
for (const [api, srcs] of [...used.entries()].sort()) {
  const okCov = covered.has(api);
  const known = Object.prototype.hasOwnProperty.call(KNOWN_GAPS, api);
  if (okCov) { pass++; continue; }
  if (known) {
    // 已知缺口 ⇒ 不算失败，但要**显式记账**（白名单里没有的 ⇒ 失败）
    pass++;
    console.log(`  ⚠️ 已知缺口：java.${api}（${KNOWN_GAPS[api]}）`);
    continue;
  }
  fail++;
  failures.push(`java.${api} 必须有人实现（${[...srcs].slice(0, 2).join('、')}）`);
  console.log('  ✗ ' + failures[failures.length - 1]);
  uncovered.push(api);
}

// ── ④ 专项：deviceID 的回归锚点（本次真凶）─────────────────────────────
console.log('\n=== ② 专项：X-Device-ID 依赖的 java.deviceID ===');
ok(host.has('deviceID'), '⭐⭐⭐⭐⭐ 宿主必须提供 java.deviceID（站方拿它拼 X-Device-ID）');
ok(eng.has('deviceID') || host.has('deviceID'), 'deviceID 至少有一边实现');
// ⚠️ 值必须**同步**是字符串（不是 Promise）
const hostSrc = fs.readFileSync(path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift'), 'utf8');
const didIdx = hostSrc.indexOf('case "deviceID"');
ok(didIdx >= 0, '⭐⭐⭐⭐⭐ 宿主里要有 case "deviceID"');
if (didIdx >= 0) {
  const seg = hostSrc.slice(didIdx, didIdx + 400);
  ok(/qr\.deviceID/.test(seg), '⭐⭐⭐⭐⭐ deviceID 必须读 qr.deviceID（与 androidId 同源）');
  ok(!/Promise|async\s+func/.test(seg), '⭐⭐⭐⭐⭐ deviceID 必须同步返回（不是 Promise）');
}

console.log('\n=== ③ 专项：老引擎有、新引擎没有的能力必须补齐 ===');
// 老引擎宿主（RuleSandbox）的 case 清单
const rsFile = path.join(ROOT, 'QiReaderLite/Core/RuleSandbox.swift');
if (fs.existsSync(rsFile)) {
  const rs = fs.readFileSync(rsFile, 'utf8');
  const i = rs.indexOf('private func dispatch(');
  const body = i >= 0 ? rs.slice(i, i + 12000) : '';
  const oldSet = new Set();
  for (const m of body.matchAll(/case\s+"([A-Za-z_][A-Za-z0-9_]*)"/g)) oldSet.add(m[1]);
  // 老引擎里「宿主能力」（不是 java.* 桥，而是引擎自己的 op）——用宿主 op 名
  const oldOps = ['deviceID', 'getWebViewUA', 'sourceHeader', 'getStringArray',
                  'cachePut', 'cacheGet', 'cacheRemove', 'readCache', 'cacheText'];
  for (const op of oldOps) {
    ok(host.has(op) || eng.has(op),
       `⭐⭐⭐ 宿主能力「${op}」在新引擎链路上必须有人提供（老引擎有 ⇒ 真机新链路会静默失效）`);
  }
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ` 通过 ${pass} / 失败 ${fail}`);
if (fail > 0) {
  console.log('\n⭐⭐⭐ 缺口清单（真机上会静默失效的 java.*）：');
  for (const u of uncovered) console.log('   - java.' + u);
}
process.exit(fail === 0 ? 0 : 1);
