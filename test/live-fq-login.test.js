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
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改跑新引擎**（Swift，`legado-engine`）⭐⭐⭐
 *
 * 迁移要点：
 *   ① 老的 JS 层 `nativeMock`（`openBrowser` / `request` / `getCookie` / `setCookie` …）
 *      ⇒ 拆成两半：
 *        · **假服务器** ⇒ 声明式 `routes`（规范 §1.1）
 *        · **假浏览器** ⇒ 声明式 `browserPages`（浏览器是**宿主**的能力 ⇒ 宿主给页面和 cookie）
 *   ② 请求记录从 `sandbox.__requests` 取（规范 §1.1）
 *   ③ 站方原文（toast/log）从 op 的 `messages` 里取（新引擎的 `login` op 收站方原文）⭐
 *   ④ 引擎不可用 ⇒ **显式 SKIP 并说明**（规范 §3.4 ⇒ 不许假绿）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

// ⭐⭐⭐ **不许「跳过」**（2026-10-24 真机教训）—— 找不到就回退仓库副本
//   跳过 = 登录路径一次都没被验过 ⇒ 真机炸了沙盒还全绿 ⭐⭐⭐
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

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐ **引擎不可用 ⇒ 显式 SKIP**（规范 §3.4）⭐⭐⭐
if (!engineAvailable()) {
  console.log('⏭ 跳过：新引擎（legado-engine 的 conformance）不在本机 ⇒ 这条链路**没验到**');
  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(0);
}

// ── ⭐⭐⭐ **假服务器（声明式 routes）** ─────────────────────────────
//   站方第 ④ 步打的是 `https://fanqienovel.com/api/user/info/v2` ⇒ 返回用户信息
const routes = [
  { match: '/api/user/info/v2', status: 200, body: JSON.stringify({ data: { name: '测试用户' } }) },
];

// ── ⭐⭐⭐ **假浏览器（声明式 browserPages）** ─────────────────────────
//   站方第 ① 步会**先删掉** fanqienovel.com 的旧 cookie ⇒ 第 ③ 步的 sessionid
//   **只能靠「用户在浏览器里登完 ⇒ 宿主把浏览器的 cookie 合并回来」** ⇒
//   所以 cookie 必须由**浏览器**带回来（不是预先塞在 cookie 罐里）⭐⭐⭐
const browserPages = [
  {
    match: 'fanqienovel.com',
    html: '<html><body>已登录</body></html>',
    cookies: { 'fanqienovel.com': 'sessionid=TEST_SESSION_ABC; tt_webid=xyz' },
  },
];

console.log('=== 跑 fq_login()（番茄登录）===');
const { win, sandbox } = createSandbox({ routes });
const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

const r = win.__qrInvoke('login', {
  source,
  jsLib: src.jsLib,              // ⭐ 站方 jsLib（`host` / `getArgument` 等）
  action: 'fq_login()',
  formValues: {},
  browserPages,
  routes,
});

console.log('  ok          :', r && r.ok);
console.log('  error       :', (r && r.error) || '(无)');
console.log('  浏览器弹了  :', ((r && r.browsers) || []).length, '次');
console.log('  请求序列    :');
for (const q of sandbox.__requests) {
  console.log('    | ' + q);
}
console.log('  toast       :');
for (const t of ((r && r.messages) || [])) console.log('    | ' + t.split('\n').filter(Boolean).join(' / '));

const all = ((r && r.messages) || []).join('\n');

console.log('\n=== 判定 ===');
// ① 内嵌浏览器弹出来了
//   ⚠️ 语义等价在哪：老门禁数的是 JS 层 mock 的 `openBrowser` 次数；
//   新架构里「弹浏览器」是**宿主**的能力（真机 = `RuleSandbox` 的 op）⇒
//   沙盒里由**假浏览器**接管 ⇒ 引擎把「要开哪个 URL」交给宿主 ⇒ 门禁看这个记录 ⭐⭐⭐
const browsers = (r && r.browsers) || [];
ok(browsers.some(u => u.indexOf('fanqienovel.com') >= 0),
   '内嵌浏览器弹出来了（引擎把番茄登录页交给了宿主）',
   '实际：' + JSON.stringify(browsers));

// ② 请求带上了浏览器里登出来的 sessionid（③→④ 这段通不通）
//   ⚠️ 语义等价在哪：老门禁看的是 JS 层 mock 记下来的请求头；
//   新引擎的站方 `java.ajax` 把请求头编码在 URL 的规则后缀里（Legado 语义）
//   ⇒ 门禁看 `sandbox.__requests` 里的 URL 后缀 ⭐⭐⭐
const withRealCookie = sandbox.__requests.map(String)
  .filter(u => /sessionid=TEST_SESSION_ABC/.test(u));
ok(withRealCookie.length >= 1,
   '请求带上了浏览器里登出来的 sessionid（③→④ 这段通不通）',
   '实际：' + JSON.stringify(sandbox.__requests));

// ③ 欢迎语
ok(/欢迎/.test(all) && /测试用户/.test(all), 'toast 里有「欢迎 XXX 登录成功」',
   '实际：' + all.replace(/\n/g, ' / ').slice(0, 200));
// ④ 没有失败分支
ok(!/未获取到登录凭据/.test(all), '没有「未获取到登录凭据，登录失败」');

// ⑤ ⭐⭐⭐ **浏览器里登出来的 cookie 真的回到引擎的 cookie 罐了**（老门禁没这条 ⇒ 现在补上）
//   ⇒ 站方第 ① 步刚把 cookie 删了 ⇒ 罐里还有 sessionid ⇒ 只可能是浏览器带回来的 ⭐⭐⭐
const cookies = (r && r.__cookies) || {};
ok(JSON.stringify(cookies).indexOf('sessionid=TEST_SESSION_ABC') >= 0,
   '浏览器里登出来的 sessionid 回到引擎的 cookie 罐了（③ 的前提）',
   '实际：' + JSON.stringify(cookies));

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
