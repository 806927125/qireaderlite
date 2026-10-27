#!/usr/bin/env node
/**
 * ⭐⭐⭐ **UAA 四合一（知秋）：「获取Token」链路**（2026-10-27）
 *
 * 跑法：node test/uaa-token.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 用户报的现象：点「获取Token」⇒ **获取 token 不了**
 *
 * ⭐⭐⭐ **根因（真服务器实证）**：
 *   站方把 token 放在**站方变量**（Legado 的 `source.getVariable()` / `setVariable()`）里：
 *     'authorization': `Bearer ${source.getVariable()}`
 *   而**轻阅把「站方变量」和「书源变量」混成了一份 map** ⇒
 *     `getVariable()` 返回的是 `{"androidId":"…"}` ⇒ 请求头变成 `Bearer {"androidId":"…"}`
 *     ⇒ 服务端 **403「无效JWT」**（**口令压根没被检查**）⇒ 永远拿不到 token ⭐⭐⭐
 *
 * ⭐⭐⭐ **修法 = 通用修复（不是给一个源打补丁）**：
 *   把两套拆开（Legado 语义）⇒ 见 `test/source-variable-contract.test.js`
 *   ⇒ **原版源一字不改也能用** ⭐（本门禁就是它的证明）
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁钉四件事：
 *   ① **原版源 + 通用修复** ⇒ 请求**不带**垃圾 authorization 头（`Bearer {`）
 *   ② token **真的存下来了**（`__sourceVariable` ⇒ 原生落盘）
 *   ③ **回环**：存下来的 token ⇒ 下次请求头就是 `Bearer <token>`
 *   ④ **A/B 对照**：不喂 `__variable`（老行为）⇒ 垃圾头出现（= 原 bug）
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

/**
 * 跑一次 login op
 * @param variable 站方变量（= 通用修复后 App 喂进来的 `__variable`）；null ⇒ 老行为（不喂）
 */
async function runLogin(src, { action, formValues, variables, variable }) {
  const reqs = [];
  const { win } = createSandbox({ nativeMock: makeMock(reqs) });
  const source = Object.assign({}, src, { __variables: variables || '', __loginInfo: {} });
  if (variable !== null) source.__variable = variable || '';
  const payload = { source, action, formValues: formValues || {}, cookieSnapshot: {} };
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

const FORM = { '源作者': '作者甲', '官方反馈群': '群乙', '临时Token口令': '口令丙' };

(async () => {
  console.log('=== 0. 文件在不在 ===');
  ok(fs.existsSync(ADAPTED), '轻阅版源在 sources/（可选，通用修复后原版也能用）');
  ok(fs.existsSync(ORIGINAL), '原版源在 test/fixtures/（A/B 对照用）');
  if (!fs.existsSync(ADAPTED) || !fs.existsSync(ORIGINAL)) {
    console.log(`\n通过 ${pass} / 失败 ${fail}`); process.exit(1);
  }
  const adapted = JSON.parse(fs.readFileSync(ADAPTED, 'utf8'))[0];
  const original = JSON.parse(fs.readFileSync(ORIGINAL, 'utf8'))[0];

  console.log('\n=== 1. 原版源 + 通用修复 ⇒ 点「获取Token」不带垃圾头 ===');
  const a1 = await runLogin(original, { action: 'getTempToken()', formValues: FORM, variable: '' });
  ok(a1.r.ok === true, 'login op 成功', a1.r.error);
  const tempReqs = a1.reqs.filter(q => q.url.indexOf('/user/temp') >= 0);
  ok(tempReqs.length > 0, '「获取Token」真的发起了请求');
  ok(tempReqs[0].url.indexOf('pw1=') >= 0 && tempReqs[0].url.indexOf('pw3=') >= 0,
     '请求带上了输入框里的三个口令（result[\'源作者\'] 等读得到）');
  ok(badAuth(a1.reqs).length === 0,
     '**没有** `Bearer {…}` 那种垃圾 authorization 头（= 旧坑「无效JWT」）',
     JSON.stringify(badAuth(a1.reqs)[0] && badAuth(a1.reqs)[0].headers));

  console.log('\n=== 2. token 真的存下来了（站方变量 ⇒ 原生落盘）===');
  ok(a1.r.__sourceVariable === FAKE_TOKEN,
     'op 回传 __sourceVariable = token 串（**不是**整份 map）',
     String(a1.r.__sourceVariable).slice(0, 80));
  let savedMap = null;
  try { savedMap = JSON.parse(a1.r.__sourceVars || '{}'); } catch (e) {}
  ok(!(savedMap && savedMap.token === FAKE_TOKEN),
     '书源变量里**没有**被塞进 token（两套各归各）',
     savedMap ? JSON.stringify(savedMap).slice(0, 100) : '(没有)');

  console.log('\n=== 3. 回环：存下来的 token ⇒ 下次请求头是 `Bearer <token>` ===');
  const a2 = await runLogin(original, {
    action: 'queryToken()',
    formValues: { 'Token': FAKE_TOKEN },
    variable: a1.r.__sourceVariable || '',
  });
  const testReqs = a2.reqs.filter(q => q.url.indexOf('/user/test') >= 0);
  ok(testReqs.length > 0, '「查询Token」真的发起了请求');
  const auth = testReqs[0] && (testReqs[0].headers.authorization || testReqs[0].headers.Authorization);
  ok(auth === 'Bearer ' + FAKE_TOKEN, '请求头是 `Bearer <token>`（不是整份变量 JSON）', String(auth));

  console.log('\n=== 4. A/B 对照：不喂 `__variable`（老行为）⇒ 垃圾头出现 ===');
  const b1 = await runLogin(original, { action: 'getTempToken()', formValues: FORM, variable: null });
  ok(badAuth(b1.reqs).length > 0,
     '老行为**会**发出 `Bearer {…}` 垃圾头（= 服务端 403「无效JWT」的真正原因）',
     '老行为居然没发垃圾头 ⇒ 对照失效了？');

  console.log('\n=== 5. 轻阅版源（可选）⇒ 没 token 时连空 Bearer 都不发 ===');
  const c1 = await runLogin(adapted, { action: 'getTempToken()', formValues: FORM, variable: '' });
  const cReqs = c1.reqs.filter(q => q.url.indexOf('/user/temp') >= 0);
  const cAuth = cReqs[0] && (cReqs[0].headers.authorization || cReqs[0].headers.Authorization);
  ok(!cAuth || !/Bearer/.test(String(cAuth)),
     '轻阅版：没有 token ⇒ **不发** authorization 头（连空 Bearer 都没有）', String(cAuth));

  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
