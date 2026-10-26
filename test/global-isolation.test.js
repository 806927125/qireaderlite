#!/usr/bin/env node
/**
 * **全局态治理：切书源要清掉上一个源的全局**（2026-10-22 用户反馈）
 *
 * 跑法：node test/global-isolation.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 起因（用户原话）：「我感觉用了大灰狼别的书源加载就有问题了，是不是污染别的书源了」
 *
 * 事实链：
 *   ① 引擎是**单例 WKWebView**（`RuleSandbox.shared`）⇒ 全 App 生命周期一个
 *   ② jsLib 用**间接 eval** 加载 ⇒ `var` / `function` **全部进全局作用域**
 *      （`new Function('__code','return (0, eval)(__code);')`）
 *   ③ 以前**没有任何清理机制** ⇒ 大灰狼的 `host` / `getArguments` /
 *      `getFanqieCookie` / `createFilter` … 永远留在全局
 *   ⇒ 别的书源一用同名标识符就串 ⭐
 *   （栖阅有 `restoreMutatedBaseGlobals` / `purgeUnexpectedGlobals` 防这个，轻阅以前没有）
 *
 * 修法：
 *   ① 载入 jsLib 时记下「**本次新增**的全局」⇒ 切书源时删掉
 *   ② 换线用的线路列表 `QR.__qrStationHosts` **按书源隔离**（不再读全局 `host`）
 */
const { createSandbox } = require('./harness');

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

function srcWith(jsLib, url) {
  return {
    bookSourceUrl: url,
    bookSourceName: url,
    jsLib,
    // 站方 exploreUrl 用最简的静态 JSON 数组（不走 JS 也能测到全局切换）
    exploreUrl: JSON.stringify([{ title: '分类一', url: 'https://x.example.com/c1' }]),
  };
}

(async () => {
  const { win } = createSandbox({ nativeMock: async () => ({ ok: true, value: '' }) });

  console.log('=== ① 载入 A ⇒ A 的全局都在 ===');
  await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
    source: srcWith(JSLIB_A, 'https://source-a.example.com'),
  })})`);
  const afterA = await win.eval(`JSON.stringify({
    host: typeof host !== 'undefined' ? host : null,
    fnA: typeof getArgumentsOfA !== 'undefined' ? getArgumentsOfA(1) : null,
    markerA: typeof myGlobalMarkerA !== 'undefined' ? myGlobalMarkerA : null,
    stationHosts: (window.QR && window.QR.__qrStationHosts) || null
  })`);
  const a = JSON.parse(afterA);
  console.log('  ', afterA);
  ok(a.host && a.host.length === 2, 'A 的 host 在全局里');
  ok(a.fnA === 'A1', 'A 的函数在全局里');
  ok(a.markerA === 'marker-A', 'A 的变量在全局里');
  ok(Array.isArray(a.stationHosts) && a.stationHosts.length === 2,
     `换线用的线路列表 = A 的两条（实际 ${JSON.stringify(a.stationHosts)}）`);

  console.log('\n=== ② 切到 B ⇒ A 的全局必须被清掉 ===');
  await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
    source: srcWith(JSLIB_B, 'https://source-b.example.com'),
  })})`);
  const afterB = await win.eval(`JSON.stringify({
    fnA: typeof getArgumentsOfA !== 'undefined' ? getArgumentsOfA(1) : null,
    markerA: typeof myGlobalMarkerA !== 'undefined' ? myGlobalMarkerA : null,
    fnB: typeof getArgumentsOfB !== 'undefined' ? getArgumentsOfB(1) : null,
    markerB: typeof myGlobalMarkerB !== 'undefined' ? myGlobalMarkerB : null,
    host: typeof host !== 'undefined' ? host : null,
    stationHosts: (window.QR && window.QR.__qrStationHosts) || null
  })`);
  const b = JSON.parse(afterB);
  console.log('  ', afterB);
  ok(b.fnA === null, 'A 的函数被清掉了（否则会串台）');
  ok(b.markerA === null, 'A 的变量被清掉了');
  ok(b.fnB === 'B1', 'B 的函数在');
  ok(b.markerB === 'marker-B', 'B 的变量在');
  ok(b.host && b.host.length === 1 && b.host[0] === 'https://b.example.com',
     '全局 host 现在是 B 的（B 覆盖了 A，正常）');
  ok(Array.isArray(b.stationHosts) && b.stationHosts.length === 1 &&
     b.stationHosts[0] === 'https://b.example.com',
     `换线用的线路列表**只认当次书源**（实际 ${JSON.stringify(b.stationHosts)}）`);

  console.log('\n=== ③ 切回 A ⇒ A 的 jsLib 重新加载（不能因为被清过就失效）===');
  await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
    source: srcWith(JSLIB_A, 'https://source-a.example.com'),
  })})`);
  const backA = JSON.parse(await win.eval(`JSON.stringify({
    fnA: typeof getArgumentsOfA !== 'undefined' ? getArgumentsOfA(1) : null,
    markerA: typeof myGlobalMarkerA !== 'undefined' ? myGlobalMarkerA : null,
    stationHosts: (window.QR && window.QR.__qrStationHosts) || null
  })`));
  console.log('  ', JSON.stringify(backA));
  ok(backA.fnA === 'A1', 'A 的函数重新可用（jsLib 会重新加载）');
  ok(backA.markerA === 'marker-A', 'A 的变量重新可用');
  ok(Array.isArray(backA.stationHosts) && backA.stationHosts.length === 2,
     '换线线路列表回到 A 的两条');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
