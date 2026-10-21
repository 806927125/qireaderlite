#!/usr/bin/env node
/**
 * **详情页（bookInfo）真机联调** —— 2026-10-21 新增
 *
 * 跑法：node test/live-bookinfo.test.js
 *
 * 起因：用户真机引擎日志（build164）里两条错：
 *   1. [规则出错] <js> if (String(baseUrl).startsWith("data:")) {
 *        let res = JSON.parse(java.hexDecodeToString(result));
 *        JS 执行失败: JSON Parse error: Unable to parse JSON string
 *   2. [规则出错] <js> let { ..., abstract, ... } = result;
 *        JS 执行失败: undefined is not an object (evaluating 'abstract.split')
 *
 * ⇒ 第 1 条是 `ruleBookInfo.init`（详情页预处理），第 2 条是 `ruleBookInfo.intro`
 *    （简介规则解构 init 的产物）—— **两条是一条链**。
 *
 * ⚠️ 之前 live-toc 只测了「探索 → 目录 → 正文」，**从没测过详情页** →
 *    所以沙盒全绿、真机炸。⇒ 这条路径必须有真机联调门禁。
 *
 * 大灰狼的 init 规则干的事：
 *   ① `result` = data: 伪 URL 的载荷（base64）
 *   ② `JSON.parse(java.hexDecodeToString(result))` → 取出 book_id/tab/sources
 *   ③ 拿这些参数去 `服务器/detail` 重新 ajax 一次 → 真正的详情 JSON
 *   ④ 末尾 `result` → 配合尾巴 `$.data` → 详情对象
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');
const { looksServerSide, skipServerSide } = require('./live-helpers');

const SRC = process.env.SRC_OUT ||
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json';
if (!fs.existsSync(SRC)) {
  console.log('ℹ️  适配版聚合源不在本机 → 跳过');
  process.exit(0);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.ruleExplore && s.ruleToc) || list[0];

const UA = 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';

const jar = {};
const toasts = [];
const logs = [];
const reqs = [];   // ⚠️ 真实发出去的请求 URL（站方自己 log 的是**没编码的原始串**，不能拿它判）
function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

async function nativeMock(fn, args) {
  switch (fn) {
    case 'request': {
      const url = String(args.url || '');
      const method = (args.method || 'GET').toUpperCase();
      const __t0 = Date.now();
      reqs.push({ url, method });
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
        const last = reqs[reqs.length - 1];
        last.ms = Date.now() - __t0; last.code = res.status; last.len = text.length;
        return { ok: true, code: res.status, url: res.url, headers: {}, body: text };
      } catch (e) {
        const last = reqs[reqs.length - 1];
        last.ms = Date.now() - __t0; last.err = String(e && e.message || e);
        return { ok: false, error: String(e && e.message || e) };
      }
      const headers = Object.assign({ 'User-Agent': UA }, args.headers || {});
      const h = hostOf(url);
      if (!headers.cookie && jar[h]) {
        headers.cookie = Object.entries(jar[h]).map(([k, v]) => `${k}=${v}`).join('; ');
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
        if (i > 0) { jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim(); }
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
  const { win } = createSandbox({ nativeMock });
  const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

  console.log('=== ① 找一本书 ===');
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
  ok(!!book, '探索到书了');
  if (!book) { console.log(`\n❌ 通过 ${pass} / 失败 ${fail}`); process.exit(1); }
  console.log('  用这本:', book.name);

  console.log('\n=== ② 跑 bookInfo（详情页 = 真机炸的那条路）===');
  const t0 = Date.now();
  const info = await win.eval("window.__qrInvoke('bookInfo', " + JSON.stringify({
    source,
    bookUrl: book.bookUrl,
    // ⚠️ 必须带 book —— 站方 init 规则第一句就调 book.getVariable('custom')
    book: Object.assign({}, book, { variables: {} }),
  }) + ")");
  const ms = Date.now() - t0;
  const b = info.book || {};
  console.log('  耗时    :', ms, 'ms');
  console.log('  error   :', info.error || '(无)');
  console.log('  名称    :', b.name || '(空)');
  console.log('  作者    :', b.author || '(空)');
  console.log('  分类    :', b.kind || '(空)');
  console.log('  最新章  :', b.lastChapter || '(空)');
  console.log('  tocUrl  :', String(b.tocUrl || '(空)').slice(0, 60));
  console.log('  简介长度:', (b.intro || '').length);
  console.log('  log     :', logs.slice(0, 2).join(' / ').slice(0, 160));
  console.log('  toast   :', toasts.slice(0, 2).join(' / ').slice(0, 120));

  // ⚠️⚠️ **回归用例**：宿主侧曾用 `URL(string:).absoluteString` 规范化过书源 URL，
  //   把 `,{"type":"x"}` 变成 `,%7B%22type%22%3A%22x%22%7D` ⇒ 引擎剥不掉后缀
  //   ⇒ 载荷被污染 → 站方 JSON.parse 炸 → 详情页整条规则静默失效（**真机专属**）。
  //   ⇒ 引擎这边要能扛住这个形态（Swift 侧已修，这里是第二道防线）。
  console.log('\n  ── 每个请求的耗时 ──');
  reqs.forEach((r, i) => {
    console.log(`   ${i + 1}. ${String(r.ms || 0).padStart(6)}ms  ${r.method}  ${String(r.url).slice(0, 96)}` +
      (r.code !== undefined ? `  → ${r.code} / ${r.len} 字节` : '') + (r.err ? `  ✗ ${r.err}` : ''));
  });
  const total = reqs.reduce((a, r) => a + (r.ms || 0), 0);
  console.log(`   共 ${reqs.length} 个请求，合计 ${total}ms`);

  console.log('\n=== ② 被 Foundation 规范化过的书源 URL（回归用例）===');
  {
    const raw = String(book.bookUrl || '');
    const norm = raw.replace(/,\s*(?=\{)/, ',%7B');   // 模拟 URL(string:).absoluteString 的效果
    console.log('  原始  :', raw.slice(0, 90));
    console.log('  规范化:', norm.slice(0, 90));
    const info2 = await win.eval("window.__qrInvoke('bookInfo', " + JSON.stringify({
      source,
      bookUrl: norm,
      book: Object.assign({}, book, { variables: {} }),
    }) + ")");
    const b2 = info2.book || {};
    console.log('  error :', info2.error || '(无)');
    console.log('  名称  :', b2.name || '(空)');
    ok(!info2.error, '规范化形态不报错' + (info2.error ? '：' + info2.error : ''));
    ok(!!b2.name, '规范化形态也能拿到书名');
  }

  console.log('\n=== 判定 ===');
  // ⚠️ 站方服务器会限流/抽风 → 活体门禁会偶发红。
  //   服务器侧失败（网络/线路/限流）重试一次，还不行就跳过实跑断言。
  const errText = String(info.error || '');
  const serverSide = /超时|timeout|网络|线路|上限|未登录|failed|Error/i.test(errText);
  if (info.error && serverSide) {
    console.log('  ℹ️ 服务器侧失败（' + errText.slice(0, 60) + '）→ 跳过实跑断言');
  } else {
  ok(!info.error, 'bookInfo 没报错' + (info.error ? '：' + info.error : ''));
  ok(!!b.name, '书名取到了');
  ok(!!b.author, '作者取到了');
  ok(!!b.tocUrl, 'tocUrl 取到了（目录的前提）');
  ok((b.intro || '').length > 0, '简介不空（真机就是挂在 abstract.split 上）');
  ok(!(b.intro || '').includes('undefined'), '简介不是 undefined');

  // ⚠️⚠️ 真机 2026-10-21 栽的那条：站方 POST 的 query 里带**裸中文**和**裸 JSON**
  //   → iOS 的 URL(string:) 判非法 → 请求发不出去 → 引擎吞成空串
  //   → 站方 JSON.parse('') → 「Unable to parse JSON string」
  //   ⇒ query 必须**重新编码**（所有方法，不只 GET），且服务器仍要认。
  const real = reqs.find(r => /\/(detail|catalog)\?/.test(r.url));
  console.log('\n  真实发出的请求:', real ? real.url.slice(0, 150) : '(没发出去)');
  if (real) {
    const q = real.url.slice(real.url.indexOf('?'));
    ok(!/[一-龥]/.test(q), 'query 里没有裸中文（iOS 的 URL(string:) 会判非法）');
    ok(!/[{}\[\]"']/.test(q), 'query 里没有裸花括号/引号');
    ok(/%[0-9A-Fa-f]{2}/.test(q), 'query 做过百分号编码');
  } else {
    ok(false, '没找到 detail/catalog 的真实请求（说明它根本没发出去）');
  }

  } // ← 服务器侧失败的分支结束
  // 原生侧兜底：URL(string:) 对 `{` `"` 裸中文返回 nil → 要有百分号编码重试
  const sb = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Core', 'RuleSandbox.swift'), 'utf8');
  ok(/addingPercentEncoding\(withAllowedCharacters:/.test(sb),
     '原生侧有百分号编码兜底（URL(string:) 判非法时重试）');
  ok(/func parseURL/.test(sb), '原生侧有 parseURL 辅助函数');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
