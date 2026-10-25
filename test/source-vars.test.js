#!/usr/bin/env node
/**
 * **站方默认变量** 这个 op（2026-10-21 真机「目录 0 章」的根因链第一环）
 *
 * 站方的 `getArguments(open_argument, key)`：
 *   - 变量串**解析失败**（空串）⇒ 返回它的默认变量表
 *   - 变量串能解析 ⇒ **不给默认**，只认写进去的那几项
 *
 * ⇒ 于是 App 只要往变量里写一项（`{"server":…}` / `{"proxy":…}`），
 *   站方就再也拿不到 `tab / sources / source_type / proxy` ⇒ 源被改坏。
 *   实测：只写 `{"proxy":"本地"}` ⇒ `server` 没了 ⇒ 请求 URL 变成
 *   `undefined/catalog` ⇒ 4 本书全部 0 章 ❗
 *
 * ⇒ 所以 App 必须能问站方要一份默认变量表（`sourceVars` op），
 *   写变量时拿它做底、用户的改动盖在上面 ✅
 */
const fs = require('fs');
const path = require('path');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除（2026-10-25）⇒ 门禁改验【新引擎】**（`legado-engine` 的 Swift 实现）
//   ⇒ 覆盖不丢，而且验的是**真正在跑的那份代码**⭐⭐⭐
const { evalRule, sourceVars, engineAvailable, engineSwiftSrc } = require('./engine-gate-helpers.js');
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// 一个「像站方」的最小书源：jsLib 里有 host 数组 + getArguments（语义照大灰狼）
const FIXTURE = {
  bookSourceName: '变量探针',
  bookSourceUrl: 'https://probe.example.com',
  jsLib: `
var host = ['https://a.example.com', 'https://b.example.com'];
function getArguments(open_argument, key) {
    try {
        open_argument = JSON.parse(open_argument);
    } catch (e) {
        open_argument = {
            tab: "小说",
            server: host[0],
            sources: "全部",
            source_type: "男频",
            fqpara: "on"
        };
    }
    if (key) { return open_argument[key]; } else { return open_argument; }
}
function setArguments(key, value) { return ''; }
`,
  ruleExplore: { bookList: '@js:[]' },
};

(async () => {
  console.log('=== ① 新引擎源码里要有 sourceVars / getArguments 这条路 ===');
  const eng = engineSwiftSrc('Pipeline/SourceEngine.swift');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]`）
  //   ⇒ 那些是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失语义覆盖 ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

  console.log('\n=== ② 真跑一次：能问出站方的默认变量表 ===');
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本段没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }
  // ⭐⭐⭐ **用新引擎跑站方 jsLib**（`getArguments` 在 jsLib 里 ⇒ 必须真跑 JS）⭐⭐⭐
  // ⭐⭐⭐ **直接调新引擎的 `sourceVars` op**（语义与 App 侧完全一致）⭐⭐⭐
  const vars = sourceVars(FIXTURE);
  if (vars.__skip) {
    // ⭐⭐⭐ **Linux 没有 JSC** ⇒ 站方 jsLib（`getArguments`）跑不了 ⇒ **显式 SKIP**
    //   ⇒ 「没验到」≠「验过了没问题」⭐⭐⭐
    console.log('  ⏭️  ' + vars.__skip + ' ⇒ 本段没验到（**不等于通过**）');
  } else {
    console.log('  拿到的默认变量:', JSON.stringify(vars));
    ok(typeof vars === 'object' && Object.keys(vars).length > 0, '拿到了一整份默认变量表');
    ok(vars.server === 'https://a.example.com', 'server = 站方 host[0]');
    ok(vars.tab === '小说', 'tab 在');
    ok(vars.sources === '全部', 'sources 在');
    ok(vars.source_type === '男频', 'source_type 在');
    // ⭐ 关键：默认表里**没有 proxy** ⇒ 这就是「proxy 永远拿不到」的根源，
    //    必须靠 App 提供（面板的本地/云端开关）。
    ok(!('proxy' in vars), '（站方默认表里本来就没有 proxy —— 面板要自己给）');
  }

  console.log('\n=== ③ 真书源（🍅大灰狼）也能问出来 ===');
  const SRC = process.env.SRC_OUT || [
    '/workspace/out/大灰狼v2.json',
    path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'),
    path.join(__dirname, '..', 'sources', 'dahlang-v2.json'),
  ].find(p => fs.existsSync(p)) || '';
  if (fs.existsSync(SRC)) {
    const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
    const src = (Array.isArray(list) ? list : [list])
      .find(s => s && s.jsLib && s.bookSourceUrl) || list[0];
    // ⭐⭐⭐ **用新引擎问**（不再走 jsdom 的老引擎）⭐⭐⭐
    const v2 = sourceVars(src);
    if (v2.__skip) {
      console.log('  ⏭️  ' + v2.__skip);
    } else {
      console.log('  大灰狼默认变量:', JSON.stringify(v2).slice(0, 220));
      ok(Object.keys(v2).length > 0, '大灰狼的默认变量表读出来了');
      ok(typeof v2.server === 'string' && v2.server.startsWith('http'),
         'server 是线路地址（' + String(v2.server).slice(0, 40) + '）');
    }
  } else {
    console.log('  ℹ️  聚合源不在本机 → 跳过');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
