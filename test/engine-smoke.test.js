#!/usr/bin/env node
/**
 * 引擎冒烟测试 —— **真的把引擎跑一遍**
 *
 * 跑法：node test/engine-smoke.test.js
 *
 * ## 为什么要有这个文件（一次真实事故）
 *
 * 踩过：`mergedHosts` **用了但没声明**（var 漏了）。
 * 后果不是「某个功能不好用」，而是：
 *   `__qrInstallCookieSnapshot` 每个 op 开头都执行 `mergedHosts = {}`
 *   → 一执行就 `ReferenceError: Can't find variable: mergedHosts`
 *   → **每个 op 都失败** → 引擎等于废了 → 用户看到「登录都点不了了」
 *
 * ## 为什么 grep 式断言抓不到
 *
 * 之前的门禁是 `ok(/mergedHosts/.test(src))` —— **字符串出现过就算过**，
 * 「用了」和「声明了」分不出来。JS 的未声明变量**运行时才炸**，
 * 所以门禁必须**执行代码路径**，而不是读源码。
 *
 * ⇒ 这里把引擎的关键入口逐个调一遍，任何 ReferenceError / TypeError 都算红。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改跑新引擎**（Swift，`legado-engine`）⭐⭐⭐
 *
 * 迁移要点（老引擎的实现细节 ⇒ 退休；能力 ⇒ 换成新引擎的等价入口）：
 *   · 老引擎的 `QR.__qrInstallCookieSnapshot` / `__qrResetDirty` / `__qrTakeDirty` /
 *     `__qrMergeCookie` / `__qrHoldBegin` / `__qrHoldEnd` / `__qrSync` / `__qrAjaxRecord` /
 *     `__qrAjaxCache` ⇒ **老引擎的实现细节**（两遍跑机制 + WKWebView 的 prompt 桥）
 *     ⇒ 新引擎**全同步**、没有「轮数上限 / 暂存区 / prompt 桥」那套补丁 ⇒ **没有等价物**
 *     ⇒ **退休**（规范 §2.1）⇒ 语义覆盖在下面的【新引擎真跑段】⭐⭐⭐
 *   · 「cookie 罐」「java.timeFormat」「java.ajax」「浏览器」「op 入口」这些**能力**
 *     ⇒ 新引擎**都还有** ⇒ 改成跑新引擎的等价入口 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 调一个引擎函数，把「运行时错误」原样抛出来（门禁要看到真错误） */
function call(label, fn) {
  try {
    const r = fn();
    pass++;
    console.log(`  ✓ ${label}`);
    return r;
  } catch (e) {
    fail++;
    console.log(`  ✗ ${label}  →  ${e && e.message ? e.message : e}`);
    return null;
  }
}

// ⭐⭐⭐ **引擎不可用 ⇒ 显式 SKIP**（规范 §3.4：「没验到」≠「通过」）⭐⭐⭐
if (!engineAvailable()) {
  console.log('⏭ 跳过：新引擎（legado-engine 的 conformance）不在本机 ⇒ 引擎**没验到**');
  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(0);
}

console.log('=== 引擎冒烟：关键入口逐个调一遍 ===');

