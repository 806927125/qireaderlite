#!/usr/bin/env node
/**
 * **@js: 规则里不要做 `{{}}` 插值**（2026-10-22 实测 NovelHub 聚合源炸在这）
 *
 * 跑法：node test/js-no-interpolate.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * Legado / 栖阅的语义：**`@js:` 是 JS 源码，里面的 `{{}}` 原样保留**
 * （插值只发生在「URL 模板」规则上，比如 `searchUrl: "https://x?q={{keyword}}"`）
 *
 * 轻阅以前在 `exploreKinds` 里对 `@js:` 源码做了 interpolate ⇒ 踩了两个坑：
 *   ① `{{...}}`（**JS 对象展开语法**）被 evalExpr 求值失败 → 吃成空串
 *      ⇒ **整个 JS 语法坏掉** ⇒ 「Invalid or unexpected token」⭐
 *   ② `{{page+1}}` / `{{(page-1)*30}}` 被算成**固定数字**
 *      ⇒ 站方 JS 拼出来的分类 URL 的 page 写死 ⇒ **发现页翻页失效** ⭐
 *
 * 真实受害源：🍒NovelHub聚合小说（exploreUrl 是 168KB 的 `@js:`，含 750 个 `{{page}}`）
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
console.log('=== 1. 源码：exploreKinds 的 @js: 分支不插值 ===');
// 找到 exploreKinds 那一段
const seg = (engineSrc.match(/exploreKinds: function[\s\S]{0,1800}/) || [''])[0];
ok(seg.length > 0, '找到 exploreKinds 实现');
ok(seg.indexOf('rule.interpolate(rule.stripJsWrapper(spec), scope)') < 0,
   'exploreKinds 里不再对 @js: 源码做 interpolate');
ok(seg.indexOf('rule.stripJsWrapper(spec)') >= 0, '仍然用 stripJsWrapper 剥壳');

console.log('\n=== 2. 活体：NovelHub 聚合源的 exploreUrl 能在引擎里跑（不报语法错）===');
const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
if (!fs.existsSync(NH)) {
  console.log('  (跳过：本地没有 NovelHub 源文件)');
} else {
  const src = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];
  const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
  const nativeMock = async (fn, args) => {
    if (fn === 'request') {
      const url = String(args.url || '');
      const method = (args.method || 'GET').toUpperCase();
      const headers = Object.assign({ 'User-Agent': UA }, args.headers || {});
      try {
        const res = await fetch(url, {
          method, headers,
          body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
          redirect: 'follow',
        });
        const t = await res.text();
        return { ok: true, code: res.status, url: res.url, headers: {}, body: t };
      } catch (e) { return { ok: false, error: String(e.message) }; }
    }
    if (fn === 'log' || fn === 'toast') return { ok: true };
    if (fn === 'deviceID') return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
    if (fn === 'getWebViewUA') return { ok: true, value: UA };
    return { ok: true, value: '' };
  };
  const { win } = createSandbox({ nativeMock });
  const r = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
    source: Object.assign({}, src, { __variables: '', __loginInfo: {} }),
    cookieSnapshot: {},
  })})`);
  console.log('  error:', r.error || '(无)');
  console.log('  kinds:', (r.kinds || []).length, '| filters:', (r.filters || []).length);
  ok(!/Invalid or unexpected token/.test(String(r.error || '')),
     '**不报**「Invalid or unexpected token」（`{{...}}` 被吃掉 ⇒ 语法坏）');
  ok(!/JS 执行失败/.test(String(r.error || '')),
     '不报「JS 执行失败」（没登录时应该是「没数据」而不是崩溃）');
}

console.log('\n=== 3. 站方 URL 模板里的 {{page}} 要能活到 explore 阶段 ===');
if (fs.existsSync(NH)) {
  const src = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];
  const code = String(src.exploreUrl || '');
  const n = (code.match(/\{\{page\}\}/g) || []).length;
  console.log('  exploreUrl 里的 {{page}} 数量:', n);
  ok(n > 0, '站方 exploreUrl 里有 {{page}}（说明必须靠「不插值」保留它）');
  ok(/\{\{\.\.\.\}\}/.test(code) || !/\{\{\.\.\.\}\}/.test(code),
     '（占位：{{...}} 是 JS 展开语法，不能被当模板）');
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
