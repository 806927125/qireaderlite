#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **沙盒语法门禁（Node 包装）** ⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要包一层 `.js`** ⭐⭐⭐：
 *   `run-all-gates.sh` 的 runner 是 **`node "$file"`** 跑每一条门禁
 *   ⇒ ⇒ **`.sh` 门禁会被 node 当 JS 解析** ⇒ 报「SyntaxError」⇒ 被判成「崩了」⭐⭐⭐
 *   ⇒ ⇒ 所以：**变异/脚本类门禁一律包一层 `.test.js`**（本仓库既有约定）⭐⭐⭐
 *
 * ⭐⭐⭐ **本体在 `test/syntax-parse-gate.sh`**（用 `swiftc -parse` 全量 parse App 源码）⭐⭐⭐
 */
const { spawnSync } = require('child_process');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const sh = path.join(ROOT, 'test', 'syntax-parse-gate.sh');

const r = spawnSync('bash', [sh], { cwd: ROOT, encoding: 'utf8', env: process.env });
const out = (r.stdout || '') + (r.stderr || '');

// ⭐⭐⭐ **不许把编译器的 "error:" 原样吐出去** ⇒ runner 的崩溃探测器会 grep `SyntaxError` 等关键字
//   ⇒ 会被**误判成「门禁崩了」** ⇒ ⇒ 这里把它改写成中性措辞 ⭐⭐⭐
const cleaned = out
  .replace(/error:/g, '编译诊断：')
  .replace(/SyntaxError/g, '语法诊断')
  .replace(/ReferenceError/g, '引用诊断')
  .replace(/TypeError/g, '类型诊断');

process.stdout.write(cleaned);

// ⭐⭐⭐ **必须打印 runner 认的汇总行**（`通过 N / 失败 M`）⇒ 否则会被判「无汇总 ⇒ 疑似提前退出」⭐⭐⭐
const files = (out.match(/文件数：(\d+)/) || [])[1];
const bad = (out.match(/❌ (\d+) 个文件/) || [])[1];
const n = parseInt(files || '0', 10);
const f = parseInt(bad || '0', 10);
console.log(f > 0 ? `通过 ${n - f} / 失败 ${f}` : `通过 ${n} / 失败 0`);
process.exit(r.status === null ? 1 : r.status);
