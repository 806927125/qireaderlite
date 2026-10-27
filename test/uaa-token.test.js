#!/usr/bin/env node
/**
 * **UAA 四合一（知秋）：「获取Token」链路门禁**（2026-10-27）
 *
 * 跑法：node test/uaa-token.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 用户报的现象：点「获取Token」⇒ **获取 token 不了**
 *
 * ⭐⭐⭐ **病根（沙盒实证 + 真服务器回应）**：
 *
 *   站方把 token 放在 **站方变量**（Legado 的 `source.getVariable()` / `setVariable()`）里：
 *     function getApiUrl(path, data, _) {
 *       let option = { method: "GET", headers: {
 *         'authorization': `Bearer ${source.getVariable()}`,   // ← token 从这儿来
 *         'x-android-id': androidId } }
 *       ...
 *     }
 *
 *   而**轻阅的 `source.getVariable()` 返回的是整份「书籍变量」JSON**（不是站方变量）：
 *     → 请求头变成 `authorization: Bearer {"androidId":"b4e6060006b920bc"}`
 *     → 服务端回 **403 `{"code":403,"error":"无效JWT"}`**
 *     → 站方 `requestApiUrl` 返回 null ⇒ 弹「❌获取 token 失败,请检查 API 域名/网络/口令」
 *     → **用户永远拿不到 token** ⭐⭐⭐
 *
 *   ⚠️ **不能改引擎的 `getVariable()` 语义**（大灰狼 37 处 / NovelHub 26 处都拿它当
 *      「书籍变量 JSON」用）⇒ **改源**（token 存「书源变量·token」项 ⇒ 三端都有这套 API）⭐
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁钉四件事：
 *   ① 点「获取Token」⇒ 请求**不带**垃圾 authorization 头（`Bearer {` ⇒ 就是旧坑）
 *   ② token **真的存下来了**（`__sourceVars` 里有 `token` 项 ⇒ 原生会落盘）
 *   ③ **回环**：存下来的 token ⇒ 下次请求头就是 `Bearer <token>`（不是 `Bearer {…}`）
 *   ④ **变异对照**：拿**原版源**跑同一道门禁 ⇒ 必须红（证明这道门禁抓得住这个 bug）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const root = path.join(__dirname, '..');
const ADAPTED = path.join(root, 'sources', '✿UAA四合一（知秋）✿-轻阅版.json');
const ORIGINAL = path.join(root, 'test', 'fixtures', 'uaa-original.json');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

const FAKE_TOKEN = 'a'.repeat(64) + 'b'.repeat(8);

/** 造一个假服务器：/user/temp 给 token，/user/test 给用户信息 */
function makeMock(reqs) {
  return async (fn, args) => {
    if (fn === 'request') {
      const url = String(args.url || '');
      const method = (args.method || 'GET').toUpperCase();
      reqs.push({ url, method, headers: args.headers || {} });
      let body = '{"code":0,"data":{"ok":true}}';
      if (url.indexOf('/user/temp') >= 0) {
        body = JSON.stringify({ code: 0, data: {
          token: FAKE_TOKEN, id: 'u42', left: 99, createTime: '2026-10-27', ddlTime: '2026-10-30' } });
      } else if (url.indexOf('/user/test') >= 0) {
        body = JSON.stringify({ code: 0, data: {
          id: 'u42', max: 100, used: 1, left: 99, createTime: '2026-10-27' } });
      }
      return { ok: true, code: 200, url, headers: {}, body };
    }
    if (fn === 'log' || fn === 'toast') return { ok: true };
    if (fn === 'deviceID') return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
    return { ok: true, value: '' };
  };
}

/** 跑一次 login op */
async function runLogin(src, { action, formValues, variables }) {
  const reqs = [];
  const { win } = createSandbox({ nativeMock: makeMock(reqs) });
  const payload = {
    source: Object.assign({}, src, { __variables: variables || '', __loginInfo: {} }),
    action,
    formValues: formValues || {},
    cookieSnapshot: {},
  };
  const r = await win.eval(`window.__qrInvoke('login', ${JSON.stringify(payload)})`);
  return { r, reqs };
}

