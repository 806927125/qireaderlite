#!/usr/bin/env node
/**
 * **正文空 —— 复现脚本**（2026-10-21 真机报告：详情/目录/发现都过，正文空）
 *
 * 跑法：node test/repro-content.js
 *
 * 目标：把大灰狼的「发现 → 详情 → 目录 → 正文」整条链在沙盒里跑一遍，
 *      打印每一次真实请求（URL + cookie + 响应开头），
 *      定位「正文 content = ''」到底断在哪一步。
 *
 * ⚠️ 关键前置：**预置 qttoken cookie**（真机上来自 cookie 罐）
 *    —— 不带 qttoken，服务器直接回「您今日免登录访问次数已达上限(3次)」。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

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
      if (!headers.cookie) {
        const h = hostOf(url);
        headers.cookie = jar[h] || COOKIE;   // 兜底给 qttoken
      }
      console.log(`\n  [REQ#${++n}] ${method} ${url.slice(0, 200)}`);
      console.log(`     cookie : ${String(headers.cookie || '').slice(0, 140)}`);
      if (args.body) console.log(`     body   : ${String(args.body).slice(0, 260)}`);
      try {
        const res = await fetch(url, {
          method, headers,
          body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
          redirect: 'follow',
        });
        const text = await res.text();
        const h = hostOf(url);
        for (const line of (res.headers.getSetCookie ? res.headers.getSetCookie() : [])) {
          const kv = line.split(';')[0]; const i = kv.indexOf('=');
          if (i > 0) { jar[h] = jar[h] || {}; jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim(); }
        }
        console.log(`     ← ${res.status} ${text.length}B  ${text.slice(0, 200).replace(/\n/g, ' ')}`);
        return { ok: true, code: res.status, url: res.url, headers: {}, body: text };
      } catch (e) {
        console.log(`     ✗ ${e && e.message}`);
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
    case 'log': console.log('  [LOG] ' + String(args.msg || '').slice(0, 260)); return { ok: true };
    case 'toast': console.log('  [TOAST] ' + String(args.msg || '')); return { ok: true };
    case 'deviceID': return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
    case 'getWebViewUA': return { ok: true, value: UA };
    default: return { ok: true, value: '' };
  }
}

const SNAP = { 'langge.uk': COOKIE };

(async () => {
  const { win } = createSandbox({ nativeMock });
  // ⭐ hook java.ajax：看每一遍到底 ajax 了哪个 URL、拿回什么
  const _origAjax = win.java.ajax;
  win.java.ajax = function (u) {
    const r = _origAjax.apply(this, arguments);
    const key = String((u && typeof u === 'object') ? (u.url || '') : (u || ''));
    const v = (typeof r === 'string') ? (r.length > 80 ? r.slice(0, 80) + '…' : r) : ('<' + typeof r + '>');
    console.log('  [AJAX] ' + key.slice(0, 110) + '\n         → ' + JSON.stringify(v));
    return r;
  };
  const VARS = JSON.stringify({
    tab: '漫画', tone_id: '4', shuqi_tone_id: 'multi_role',
    server: 'http://219.154.201.122:5006', sources: '番茄',
    source_type: '男频', fqpara: 'on', fqcommunity: 'on', pstyle: '0'
  });
  const source = Object.assign({}, src, { __variables: VARS, __loginInfo: {} });
  const base = { source, cookieSnapshot: SNAP };

  // ⭐ 直接复现**真机状态**：详情链 setArguments 改过 server ⇒ base_url = 兜底 IP 线路
  const BOOKURL = 'data:;base64,eyJib29rX2lkIjoiTnpBNU5qazFNalkyTmpBd09UTTNNemN6TXciLCJzb3VyY2VzIjoi55Wq6IyEIiwidGFiIjoi5ryr55S7IiwidXJsIjoiIn0=,{"type":"qingtian"}';
  const book = { name: '斗罗大陆', bookUrl: BOOKURL, variable: 'custom' };

  console.log('=== ③ bookInfo（真机跑过：会切线路 + setArguments 改 server）===');
  const bi = await win.eval(`window.__qrInvoke('bookInfo', ${JSON.stringify(
    Object.assign({}, base, { bookUrl: book.bookUrl, book: Object.assign({}, book, { variable: 'custom' }) }))})`);
  console.log('  error:', bi.error || '(无)');
  console.log('  书名:', bi.name, '| 最新:', String(bi.lastChapter || '').slice(0, 40));

  console.log('\n=== ④ toc ===');
  const t = await win.eval(`window.__qrInvoke('toc', ${JSON.stringify(
    Object.assign({}, base, { bookUrl: book.bookUrl, book: Object.assign({}, book, { variable: 'custom' }), maxPages: 1 }))})`);
  const chs = t.chapters || [];
  console.log('  error:', t.error || '(无)', '| 章节数:', chs.length);
  if (!chs.length) { console.log('❌ 没章节，正文没法测'); process.exit(1); }
  console.log('  第一章:', chs[0].title, '| url:', String(chs[0].url).slice(0, 100));

  console.log('\n=== ⑤ content（重点）===');
  const c = await win.eval(`window.__qrInvoke('content', ${JSON.stringify(
    Object.assign({}, base, {
      chapterUrl: chs[1].url,
      chapter: Object.assign({}, chs[1], { variable: 'custom' }),
      book: Object.assign({}, book, { variables: {} }),
    }))})`);
  console.log('  error  :', c.error || '(无)');
  console.log('  标题   :', c.title);
  console.log('  正文长度:', (c.content || '').length);
  console.log('  正文开头:', String(c.content || '').slice(0, 160).replace(/\n/g, ' '));
  console.log(`\n${(c.content || '').length > 10 ? '✅ 正文拿到了' : '❌ 正文是空的'}`);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
