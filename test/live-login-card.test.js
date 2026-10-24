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
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

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

const jar = {};
const toasts = [];
const logs = [];

function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

async function nativeMock(fn, args) {
  switch (fn) {
    case 'request': {
      const url = args.url || '';
      const h = hostOf(url);
      // ★ /user_api 一律返回「已登录」的用户 → 站方会走卡片那条路径
      if (url.indexOf('/user_api') >= 0) {
        return { ok: true, code: 200, url, headers: {}, body: JSON.stringify(USER) };
      }
      return { ok: true, code: 200, url, headers: {}, body: '{}' };
    }
    case 'getCookie': {
      const h = hostOf(args.url || '');
      const c = jar[h] || {};
      return { ok: true, value: Object.entries(c).map(([k, v]) => `${k}=${v}`).join('; ') };
    }
    case 'setCookie': {
      const h = hostOf(args.url || '');
      jar[h] = jar[h] || {};
      for (const part of String(args.cookie || '').split(';')) {
        const kv = part.trim(); const i = kv.indexOf('=');
        if (i > 0) jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim();
      }
      return { ok: true, value: '1' };
    }
    case 'toast': toasts.push(String(args.msg || '')); return { ok: true };
    case 'log': logs.push(String(args.msg || '')); return { ok: true };
    case 'deviceID': return { ok: true, value: 'test-device-id' };
    case 'getString': return { ok: true, value: '' };
    case 'getStringArray': return { ok: true, value: [] };
    default: return { ok: true, value: '' };
  }
}

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  const { win } = createSandbox({ nativeMock });
  const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

  console.log('=== 会员卡片能不能拼出来（用户上报的那条路径）===');
  const probe = await win.eval(`window.__qrInvoke('loginProbe', ${JSON.stringify({
    source, cookieSnapshot: {},
  })})`);

  const all = [...(probe.messages || []), ...toasts, ...logs].join('\n');
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

  // ⚠️ 汇总行必须有：崩了的门禁不产汇总 → 空输出会被当成通过（踩过）
  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
