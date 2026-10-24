#!/usr/bin/env node
/**
 * **目录（toc）真机联调**
 *
 * 跑法：node test/live-toc.test.js
 *
 * 背景：用户真机「目录一条章节都没解析出来（chapterList 规则没命中）」。
 * App 的「目录诊断」显示：请求 URL 是个 `data:;base64,…`、状态码 0、响应字节 21。
 *
 * ⚠️ 站方的 ruleToc.chapterList 是**复合规则**：
 *     <js>
 *       let res = JSON.parse(java.hexDecodeToString(result));   // 解 data: URL 的载荷
 *       …
 *       let data = java.ajax(`${base_url}/catalog?…`, {method:"POST", body:{html}});
 *       data;                                                     // ← 完成值
 *     </js>$.data                                                  // ← 尾巴再走 JSONPath
 * ⇒ 需要「JS 的完成值 → 再喂给 $.data」这条链（splitJsWithTail + selectFromJsResult）。
 *
 * 这个测试：真网络 + 真源 → 找一本书 → 跑 toc → 看章节出来没有。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');
const { looksServerSide, skipServerSide } = require('./live-helpers');

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
  .find(s => s && s.bookSourceUrl && s.ruleExplore && s.ruleToc) || list[0];

const UA = 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';

// ⚠️⚠️ **win 必须声明在模块顶层** —— nativeMock 定义在模块作用域，
//   引用不到下面 async IIFE 里的 `const { win }`（块级作用域）
//   ⇒ 以前会抛「win is not defined」⇒ 目录请求全失败
//   ⇒ 门禁每次都「因站方限流跳过」⇒ **这个断言其实一直没验过** ⭐
let win = null;
const jar = {};
const toasts = [];
const logs = [];
function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

async function nativeMock(fn, args) {
  switch (fn) {
    case 'request': {
      const url = String(args.url || '');
      const method = (args.method || 'GET').toUpperCase();
      const headers = Object.assign({ 'User-Agent': UA }, args.headers || {});
      const h = hostOf(url);
      if (!headers.cookie && jar[h]) {
        headers.cookie = Object.entries(jar[h]).map(([k, v]) => `${k}=${v}`).join('; ');
      }
      (win.__reqs = win.__reqs || []).push({ url, method });
      try {
        const res = await fetch(url, {
          method, headers,
          body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
          redirect: 'follow',
        });
        const text = await res.text();
        for (const line of (res.headers.getSetCookie ? res.headers.getSetCookie() : [])) {
          const kv = line.split(';')[0]; const i = kv.indexOf('=');
          if (i > 0) { jar[h] = jar[h] || {}; jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim(); }
        }
        return { ok: true, code: res.status, url: res.url, headers: {}, body: text };
      } catch (e) {
        return { ok: false, error: String(e && e.message || e) };
      }
    }
    case 'getCookie': {
      const h = hostOf(args.url || '');
      return { ok: true, value: Object.entries(jar[h] || {}).map(([k, v]) => `${k}=${v}`).join('; ') };
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
    case 'deviceID': return { ok: true, value: 'test-device' };
    case 'getWebViewUA': return { ok: true, value: UA };
    default: return { ok: true, value: '' };
  }
}

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  win = createSandbox({ nativeMock }).win;
  const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

  console.log('=== ① 先找一本书 ===');
  const kinds = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({ source })})`);
  const allKinds = kinds.kinds || [];
  const picked = allKinds.find(k => /get_discover/.test(String(k.url || ''))) || allKinds.find(k => k.url);
  const ex = await win.eval(`window.__qrInvoke('explore', ${JSON.stringify({
    source, kindUrl: picked.url, page: 1,
  })})`);
  const books = ex.books || [];
  console.log('  探索到书:', books.length);
  const book = books[0];
  if (!book && looksServerSide(logs, toasts)) {
    skipServerSide('限流/未登录', logs.concat(toasts).join(' | ').slice(0, 160));
  }
  if (!book) { console.log('❌ 连书都没有，后面的没法测'); process.exit(1); }
  console.log('  用这本:', book.name);
  console.log('  bookUrl:', String(book.bookUrl).slice(0, 70));

  console.log('\n=== ② 跑 toc（目录）===');
  const tocPayload = {
    source,
    bookUrl: book.bookUrl,
    book: Object.assign({}, book, { variable: 'custom' }),
    maxPages: 1,
  };
  const t = await win.eval(
    "window.__qrInvoke('toc', " + JSON.stringify(tocPayload) + ")");

  const chs = t.chapters || [];
  console.log('  error   :', t.error || '(无)');
  // 真实发出的目录请求 URL（下面断言用）
  win.__lastCatalogUrl = (win.__reqs || []).filter(r => /\/catalog/.test(r.url)).map(r => r.url)[0] || '';
  console.log('  章节数  :', chs.length);
  for (const c of chs.slice(0, 3)) {
    console.log(`    · ${c.title}  url=${String(c.url || '').slice(0, 46)}`);
  }
  console.log('  toast   :', toasts.slice(0, 3).join(' / '));
  console.log('  log     :', logs.slice(0, 3).join(' / '));

  console.log('\n=== ③ 正文（第一��）===');
  let c = null;
  if (chs.length) {
    // ⚠️ 必须传 book —— 站方正文 JS 第一句就调 book.getVariable('custom')
    c = await win.eval("window.__qrInvoke('content', " + JSON.stringify({
      source,
      chapterUrl: chs[0].url,
      chapter: Object.assign({}, chs[0], { variable: 'custom' }),
      book: Object.assign({}, book, { variables: {} }),
    }) + ")");
    console.log('  error  :', c.error || '(无)');
    console.log('  标题   :', c.title);
    console.log('  正文长度:', (c.content || '').length);
    console.log('  正文开头:', String(c.content || '').slice(0, 90).replace(/\n/g, ' '));
  }

  console.log('\n=== 判定 ===');
  ok(!t.error, 'toc 没报错' + (t.error ? '：' + t.error : ''));
  // ⭐ 变量只写一半 ⇒ server 没了 ⇒ URL 变成 `undefined/catalog` ⇒ 0 章
  //   （2026-10-21 真机「目录 0 章」的根因之一）⇒ 盯着真实请求 URL
  const catUrl = String(win.__lastCatalogUrl || '');
  ok(/^https?:\/\//.test(catUrl),
     '目录请求 URL 是个真地址（不是 undefined/…）' + (catUrl ? '：' + catUrl.slice(0, 60) : ''));
  ok(chs.length > 0, `目录出章节了（现在 ${chs.length} 条）`);
  // ⚠️ 章节对象是 {title, url, index, ...} —— 字段叫 **title** 不是 name
  ok(chs.every(c => c.title), '每章都有标题');
  ok(chs.some(c => c.url), '至少一章有 url（点进去要能开）');
  ok(chs.length > 10, '章节数量合理（>10）');
  // ⚠️ 番茄有「免登录访问次数上限（3 次）」→ 反复联调会被限流，
  //    正文会变成「您今日免登录访问次数已达上限(3次)！」→ 所以只断言「有内容」✅
  //    （这也说明：番茄登录是刚需，不登录正文只能看 3 次）
  ok(!!(c && c.content && c.content.length > 10), '正文取到了（>10 字）');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
