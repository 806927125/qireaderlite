#!/usr/bin/env node
/**
 * **聚合源平台切换联调**（2026-10-22 真机反馈）
 *
 *   ① 发现页加载「番茄」很慢很慢，其他平台挺快
 *   ② 切到「QQ 阅读」后**目录出不来**
 *
 * 跑法：node test/platform-switch.test.js
 *
 * ⚠️ 这个脚本**测网络**（站方活体）⇒ 会有波动；只作诊断用，不进门禁。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const SRC = process.env.SRC ||
  path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');
const raw = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(raw) ? raw : [raw])[0];

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 '
  + '(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
const COOKIE = process.env.QR_COOKIE || 'qttoken=Q8eBmA4mSisRUqhV; deviceId=0o6q14mk3z3qmvi6dtvf';

let n = 0;
const jar = {};
function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

async function nativeMock(fn, args) {
  switch (fn) {
    case 'request': {
      const url = String(args.url || '');
      const method = (args.method || 'GET').toUpperCase();
      const headers = Object.assign({ 'User-Agent': UA }, args.headers || {});
      if (!headers.cookie) headers.cookie = COOKIE;
      const t0 = Date.now();
      console.log(`      [REQ#${++n}] ${method} ${url.slice(0, 120)}`);
      try {
        const res = await fetch(url, {
          method, headers,
          body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
          redirect: 'follow',
        });
        const text = await res.text();
        console.log(`      ← ${res.status} ${text.length}B ${Date.now() - t0}ms`);
        return { ok: true, code: res.status, url: res.url, headers: {}, body: text };
      } catch (e) {
        console.log(`      ✗ ${e && e.message} (${Date.now() - t0}ms)`);
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
    case 'log': return { ok: true };
    case 'toast': console.log('      [TOAST] ' + String(args.msg || '').slice(0, 120)); return { ok: true };
    case 'deviceID': return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
    case 'getWebViewUA': return { ok: true, value: UA };
    default: return { ok: true, value: '' };
  }
}

const SNAP = { 'langge.uk': COOKIE };

/** 站方默认变量表（getArguments 的兜底） */
function varsWith(platform, tab) {
  return JSON.stringify({
    tab: tab || '小说',
    tone_id: '默认音色',
    shuqi_tone_id: 'multi_role',
    server: 'https://v5.langge.uk',
    sources: '全部',
    source_type: '男频',
    find_source: platform,
    find_tab: tab || '小说',
    fqpara: 'on',
    fqcommunity: 'on',
    pstyle: '0',
  });
}

(async () => {
  const { win } = createSandbox({ nativeMock });

  const platforms = (process.env.PLATFORMS || '番茄,七猫,QQ阅读').split(',');

  for (const p of platforms) {
    console.log(`\n════════ 平台：${p} ════════`);
    n = 0;
    const source = Object.assign({}, src, { __variables: varsWith(p), __loginInfo: {} });
    const base = { source, cookieSnapshot: SNAP };

    // ── ① exploreKinds（分类 + 筛选栏）──
    const t0 = Date.now();
    const kd = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify(base)})`);
    const ms = Date.now() - t0;
    const kinds = kd.kinds || [];
    const filters = kd.filters || [];
    console.log(`  exploreKinds 耗时 ${ms}ms · 分类 ${kinds.length} · 筛选项 ${filters.length}`);
    console.log('  筛选项:', filters.map(f => `${f.title}=${f.default}`).join(' | ') || '(无)');
    const real = kinds.filter(k => k.url && !/个人中心|登录|书架|历史|推荐/.test(k.title));
    console.log('  分类:', (real.length ? real : kinds).slice(0, 5).map(k => k.title).join(' , '));
    const picked = (real.length ? real : kinds).find(k => k.url);
    if (!picked) { console.log('  ❌ 没有可用分类'); continue; }
    console.log('  用分类:', picked.title, '→', String(picked.url).slice(0, 100));

    // ── ② explore（拿书）──
    const t1 = Date.now();
    const ex = await win.eval(`window.__qrInvoke('explore', ${JSON.stringify(
      Object.assign({}, base, { kindUrl: picked.url, page: 1 }))})`);
    const books = ex.books || [];
    console.log(`  explore 耗时 ${Date.now() - t1}ms · ${books.length} 本`);
    const book = books[0];
    if (!book) { console.log('  ❌ 没书'); continue; }
    console.log('  书:', book.name, '| author:', book.author);
    console.log('  bookUrl:', String(book.bookUrl).slice(0, 110));

    // ── ③ bookInfo ──
    const t2 = Date.now();
    const bi = await win.eval(`window.__qrInvoke('bookInfo', ${JSON.stringify(
      Object.assign({}, base, { bookUrl: book.bookUrl, book: Object.assign({}, book, { variable: 'custom' }) }))})`);
    console.log(`  bookInfo 耗时 ${Date.now() - t2}ms · error=${bi.error || '无'} · 书名=${bi.name}`);
    console.log('  tocUrl:', String(bi.tocUrl || '').slice(0, 110));

    // ── ④ toc ──
    const t3 = Date.now();
    const tc = await win.eval(`window.__qrInvoke('toc', ${JSON.stringify(
      Object.assign({}, base, {
        bookUrl: book.bookUrl,
        book: Object.assign({}, book, { variable: 'custom' }),
        maxPages: 1,
      }))})`);
    const chs = tc.chapters || [];
    console.log(`  toc 耗时 ${Date.now() - t3}ms · error=${tc.error || '无'} · 章节 ${chs.length}`);
    for (const c of chs.slice(0, 3)) {
      console.log(`    · ${c.title}  url=${String(c.url || '').slice(0, 70)}`);
    }
  }
})().catch(e => { console.error('炸了：', e); process.exit(2); });
