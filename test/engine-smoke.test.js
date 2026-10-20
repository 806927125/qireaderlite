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
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 调一个引擎函数，把「运行时错误」原样抛出来（门禁要看到真错误） */
function call(win, label, fn) {
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

console.log('=== 引擎冒烟：关键入口逐个调一遍 ===');
const { win } = createSandbox({ nativeMock: async () => ({ ok: true, value: '' }) });

// ⚠️ 先把引擎脚本都加载上（g.cookie 是 source-api.js 加载时才装的）
console.log('\n=== 引擎脚本逐个求值（顶层不能抛）===');
const ENGINE = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');
const FILES = fs.readdirSync(ENGINE).filter(f => f.endsWith('.js')).sort();
for (const f of FILES) {
  const code = fs.readFileSync(path.join(ENGINE, f), 'utf8');
  call(win, `加载 ${f}`, () => {
    win.eval(code + '\n;void 0;');
  });
}

// ① cookie 快照安装（**每个 op 开头都跑** → 这里炸 = 全盘皆输）
call(win, 'QR.__qrInstallCookieSnapshot({})', () => {
  win.eval('QR.__qrInstallCookieSnapshot({"example.com":"a=b"});');
});

// ② 脏标记
call(win, 'QR.__qrResetDirty()', () => win.eval('QR.__qrResetDirty();'));
call(win, 'QR.__qrTakeDirty()', () => win.eval('QR.__qrTakeDirty();'));

// ③ cookie 合并 + 删除（**mergedHosts 的两个用法**）
call(win, 'QR.__qrMergeCookie(host, cookie)', () => {
  win.eval('QR.__qrMergeCookie("fanqienovel.com","sessionid=TEST");');
});
call(win, 'cookie.removeCookie(合并回来的域) —— 不该抛', () => {
  win.eval('window.cookie.removeCookie("fanqienovel.com");');
});
call(win, 'cookie.removeCookie(别的域)', () => {
  win.eval('window.cookie.removeCookie("other.example.com");');
});
call(win, 'cookie.getCookie / setCookie / getKey', () => {
  win.eval('window.cookie.setCookie("a.com","x=1");'
    + 'var v = window.cookie.getCookie("a.com");'
    + 'var k = window.cookie.getKey("a.com","x");'
    + 'if (k !== "1") throw new Error("getKey 读不到刚写的值: " + k);');
});

// ④ 暂存区（消息捕获）
call(win, 'QR.__qrHoldBegin / __qrHoldEnd', () => {
  win.eval('var h = QR.__qrHoldBegin();'
    + 'QR.__qrPushMsg ? QR.__qrPushMsg("x","toast") : null;'
    + 'QR.__qrHoldEnd(true);');
});

// ⑤ 同步通道（默认关 → 不能抛，也不该去碰 prompt）
call(win, 'QR.__qrSync（默认关闭 → 返回 null，不抛）', () => {
  win.eval('var r = QR.__qrSync("timeFormat",{input:"0"});'
    + 'if (r !== null && r !== undefined) throw new Error("同步通道默认应该关闭");');
});

// ⑥ java.* 的常用能力
call(win, 'java.timeFormat（兜底路径）', () => {
  win.eval('var s = java.timeFormat("2017-04-24 14:16:34");'
    + 'if (typeof s !== "number" && typeof s !== "string") throw new Error("timeFormat 返回了怪东西: " + typeof s);');
});
call(win, 'java.startBrowserAwait（走录制器，不直连原生）', () => {
  win.eval('var rec = [];'
    + 'QR.__qrAjaxRecord = function (u, kind) { rec.push(kind); return ""; };'
    + 'java.startBrowserAwait("https://x.com/","t");'
    + 'if (rec.length !== 1 || rec[0] !== "browser") throw new Error("没按 browser 录制: " + JSON.stringify(rec));'
    + 'QR.__qrAjaxRecord = undefined;');
});
call(win, 'java.ajax（缓存优先 → 命中缓存直接返回）', () => {
  win.eval('QR.__qrAjaxCache = {"https://y.com/":"CACHED"};'
    + 'var r = java.ajax("https://y.com/");'
    + 'if (r !== "CACHED") throw new Error("缓存没命中: " + r);'
    + 'QR.__qrAjaxCache = undefined;');
});

// ⑦ 引擎调度层在位
call(win, 'window.__qrInvoke 存在', () => {
  const t = win.eval('typeof window.__qrInvoke');
  if (t !== 'function') throw new Error('__qrInvoke 不是函数: ' + t);
});

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
