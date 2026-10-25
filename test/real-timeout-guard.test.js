#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **真超时门禁**：引擎调用的超时必须**真的能返回**
 *
 * **事故（2026-10-25 真机闪退）**：build252 的用户反馈「又崩溃了」
 *
 * ⚠️⚠️⚠️ **根因（沙盒可证伪实验）**：
 *   旧写法用 `withThrowingTaskGroup`：
 *     · TaskGroup 在**退出作用域时必须等所有子任务结束**
 *     · 站方 JS 死循环那个子任务跑在 `DispatchQueue.global().async` 里 ⇒ **不可取消**
 *     * ⇒ `group.cancelAll()` 救不了它 ⇒ **超时永远不生效**
 *     * ⇒ 沙盒实测：1 秒超时 ⇒ **实际耗时 8 秒**（等到了卡死子任务）⭐⭐⭐
 *   ⇒ 站方 JS 死循环在 **App 进程内** 100% CPU 空转 ⇒ 设备发烫
 *   ⇒ iOS 热保护 / 看门狗杀 App ⇒ **表现为「闪退」**（系统杀的 ⇒ 没有崩溃日志）⭐⭐⭐
 *
 * ⇒ 修法：**不用 TaskGroup** ⇒ 「一次性 resume 闸门 + 独立超时定时器」
 *   ⇒ 超时信号与引擎线程**解耦** ⇒ 卡死线程拖不住返回 ⭐⭐⭐
 *
 * ⭐ **本门禁的判据**（都是「从源码解析出来的」⇒ 不是复述实现意图）：
 *   ① 引擎调用路径里**不许**出现 `withThrowingTaskGroup`（它会等卡死子任务）
 *   ② 必须有「独立超时定时器」⇒ `DispatchSource.makeTimerSource`
 *   ③ 必须有「一次性闸门」⇒ 续体只恢复一次（`finished` 标志）
 *   ④ 超时后必须**换掉卡死的会话**（`dropSession`）—— 不换 ⇒ 死循环会传染
 *   ⑤ 必须有**卡死线程配额**（老引擎退役后，这层保护没了 ⇒ 必须自己补）⭐
 *   ⑥ 必须有**熔断**（连续超时 ⇒ 不再无限重试 ⇒ 否则反复烧 CPU ⇒ 又被杀）
 *
 * ⭐⭐⭐ **变异测试**：把 `withRealTimeout` 改回 `withThrowingTaskGroup` ⇒ 本门禁必须红
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const FILE = path.join(ROOT, 'QiReaderLite/Core/SourceService.swift');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

if (!fs.existsSync(FILE)) {
  console.log('  ✗ 找不到 ' + FILE);
  process.exit(1);
}
const src = fs.readFileSync(FILE, 'utf8');

/** 取 `withRealTimeout` 这个函数的函数体（大括号配平，忽略字符串/注释里的括号） */
function extractFunction(src, name) {
  const idx = src.indexOf('func ' + name);
  if (idx < 0) return null;
  const lines = src.slice(idx).split('\n');
  let body = '', depth = 0, started = false;
  for (const l of lines) {
    let clean = l.replace(/\/\/.*$/, '');
    clean = clean.replace(/"(?:[^"\\]|\\.)*"/g, '""');
    for (const ch of clean) {
      if (ch === '{') { depth++; started = true; }
      else if (ch === '}') depth--;
    }
    body += l + '\n';
    if (started && depth <= 0) break;
  }
  return body;
}

const timeoutFn = extractFunction(src, 'withRealTimeout');
const invokeFn = extractFunction(src, 'invokeNewEngine');
// ⭐⭐⭐ **闸门类型 `TimeoutGate` 在文件顶层**（Swift 不许泛型函数里嵌套类型 ⇒ 硬编译错误）
// ⚠️ 闸门有**好几个方法**（timeout / arm / finish）⇒ 要**合并起来**看
//   （只看一个方法 ⇒ 定时器在 arm 里、闸门标志在 finish 里 ⇒ 误报）⭐⭐⭐
const gateFn = ['timeout', 'arm', 'finish']
  .map(n => extractFunction(src, n))
  .filter(Boolean)
  .join('\n');

ok(!!timeoutFn, '⭐⭐⭐ 有 `withRealTimeout` 这个真超时实现（找不到 ⇒ 有人改回去了）');
ok(!!invokeFn, '有 `invokeNewEngine`');
// ⭐⭐⭐ 闸门必须是**顶层类型**（不是泛型函数里的嵌套类 ⇒ Swift 编译错误 ⇒ CI 必挂）
ok(/final class TimeoutGate</.test(src),
   '⭐⭐⭐⭐⭐ 闸门必须是**顶层类型** `TimeoutGate`'
   + '（Swift 不许泛型函数里嵌套类型 ⇒ `type X cannot be nested in generic function` ⇒ CI 必挂）');

// ⭐⭐⭐ 「泛型函数里嵌套类型」这条**交给编译门禁**（`test/linux-compile-gate.sh`）
//   ⇒ 那里是**真 swiftc 编译** ⇒ 实测能报红（`type 'X' cannot be nested in generic function`）⭐⭐⭐
//   ⚠️ 本文件里的「纯文本扫描」**不可靠**（Swift 语法太复杂 ⇒ 深度/签名跨行都会误判）
//   ⇒ 教训：**能用真编译器验的，别用文本扫描凑** ⭐⭐⭐
//   ⇒ 顶层的 `final class TimeoutGate` 断言保留（它抓的是「有人把类型挪回函数里」这个意图）⭐
ok(/final class TimeoutGate</.test(src),
   '⭐⭐⭐⭐⭐ 闸门 `TimeoutGate` 必须是**顶层类型**（嵌套进泛型函数 ⇒ Swift 编译错误 ⇒ 编译门禁会红）');

