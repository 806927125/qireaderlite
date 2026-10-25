#!/usr/bin/env node
/**
 * **ajax 失败必须能被识别、必须能重试** —— 别把「失败」伪装成「成功但为空」
 *
 * 起因（真机 2026-10-21，「详情页时好时坏」）：
 *   站方 `java.ajax(url)` 是**同步**的（`JSON.parse(java.ajax(url))` 到处在用），
 *   老引擎时代轻阅的原生桥是**异步**的 ⇒ 只能「两遍跑」：
 *     第 1 遍只录 URL（返回空串）→ 引擎把 URL 抓回来填进缓存
 *     第 2 遍命中缓存 → 同步返回真正的正文
 *
 * ⚠️⚠️ **原来的 bug**（老引擎的 `fetchRecorded`）：
 *   **ajax 失败时也往缓存里写空串**：
 *       .catch(function (e) { out[u] = ''; ... })
 *   ⇒ 网络抖一下（超时 / 502）⇒ 缓存里躺了个空串
 *   ⇒ 第 2 遍 `java.ajax` **命中了这个空串** ⇒ 返回 ''
 *   ⇒ 而且因为「命中缓存就不录了」⇒ `recorded.length === 0`
 *   ⇒ 判定成「这一遍是真的」⇒ **直接返回空串，不重试**
 *   ⇒ 站方 `JSON.parse('')` 炸 ⇒ 详情页加载失败
 *
 *   ⇒ **一次网络抖动 = 整条详情规则死定** ⭐ 这就是「时好时坏」
 *
 *   修法：**失败/空响应不写缓存** ⇒ 下一遍会重新录、重新请求
 *        ⇒ 两遍跑天然带上了重试能力。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新引擎**没有两遍跑、没有「录制缓存」**（站方 JS 由引擎**同步**执行）
 *   ⇒ 「失败被写成空串缓存」这条路**结构上就不存在**了 ⭐⭐⭐
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「ajax 失败 ⇒ 不能把空串写进缓存 ⇒ 下一遍会**重新请求**（真重试）」
 *   新语义「引擎没有录制缓存 ⇒ **每次 `java.ajax` 都是一次真请求**
 *             ⇒ 失败时站方拿到的是**「失败」**（不是空串）⇒ 站方自己 catch 后再调一次就是真重试」
 *   ⇒ 可观测结果一致：**失败之后再来一次调用 ⇒ 请求数 +1（真发了），且拿到的是真内容** ⭐⭐⭐
 *
 * ⚠️ 假服务器写法变了：老门禁用 JS 层的 `nativeMock`（async mock），
 *    现在是**声明式 routes**（下沉到 transport 层 ⇒ 引擎同步执行时也拦得到）⭐⭐⭐
 */
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 取 Swift 里某个函数的函数体（按 4 空格缩进的收尾大括号切） */
function funcBody(src, marker) {
  const i = src.indexOf(marker);
  if (i < 0) return '';
  const end = src.indexOf('\n    }', i);
  return end < 0 ? '' : src.slice(i, end + 6);
}

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  // ── ① 失败不是「成功但为空」+ 每次调用都真发请求（没有空串缓存）────
  console.log('=== ① ajax 失败 ⇒ 站方能识别出失败（不是空串），且再来一次是真发请求 ===');
  {
    const { win, sandbox } = createSandbox({
      routes: [{ match: 'x.com', status: 502, body: '<html>502</html>' }],
    });
    // 站方视角：第一次失败 ⇒ catch ⇒ 再来一次
    const code = `
var r1 = java.ajax('https://x.com/');
var caught = false;
try { JSON.parse(r1); } catch (e) { caught = true; }
var r2 = java.ajax('https://x.com/');
r1 + '|' + caught + '|' + r2
`;
    const r = String(win.QR.rule.runJs(code, {}));
    const parts = r.split('|');
    console.log('  站方拿到:', JSON.stringify(r.slice(0, 160)));
    console.log('  真实请求:', sandbox.__requests.length);
    ok(sandbox.__requests.length === 2,
       `两次调用 ⇒ 两次**真请求**（实际 ${sandbox.__requests.length} 次）—— 没有「命中空串缓存」那条路`);
    ok(parts.length >= 3 && parts[1] === 'true',
       '站方的 catch 被触发（失败被识别成失败）');
    ok(parts.length >= 1 && parts[0] !== '',
       '失败的返回值不是空串（空串会被站方当成「成功但没内容」）');
    ok(parts.length >= 3 && parts[2] === parts[0],
       '重试拿到的和第一次一样（失败的响应是确定的，不是随机成功）');
  }

  // ── ② 成功 ⇒ 拿到真内容（重试成功时站方能拿到正文）─────────────────
  console.log('\n=== ② 成功时拿到真内容 ===');
  {
    const { win, sandbox } = createSandbox({
      routes: [{ match: 'x.com', status: 200, body: '{"title":"真结果"}' }],
    });
    const r = String(win.QR.rule.runJs('java.ajax("https://x.com/")', {}));
    console.log('  站方拿到:', JSON.stringify(r));
    ok(r === '{"title":"真结果"}',
       `成功时必须拿到真内容（实际: ${JSON.stringify(r).slice(0, 80)}）`);
    ok(sandbox.__requests.length === 1, '一次调用 = 一个请求');
  }

  // ── ③ 老引擎的「失败不污染缓存」实现细节 ⇒ 退休 ────────────────────
  console.log('\n=== ③ 老引擎的录制缓存实现细节 ⇒ 已退休 ===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（`fetchRecorded` / `out[u] = ''`
  //     / `delete out[u]` / `MAX_PASS` 5 轮）⇒ 那些是**实现细节**，不是语义
  //   ⇒ 老引擎退役后**没有等价物**（新引擎是同步的，压根不需要「录制 + 缓存」那套补丁）
  //   ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

  // ── ④ 结构性自证：引擎的 java.ajax 一次调用 = 一个请求 ──────────────
  console.log('\n=== ④ 结构性自证：引擎的 java.ajax 没有引擎级重试 ===');
  {
    // ⭐ 语义等价：老引擎的「重试」靠两遍跑（MAX_PASS 5 轮）；
    //   新引擎的「重试」靠**站方自己再调一次** ⇒ 前提是**引擎一次调用只发一个请求**
    //   ⇒ 否则「请求数 = 站方试了几次」就不成立（会被引擎自己的重试放大）⭐⭐⭐
    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    const body = funcBody(se, 'public func ajax(url: String');
    ok(body.length > 0, '找到新引擎的 java.ajax 实现');
    if (body.length > 0) {
      const fetches = (body.match(/fetcher\.fetch\(/g) || []).length;
      ok(fetches === 1,
         `java.ajax 一次调用只发一个请求（实际 ${fetches} 次 fetch）—— 重试归站方，不归引擎`);
      ok(!/Task\.sleep|withCheckedContinuation|await /.test(body),
         'java.ajax 是**同步**的（没有异步等待 ⇒ 不存在「请求成功了但 JS 已经不等了」的窗口）');
    }
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
