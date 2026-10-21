#!/usr/bin/env node
/**
 * **JS 侧等待时间必须覆盖原生侧的最坏耗时**（2026-10-21 真机实测）
 *
 * 真机现象（build189 测书源报告）：
 *     [request] 第 1 次失败：https://v10.langge.uk/get_book_shelf
 *     [request] 第 2 次失败：https://v10.langge.uk/get_book_shelf
 *     ⏱ op「explore」耗时 23018ms
 *     [request] 重试成功（第 3 次）https://v10.langge.uk/get_book_shelf
 *     ❌ 发现功能　engineFailed("原生调用超时: request")
 *
 * ⇒ **第 3 次其实成功了，但 JS 侧已经不等了** ⇒ 白跑。
 *
 * 根因（两边超时预算算错）：
 *   · 原生侧 `nativeRequest`：重试 3 次，每次 `per = max(3, timeout/(attempts-i))`
 *     ⇒ **分母递减** ⇒ 总耗时 = timeout×(1/3+1/2+1) ≈ **1.83 × timeout**
 *       （12s ⇒ 4+6+12 = 22s + 0.6s 退避 ≈ **22.6 秒**）
 *   · JS 侧 `rawRequest`：只等 `(__t + 3)` = **15 秒** ⇒ **必然可能先超时** ❗
 *
 * ⇒ 修：JS 侧等 `__t × 2 + 5`（12s ⇒ 29 秒）⇒ 盖住 22.6 秒 ✅
 *
 * ⚠️ 这个坑是**全局**的：所有走 `java.ajax` / `java.get` 的站方规则都受影响
 *    ⇒ 线路一慢，op 必挂 ⇒ 「时好时坏」的另一半机制。
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };
const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

(async () => {
  const ja = read('QiReaderLite/Resources/engine/java-api.js');
  const sw = read('QiReaderLite/Core/RuleSandbox.swift');

  console.log('=== ① JS 侧等待时间公式 ===');
  const m = ja.match(/var __waitMs = \(([^)]*)\)\s*\*\s*1000;/);
  ok(!!m, '找到 __waitMs 计算');
  if (m) {
    ok(/\*\s*2/.test(m[1]), `JS 侧等待要放大到 2 倍（实际公式：${m[1]}）`);
    ok(/\+\s*5/.test(m[1]), `要留 5 秒余量（实际公式：${m[1]}）`);
  }
  ok(/__waitMs/.test(ja), 'nativeCall 用的是 __waitMs');
  ok(!/\(__t \+ 3\) \* 1000/.test(ja), '旧的 `(__t + 3) * 1000` 已经没有了');

  console.log('\n=== ② 原生侧重试预算 ===');
  ok(/attempts\s*=\s*3/.test(sw), '原生侧重试 3 次');
  // 分母递减 ⇒ 总耗时 1.83 × timeout ⇒ JS 侧必须等 ≥ 2 × timeout
  ok(/timeout \/ Double\(attempts - i\)/.test(sw),
     '原生侧每次超时是 timeout/(attempts-i)（分母递减 ⇒ 总 1.83×timeout）');
  ok(/opTimeoutSeconds\s*:\s*Double\s*=\s*360/.test(sw),
     'op 超时 360 秒（远大于单次请求的 29 秒）');

  console.log('\n=== ③ 超时链路自证 ===');
  // 12s ⇒ 原生侧最坏 22.6s ⇒ JS 侧等 29s ⇒ 覆盖
  const per = [12 / 3, 12 / 2, 12 / 1];
  const nativeWorst = per.reduce((a, b) => a + Math.max(3, b), 0) + 0.6;
  const jsWait = 12 * 2 + 5;
  console.log(`  原生侧最坏 = ${nativeWorst.toFixed(1)}s（${per.map(p => Math.max(3, p)).join(' + ')} + 0.6 退避）`);
  console.log(`  JS 侧等待 = ${jsWait}s`);
  ok(jsWait > nativeWorst, `JS 侧等待(${jsWait}s) > 原生侧最坏(${nativeWorst.toFixed(1)}s)`);

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
