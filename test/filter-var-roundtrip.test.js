#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：筛选变量的【写入 ⇒ 站方读回】必须真跑**（2026-11-21 真机「筛选键没用」二次实证）
 *
 * ⚠️⚠️⚠️ **为什么这一条要「真跑」而不是静态断言**：
 *   这一轮我连修两次都没生效（第一次只补了 `infoMap`，但 UI 走的是**另一条路**）⭐⭐⭐
 *   ⇒ 教训：**光断言「代码里写了某个键」不够** ⇒ 必须**把整条「写入 → 站方读回」真跑一遍** ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **站方的真实读法**（真 NovelHub 源 jsLib 原文）：
 *   var NH_D = {"src":"全部","gender":"全部","status":"不限","sort":"最热","line":"自动"};
 *   var _raw = String(source.getVariable() || "").trim();
 *   if (_raw !== "") { var _o = JSON.parse(_raw); ... NH_D = _o; }
 *   ⇒ 站方读的是【**站方变量整串**】里的 **src** ⭐⭐⭐
 *   ⇒ 而轻阅抠出来的 paramKey 是 **find_source** ⇒ **键名对不上** ⇒ 站方根本不读 ⭐⭐⭐
 *
 * ⭐⭐⭐ **站方的约定**（真源 jsLib 原文）：
 *   c['src']=v; c['find_source']=String(v); c['find_tab']='小说';
 *   ⇒ **src 与 find_source 是同一个平台值的两个键名** ⭐⭐⭐
 *
 * ⭐ **真跑方式**：`swiftc` 编 **App 的真文件**（`QiReaderLite/Core/SourceVariables.swift`）
 *   + `test/filter-var-roundtrip.swift` ⇒ **App 与门禁同源** ⇒ 门禁变红 ⇒ App 一定有问题 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

// ── 找 swiftc（与 run-swift-tests.sh **同一份逻辑** ⇒ 单一真相）──────────────
// ⚠️⚠️⚠️ **沙盒会把 /tmp 清掉** ⇒ 工具链要放 workspace 的常驻位置 ⇒ 用软链接回 /tmp ⭐⭐⭐
//   （与 test/run-swift-tests.sh 的探测顺序完全一致 ⇒ 别分叉）⭐⭐⭐
let SWIFTC = '';
for (const c of [
  '/tmp/swift/usr/bin/swiftc',
  '/workspace/.toolchain/swift/usr/bin/swiftc',
  '/workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc',
  require('child_process').execSync('command -v swiftc || true', { encoding: 'utf8' }).trim(),
]) {
  if (c && fs.existsSync(c) && fs.statSync(c).isFile()) { SWIFTC = c; break; }
}
// 找到 workspace 里的但 /tmp/swift 不存在 ⇒ 建软链（否则动态链接的 libswiftCore 找不到）
if (SWIFTC && !fs.existsSync('/tmp/swift/usr/bin/swiftc')) {
  try {
    fs.mkdirSync('/tmp', { recursive: true });
    fs.symlinkSync(path.dirname(path.dirname(SWIFTC)), '/tmp/swift');
  } catch (e) {}
}
if (SWIFTC) {
  const libDir = path.join(path.dirname(path.dirname(SWIFTC)), 'usr/lib/swift/linux');
  if (fs.existsSync(libDir)) {
    process.env.LD_LIBRARY_PATH = libDir + ':' + (process.env.LD_LIBRARY_PATH || '');
  }
}
if (!SWIFTC) {
  console.log('⚠️ 没找到 swiftc ⇒ 跳过（沙盒无 Swift 工具链）');
  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail === 0 ? 0 : 1);
}

const SV = path.join(ROOT, 'QiReaderLite/Core/SourceVariables.swift');
const SWIFT_TEST = path.join(ROOT, 'test/filter-var-roundtrip.swift');

