#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **变异测试门禁**（`@js:` 规则不许在正文里被「尾部 JS」腰斩）
 *
 * 跑法：node test/mutation-js-rule-tail.test.js
 *
 * ⚠️ **为什么要这一层**：门禁「全绿」有两种可能 ——
 *   ① 实现真的对 ② **门禁压根没抓到东西**（平凡通过）⭐⭐⭐
 *   ⇒ 这一层把实现改坏 3 种（去掉保护 / 加长度限制 / 用修复前的基座）⇒ 每次都必须红 ⭐⭐⭐
 *
 * ⚠️ **它会真的改仓库里的源码**（改完立刻拷副本复原）⇒ 跑之前先 commit ⭐
 */
const { spawnSync } = require('child_process');
const path = require('path');

const root = path.join(__dirname, '..');
const script = path.join(root, 'test', 'mutation-js-rule-tail.sh');

const r = spawnSync('bash', [script], { cwd: root, encoding: 'utf8', timeout: 15 * 60 * 1000 });
const out = (r.stdout || '') + (r.stderr || '');

if (r.error) {
  console.log(`❌ 变异测试脚本跑不起来：${r.error.message}`);
  process.exit(1);
}

console.log(out.trim());

const m = out.match(/变异测试：通过 (\d+) \/ 失败 (\d+)/);
if (!m) {
  console.log('❌ 没找到汇总行（脚本崩了 ⇒ 不算通过）');
  process.exit(1);
}
const pass = Number(m[1]), fail = Number(m[2]);
if (fail > 0) {
  console.log(`❌ 变异测试：通过 ${pass} / 失败 ${fail}`);
  process.exit(1);
}
console.log(`✅ 变异测试：通过 ${pass} / 失败 ${fail}`);
process.exit(0);
