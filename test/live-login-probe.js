#!/usr/bin/env node
/**
 * 登录检测的**真机联调**：拿真的大灰狼聚合源，打真的服务器。
 *
 * 跑法：node test/live-login-probe.js
 *
 * 干两件事：
 *   ① 跑引擎的 loginProbe op → 看服务器地址解析对不对、站方 checkStatus 的原文收没收回来
 *   ② 跑引擎的 login op（不带密码）→ 看站方的报错原文有没有被收回来
 *
 * ⚠️ 这里**不登录**（没有账号密码）→ 预期结果是「未登录」。
 *    这恰恰是最有价值的用例：
 *    「未登录」必须报成未登录，不能报成「已登录」或者「执行完成」。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const SRC = process.env.SRC_OUT || [
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json',
  path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'),
  path.join(__dirname, '..', 'sources', 'dahlang-v2.json'),
].find(p => fs.existsSync(p)) || '';
if (!fs.existsSync(SRC)) {
  console.log('ℹ️  适配版聚合源不在本机 → 跳过');
  process.exit(0);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.loginUrl) || list[0];

// ── 原生 mock：真发 HTTP + 真的 cookie 罐 ──
const jar = {};          // host → { name: value }
const toasts = [];
const logs = [];

function hostOf(u) {
  try { return new URL(u).host; } catch (e) { return ''; }
}

async function nativeMock(fn, args) {
  switch (fn) {
    case 'request': {
      const url = args.url || '';
      const method = (args.method || 'GET').toUpperCase();
      const headers = Object.assign({}, args.headers || {});
      const h = hostOf(url);
      // 把 cookie 罐里的东西带上（模拟 WKWebView 的 cookie 行为）
      if (!headers.cookie && jar[h]) {
        headers.cookie = Object.entries(jar[h]).map(([k, v]) => `${k}=${v}`).join('; ');
      }
      if (!headers['User-Agent']) {
        headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 ' +
          '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';
      }
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 12000);
      try {
        const res = await fetch(url, {
          method, headers,
          body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
          signal: ctl.signal, redirect: 'follow',
        });
        const text = await res.text();
        // 存 cookie（set-cookie）
        const sc = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
        for (const line of sc) {
          const kv = line.split(';')[0];
          const i = kv.indexOf('=');
          if (i > 0) {
            const nm = kv.slice(0, i).trim(), vv = kv.slice(i + 1).trim();
            jar[h] = jar[h] || {};
            jar[h][nm] = vv;
          }
        }
        return { ok: true, code: res.status, url: res.url, headers: {}, body: text };
      } catch (e) {
        return { ok: false, error: String(e && e.message || e) };
      } finally {
        clearTimeout(timer);
      }
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
        const kv = part.trim();
        const i = kv.indexOf('=');
        if (i > 0) jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim();
      }
      return { ok: true, value: '1' };
    }
    case 'toast':
      toasts.push(String(args.msg || ''));
      return { ok: true };
    case 'log':
      logs.push(String(args.msg || ''));
      return { ok: true };
    case 'deviceID':
      return { ok: true, value: 'test-device-id' };
    case 'getString':
      return { ok: true, value: '' };
    case 'getStringArray':
      return { ok: true, value: [] };
    default:
      return { ok: true, value: '' };
  }
}

function cookieSnapshot() {
  const out = {};
  for (const [h, c] of Object.entries(jar)) {
    out[h] = Object.entries(c).map(([k, v]) => `${k}=${v}`).join('; ');
  }
  return out;
}

(async () => {
  const { win } = createSandbox({ nativeMock });
  const source = Object.assign({}, src, {
    __variables: '',
    __loginInfo: {},
  });

  console.log('=== ① loginProbe（检测登录状态）===');
  const probe = await win.eval(`window.__qrInvoke('loginProbe', ${JSON.stringify({
    source, cookieSnapshot: cookieSnapshot(),
  })})`);
  console.log('  baseUrl     :', probe.baseUrl);
  console.log('  stationCheck:', probe.stationCheck);
  console.log('  messages    :');
  for (const m of (probe.messages || [])) console.log('    | ' + m);
  console.log('  引擎收到的 toast:');
  for (const t of toasts) console.log('    | ' + t.split('\n').filter(Boolean).join(' / '));
  console.log('  引擎收到的 log  :');
  for (const l of logs) console.log('    | ' + l.split('\n').filter(Boolean).join(' / '));

  console.log('\n=== ② login op（站方报错能不能被收回来）===');
  toasts.length = 0; logs.length = 0;
  const login = await win.eval(`window.__qrInvoke('login', ${JSON.stringify({
    source, cookieSnapshot: cookieSnapshot(),
    action: 'login(true)',
    formValues: { '邮箱': '', '密码': '' },
  })})`);
  console.log('  ok      :', login.ok);
  console.log('  error   :', login.error || '(无)');
  console.log('  messages:');
  for (const m of (login.messages || [])) console.log('    | ' + m);
  console.log('  toast   :');
  for (const t of toasts) console.log('    | ' + t.split('\n').filter(Boolean).join(' / '));

  // ── 判定 ──
  const problems = [];
  if (!probe.baseUrl) problems.push('baseUrl 没解析出来');
  if (!(probe.messages || []).length && !toasts.length) {
    problems.push('站方 checkStatus 的原文一条都没收到（toast 还是被吞了）');
  }
  const all = [...(probe.messages || []), ...toasts, ...logs].join('\n');
  if (!/未找到密钥|检测登录失败|未登录|检测中/.test(all)) {
    problems.push('没看到「未登录」类的字样 —— 站方到底报了什么要人工看');
  }
  if (!login.ok) problems.push('login op 报错了：' + login.error);
  // ⚠️ 关键断言：login op 必须把站方原文带回来。
  //    这一遍**没有 ajax**（邮箱密码为空 → 站方直接 toast 提示），
  //    所以是第一遍的**真**结果 —— 以前被「第一遍一律静音」吃掉了。
  if (!(login.messages || []).length) {
    problems.push('login op 没带回任何 messages（第一遍的真结果被静音吃掉了？）');
  }
  if (!/请先填写邮箱和密码|正在登录中/.test((login.messages || []).join('\n'))) {
    problems.push('login op 的 messages 里没有站方的提示原文：'
      + JSON.stringify((login.messages || []).join(' | ')));
  }

  console.log('\n' + (problems.length ? '❌ 有问题：' : '✅ 符合预期'));
  for (const p of problems) console.log('  · ' + p);
  process.exit(problems.length ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
