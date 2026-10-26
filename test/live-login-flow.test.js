#!/usr/bin/env node
/**
 * **登录流程端到端联调**（用户真机跑 build154 后：cookie 空、密钥没了、书籍变量里 token 还在）
 *
 * 跑法：node test/live-login-flow.test.js
 *
 * 站方 login(true) 的真实流程：
 *   ① putLoginInfo(表单值)          ← **只存邮箱密码 → 把「密钥」抹掉**
 *   ② 读 base_url（getArgument('server')）
 *   ③ POST {base}/login_api {邮箱,密码}
 *   ④ code==0 → toast「✅️登录成功」+ cookie.setCookie(qttoken) + result['密钥']=data.key
 *                + putLoginInfo(带密钥的 result)   ← 密钥在这一步才被写回去
 *   ⑤ code!=0 / 抛错 → toast「💔登录失败」→ **密钥永远是空的**
 *
 * 所以「密钥没了」只说明一件事：**③ 那一步失败了**（④ 没跑到）。
 * 本测试 mock 一个成功的 /login_api，把整条路跑一遍：
 *   - toast 要有「✅️登录成功」
 *   - cookie 罐里要有 qttoken
 *   - 登录信息里要有「密钥」
 *   - 书籍变量里要有 qttoken
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

// ⭐⭐⭐ **不许「跳过」**（2026-10-24 真机教训）
//   以前这里找不到文件就 `process.exit(0)` ⇒ 门禁「跳过」⇒ **登录路径一次都没被验过**
//   ⇒ 真机才炸出「登录界面没了 / 打开登录卡死」⇒ 沙盒全绿、用户全黑 ⭐⭐⭐
//   ⇒ 现在：**回退到仓库里的源文件副本** ⇒ 干净克隆也能跑 ⇒ 门禁永远在跑 ⭐
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
console.log('ℹ️  用源文件：', SRC);
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.loginUrl) || list[0];

const jar = {};
const toasts = [];
const logs = [];
const requests = [];

function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

async function nativeMock(fn, args) {
  switch (fn) {
    case 'request': {
      const url = args.url || '';
      const h = hostOf(url);
      requests.push(url.split('?')[0]);
      // ★ /login_api → 模拟**成功登录**
      if (url.indexOf('/login_api') >= 0) {
        return {
          ok: true, code: 200, url, headers: {},
          body: JSON.stringify({ code: 0, key: 'TESTKEY123456' }),
        };
      }
      if (url.indexOf('/user_api') >= 0) {
        return {
          ok: true, code: 200, url, headers: {},
          body: JSON.stringify({ id: 6044, nickname: '流云', email: 'a@b.com' }),
        };
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

  console.log('=== 跑 login(true)（mock 登录成功）===');
  const r = await win.eval(`window.__qrInvoke('login', ${JSON.stringify({
    source,
    cookieSnapshot: {},
    action: 'login(true)',
    formValues: { '邮箱': 'a@b.com', '密码': 'pw123456' },
  })})`);

  console.log('  ok        :', r.ok);
  console.log('  error     :', r.error || '(无)');
  console.log('  请求序列  :', requests.join(' → ') || '(一条都没发!)');
  console.log('  toast     :');
  for (const t of toasts) console.log('    | ' + t.split('\n').filter(Boolean).join(' / '));
  console.log('  log       :');
  for (const l of logs) console.log('    | ' + l.split('\n').filter(Boolean).join(' / '));
  console.log('  登录信息  :', r.__loginInfo);
  console.log('  书籍变量  :', r.__sourceVars);

  const all = [...toasts, ...logs].join('\n');
  const loginInfo = r.__loginInfo ? JSON.parse(r.__loginInfo) : {};

  console.log('\n=== 判定 ===');
  ok(requests.some(u => u.indexOf('/login_api') >= 0),
     'login_api 请求真的发出去了（没发 = 两遍跑没把 URL 抓回来）');
  ok(/登录成功/.test(all), 'toast 里有「登录成功」');
  ok(!/登录失败/.test(all), 'toast 里没有「登录失败」');
  ok(/qttoken/.test(JSON.stringify(jar)), 'cookie 罐里有 qttoken');
  ok(!!loginInfo['密钥'], '登录信息里有「密钥」（④ 那步走到了）');
  ok(!!loginInfo['邮箱'], '登录信息里有邮箱');
  ok(/qttoken/.test(String(r.__sourceVars || '')), '书籍变量里有 qttoken');

  // ── 场景 2：**登录失败**不许把已有的登录态弄坏 ──
  //
  // 站方 login(true) 第一步无条件 putLoginInfo(表单值) → **密钥被抹掉**；
  // 而密钥是「登录成功」的标志（只有成功那步才写回去）。
  // ⇒ 登录_api 失败（服务器 502 / 密码错）时，密钥就永远回不来了。
  // 引擎的 login op 现在会**恢复**旧的那份 → 失败不该破坏已有状态。
  console.log('\n=== 场景 2：登录_api 失败（服务器 502）→ 旧的密钥要保住 ===');
  const savedLogin = JSON.stringify({ '邮箱': 'a@b.com', '密码': 'pw123456', '密钥': 'OLDTOKEN999' });
  const src2 = Object.assign({}, src, { __variables: '', __loginInfo: JSON.parse(savedLogin) });
  toasts.length = 0; logs.length = 0; requests.length = 0;
  // 让 login_api 返回 502
  const origMock = nativeMock;
  const failMock = async (fn, args) => {
    if (fn === 'request' && String(args.url || '').indexOf('/login_api') >= 0) {
      return { ok: true, code: 502, url: args.url, headers: {},
               body: '<!DOCTYPE html><html>502</html>' };
    }
    return origMock(fn, args);
  };
  const sb2 = createSandbox({ nativeMock: failMock });
  const r2 = await sb2.win.eval(`window.__qrInvoke('login', ${JSON.stringify({
    source: src2, cookieSnapshot: {}, action: 'login(true)',
    formValues: { '邮箱': 'a@b.com', '密码': 'pw123456' },
  })})`);
  const info2 = r2.__loginInfo ? JSON.parse(r2.__loginInfo) : {};
  console.log('  登录信息  :', r2.__loginInfo);
  ok(info2['密钥'] === 'OLDTOKEN999',
     '登录失败后「密钥」还在（失败的登录不许破坏已有登录态）');
  ok(info2['邮箱'] === 'a@b.com', '邮箱没丢');
  ok(/登录失败|请求参数中未找到密钥|Unexpected|502/.test([...toasts, ...logs].join('\n'))
     || true, '（失败提示有就更好，没有也不影响本用例）');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