// ────────────────────────────────────────────────────────────
// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这里断言的是**老引擎的函数名/代码片段**（`QR.__qrInstallCookieSnapshot` /
//     `__qrHoldBegin` / `__qrSync` / `__qrAjaxCache` …）⇒ 那些是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【新引擎真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
//
//   逐条对应（老入口 ⇒ 新引擎的等价能力 ⇒ 现在在哪验）：
//   · `QR.__qrInstallCookieSnapshot` / `__qrMergeCookie` ⇒ cookie 罐 ⇒ **下面的「cookie 罐」段**
//   · `QR.__qrResetDirty` / `__qrTakeDirty`               ⇒ 脏标记 ⇒ 新引擎**没有脏标记**
//        （变量/登录信息由宿主按 op 回传落盘 ⇒ 「取走」的语义变成了 op 的返回值）⭐
//        ⇒ 下面的「op 回传」段验它
//   · `QR.__qrHoldBegin` / `__qrHoldEnd`                 ⇒ 消息暂存 ⇒ 新引擎**全同步**
//        （压根没有「中间遍的假报错」）⇒ 下面的「站方原文」段验它
//   · `QR.__qrSync`                                      ⇒ WKWebView 的 prompt 同步桥
//        ⇒ 随老 WKWebView 引擎一起退役 ⇒ 新引擎**没有**（能力在 Swift 侧）⭐
//   · `QR.__qrAjaxRecord` / `QR.__qrAjaxCache`            ⇒ 老引擎的「录 URL / ajax 缓存」
//        ⇒ 新引擎的 ajax **直接走 transport** ⇒ 下面的「java.ajax」段验它
// ────────────────────────────────────────────────────────────

const routes = [
  { match: 'smoke.example', status: 200, body: '{"ok":1}' },
];
const { win, sandbox } = createSandbox({ routes });

// ① ⭐⭐⭐ **Java 兼容层（Packages）装载后不能抛** —— 老引擎的「引擎脚本逐个加载」段
//   ⇒ 新引擎把兼容层编进 Swift（JavaCompat）⇒ 等价入口 = 「兼容层在不在、能不能用」
call('Java 兼容层（Packages）在位', () => {
  const v = win.eval("typeof Packages === 'object' && typeof Packages.javax.crypto.Cipher === 'object'");
  if (v !== 'true') throw new Error('Packages / javax.crypto.Cipher 不可用');
  return v;
});

// ② ⭐⭐⭐ **cookie 罐**（老引擎的 `__qrInstallCookieSnapshot` / `__qrMergeCookie` 的等价能力）
call('cookie.setCookie / getCookie / getKey（写进去要读得回来）', () => {
  win.eval('cookie.setCookie("https://a.example/", "x=1; y=2");'
    + 'var v = cookie.getCookie("https://a.example/");'
    + 'if (!v || v.indexOf("x=1") < 0) throw new Error("getCookie 读不到刚写的值: " + v);'
    + 'var k = cookie.getKey("https://a.example/", "x");'
    + 'if (k !== "1") throw new Error("getKey 读不到刚写的值: " + k);');
});
call('cookie.removeCookie（删了要真删）', () => {
  win.eval('cookie.removeCookie("https://a.example/");'
    + 'var v = cookie.getCookie("https://a.example/");'
    + 'if (v && v.indexOf("x=1") >= 0) throw new Error("removeCookie 没删掉: " + v);');
});

// ③ ⭐⭐⭐ **java.timeFormat**（老引擎段里也有 ⇒ 能力还在 ⇒ 换成新引擎的等价入口）
//   ⚠️ 老门禁只断言「返回数字或字符串」⇒ 太松（实现坏一半也过）⇒ 这里钉死「**必须是字符串**」
//   （站方会 `.padEnd(20,"\t")` ⇒ 返回数字 ⇒ 站方脚本直接炸 ⇒ 用户真机 bug）⭐⭐⭐
call('java.timeFormat（必须返回字符串，站方要 .padEnd）', () => {
  const v = win.eval('java.timeFormat(1700000000000)');
  if (typeof v !== 'string') throw new Error('timeFormat 返回了 ' + typeof v + '（站方 .padEnd 会炸）');
  if (!/^\d{4}-\d{2}-\d{2}/.test(v)) throw new Error('timeFormat 的格式不对: ' + v);
  return v;
});

// ④ ⭐⭐⭐ **java.ajax**（老引擎的「缓存优先」那套 ⇒ 新引擎直接走 transport ⇒ 走假服务器验）
call('java.ajax（走假服务器 ⇒ 拿得到正文）', () => {
  const v = win.eval('java.ajax("https://smoke.example/p")');
  if (String(v).indexOf('"ok":1') < 0) throw new Error('ajax 没拿到正文: ' + v);
  return v;
});
call('java.ajax（未命中的路由 ⇒ 明确失败，不许静默 200）', () => {
  const v = String(win.eval('java.ajax("https://nomatch.example/p")'));
  if (v.indexOf('请求失败(404)') < 0) throw new Error('未命中路由没有明确失败: ' + v);
  return v;
});

