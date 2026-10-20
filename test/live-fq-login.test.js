#!/usr/bin/env node
/**
 * **番茄登录（fq_login）端到端联调**
 *
 * 跑法：node test/live-fq-login.test.js
 *
 * 站方 fq_login() 的完整流程：
 *   ① cookie.removeCookie('snssdk.com' / 'fanqienovel.com')
 *   ② java.startBrowserAwait('https://fanqienovel.com/', '登录')
 *      → 弹内嵌浏览器 → 用户在番茄官方登录 → 关掉浏览器
 *   ③ cookie.getKey('fanqienovel.com', 'sessionid')   ← **浏览器里登出来的 cookie 必须回到引擎**
 *   ④ java.ajax('https://fanqienovel.com/api/user/info/v2', {headers:{Cookie: cookie_}})
 *   ⑤ toast「欢迎 XXX 登录成功！」
 *
 * 本测试 mock 浏览器返回带 sessionid 的 cookie，断言 ③ 拿到了、④ 带上了 Cookie 头、⑤ 出了欢迎语。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const SRC = process.env.SRC_OUT ||
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json';
if (!fs.existsSync(SRC)) {
  console.log('ℹ️  适配版聚合源不在本机 → 跳过');
  process.exit(0);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.loginUrl) || list[0];

const jar = {};
const toasts = [];
const logs = [];
const requests = [];
let browserOpened = 0;

function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

async function nativeMock(fn, args) {
  switch (fn) {
    case 'openBrowser': {
      // ★ 模拟：用户在番茄官方登录完，关掉浏览器 → 带着 sessionid
      browserOpened++;
      const url = String(args.url || '');
      const h = hostOf(url);
      jar[h] = jar[h] || {};
      jar[h]['sessionid'] = 'TEST_SESSION_ABC';
      return {
        ok: true,
        value: {
          html: '<html><body>已登录</body></html>',
          url: 'https://fanqienovel.com/',
          cookie: 'sessionid=TEST_SESSION_ABC; tt_webid=xyz',
        },
      };
    }
    case 'request': {
      const url = String(args.url || '');
      requests.push({ url: url.split('?')[0], headers: args.headers || {} });
      if (url.indexOf('/api/user/info/v2') >= 0) {
        return { ok: true, code: 200, url, headers: {},
                 body: JSON.stringify({ data: { name: '测试用户' } }) };
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

  console.log('=== 跑 fq_login()（番茄登录）===');
  const r = await win.eval(`window.__qrInvoke('login', ${JSON.stringify({
    source, cookieSnapshot: {},
    action: 'fq_login()',
    formValues: {},
  })})`);

  console.log('  ok          :', r.ok);
  console.log('  error       :', r.error || '(无)');
  console.log('  浏览器弹了  :', browserOpened, '次');
  console.log('  请求序列    :');
  for (const q of requests) {
    console.log('    | ' + q.url + '   Cookie头=' + JSON.stringify(q.headers['Cookie'] || q.headers['cookie'] || '(无)'));
  }
  console.log('  toast       :');
  for (const t of toasts) console.log('    | ' + t.split('\n').filter(Boolean).join(' / '));
  console.log('  log         :');
  for (const l of logs) console.log('    | ' + l.split('\n').filter(Boolean).join(' / '));

  const all = [...toasts, ...logs].join('\n');
  const infoReq = requests.find(q => q.url.indexOf('/api/user/info/v2') >= 0);

  console.log('\n=== 判定 ===');
  ok(browserOpened >= 1, '内嵌浏览器弹出来了');
  ok(!!infoReq, '打了 /api/user/info/v2');
  // ⚠️ 会有**两条**请求：第一遍的 ajax 是假的（cookie 还没合并 → sessionid=undefined），
  //    第二遍才是真的。两遍跑就是干这个的。
  //    所以要断言「**至少有一条**带上了真 sessionid」。
  const withRealCookie = requests.filter(q =>
    /sessionid=TEST_SESSION_ABC/.test(String(q.headers['Cookie'] || q.headers['cookie'] || '')));
  ok(withRealCookie.length >= 1,
     '请求带上了浏览器里登出来的 sessionid（③→④ 这段通不通）');
  ok(/欢迎/.test(all) && /测试用户/.test(all), 'toast 里有「欢迎 XXX 登录成功」');
  ok(!/未获取到登录凭据/.test(all), '没有「未获取到登录凭据，登录失败」');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