/** 请求头里有没有「垃圾 authorization」（`Bearer {` ⇒ 旧坑：整份变量 JSON 当 token） */
function badAuth(reqs) {
  return reqs.filter(q => {
    const a = q.headers && (q.headers.authorization || q.headers.Authorization);
    return a && /Bearer\s*\{/.test(String(a));
  });
}

(async () => {
  console.log('=== 0. 文件在不在 ===');
  ok(fs.existsSync(ADAPTED), '轻阅版源在 sources/');
  ok(fs.existsSync(ORIGINAL), '原版源在 test/fixtures/（变异对照用）');
  if (!fs.existsSync(ADAPTED) || !fs.existsSync(ORIGINAL)) {
    console.log(`\n通过 ${pass} / 失败 ${fail}`); process.exit(1);
  }
  const adapted = JSON.parse(fs.readFileSync(ADAPTED, 'utf8'))[0];
  const original = JSON.parse(fs.readFileSync(ORIGINAL, 'utf8'))[0];

  console.log('\n=== 1. 点「获取Token」⇒ 请求不能带垃圾 authorization 头 ===');
  const a1 = await runLogin(adapted, {
    action: 'getTempToken()',
    formValues: { '源作者': '作者甲', '官方反馈群': '群乙', '临时Token口令': '口令丙' },
  });
  ok(a1.r.ok === true, 'login op 成功', a1.r.error);
  const tempReqs = a1.reqs.filter(q => q.url.indexOf('/user/temp') >= 0);
  ok(tempReqs.length > 0, '「获取Token」真的发起了请求');
  ok(tempReqs[0].url.indexOf('pw1=') >= 0 && tempReqs[0].url.indexOf('pw3=') >= 0,
     '请求带上了输入框里的三个口令（result[\'源作者\'] 等读得到）');
  ok(badAuth(a1.reqs).length === 0,
     '**没有** `Bearer {…}` 那种垃圾 authorization 头（= 旧坑「无效JWT」）',
     JSON.stringify(badAuth(a1.reqs)[0] && badAuth(a1.reqs)[0].headers));

  console.log('\n=== 2. token 真的存下来了（原生会落盘）===');
  let savedVars = null;
  try { savedVars = JSON.parse(a1.r.__sourceVars || '{}'); } catch (e) { savedVars = null; }
  ok(savedVars !== null, 'op 回传了 __sourceVars', String(a1.r.__sourceVars).slice(0, 80));
  ok(savedVars && savedVars.token === FAKE_TOKEN,
     '书源变量里有 `token` 项（= 站方拿到的 token）',
     savedVars ? JSON.stringify(savedVars).slice(0, 120) : '(没有)');

  console.log('\n=== 3. 回环：存下来的 token ⇒ 下次请求头是 `Bearer <token>` ===');
  const a2 = await runLogin(adapted, {
    action: 'queryToken()',
    formValues: { 'Token': FAKE_TOKEN },
    variables: a1.r.__sourceVars || '',
  });
  const testReqs = a2.reqs.filter(q => q.url.indexOf('/user/test') >= 0);
  ok(testReqs.length > 0, '「查询Token」真的发起了请求');
  const auth = testReqs[0] && (testReqs[0].headers.authorization || testReqs[0].headers.Authorization);
  ok(auth === 'Bearer ' + FAKE_TOKEN, '请求头是 `Bearer <token>`（不是整份变量 JSON）', String(auth));
  ok(badAuth(a2.reqs).length === 0, '**没有** `Bearer {…}` 那种垃圾头');

  console.log('\n=== 4. 变异对照：原版源跑同一道门禁 ⇒ 必须红 ===');
  const o1 = await runLogin(original, {
    action: 'getTempToken()',
    formValues: { '源作者': '作者甲', '官方反馈群': '群乙', '临时Token口令': '口令丙' },
  });
  const oBad = badAuth(o1.reqs);
  ok(oBad.length > 0,
     '原版源**会**发出 `Bearer {…}` 垃圾头（= 服务端 403「无效JWT」的真正原因）',
     '原版居然没发垃圾头 ⇒ 门禁失效了？');
  let oVars = null;
  try { oVars = JSON.parse(o1.r.__sourceVars || '{}'); } catch (e) { oVars = null; }
  ok(!(oVars && oVars.token === FAKE_TOKEN),
     '原版源**存不下** `token` 项（它把整份变量替换成了 token 串）',
     oVars ? JSON.stringify(oVars).slice(0, 120) : '(没有)');

  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
