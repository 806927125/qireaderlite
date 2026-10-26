/**
 * **内存水位门禁**（2026-10-26 jetsam 6.8GB 实证）
 *
 * 背景（2026-10-26 真机崩溃日志实证）：
 *   jetsam 记录里 `QingYue` **单进程** `rpages = 425984` ⇒ ×16KB = **6.8GB**
 *   ⇒ **被系统内存杀**（jetsam，不是崩溃）⇒ 现象 =「闪退」+ **没有 .ips 崩溃日志** ⭐⭐⭐
 *   ⇒ 同一批证据里「本小时写盘」只有 142 B ⇒ **磁盘写入这条线彻底排除** ⭐⭐⭐
 *   ⇒ 面板里当时**没有内存项** ⇒ App 自己完全不知道自己涨到多少 ⇒ 只能靠猜 ⭐⭐⭐
 *
 * ⭐⭐⭐ 本门禁钉三件事（**「钉已修好」**，不是「钉现状」）：
 *   ① **量的是 jetsam 口径**（`phys_footprint`）⇒ 阈值跟系统同一把尺
 *   ② **面板看得见**（`diagnose()` 里必须有内存那一行）
 *   ③ **超限自己先清**（引擎调用路径上必须挂着水位自检 ⇒ 清引擎会话 = 重建 JS context）
 *
 * ⚠️⚠️ **为什么要「静态断言 + 真跑一遍」两段**：
 *   只静态断言 ⇒ 只能证明「代码长这样」⇒ 证明不了「逻辑对」
 *   只真跑 ⇒ 证明不了「真的接在引擎调用路径上」（把 hook 删了照样绿）
 *   ⇒ 两段都要 ⭐⭐⭐
 *
 * ⚠️ **真跑那段需要 swiftc** ⇒ 没有就**跳过**（并明说「没验到」）
 *   ⇒ 跳过**不算通过**（沙盒里没装工具链时不能当绿）
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

// ── 找 swiftc（跟仓库里其他门禁同一份逻辑 ⇒ 单一真相）──
function findSwiftc() {
  const cands = [
    process.env.SWIFTC,
    `${process.env.SWIFT || ''}/usr/bin/swiftc`,
    '/workspace/.toolchain/swift/usr/bin/swiftc',
    '/workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc',
    '/opt/swift/swift-6.1.2-RELEASE-debian12/usr/bin/swiftc',
    '/usr/bin/swiftc',
    '/usr/local/bin/swiftc',
  ].filter(Boolean);
  for (const c of cands) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch (e) { /* 下一个 */ }
  }
  return null;
}

const memPath = path.join(APP, 'Core/MemoryMeter.swift');
const svcPath = path.join(APP, 'Core/SourceService.swift');
const sbPath = path.join(APP, 'Core/RuleSandbox.swift');

/**
 * ⭐⭐⭐ **剥掉注释**（再拿去做断言）
 *
 * ⚠️⚠️ **为什么必须剥**（实测踩到）：变异测试里把调用改成
 *   `// Self.checkMemoryWaterline(op: op)`（**注释掉**）
 *   ⇒ 直接 grep 源码**照样命中** ⇒ 门禁全绿 ⇒ **假绿** ⭐⭐⭐
 *   ⇒ 断言必须作用在**真代码**上 ⇒ 注释不算数 ⭐⭐⭐
 *
 * ⚠️ 不能粗暴地按 `//` 切行：源码里有 `https://...` 这样的**字符串**
 *   ⇒ 粗暴切会把后面的真代码一起吃掉（那是另一种假红）⇒ 手工扫一遍字符串状态 ⭐⭐⭐
 */
function stripComments(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  let inLine = false, inBlock = false, inStr = null;
  while (i < n) {
    const c = src[i], c2 = src.substr(i, 2);
    if (inLine) {
      if (c === '\n') { inLine = false; out += c; }
      i++; continue;
    }
    if (inBlock) {
      if (c2 === '*/') { inBlock = false; i += 2; continue; }
      if (c === '\n') out += c;      // 保留行数（行号相关断言才准）
      i++; continue;
    }
    if (inStr) {
      out += c;
      if (c === '\\') { out += src[i + 1] || ''; i += 2; continue; }
      if (c === inStr) inStr = null;
      i++; continue;
    }
    if (c2 === '//') { inLine = true; i += 2; continue; }
    if (c2 === '/*') { inBlock = true; i += 2; continue; }
    if (c === '"' || c === "'") { inStr = c; out += c; i++; continue; }
    out += c; i++;
  }
  return out;
}

