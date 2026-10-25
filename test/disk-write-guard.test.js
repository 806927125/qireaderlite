#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **写盘纪律门禁**（2026-10-26 iOS「diskwrites」限额被杀）
 *
 * ────────────────────────────────────────────────────────────
 * 事故（用户提供的 .ips 崩溃日志实证）
 * ────────────────────────────────────────────────────────────
 *   Event:            disk writes
 *   Writes:           1073.75 MB over 25222 秒 (42.57 KB/s)
 *   限额:             12.43 KB/s × 86400s ≈ 1073.74 MB
 *   Action taken:     none   ← 这次侥幸没被杀，再写一点就杀
 *   Heaviest stack:   libswift_Concurrency → Foundation ×3 → libsystem_kernel(write)
 *
 *   ⇒ **iOS 会因「磁盘写入超限」杀进程** ⇒ 用户看到的现象是「闪退」⭐⭐⭐
 *   ⇒ 栈顶 `libswift_Concurrency` ⇒ **每条日志一次 `Task { @MainActor }`** ⭐⭐⭐
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁钉的三条纪律（改动实现会被抓）
 * ────────────────────────────────────────────────────────────
 *   ① **落盘不许用 `.atomic`**
 *      ⇒ `.atomic` = 写临时文件 + rename ⇒ **每次写盘量翻倍** ⭐⭐⭐
 *   ② **日志落盘必须批量**（不许「每行一次 IO」）
 *      ⇒ 攒够 N 行 / 2 秒才写一次 ⇒ IO 次数降一个数量级 ⭐⭐⭐
 *   ③ **必须有写盘计量 + 限流**
 *      ⇒ `DiskWriteMeter` 记字节数 ⇒ 超上限停写 ⇒ **宁可少落盘也不被系统杀** ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const read = (p) => { try { return fs.readFileSync(path.join(ROOT, p), 'utf8'); } catch (e) { return ''; } };

console.log('=== ① App 侧所有落盘点：写文件不许用 `.atomic`（= 双倍写盘）===');
const WRITE_SITES = [
  ['QiReaderLite/Core/RuleSandbox.swift', '引擎日志落盘'],
  ['QiReaderLite/Core/Store.swift', '源列表 / 书架 / 正文缓存'],
  ['QiReaderLite/Core/HostTools.swift', '站方文件缓存'],
  ['QiReaderLite/Core/SourceRawArchive.swift', '源原始 JSON 存档'],
];
let atomicHits = [];
for (const [f, what] of WRITE_SITES) {
  const src = read(f);
  if (!src) { ok(false, `${f} 读不到`); continue; }
  const lines = src.split('\n');
  lines.forEach((l, i) => {
    if (/\.write\(to:/.test(l) && /\.atomic/.test(l)) {
      atomicHits.push(`${f}:${i + 1}  ${l.trim()}`);
    }
  });
}
ok(atomicHits.length === 0,
   `写盘不许用 .atomic（实际 ${atomicHits.length} 处）` +
   (atomicHits.length ? '\n     ' + atomicHits.join('\n     ') : ''));

console.log('');
console.log('=== ② 引擎日志落盘必须批量（不许每行一次 IO）===');
const rs = read('QiReaderLite/Core/RuleSandbox.swift');
ok(/func persistToDisk/.test(rs), '有 persistToDisk（落盘入口）');
ok(/diskBuffer/.test(rs), '有内存缓冲（批量写）');
ok(/flushDiskLog/.test(rs), '有批量 flush 函数');
// ⭐⭐⭐ 关键：appendLog 里**不许**直接调 persistToDisk 之外还开 Task 切主线程做 IO
const appendBlock = (rs.match(/func appendLog[\s\S]*?\n    \}/) || [''])[0];
ok(/Thread\.isMainThread/.test(appendBlock),
   'appendLog 先判 Thread.isMainThread（别每次都开 Task 切主线程）');
ok(!/Task \{ @MainActor in[\s\S]{0,80}persistToDisk/.test(appendBlock),
   '落盘不许在主线程 Task 里做（IO 归后台）');

console.log('');
console.log('=== ③ 必须有写盘计量 + 限流 ===');
const ht = read('QiReaderLite/Core/HostTools.swift');
ok(/enum DiskWriteMeter/.test(ht), '有 DiskWriteMeter（写盘计量器）');
ok(/hourlyLimit/.test(ht), '有每小时写盘上限');
ok(/func record\(/.test(ht), '有 record（记账）');
ok(/currentHourBytes/.test(ht), '有 currentHourBytes（可查）');
ok(/DiskWriteMeter\.record/.test(rs), '日志落盘走了计量器');
// ⭐⭐⭐ 限流上限必须**远低于** iOS 的限额
const m = ht.match(/hourlyLimit\s*=\s*([0-9_]+)\s*\*\s*1024\s*\*\s*1024/);
if (m) {
  const mb = parseInt(m[1], 10);
  ok(mb <= 8, `每小时上限 ≤ 8 MB（实际 ${mb} MB）⇒ 远低于 iOS 的 1.07 GB/天 ⇒ 安全`);
} else {
  ok(false, '解析不出 hourlyLimit（格式变了？）');
}

console.log('');
console.log('=== ④ 自检面板要能看到写盘量（下次不用猜）===');
ok(/本小时写盘/.test(rs), '自检面板显示「本小时写盘」');

console.log('');
console.log('=== ⑤ 行数限流（引擎诊断一多也不会被刷爆）===');
ok(/diskLinesPerHour/.test(rs), '有每小时行数上限');
ok(/diskLinesThisHour > diskLinesPerHour/.test(rs), '超行数 ⇒ 停止落盘（内存日志还在）');

console.log('');
console.log('=== ⑥ 单行日志必须截断（站方 java.log 能打几十 KB）===');
ok(/maxLineLength/.test(rs), '有单行长度上限');
ok(/line\.count > Self\.maxLineLength/.test(rs) || /line\.count > maxLineLength/.test(rs),
   '超长行被截断（防写盘炸弹）');
ok(/已截断/.test(rs), '截断时有标记');
// ⭐⭐⭐ **判据必须能抓「截断逻辑被掏空」** ⇒ 查**截断动作本身**
//   （只查「变量名出现过」会被 `clipped = line` 这种绕过 ⇒ 恒真 ⇒ 装饰品）⭐⭐⭐
const clipDef = (rs.match(/let clipped =[\s\S]{0,600}?let stamped =/) || [''])[0];
ok(clipDef.length > 0, '找到 clipped 的定义');
ok(/prefix\(/.test(clipDef),
   'clipped 必须用 prefix 真截断（掏空成 `clipped = line` ⇒ 本条红）');
ok(/maxLineLength/.test(clipDef), 'clipped 的截断长度用 maxLineLength（不是硬编码）');

console.log('');
console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
