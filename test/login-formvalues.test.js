#!/usr/bin/env node
/**
 * **登录：表单值要合并进 `__loginInfo`**（2026-10-22 真机「解锁整个源」点了没反应）
 *
 * 跑法：node test/login-formvalues.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * 站方（🍒NovelHub 聚合源）是从 **`source.getLoginInfoMap()`** 读**当前输入框的值**的：
 *   function nhAuthUiMap() { return source.getLoginInfoMap ? source.getLoginInfoMap() : {}; }
 *   function unlockAll() {
 *     var _m = nhAuthUiMap();
 *     var _pw = String((_m && _m["整源解锁密码"]) || "").trim();
 *     if (_pw === "") { nhSay("🔒 请在下面「整源解锁密码」输入框里填密码…"); return; }
 *     ...
 *   }
 *
 * 轻阅以前**只把 formValues 挂到 `result`** ⇒ 站方读到的 `getLoginInfoMap()` 是**空的**
 * ⇒ 用户明明在输入框里填了密码，点了「解锁整个源」却一直提示「没填密码」⭐
 *
 * ⇒ **Legado / 栖阅的语义**：点 action 按钮时**先把当前输入框的值写进 loginInfo**，再执行 action
 * （站方 `login(true)` 第一步也是 `putLoginInfo(JSON.stringify(result))`）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  x ' + m)); };

const root = path.join(__dirname, '..');
const engineSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'engine.js'), 'utf8');

(async () => {
console.log('=== 1. 源码：login op 里表单值要合并进 __loginInfo ===');
const seg = (engineSrc.match(/login: function \(p\) \{[\s\S]{0,3000}/) || [''])[0];
ok(seg.length > 0, '找到 login op');
ok(/src\.__loginInfo\s*=\s*Object\.assign/.test(seg),
   '表单值被合并进 src.__loginInfo（站方 getLoginInfoMap() 才读得到）');
ok(/formValues/.test(seg) && /__loginInfo/.test(seg), '合并用的是 formValues');

console.log('\n=== 2. 活体：填密码 + 点「解锁整个源」⇒ 站方应回「已解锁」 ===');
const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
if (!fs.existsSync(NH)) {
  console.log('  (跳过：本地没有 NovelHub 源文件)');
} else {
  const src = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];
  const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
  const crypto = require('crypto');
  const nativeMock = async (fn, args) => {
    if (fn === 'request') {
      const url = String(args.url || '');
      const method = (args.method || 'GET').toUpperCase();
      try {
        const res = await fetch(url, {
          method,
          headers: Object.assign({ 'User-Agent': UA }, args.headers || {}),
          body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
          redirect: 'follow',
        });
        const t = await res.text();
        return { ok: true, code: res.status, url, headers: {}, body: t };
      } catch (e) { return { ok: false, error: String(e.message) }; }
    }
    if (fn === 'log' || fn === 'toast') return { ok: true };
    if (fn === 'deviceID') return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
    if (fn === 'getWebViewUA') return { ok: true, value: UA };
    if (fn === 'md5Encode') {
      // 站方要比对 md5(密码) ⇒ 这里给真实的 md5
      return { ok: true, value: crypto.createHash('md5').update(String(args.text || args.str || '')).digest('hex') };
    }
    return { ok: true, value: '' };
  };
  const { win } = createSandbox({ nativeMock });
  const r = await win.eval(`window.__qrInvoke('login', ${JSON.stringify({
    source: Object.assign({}, src, { __variables: '', __loginInfo: {} }),
    action: 'unlockAll()',
    formValues: { '整源解锁密码': 'nhub2026' },
    cookieSnapshot: {},
  })})`);
  const msgs = (r.messages || []).join('\n');
  console.log('  ok:', r.ok, '| error:', r.error || '(无)');
  console.log('  站方回复:', msgs.split('\n')[0]);
  ok(r.ok === true, 'login op 成功');
  ok(/已解锁/.test(msgs), '站方回「已解锁」（说明它从 getLoginInfoMap() 读到了输入框的密码）');
  ok(!/请在下面/.test(msgs), '**不再**提示「请在下面输入框里填密码」');
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