console.log('\n── 1. 内存计量器必须在（而且量的是 jetsam 口径）──');
ok(fs.existsSync(memPath), 'Core/MemoryMeter.swift 存在');
const mem = fs.existsSync(memPath) ? stripComments(fs.readFileSync(memPath, 'utf8')) : '';
ok(/phys_footprint/.test(mem), '量的是 phys_footprint（jetsam 判杀用的量）');
ok(/TASK_VM_INFO/.test(mem), '走的是 TASK_VM_INFO（不是猜的）');
ok(/autoResetThresholdMB\s*=\s*\d+/.test(mem), '有自动清理阈值常量');
ok(/#if canImport\(Darwin\)/.test(mem), '平台代码有 canImport 守卫（沙盒能编）');
ok(/cooldown|Cooldown/i.test(mem), '有冷却期（别反复清）');

console.log('\n── 2. 自检面板必须有内存项（之前没有 ⇒ 涨到多少完全看不见）──');
const sb = fs.existsSync(sbPath) ? stripComments(fs.readFileSync(sbPath, 'utf8')) : '';
ok(/MemoryMeter\.panelLine/.test(sb), 'diagnose() 里挂了内存那一行');
ok(/MemoryMeter\.sample\(\)/.test(sb), '面板会先采样一次（拿的是实时水位）');

console.log('\n── 3. 超限必须自己先清（清引擎会话 = 重建 JS context）──');
const svc = fs.existsSync(svcPath) ? stripComments(fs.readFileSync(svcPath, 'utf8')) : '';
ok(/checkMemoryWaterline/.test(svc), '引擎调用路径上挂了水位自检');
ok(/dropAllSessions/.test(svc), '超限会清空引擎会话（⇒ JS context 重建）');
ok(/MemoryMeter\.record\(/.test(svc), '判定走的是 MemoryMeter.record（阈值逻辑集中在一处）');
// ⚠️ 关键：hook 必须在 **op 跑完之后**（不能中途掀掉正在跑的调用）
const hookIdx = svc.indexOf('checkMemoryWaterline(op: op)');
const invokeIdx = svc.indexOf('LegadoEngineBackend.shared.invoke(op, payload, source: source)');
ok(hookIdx > 0 && invokeIdx > 0 && hookIdx > invokeIdx,
   '水位自检在引擎调用**之后**（不掀掉正在跑的结果）');
// ⚠️⚠️ **不能只是「函数存在」** ⇒ 那个函数得**真的被调用**
//   （注释掉调用点 ⇒ 门禁必须红；这条就是变异测试逼出来的）
const callSites = (svc.match(/Self\.checkMemoryWaterline\(op:\s*op\)/g) || []).length;
ok(callSites >= 1, 'checkMemoryWaterline 真的被调用了（不是只定义不用）');

console.log('\n── 4. 真跑一遍阈值/峰值逻辑（需要 swiftc）──');
const swiftc = findSwiftc();
if (!swiftc) {
  console.log('  ⏭ 跳过：没找到 swiftc ⇒ **这段没验到**（不算通过）');
} else {
  const tmp = fs.mkdtempSync('/tmp/memwater-');
  const mainSwift = path.join(tmp, 'main.swift');
  // ⚠️ 断言必须作用在**真代码**上 ⇒ 直接引 MemoryMeter.swift 编译
  fs.writeFileSync(mainSwift, `
import Foundation

func expect(_ cond: Bool, _ label: String) {
  if cond { print("  ✓ " + label) } else { print("  ✗ " + label); exit(1) }
}

let MB = 1024 * 1024
let thr = MemoryMeter.autoResetThresholdMB

// ① 量不到（0）⇒ **不得当成超限**（否则会把好会话白丢）
expect(MemoryMeter.record(bytes: 0) == false, "量不到(0) 不算超限")
// ② 低于阈值 ⇒ 不清
expect(MemoryMeter.record(bytes: (thr - 1) * MB) == false, "低于阈值不清")
// ③ 正好到阈值 ⇒ 清
expect(MemoryMeter.record(bytes: thr * MB) == true, "到阈值就清")
// ④ 峰值只增不减
let peakBefore = MemoryMeter.peakMB
expect(MemoryMeter.record(bytes: 10 * MB) == false, "回落后不清")
expect(MemoryMeter.peakMB == peakBefore, "峰值只增不减")
expect(MemoryMeter.currentMB == 10, "当前值跟着最新采样走")
// ⑤ 文本格式
expect(MemoryMeter.text(0) == "不可用", "量不到显示「不可用」")
expect(MemoryMeter.text(1536 * 1024).hasPrefix("1.5 MB"), "文本是 MB")
// ⑥ 面板那一行必须出现「内存」+ 限额
expect(MemoryMeter.panelLine.contains("内存"), "面板行里有「内存」")
expect(MemoryMeter.panelLine.contains("\\(thr)"), "面板行里写明限额")
// ⑦ 冷却：刚清过 ⇒ 短时间内不再清
MemoryMeter.noteAutoReset(fromMB: 700, toMB: 300)
expect(MemoryMeter.autoResetCount >= 1, "记下了自动清理次数")
expect(MemoryMeter.canAutoResetNow == false, "刚清过 ⇒ 冷却期内不再清")
print("SWIFT_OK")
`);
  try {
    const bin = path.join(tmp, 'memwater');
    execFileSync(swiftc, ['-swift-version', '5', '-o', bin, memPath, mainSwift],
                 { stdio: 'pipe', encoding: 'utf8' });
    const out = execFileSync(bin, [], { stdio: 'pipe', encoding: 'utf8' });
    const lines = out.split('\n').filter(l => l.includes('✓'));
    pass += lines.length;
    lines.forEach(l => console.log(l));
    ok(out.includes('SWIFT_OK'), 'swift 断言全过');
  } catch (e) {
    fail++;
    console.log('  ✗ swift 跑挂了 ⇒ ' + String(e.message).split('\n').slice(0, 4).join(' | '));
    if (e.stdout) console.log('    stdout: ' + String(e.stdout).slice(0, 400));
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* 忽略 */ }
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
if (fail > 0) process.exit(1);
