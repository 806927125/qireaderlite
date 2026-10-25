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
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改跑新引擎**（Swift，`legado-engine`）⭐⭐⭐
 *
 * 迁移要点：
 *   ① 老的 JS 层 `nativeMock` ⇒ 改成**声明式 routes**（规范 §1.1）
 *      ⇒ 「登录_api 失败」那个场景用**第二组 routes**（status 502）来表达 ⭐⭐⭐
 *   ② 请求记录从 `sandbox.__requests` 取（规范 §1.1）
 *   ③ 站方原文（toast/log）从 op 的 `messages` 里取（新引擎的 `login` op 收站方原文）⭐
 *   ④ 登录信息 / cookie 罐 / 书籍变量从 op 的 `__loginInfo` / `__cookies` / `__sourceVars` 取
 *      （= App 侧落盘的那三份 ⇒ 老门禁是从 JS 层的 mock 罐里读的 ⇒ **语义等价**）⭐⭐⭐
 *   ⑤ 引擎不可用 ⇒ **显式 SKIP 并说明**（规范 §3.4 ⇒ 不许假绿）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

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

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐ **引擎不可用 ⇒ 显式 SKIP**（规范 §3.4）⭐⭐⭐
if (!engineAvailable()) {
  console.log('⏭ 跳过：新引擎（legado-engine 的 conformance）不在本机 ⇒ 这条链路**没验到**');
  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(0);
}

// ── ⭐⭐⭐ **假服务器（声明式 routes）** ─────────────────────────────
//   `/login_api` ⇒ 模拟**成功登录**（站方读 `code == 0` 与 `key`）
const okRoutes = [
  { match: '/login_api', status: 200, body: JSON.stringify({ code: 0, key: 'TESTKEY123456' }) },
];

console.log('=== 跑 login(true)（mock 登录成功）===');
const { win, sandbox } = createSandbox({ routes: okRoutes });
const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

const r = win.__qrInvoke('login', {
  source,
  jsLib: src.jsLib,                 // ⭐ 站方 jsLib（`getArgument` / `host` 等）
  action: 'login(true)',
  formValues: { '邮箱': 'a@b.com', '密码': 'pw123456' },
  routes: okRoutes,
});

console.log('  ok        :', r && r.ok);
console.log('  error     :', (r && r.error) || '(无)');
console.log('  请求序列  :', sandbox.__requests.map(String).join(' → ') || '(一条都没发!)');
console.log('  toast     :');
for (const t of ((r && r.messages) || [])) console.log('    | ' + t.split('\n').filter(Boolean).join(' / '));
console.log('  登录信息  :', r && r.__loginInfo);
console.log('  书籍变量  :', r && r.__sourceVars);

const all = ((r && r.messages) || []).join('\n');
const loginInfo = (r && r.__loginInfo) ? JSON.parse(r.__loginInfo) : {};
const cookies = (r && r.__cookies) || {};

console.log('\n=== 判定 ===');
ok(sandbox.__requests.map(String).some(u => u.indexOf('/login_api') >= 0),
   'login_api 请求真的发出去了（没发 = 站方那一步根本没跑到）',
   '实际：' + JSON.stringify(sandbox.__requests));
ok(/登录成功/.test(all), 'toast 里有「登录成功」', '实际：' + all.replace(/\n/g, ' / ').slice(0, 200));
ok(!/登录失败/.test(all), 'toast 里没有「登录失败」');
// ⚠️ cookie 罐 ⇒ 新架构从 op 的 `__cookies` 拿（= 宿主 cookie 罐的快照）
ok(JSON.stringify(cookies).indexOf('qttoken') >= 0,
   'cookie 罐里有 qttoken', '实际：' + JSON.stringify(cookies).slice(0, 200));
ok(!!loginInfo['密钥'], '登录信息里有「密钥」（④ 那步走到了）', '实际：' + JSON.stringify(loginInfo));
ok(!!loginInfo['邮箱'], '登录信息里有邮箱');
ok(/qttoken/.test(String((r && r.__sourceVars) || '')), '书籍变量里有 qttoken',
   '实际：' + String((r && r.__sourceVars) || '').slice(0, 200));

// ── 场景 2：**登录失败**不许把已有的登录态弄坏 ──
//
// 站方 login(true) 第一步无条件 putLoginInfo(表单值) → **密钥被抹掉**；
// 而密钥是「登录成功」的标志（只有成功那步才写回去）。
// ⇒ 登录_api 失败（服务器 502 / 密码错）时，密钥就永远回不来了。
// 引擎的 login op 现在会**恢复**旧的那份 → 失败不该破坏已有状态。
console.log('\n=== 场景 2：登录_api 失败（服务器 502）→ 旧的密钥要保住 ===');
const savedLogin = { '邮箱': 'a@b.com', '密码': 'pw123456', '密钥': 'OLDTOKEN999' };
const src2 = Object.assign({}, src, {
  __variables: '',
  __loginInfo: JSON.stringify(savedLogin),
});
// ⭐⭐⭐ **第二组 routes**：/login_api 返回 502（= 服务器挂了）⭐⭐⭐
//   ⇒ 老门禁是用 JS 层 mock 换了个实现来表达「502」⇒ 现在用声明式路由表达（规范 §1.1）⭐
const failRoutes = [
  { match: '/login_api', status: 502, body: '<!DOCTYPE html><html>502</html>' },
];
const sb2 = createSandbox({ routes: failRoutes });
const r2 = sb2.win.__qrInvoke('login', {
  source: src2,
  jsLib: src.jsLib,
  action: 'login(true)',
  formValues: { '邮箱': 'a@b.com', '密码': 'pw123456' },
  routes: failRoutes,
});
const info2 = (r2 && r2.__loginInfo) ? JSON.parse(r2.__loginInfo) : {};
console.log('  登录信息  :', r2 && r2.__loginInfo);
ok(info2['密钥'] === 'OLDTOKEN999',
   '登录失败后「密钥」还在（失败的登录不许破坏已有登录态）', '实际：' + JSON.stringify(info2));
ok(info2['邮箱'] === 'a@b.com', '邮箱没丢', '实际：' + JSON.stringify(info2));
// ⭐⭐⭐ **失败要有站方原文**（老门禁这条是 `|| true` 的空断言 ⇒ 现在补成真的）⭐⭐⭐
ok(/登录失败/.test(((r2 && r2.messages) || []).join('\n')),
   '站方原文里有「登录失败」（用户要看得见成没成功）',
   '实际：' + ((r2 && r2.messages) || []).join(' / ').slice(0, 200));

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