function runSwift() {
  const TMP = fs.mkdtempSync('/tmp/fvrt-');
  try {
    const main = path.join(TMP, 'main.swift');
    fs.copyFileSync(SWIFT_TEST, main);
    // ⚠️⚠️ **要带上依赖文件**（`SourceVariables.swift` 引用 `StationVarForm` / `engineLog`）⭐⭐⭐
    const FORM = path.join(ROOT, 'QiReaderLite/Core/StationVarForm.swift');
    const NORM = path.join(ROOT, 'QiReaderLite/Core/ExploreKindsNormalizer.swift');   // filterAssignedKeys ⭐
    const LOG = path.join(ROOT, 'QiReaderLite/Core/EngineLog.swift');   // 纯 Foundation 的日志出口 ⭐
    const bin = path.join(TMP, 'fvrt');
    // ⚠️⚠️⚠️ **必须【编译 + 真跑】**（2026-11-21 实证：只编译不跑 ⇒ 输出为空 ⇒ 门禁假红）⭐⭐⭐
    execFileSync(SWIFTC, ['-O', main, SV, FORM, LOG, NORM, '-o', bin],
                 { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return execFileSync(bin, [], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } finally {
    try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (e) {}
  }
}

console.log('=== 1. 真跑：轻阅写入 ⇒ 站方读回（App 与门禁同源）===');
let out = '';
let failed = false;
try {
  out = runSwift();
} catch (e) {
  failed = true;
  out = (e.stdout || '') + (e.stderr || '');
}
if (!failed && out.includes('OK')) {
  ok(out.includes('SCENARIO1 OK'), '★ 场景1（🍒NovelHub：键名从 action 解析出 src）真跑通过');
  ok(out.includes('SCENARIO2 OK'), '★ 场景2（🍅大灰狼：键名退回 paramKey find_source）真跑通过');
  ok(/RAW1=.*"gender":"男频"/.test(out), '★ 站方的 gender 没被冲掉（增量合并生效）');
  ok(/RAW1=.*"status":"连载中"/.test(out), '★ 站方的 status 没被冲掉');
  ok(/RAW1=.*"src":"QQ阅读"/.test(out), '★ 站方变量里的 src = 新平台');
  ok(/RAW2=.*"find_source":"QQ阅读"/.test(out), '★ 大灰狼形态：站方读到的 find_source = 新值');
  ok(/RAW2=.*"gender":"男频"/.test(out), '★ 大灰狼形态：站方的 gender 也没被冲掉');
  ok(/SCENARIO1 keys=\["src",\s*"find_source"\]/.test(out),
     '★ 键名解析：含 src 与 find_source、**不含**固定值的 find_tab（★ 通用）');
} else {
  ok(false, 'Swift 真跑未通过', out.slice(0, 500));
}

console.log('\n=== 2. 变异对照：改坏 ⇒ 真跑必须红 ===');
{
  const orig = fs.readFileSync(SV, 'utf8');
  try {
    // 变异 1：增量合并 ⇒ 整份覆盖（站方其它状态被冲掉）
    const m1 = orig.replace(
      'var cur = stationVarObject(for: sourceUrl)\n        for (k, v) in obj { cur[k] = v }',
      'var cur = [String: Any]()\n        for (k, v) in obj { cur[k] = v }');
    const m2b = orig.replace('if !stationKeys.isEmpty, let sv = stationValue, !sv.isEmpty {',
                             'if false, let sv = stationValue, !sv.isEmpty {');
    ok(m1 !== orig, '变异锚点命中（增量合并 → 整份覆盖）');
    if (m1 !== orig) {
      fs.writeFileSync(SV, m1, 'utf8');
      let o2 = '', f2 = false;
      try { o2 = runSwift(); } catch (e) { f2 = true; o2 = (e.stdout || '') + (e.stderr || ''); }
      ok(f2 || !o2.includes('OK'), '★ 变异后真跑失败（门禁有牙齿）');
    }

    // 变异 1b：不用 stationKeys（通用键名失效 ⇒ 大灰狼/NovelHub 都不对）
    ok(m2b !== orig, '变异锚点命中（不用 stationKeys ⇒ 通用键名失效）');
    if (m2b !== orig) {
      fs.writeFileSync(SV, m2b, 'utf8');
      let o2b = '', f2b = false;
      try { o2b = runSwift(); } catch (e) { f2b = true; o2b = (e.stdout || '') + (e.stderr || ''); }
      ok(f2b || !o2b.includes('OK'), '★ 变异后真跑失败（门禁有牙齿）');
    }

    // 变异 2：把「增量合并」改成「整份覆盖」的第二种写法（站方其它状态被冲掉）⭐⭐⭐
    const m2 = orig.replace(
      'var cur = stationVarObject(for: sourceUrl)\n        for (k, v) in obj { cur[k] = v }',
      'var cur = [String: Any]()\n        for (k, v) in obj { cur[k] = v }');
    ok(m2 !== orig, '变异锚点命中（增量合并 → 整份覆盖 · 第二处）');
    if (m2 !== orig) {
      fs.writeFileSync(SV, m2, 'utf8');
      let o3 = '', f3 = false;
      try { o3 = runSwift(); } catch (e) { f3 = true; o3 = (e.stdout || '') + (e.stderr || ''); }
      ok(f3 || !o3.includes('OK'), '★ 变异后真跑失败（门禁有牙齿）');
    }
  } finally {
    fs.writeFileSync(SV, orig, 'utf8');
  }
}

console.log('\n=== 3. 站方约定的证据（真源 jsLib）===');
{
  const srcPath = '/workspace/output/NovelHub聚合小说-轻阅新引擎适配.json';
  if (fs.existsSync(srcPath)) {
    const raw = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
    const src = Array.isArray(raw) ? raw[0] : raw;
    const lib = src.jsLib || '';
    ok(/source\.getVariable\(\)/.test(lib), '★ 站方 exploreUrl 读 source.getVariable()（站方变量整串）');
    ok(/c\['src'\]=v/.test(lib) && /c\['find_source'\]=String\(v\)/.test(lib),
       '★ 站方自己把 src 与 find_source 写成同一个值（★ 约定成立）');
  } else {
    ok(false, '真源产物不在（无法取证据）', srcPath);
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
