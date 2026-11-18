#!/usr/bin/env node
/**
 * ⭐⭐⭐ **站方 URL 选项里的 `charset` 要被采纳**（2026-11-18 · 对齐栖阅 AnalyzeUrl）
 *
 * 跑法：node test/charset-option-contract.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景（「轻阅不行、柴阅可以」的一类真因）
 *
 *   栖阅的 URL 选项键全集里有 **`charset`**（`AnalyzeUrl` 反推规格 §3.2）⇒
 *   柴阅（与栖阅同构）⇒ **认**站方显式指定的字符集。
 *
 *   而老站（GBK / GB2312 / Big5）**经常不声明、或声明错** `Content-Type` 的 charset
 *   ⇒ 只按响应头解码 ⇒ **正文/标题全是乱码** ⇒ 用户看到「这个源在轻阅里不行」。
 *
 *   本地语料实测用到 `charset` 的源（3 个）：
 *   · 同人小说（优）  gb2312
 *   · 晋江文学        gbk
 *   · 998读书         GBK
 *
 * ✅ 正确口径：**站方指定的 charset 优先于响应头**（原生层 `RuleSandbox.perform`）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? (pass++, console.log('  ✓ ' + m)) : (fail++, console.log('  ✗ ' + m)); };

const root = path.join(__dirname, '..');
const engineDir = path.join(root, 'QiReaderLite', 'Resources', 'engine');
const engineSrc = fs.readFileSync(path.join(engineDir, 'engine.js'), 'utf8');
const javaApiSrc = fs.readFileSync(path.join(engineDir, 'java-api.js'), 'utf8');
const analyzeUrlSrc = fs.readFileSync(path.join(root, 'QiReaderLite', 'Core', 'AnalyzeUrl.swift'), 'utf8');
const sandboxSrc = fs.readFileSync(path.join(root, 'QiReaderLite', 'Core', 'RuleSandbox.swift'), 'utf8');

(async () => {
  console.log('=== 1. 静态：JS 侧解析并透传 charset ===');
  ok(/charset:\s*String\(opt\.charset/.test(engineSrc),
     "engine.js 的 analyzeUrl 把 opt.charset 取出来");
  ok(/target\.charset/.test(engineSrc),
     "engine.js 的 fetchPage 把 charset 交给 rawRequest");
  ok(/charset:\s*charset\s*\?\s*String\(charset\)\s*:\s*''/.test(javaApiSrc),
     "java-api.js 的 rawRequest 把 charset 透传给原生");
  ok(/rawRequest\(url, method, headers, data, timeout, charset/.test(javaApiSrc),
     "rawRequest 的签名多了 charset 参数");

  console.log('\n=== 2. 静态：原生侧按站方指定的 charset 解码 ===');
  ok(/charset:\s*String/.test(analyzeUrlSrc), "AnalyzeUrl 解析出 charset");
  ok(/var charsetName = hasOption \? parsed\.charset/.test(sandboxSrc),
     "原生请求层取站方指定的 charset（URL 选项优先）");
  ok(/charsetName\.isEmpty\s*\n?\s*\?\s*Self\.charset\(of: http\?\.textEncodingName\)/.test(sandboxSrc)
     || /let charset = charsetName\.isEmpty/.test(sandboxSrc),
     "解码时：站方指定优先，没有才按响应头");

  console.log('\n=== 3. 活体：引擎抓带 `,{"charset":"gbk"}` 的 URL ⇒ 原生收到 charset ===');
  {
    const seen = [];
    const { win } = createSandbox({
      origin: 'https://x.com',
      nativeMock: async (fn, args) => {
        if (fn === 'request') {
          seen.push(args);
          return { ok: true, code: 200, body: '<html><body>x</body></html>' };
        }
        return { ok: true, code: 200, body: '' };
      },
    });
    const chapterUrl = 'http://y.com/c?a=1,{"charset":"gbk"}';
    const src = {
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'charset 门禁源',
      searchUrl: '', exploreUrl: '',
      ruleSearch: { name: '', bookUrl: '' },
      ruleBookInfo: { name: 'x', author: '', intro: '', kind: '', lastChapter: '', coverUrl: '', tocUrl: '', wordCount: '' },
      ruleToc: { chapterList: '' },
      ruleContent: { content: chapterUrl },
    };
    try {
      await win.eval(`window.__qrInvoke('content', ${JSON.stringify({
        source: src, bookUrl: 'http://y.com/b', chapterUrl,
        book: { bookUrl: 'http://y.com/b', name: '', author: '', intro: '' },
        chapter: { url: chapterUrl, name: 'c', index: 0 },
      })})`);
    } catch (e) { /* 门禁只关心请求参数，不关心正文 */ }
    const hit = seen.find(a => String(a.url || '').indexOf('y.com/c') >= 0);
    console.log('  原生收到的请求 =', hit ? JSON.stringify({ url: String(hit.url).slice(0, 60), charset: hit.charset }) : '(没抓到)');
    ok(!!hit, '引擎确实发了这个请求');
    ok(hit && String(hit.charset || '').toLowerCase() === 'gbk',
       '⭐⭐⭐ 原生收到了 charset=gbk（站方指定的字符集没被丢掉）');
  }

  console.log('\n=== 4. 回归：本地语料里用到 charset 的源（3 个）===');
  {
    const pack = path.join(root, 'sources', '配置文件125个-轻阅适配版.json');
    if (!fs.existsSync(pack)) {
      console.log('  (跳过：本地没有 125 源包)');
    } else {
      const arr = JSON.parse(fs.readFileSync(pack, 'utf8'));
      const names = [];
      for (const s of (Array.isArray(arr) ? arr : [arr])) {
        // ⚠️ 要在**原始字符串**里找（选项里的引号在 JSON 字符串里是转义的 ⇒ stringify 后匹配不到）
        const raw = [s.searchUrl, s.exploreUrl].map(x => typeof x === 'string' ? x : JSON.stringify(x || '')).join('\n');
        if (/"charset"\s*:\s*"(gbk|gb2312)"/i.test(raw)) names.push(s.bookSourceName);
      }
      console.log('  用到 charset 的源 =', names.join(' / '));
      ok(names.length >= 3, '⭐ 语料里确实有 3 个源用 charset（这条门禁不是摆设）');
    }
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