if (timeoutFn) {
  // ① ⭐⭐⭐ **不许用 TaskGroup**（它会等卡死的子任务 ⇒ 超时形同虚设）
  ok(!/withThrowingTaskGroup/.test(timeoutFn),
     '⭐⭐⭐⭐⭐ `withRealTimeout` 里**不许**用 `withThrowingTaskGroup`'
     + '（它退出时必须等所有子任务 ⇒ 站方 JS 死循环那个子任务永不结束 ⇒ 超时形同虚设）');
  ok(!/withThrowingTaskGroup/.test(gateFn || ''),
     '⭐⭐⭐⭐⭐ 闸门里也不许用 `withThrowingTaskGroup`');
}

if (gateFn) {
  // ② ⭐ **独立超时定时器**（超时信号与引擎线程解耦）
  ok(/DispatchSource\.makeTimerSource/.test(gateFn),
     '⭐⭐⭐ 闸门必须有**独立超时定时器**（`DispatchSource.makeTimerSource`）'
     + ' ⇒ 超时信号与引擎线程解耦 ⇒ 卡死线程拖不住返回');

  // ③ ⭐ **一次性闸门**（续体只能恢复一次 ⇒ 否则会 crash: "resume of continuation more than once"）
  ok(/finished/.test(gateFn) && /if finished/.test(gateFn),
     '⭐⭐⭐ 闸门必须有「一次性闸门」（续体只恢复一次）');

  // ④ ⭐ **定时器必须能被取消**（否则每次调用都留一个定时器 ⇒ 泄漏）
  ok(/\.cancel\(\)/.test(gateFn),
     '⭐⭐⭐ 闸门的定时器必须 `cancel()`（否则泄漏）');
}

if (invokeFn) {
  // ⑤ ⭐⭐⭐ 超时后必须**换掉卡死的会话**（JSC context 复用 ⇒ 死循环会传染）
  ok(/dropSession/.test(invokeFn),
     '⭐⭐⭐ 超时后必须 `dropSession`（换掉卡死的会话 ⇒ 死循环不传染给后面的 op）');

  // ⑥ ⭐⭐⭐ **卡死线程配额**（老引擎退役 ⇒ 这层保护没了 ⇒ 必须自己补）
  ok(/hasStuckThreadBudget/.test(invokeFn),
     '⭐⭐⭐⭐⭐ 引擎调用前必须检查**卡死线程配额**'
     + '（JSC 没有中断 API ⇒ 死循环线程收不回来 ⇒ 多个叠加 ⇒ 手机发烫 ⇒ iOS 杀 App）');
  ok(/noteStuckThread/.test(invokeFn),
     '⭐⭐⭐⭐⭐ 超时后必须 `noteStuckThread`（记一笔收不回来的线程）');

  // ⑦ ⭐⭐⭐ **熔断**（连续超时 ⇒ 不再无限重试 ⇒ 否则反复烧 CPU ⇒ 又被杀）
  //   ⚠️ 判据必须**精确**：光看 `newEngineFatalTimeoutCount` 出现过不算数
  //   （常量声明处也会出现 ⇒ 变异 `let fatal = false` 会漏过）⇒ 必须看**比较表达式**⭐
  ok(/newEngineTimeouts\s*>=\s*Self\.newEngineFatalTimeoutCount/.test(invokeFn),
     '⭐⭐⭐⭐⭐ 必须有**熔断**（`newEngineTimeouts >= 阈值` ⇒ 连续超时 ⇒ 停止重试'
     + ' ⇒ 否则每次点都烧一轮 CPU ⇒ 又被杀）');
  ok(/if fatal\s*\{/.test(invokeFn) && /newEngineTimeouts\s*=\s*0/.test(invokeFn),
     '⭐⭐⭐⭐⭐ 熔断后必须**重置计数 + 抛错**（不能只是记一笔日志）');
}

// ⑧ ⭐⭐⭐ **配额与熔断的实现必须在文件里**（不能只是引用）
const whole = src;
ok(/static let maxStuckThreads\s*=\s*\d+/.test(whole),
   '⭐⭐⭐ 有 `maxStuckThreads` 配额常量（几��满载线程就熔）');
ok(/func noteStuckThread\(\)/.test(whole), '有 `noteStuckThread()`');
ok(/func hasStuckThreadBudget\(\) -> Bool/.test(whole), '有 `hasStuckThreadBudget()`');
ok(/static let newEngineFatalTimeoutCount\s*=\s*\d+/.test(whole), '有 `newEngineFatalTimeoutCount` 熔断阈值');

// ⑨ ⭐⭐⭐ **变异测试**：把真超时改回 TaskGroup ⇒ ① 必须红
{
  const mutated = timeoutFn.replace(/withRealTimeout/g, 'withRealTimeout')
    .replace(/func withRealTimeout/, 'func withRealTimeout')
    + '\n' + '        let _ = withThrowingTaskGroup(of: Int.self) { $0.addTask { 1 } }';
  const stillHasGroup = /withThrowingTaskGroup/.test(mutated);
  const wouldFail = stillHasGroup && !/withThrowingTaskGroup/.test(timeoutFn);
  ok(wouldFail,
     '⭐⭐⭐⭐⭐ **变异测试**：注入 `withThrowingTaskGroup` 后 ① 的判据必须变红'
     + '（证明这条门禁真能抓到那个致命写法）');
}

console.log(`\n真超时门禁：通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
