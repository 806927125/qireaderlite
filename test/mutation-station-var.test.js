#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **变异测试门禁**（把实现改坏 ⇒ 门禁必须红）
 *
 * 跑法：node test/mutation-station-var.test.js
 *
 * ⚠️ **为什么要有这一层**：
 *   门禁「全绿」有两种可能 ——
 *     ① 实现真的对
 *     ② **门禁压根没抓到东西**（平凡通过）⭐⭐⭐
 *   ⇒ 所以每个断言都要问一句「**把实现改坏，它会不会红**」⭐
 *   ⇒ 这一层把「站方变量形态」这块的 9 种改坏方式各试一遍 ⇒ 每次都必须红 ⭐⭐⭐
 *
 * ⚠️ **它会真的改仓库里的源码**（改完立刻 `git checkout` 复原）⇒
 *   ⇒ **跑之前先 commit**（脚本最后会验「复原后门禁恢复绿」）⭐
 */
const { spawnSync } = require('child_process');
const path = require('path');

const root = path.join(__dirname, '..');
const script = path.join(root, 'test', 'mutation-station-var.sh');

const r = spawnSync('bash', [script], { cwd: root, encoding: 'utf8', timeout: 15 * 60 * 1000 });
const out = (r.stdout || '') + (r.stderr || '');

// ⭐ 崩溃判定（崩了就没有汇总行 ⇒ 不能当成通过）
if (r.error) {
  console.log(`❌ 变异测试脚本跑不起来：${r.error.message}`);
  process.exit(1);
}
if (/COMPILE_ERROR/.test(out)) {
  console.log('❌ 变异测试脚本编译失败（门禁脚本自己坏了）');
  console.log(out.split('\n').slice(-20).join('\n'));
  process.exit(1);
}

console.log(out.trim());

// 汇总行：「变异测试：通过 N / 失败 M」
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
