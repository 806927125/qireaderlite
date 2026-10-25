#!/usr/bin/env node
/**
 * 目录性能 A/B：v1（原版规则，每章一次 <js>）vs v2（列表阶段一次算完）
 *
 * 跑法：
 *   node test/bench-toc.js --src <书源.json> [--book <book.json>] [--out <book.json>]
 *
 * 为什么要它：
 *   大灰狼的 ruleToc.chapterUrl 是**每章一次** `<js>`（base64 + JSON.stringify）。
 *   2000+ 章 → 引擎要跑 2000+ 次 JS。真机（WKWebView）上这一步很慢，
 *   表现是「目录一直转不出来 / 像卡死」。
 *   ⇒ 必须**用同一本书**量两次，才知道 v2 到底省了多少。
 *
 * ⚠️ 番茄有「免登录访问次数上限（3 次）」→ 正文会变成提示句，这里只关心目录。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const args = process.argv.slice(2);
function arg(name, dflt) {
  const i = args.indexOf('--' + name);
  return i >= 0 ? args[i + 1] : dflt;
}

const SRC = arg('src', '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json');
const BOOK_FILE = arg('book', '/workspace/out/bench-book.json');
const OUT_BOOK = arg('out', '');

const UA = 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';

const jar = {};
const toasts = [];
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
        if (i > 0) { jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim(); }
      }
      return { ok: true, value: '1' };
    }
    case 'toast': toasts.push(String(args.msg || '')); return { ok: true };
    case 'log': return { ok: true, value: '' };
    case 'deviceID': return { ok: true, value: 'test-device' };
    case 'getWebViewUA': return { ok: true, value: UA };
    default: return { ok: true, value: '' };
  }
}

(async () => {
  const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
  const src = (Array.isArray(list) ? list : [list])
    .find(s => s && s.bookSourceUrl && s.ruleExplore && s.ruleToc) || list[0];
  const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

  const { win } = createSandbox({ nativeMock });

  let book = null;
  if (fs.existsSync(BOOK_FILE)) {
    book = JSON.parse(fs.readFileSync(BOOK_FILE, 'utf8'));
    console.log('用固定的書:', book.name);
  } else {
    console.log('=== 探索（第一次跑，固定一本书给后面复用）===');
    const kinds = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({ source })})`);
    const allKinds = kinds.kinds || [];
    const picked = allKinds.find(k => /get_discover/.test(String(k.url || ''))) || allKinds.find(k => k.url);
    const ex = await win.eval(`window.__qrInvoke('explore', ${JSON.stringify({
      source, kindUrl: picked.url, page: 1,
    })})`);
    const books = ex.books || [];
    console.log('  探索到书:', books.length);
    book = books[0];
    if (!book) { console.log('❌ 没书'); process.exit(1); }
    if (OUT_BOOK) {
      fs.writeFileSync(OUT_BOOK, JSON.stringify(book, null, 2));
      console.log('  已固定到', OUT_BOOK);
    }
  }

  console.log('\n=== toc（计时）===');
  const t0 = Date.now();
  const t = await win.eval("window.__qrInvoke('toc', " + JSON.stringify({
    source,
    bookUrl: book.bookUrl,
    book: Object.assign({}, book, { variable: 'custom' }),
    maxPages: 1,
  }) + ")");
  const ms = Date.now() - t0;
  const chs = t.chapters || [];
  const withUrl = chs.filter(c => c && c.url).length;
  console.log('  书      :', book.name);
  console.log('  章节数  :', chs.length, '| 有 url:', withUrl);
  console.log('  耗时    :', ms, 'ms');
  console.log('  error   :', t.error || '(无)');
  if (chs.length) {
    console.log('  第1章   :', chs[0].title, '→', String(chs[0].url || '').slice(0, 40));
  }
  console.log('\nJSON ' + JSON.stringify({ src: path.basename(SRC), book: book.name, chapters: chs.length, ms }));
  process.exit(0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
