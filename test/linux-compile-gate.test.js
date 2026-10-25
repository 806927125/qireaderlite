#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **Linux 编译门禁（node 包装器）**
 *
 * ⚠️⚠️⚠️ **为什么必须有这个**（2026-10-25 build253 CI 失败事故）：
 *   我改了 `SourceService.swift`（新增 `withRealTimeout`）⇒ **沙盒门禁全绿**
 *   ⇒ 但沙盒的 swift 门禁**根本没编这个文件**（只编 LegadoCompat / AnalyzeUrl / Book …）
 *   ⇒ 于是**多了一个 `}`** 也没人发现 ⇒ 推到 CI ⇒ **BUILD FAILED**（白等一轮 CI）⭐⭐⭐
 *
 * ⇒ 核心在 `test/linux-compile-gate.sh`（真正干活的那个）
 *   本文件只负责：**找到 swiftc → 跑那个脚本 → 把它的输出/退出码转成门禁格式** ⭐
 *
 * ⭐ **总门禁的执行器只跑 `node`** ⇒ 所以 bash 脚本外面必须包一层 node ⭐
 *   （之前直接写 `"linux-compile:bash test/..."` ⇒ 被当成**文件名** ⇒ 报「缺文件」⭐⭐⭐）
 */
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SCRIPT = path.join(ROOT, 'test/linux-compile-gate.sh');

if (!fs.existsSync(SCRIPT)) {
  console.log('  ✗ 找不到 ' + SCRIPT);
  process.exit(1);
}

// ⭐ 找 swiftc（跟 run-swift-tests.sh 同一份逻辑 ⇒ 单一真相）
function findSwiftc() {
  const cands = [
    process.env.SWIFT ? path.join(process.env.SWIFT, 'usr/bin/swiftc') : null,
    '/workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc',
    '/workspace/.toolchain/swift/usr/bin/swiftc',
    '/usr/bin/swiftc',
    '/usr/local/bin/swiftc',
  ].filter(Boolean);
  for (const c of cands) { try { fs.accessSync(c, fs.constants.X_OK); return c; } catch (_) {} }
  return null;
}

const swiftc = findSwiftc();
if (!swiftc) {
  // ⭐⭐⭐ **显式 SKIP，不许说成全绿**（「跳过」≠「验过了没问题」）
  console.log('=== Linux 编译门禁：跳过 ===');
  console.log('没找到 swiftc ⇒ 跑不了编译检查');
  console.log('  ⚠️ 本次**没验到**（不等于通过）');
  process.exit(0);
}

const r = spawnSync('bash', [SCRIPT], {
  cwd: ROOT,
  encoding: 'utf8',
  env: { ...process.env, SWIFTC: swiftc, SWIFT: process.env.SWIFT || path.dirname(path.dirname(swiftc)) },
});
const out = (r.stdout || '') + (r.stderr || '');
process.stdout.write(out);
process.exit(r.status === null ? 1 : r.status);
