#!/usr/bin/env node
/**
 * 发现页**真机联调**（真网络 + 真聚合源）
 *
 * 跑法：node test/live-explore.test.js
 *
 * 背景：用户真机「发现页没有书」，而 App 里的「发现页诊断」说：
 *     状态码 200 / 响应字节 5877 / 正文开头 {"code":0,...,"data":[{...}]}
 *     规则命中元素: 0 / 结论: 规则只命中 0 个元素 —— 书单页结构跟规则对不上
 *
 * ⚠️ 但那条诊断（engine.js 的 explain op）**自己就按 HTML 解析**去数 CSS 节点
 *    → 对 JSON 接口源来说**结论必然是「命中 0 个」** → **它是误导**。
 *    真正的 explore 路径有 JSON 分支（ctx.isJSON → jsonpath）。
 *
 * 这个测试跑**真正的 explore op**，看真实结果。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const SRC = process.env.SRC_OUT ||
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json';
if (!fs.existsSync(SRC)) {
  console.log('ℹ️  适配版聚合源不在本机 → 跳过');
  process.exit(0);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.ruleExplore) || list[0];

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
          const kv = line.split(';')[0];
          const i = kv.indexOf('=');
          if (i > 0) {
            jar[h] = jar[h] || {};
            jar[h][kv.slice(0, i).trim()] = kv.slice(i + 1).trim();
          }
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
    case 'log': return { ok: true };
    case 'deviceID': return { ok: true, value: 'test-device' };
    default: return { ok: true, value: '' };
  }
}

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  const { win } = createSandbox({ nativeMock });
  const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

  console.log('=== ① exploreKinds（分类）===');
  const kinds = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({ source })})`);
  console.log('  分类数:', (kinds.kinds || []).length);
  console.log('  前 3 个:', (kinds.kinds || []).slice(0, 3).map(k => k.title).join(' / '));

  console.log('\n=== ② explore（真跑发现页列表）===');
  // ⚠️ 前几个 kind 是**分组标题**（线路/模式/频道…）没有 url → 要挑有 url 的真分类
  const allKinds = kinds.kinds || [];
  // ⚠️ 只挑**真分类**（URL 是 get_discover…）——
  //    有些分类是「动作按钮」（URL 是 {{java.startBrowser(...)}}），不是列表页
  const picked = allKinds.find(k => /get_discover/.test(String(k.url || '')));
  const kindUrl = (picked && picked.url) || '';
  console.log('  用分类:', picked && picked.title, '→', kindUrl ? kindUrl.slice(0, 90) : '(无)');
  const r = await win.eval(`window.__qrInvoke('explore', ${JSON.stringify({
    source, kindUrl, page: 1,
  })})`);

  console.log('  error  :', r.error || '(无)');
  console.log('  total  :', r.total);
  console.log('  books  :', (r.books || []).length);
  for (const b of (r.books || []).slice(0, 3)) {
    console.log(`    · ${b.name}  | ${b.author} | ${b.bookUrl ? '有URL' : '★无URL'}`);
  }
  if (r.books && r.books.length) console.log('  toast  :', toasts.slice(0, 3).join(' / '));

  console.log('\n=== 判定 ===');
  ok((kinds.kinds || []).length > 0, '发现页分类出来了');
  ok(!r.error, 'explore 没报错' + (r.error ? '：' + r.error : ''));
  ok((r.books || []).length > 0, `explore 出书了（现在 ${(r.books || []).length} 本）`);
  ok((r.books || []).every(b => b.name), '每本书都有名字');
  ok((r.books || []).some(b => b.bookUrl), '至少一本有 bookUrl（点进去要能开）');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
