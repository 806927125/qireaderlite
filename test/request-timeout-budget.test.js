#!/usr/bin/env node
/**
 * **请求超时的预算必须盖得住真实耗时**（2026-10-21 真机实测）
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
 * 根因（老架构，两边超时预算算错）：
 *   · 原生侧 `nativeRequest`：重试 3 次，每次 `per = max(3, timeout/(attempts-i))`
 *     ⇒ **分母递减** ⇒ 总耗时 = timeout×(1/3+1/2+1) ≈ **1.83 × timeout**
 *       （12s ⇒ 4+6+12 = 22s + 0.6s 退避 ≈ **22.6 秒**）
 *   · JS 侧 `rawRequest`：只等 `(__t + 3)` = **15 秒** ⇒ **必然可能先超时** ❗
 *   ⇒ 修：JS 侧等 `__t × 2 + 5`（12s ⇒ 29 秒）⇒ 盖住 22.6 秒 ✅
 *
 * ⚠️ 这个坑是**全局**的：所有走 `java.ajax` / `java.get` 的站方规则都受影响
 *    ⇒ 线路一慢，op 必挂 ⇒ 「时好时坏」的另一半机制。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新引擎**没有「JS 侧等待」这层**了：站方 JS 由**引擎同步执行**
 *   （`java.ajax` → `fetcher.fetch` → 返回正文 ⇒ 同一个调用栈里一气呵成）
 *   ⇒ 「请求成功了但 JS 已经不等了」这个窗口**结构上不存在** ⭐⭐⭐
 *   ⇒ 于是「超时预算」只剩**两处**要管：
 *     ① **单次请求的超时上限**（死线路最多等几秒）
 *     ② **整个 op 的超时预算**（按 op 分档：交互类 / 取内容类）
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「JS 侧等待 ≥ 原生侧最坏耗时 ⇒ 不白跑」
 *   新语义「引擎的 ajax 是同步的 ⇒ 不存在『不等』的窗口；
 *             ＋ 单次请求超时有上限（死线路不干等）；
 *             ＋ op 超时按档位（取内容类给足，站方逐条试 N 条线路是正常的）」
 *   ⇒ 可观测结果一致：**慢线路不会把 op 打成「白跑一次」** ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { engineAvailable } = require('./engine-gate-helpers.js');
const { engineSwiftSrc } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };
const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

/** 取 Swift 里某个函数的函数体（按 4 空格缩进的收尾大括号切） */
function funcBody(src, marker) {
  const i = src.indexOf(marker);
  if (i < 0) return '';
  const end = src.indexOf('\n    }', i);
  return end < 0 ? '' : src.slice(i, end + 6);
}