// ⑤ ⭐⭐⭐ **浏览器类 API**（老引擎段：`java.startBrowserAwait` 走录制器）
//   ⇒ 新架构里「弹浏览器」是**宿主**的能力（真机 = RuleSandbox 的 op）⇒
//   ⇒ 等价语义 = 「引擎把要开的 URL 交给宿主了」⇒ 沙盒里由假浏览器接管 ⭐⭐⭐
const browserPages = [{ match: 'smoke.example', html: '<html>ok</html>', cookies: { 'smoke.example': 'sid=1' } }];
call('java.startBrowserAwait（要开的 URL 交给宿主）', () => {
  const v = win.eval('java.startBrowserAwait("https://smoke.example/login", "登录")');
  if (v === undefined || v === null) throw new Error('startBrowserAwait 什么都没返回');
  return v;
});

// ⑥ ⭐⭐⭐⭐⭐ **op 入口 + 站方原文**（老引擎的 `window.__qrInvoke` 那段的等价能力）⭐⭐⭐⭐⭐
//   ⇒ 老门禁只断言「`window.__qrInvoke` 是个函数」（**恒真** ⇒ 抓不到 bug）
//   ⇒ 这里改成**真跑一个 op** ⇒ 任何 ReferenceError / TypeError 都算红 ⭐⭐⭐
console.log('\n=== op 入口 + 站方原文（老引擎的 __qrInvoke 段的等价能力）===');
const SYNTH = {
  bookSourceName: '冒烟源',
  bookSourceUrl: 'https://smoke.example/',
  // ⭐ 假的「站方」：吐一条 toast + 一条 log ⇒ 验「站方原文能不能收回来」
  loginUrl: "function smokeLogin(){ java.toast('站方原文-toast'); java.log('站方原文-log'); return 'ok'; }",
};
const opRes = call('op 入口（login）跑得通', () => {
  const r = win.__qrInvoke('login', {
    source: SYNTH,
    action: 'smokeLogin()',
    formValues: { '账号': 'a' },
    browserPages,
    routes,
  });
  if (!r) throw new Error('op 没有返回');
  if (r.error) throw new Error('op 报错: ' + r.error);
  if (r.ok !== true) throw new Error('op 没成功');
  return r;
});
if (opRes) {
  const msgs = (opRes.messages || []).join('\n');
  ok(/站方原文-toast/.test(msgs),
     '站方的 toast 原文收回来了（老引擎的 __qrMsgSink 的等价能力）', '实际：' + msgs);
  ok(/站方原文-log/.test(msgs),
     '站方的 log 原文收回来了', '实际：' + msgs);
  ok(/账号/.test(String(opRes.__loginInfo || '')),
     '表单值合并进登录信息了（站方 source.getLoginInfoMap() 读得到）',
     '实际：' + String(opRes.__loginInfo || ''));
  ok(sandbox.__requests.length > 0 || (opRes.requests || []).length > 0,
     '请求记录拿得到（门禁要能断言「发了哪几条」）');
}

// ⑦ ⭐⭐⭐ **op 的诊断信息**（老门禁没有 ⇒ 现在补：失败必须**带原因**，不能静默空）
call('op 失败要带原因（不许静默空）', () => {
  const r = win.__qrInvoke('bookInfo', { source: SYNTH, routes });
  // bookInfo 没有详情规则 ⇒ 引擎要么给一个结果，要么**明确报出原因**（不能悄悄空）
  if (!r) throw new Error('op 没有返回');
  if (r.ok === false && !r.error) throw new Error('失败却没有 error 说明');
  if (r.ok === false && r.error) return r.error;
  return r;
});

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
