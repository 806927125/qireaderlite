#!/usr/bin/env node
/**
 * **会员卡片回归测试** —— 用户真机上报的 bug 的精确复现。
 *
 * 跑法：node test/live-login-card.test.js
 *
 * 用户看到的（build153）：
 *     检测登录失败
 *     java.timeFormat(res.register_time*1000).padEnd is not a function.
 *
 * 根因：站方拼会员卡片时用 `java.timeFormat(ms).padEnd(20,"\t")`，
 *      而轻阅的 java.timeFormat 返回的是**数字**（epoch 毫秒）→ `.padEnd` 不存在 → 抛错。
 *      卡片拼不出来 → 站方 catch → 报「检测登录失败」→ **用户以为没登录，其实登录是好的**。
 *
 * 本测试**mock 一个已登录的 /user_api 响应**，把卡片那条路径真跑一遍：
 *   卡片能拼出来 → 昵称/邮箱/密钥/注册时间/会员状态/封禁状态 都在
 *   拼不出来     → 报红（回归了）
 *
 * ⚠️ 必须 mock 成已登录：未登录时 `res.id == undefined` → 站方直接抛错 → 卡片那段根本不跑，
 *    测不到东西（这是「测试用例跟架构无关」的要求 —— 直接掏空入口再验）。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改跑新引擎**（Swift，`legado-engine`）⭐⭐⭐
 *
 * 迁移要点：
 *   ① 假服务器从老的 JS 层 `nativeMock` ⇒ 改成**声明式 routes**（规范 §1.1）
 *   ② 请求记录从 `sandbox.__requests` 取（规范 §1.1）
 *   ③ 站方原文（toast/log）从 op 的 `messages` 里取 —— 新引擎的 `loginProbe` op 会把
 *      站方 `java.toast` / `java.log` 的原文收回来（老引擎的 `QR.__qrMsgSink` 同款）⭐
 *   ④ 引擎不可用 ⇒ **显式 SKIP 并说明**（规范 §3.4 ⇒ 不许假绿）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

// ⭐⭐⭐ **不许「跳过」**（2026-10-24 真机教训）
//   跳过 = 这条链路**一次都没被验过** ⇒ 真机炸了沙盒还全绿 ⭐⭐⭐
//   ⇒ 回退到**仓库里的源文件副本** ⇒ 干净克隆也能跑 ⇒ 门禁永远在跑 ⭐
const CANDIDATES = [
  process.env.SRC_OUT,
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json',
  path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'),
  path.join(__dirname, '..', 'sources', 'dahlang-v2.json'),
].filter(Boolean);
const SRC = CANDIDATES.find(p => fs.existsSync(p));
if (!SRC) {
  console.log('❌ 找不到大灰狼源文件（连仓库副本都没有）⇒ 门禁必须失败，不许跳过');
  process.exit(1);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.loginUrl) || list[0];

// ── mock 的「已登录」用户（字段跟站方 checkStatus 用的一致）──
const NOW = Math.floor(Date.now() / 1000);
const USER = {
  id: 6044,
  nickname: '流云',
  email: 'tester@example.com',
  user_key: 'Q8eB0000UqhV0000',
  register_time: NOW - 86400 * 30,
  last_read_time: NOW - 3600,
  day_read_count: 12,
  all_read_count: 3456,
  device: JSON.stringify({ a: 1, b: 2 }),
  is_banned: 0,
  vip_end_time: NOW + 86400 * 200,
  vip_level: 2,
};

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐ **引擎不可用 ⇒ 显式 SKIP**（规范 §3.4：「没验到」≠「通过」）⭐⭐⭐
if (!engineAvailable()) {
  console.log('⏭ 跳过：新引擎（legado-engine 的 conformance）不在本机 ⇒ 这条链路**没验到**');
  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(0);
}

console.log('=== 会员卡片能不能拼出来（用户上报的那条路径）===');

// ── ⭐⭐⭐ **假服务器（声明式 routes）** —— 老门禁的 JS 层 `nativeMock` 已退役 ⭐⭐⭐
//   `/user_api` 一律返回「已登录」的用户 ⇒ 站方会走卡片那条路径
const routes = [
  { match: '/user_api', status: 200, body: JSON.stringify(USER) },
];

const { win, sandbox } = createSandbox({ routes });
const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

// ⭐⭐⭐ **新引擎的 `loginProbe` op**（老引擎的 `loginProbe` 同款）
//   ⇒ 它跑站方自己的 `checkStatus()`（会员卡片走 `java.log` + `java.longToast`）
//   ⇒ 并把站方原文收回来（`messages`）⭐
const probe = win.__qrInvoke('loginProbe', {
  source,
  jsLib: src.jsLib,          // ⭐ 站方的 jsLib（`getArgument` / `host` 等都在里面）
  cookieSnapshot: {},
  routes,
});

if (!probe || probe.error) {
  console.log('  ✗ loginProbe op 失败：' + ((probe && probe.error) || '(无返回)'));
  fail++;
}

const all = [...((probe && probe.messages) || [])].join('\n');
console.log('  --- 引擎收到的内容 ---');
for (const line of all.split('\n')) {
  if (line.trim()) console.log('    | ' + line);
}

// ① 不能再有 timeFormat 的 padEnd 报错
ok(!/padEnd is not a function/.test(all),
   '没有「padEnd is not a function」（java.timeFormat 现在返回字符串了）');
ok(!/java\.timeFormat[^)]*\)\.slice is not a function/.test(all),
   '没有「.slice is not a function」');
// ② 卡片内容要出来
ok(/流云/.test(all), '昵称出来了');
ok(/注册时间/.test(all), '注册时间那行出来了');
ok(/会员状态/.test(all), '会员状态那行出来了');
ok(/封禁状态/.test(all), '封禁状态那行出来了');
ok(/正常/.test(all), '封禁状态是「正常」');
// ③ 注册时间要被格式化成 yyyy-MM-dd（不是 13 位数字）
const regLine = all.split('\n').find(l => l.indexOf('注册时间') >= 0) || '';
ok(/\d{4}-\d{2}-\d{2}/.test(regLine),
   '注册时间被格式化成 yyyy-MM-dd → ' + regLine.trim());
// ④ 不能报「检测登录失败」
ok(!/检测登录失败/.test(all), '没有「检测登录失败」（已登录却报失败 = 误报）');

// ⑤ ⭐⭐⭐ **请求真的发出去了**（老门禁没这条 ⇒ 现在补上）
//   ⇒ 站方的 checkStatus 打的是 `{server}/user_api` ⇒ 请求记录里必须有它
//   ⇒ 语义等价：老门禁用 JS 层 mock 记 URL；新引擎把记录放在 `sandbox.__requests`（规范 §1.1）⭐
const reqs = sandbox.__requests.map(String);
ok(reqs.some(u => u.indexOf('/user_api') >= 0),
   '站方的 /user_api 请求真的发出去了（没发 = 卡片那段根本没跑到）',
   '实际请求：' + JSON.stringify(reqs));
// ⑥ ⭐⭐⭐ **服务器地址解析出来了**（原生侧要拿它独立验证 ⇒ 老门禁的老引擎 loginProbe 也给）
ok(typeof (probe && probe.baseUrl) === 'string' && probe.baseUrl.length > 0,
   'loginProbe 解析出了服务器地址（原生侧要拿它独立打 /user_api）',
   '实际：' + JSON.stringify(probe && probe.baseUrl));
// ⑦ ⭐⭐⭐ **站方的自检真的跑了**（不是「源方没有 checkStatus」的空跑）
ok(probe && probe.stationCheck === true,
   '站方的 checkStatus 跑成了（stationCheck=true）');

// ⚠️ 汇总行必须有：崩了的门禁不产汇总 → 空输出会被当成通过（踩过）
console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