(async () => {
  console.log('=== ① JS 侧等待时间公式 ⇒ 老引擎的补丁已退休 ===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（`__waitMs` / `(__t + 3) * 1000`
  //     / `__t × 2 + 5` / 原生侧 `attempts = 3` / `timeout/(attempts-i)`）
  //   ⇒ 那些是**实现细节**，不是语义
  //   ⇒ 老引擎退役后**没有等价物**（新引擎是同步的 ⇒ 压根没有「JS 侧等不等」这层补丁）
  //   ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在下面的【真跑段 / 结构性段】**（现在验的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

  console.log('\n=== ② 结构性自证：引擎的 java.ajax 是同步的（没有「JS 侧不等」的窗口）===');
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }
  {
    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    const body = funcBody(se, 'public func ajax(url: String');
    ok(body.length > 0, '找到新引擎的 java.ajax 实现');
    if (body.length > 0) {
      ok(/try fetcher\.fetch\(/.test(body),
         'ajax 直接同步取页面（`try fetcher.fetch(...)`）');
      ok(!/Task\.sleep|withCheckedContinuation|await /.test(body),
         'ajax 里没有异步等待 ⇒ 请求完成前不会返回 ⇒ 不存在「请求成功了但 JS 已经不等了」');
      const fetches = (body.match(/fetcher\.fetch\(/g) || []).length;
      ok(fetches === 1,
         `ajax 一次调用只发一个请求（实际 ${fetches} 次）—— 没有引擎级重试 ⇒ 重试归站方`);
      ok(!/timeout:/.test(body),
         'ajax 不自己传 timeout ⇒ 用传输层的默认上限（见 ③）');
    }
  }

  console.log('\n=== ③ 单次请求的超时上限（死线路不能干等 30 秒）===');
  {
    // ⭐ 语义：站方 catch 循环会**挨条**试线路 ⇒ 每条死线路都要等满超时
    //   ⇒ 单次请求超时太大 ⇒ 8 条线路 = 几分钟 ⇒ 「app 死机」⭐
    //   ⇒ 老架构原生侧是 30 秒 ⇒ 新架构必须**有上限**（8 秒 ⇒ 8 条最坏 64 秒）
    const ht = engineSwiftSrc('Host/HTTPTransport.swift');
    ok(/timeout: TimeInterval = 8/.test(ht),
       '引擎的取页面默认超时 8 秒（不是 30 秒）');
    const app = read('QiReaderLite/Core/LegadoEngineBackend.swift');
    ok(/cfg\.timeoutIntervalForRequest = 8/.test(app),
       'App 的传输层请求超时 8 秒（真机同款）');
    ok(/sem\.wait\(timeout: \.now\(\) \+ request\.timeout \+ 5\)/.test(app),
       '等回调的超时比请求超时多 5 秒（别把「网络慢」误报成「引擎卡死」）');
  }

  console.log('\n=== ④ op 超时按档位（取内容类要盖住「逐条试 N 条线路」）===');
  {
    const svc = read('QiReaderLite/Core/SourceService.swift');
    ok(/func newEngineTimeoutSeconds\(for op: String\) -> Double/.test(svc),
       '有「按 op 分档取超时」这层');
    ok(/case "bookInfo", "toc", "content": return 300/.test(svc),
       '取内容类 op（详情/目录/正文）给 300 秒（8 条线路 × 29 秒是正常的）');
    ok(/default: return 60/.test(svc),
       '交互类 op（发现/搜索/分类）给 60 秒（不是 6 分钟 ⇒ 引擎卡住时用户不用干等）');
    ok(/let budget = Self\.newEngineTimeoutSeconds\(for: op\)/.test(svc),
       '真的用上了这个预算');
  }

  console.log('\n=== ⑤ 超时链路自证（算术）===');
  {
    // 单次请求上限 × 站方最多试的线路数 ⇒ 最坏耗时 ⇒ 必须被 op 预算盖住
    const perRequest = 8;
    // 🍅大灰狼 jsLib 里的线路数（站方 catch 循环挨条试）
    const lines = 8;
    const worst = lines * perRequest;
    // 取内容类 op 的预算（见 ④）
    const contentBudget = 300;
    const interactiveBudget = 60;
    console.log(`  站方逐条试 ${lines} 条死线路 ⇒ 最坏 = ${lines} × ${perRequest}s = ${worst}s`);
    console.log(`  取内容类预算 = ${contentBudget}s / 交互类预算 = ${interactiveBudget}s`);
    ok(worst <= contentBudget,
       `取内容类的 ${contentBudget}s 预算盖得住最坏的 ${worst}s（盖不住 ⇒ 慢但能用的源被误判成失败）`);
    ok(perRequest <= interactiveBudget,
       `交互类的 ${interactiveBudget}s 预算至少盖得住一次请求（${perRequest}s）`);
    // ⚠️ 交互类 60s < 8 条死线路的 64s ⇒ 所以宿主必须**先测速挑一条通的**
    //   （`ensureFastLine` ⇒ 见 test/host-failover.test.js 的 ④）⇒ 这里不重复断言
    console.log('  ℹ️  交互类 60s < 8 条死线路的 64s ⇒ 靠宿主「先测速挑一条通的」兜底');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
