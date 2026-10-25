#!/usr/bin/env node
/**
 * **全局态治理：切书源不能串台**（2026-10-22 用户反馈）
 *
 * 跑法：node test/global-isolation.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 起因（用户原话）：「我感觉用了大灰狼别的书源加载就有问题了，是不是污染别的书源了」
 *
 * 事实链（老架构）：
 *   ① 引擎是**单例 WKWebView**（`RuleSandbox.shared`）⇒ 全 App 生命周期一个
 *   ② jsLib 用**间接 eval** 加载 ⇒ `var` / `function` **全部进全局作用域**
 *      （`new Function('__code','return (0, eval)(__code);')`）
 *   ③ 以前**没有任何清理机制** ⇒ 大灰狼的 `host` / `getArguments` /
 *      `getFanqieCookie` / `createFilter` … 永远留在全局
 *   ⇒ 别的书源一用同名标识符就串 ⭐
 *   （栖阅有 `restoreMutatedBaseGlobals` / `purgeUnexpectedGlobals` 防这个，轻阅以前没有）
 *
 * 老架构的修法：
 *   ① 载入 jsLib 时记下「**本次新增**的全局」⇒ 切书源时删掉
 *   ② 换线用的线路列表 `QR.__qrStationHosts` **按书源隔离**（不再读全局 `host`）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新架构**不是**「一个大全局 + 切源时清理」，而是**每个书源一个会话**
 *   （`LegadoEngineBackend.sessions[source.bookSourceUrl]` ⇒ 一个源一个
 *     `SourceEngine` ⇒ 一个 JS 上下文 ⇒ 站方 jsLib 的全局**天然按源隔离**）⭐⭐⭐
 *   ⇒ 「切源要清掉上一个源的全局」这件事**结构上就不会发生**了
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「切源 ⇒ 上一个源的全局被清掉 ⇒ 不串台」
 *   新语义「**每个源一个会话（一个 JS 上下文）** ⇒ A 的全局只在 A 的会话里
 *             ⇒ B 的会话里**根本看不到** A 的全局 ⇒ 天然不串台；
 *             ＋ 切回 A 时 A 的会话被**复用** ⇒ A 的全局还在（不用重新加载 jsLib）」
 *   ⇒ 可观测结果一致：**站方 jsLib 定义的全局，在自己那个源的会话里可见、
 *     在别的源的会话里不可见** ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const JSLIB_A = `
var host = ['https://a.example.com', 'https://a2.example.com'];
function getArgumentsOfA(x) { return 'A' + x; }
var myGlobalMarkerA = 'marker-A';
`;

const JSLIB_B = `
var host = ['https://b.example.com'];
function getArgumentsOfB(x) { return 'B' + x; }
var myGlobalMarkerB = 'marker-B';
`;

/**
 * ⭐ 探测「当前会话里的全局长什么样」
 *
 * 做法：让引擎跑一条 **JS 分类规则**（`exploreUrl` 是 `@js:`），
 *   规则里读站方 jsLib 定义的全局 ⇒ 把读到的值塞进分类标题 ⇒ 回传给我 ⭐⭐⭐
 *   ⇒ 验的是**引擎真跑站方 JS**（不是复述实现）
 */
function probeGlobals(sandbox, jsLib, expr) {
  const { win } = sandbox;
  const res = win.__qrInvoke('exploreKinds', {
    routes: [{ match: '/probe', status: 200, body: 'ok' }],
    jsLib,
    source: {
      bookSourceUrl: 'https://source.example.com',
      bookSourceName: 'src',
      exploreUrl: '@js: JSON.stringify([{title: ' + expr + ', url: "https://source.example.com/probe"}])',
    },
  });
  const kinds = (res && res.kinds) || [];
  return kinds.length ? String(kinds[0].title) : ('ERR:' + JSON.stringify(res));
}

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  console.log('=== ① 载入 A ⇒ A 的站方全局都在（jsLib 的 var/function 落到了全局作用域）===');
  {
    const sb = createSandbox({ routes: [] });
    const got = probeGlobals(sb, JSLIB_A,
      'host.length + "|" + myGlobalMarkerA + "|" + getArgumentsOfA(1)');
    console.log('  探针:', got);
    ok(got === '2|marker-A|A1',
       `A 的全局都在（host 两条 / marker / 函数）—— 实际 ${got}`);
  }

  console.log('\n=== ② 切到 B ⇒ B 的会话里看不到 A 的全局（不串台）===');
  {
    const sb = createSandbox({ routes: [] });
    const got = probeGlobals(sb, JSLIB_B,
      'host.length + "|" + myGlobalMarkerB + "|" + getArgumentsOfB(1)'
      + ' + "|" + (typeof myGlobalMarkerA) + "|" + (typeof getArgumentsOfA)');
    console.log('  探针:', got);
    ok(got === '1|marker-B|B1|undefined|undefined',
       `B 的会话里只有 B 的全局，A 的全局**不存在**（实际 ${got}）`);
  }

  console.log('\n=== ③ 线路列表（换线用的 host[]）按书源隔离 ===');
  {
    const sb = createSandbox({ routes: [] });
    const a = probeGlobals(sb, JSLIB_A, 'host.join(",")');
    const b = probeGlobals(sb, JSLIB_B, 'host.join(",")');
    console.log('  A 的线路:', a, ' / B 的线路:', b);
    ok(a === 'https://a.example.com,https://a2.example.com',
       `A 的会话里线路 = A 的两条（实际 ${a}）`);
    ok(b === 'https://b.example.com',
       `B 的会话里线路 = B 的一条（实际 ${b}）—— 不吃上一个源的线路`);
  }

  console.log('\n=== ④ 结构性自证：隔离是「每个源一个会话」做出来的 ===');
  {
    const app = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
    ok(/private var sessions: \[String: Session\] = \[:\]/.test(app),
       '有「按源缓存的会话表」（⇒ 每个源一个引擎 = 一个 JS 上下文）');
    ok(/let key = source\.bookSourceUrl/.test(app),
       '会话的 key 是**书源 URL**（⇒ 换源 = 换会话 = 换上下文）');
    ok(/let s = try Session\(source: engineSource, jar: jar, jsLib: source\.jsLib\)/.test(app),
       '每个会话带**自己的 jsLib**（⇒ 站方全局按源隔离）');
    ok(/if let s = sessions\[key\] \{ lock\.unlock\(\); return s \}/.test(app),
       '会话会被**复用**（切回 A 时 A 的全局还在，不用重新加载 jsLib）');
    ok(/case "sourceHosts": out = \["hosts": try engine\.sourceHosts\(\)\]/.test(app),
       '线路列表走的是**当次源**的会话（不是全局共享的那份）');

    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    ok(/_ = try js\.runGlobal\(code, context: ctx\)/.test(se),
       'jsLib 走 runGlobal（间接 eval ⇒ 站方的 var/function 落进全局作用域）');
    ok(/js\.markGlobalsAsBaseline\(\)/.test(se),
       '加载完重设全局基线（⇒ 站方定义的全局不会被「清全局」误删）');
    ok(/public func sourceHosts\(\) throws -> \[String\]/.test(se),
       '引擎有 sourceHosts（站方的线路列表）');
    ok(/typeof host !== 'undefined'/.test(se),
       "sourceHosts 读的是**会话里**的全局 host（⇒ 哪个会话就是哪份线路）");
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
