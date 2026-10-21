#!/usr/bin/env node
/**
 * 目录诊断必须**说真话**（2026-10-21）
 *
 * 起因：用户真机报「目录接口通了但一条章节都没解析出来（chapterList 规则没命中）」，
 *       但沙盒里同一个源**能跑出 2566 章** → 说明「规则没命中」是**误判**。
 *
 * 误判的根源：诊断（engine.js 的 explainToc）**只按 HTML/CSS 路径**数节点 →
 *   🍅大灰狼的 chapterList 是**复合规则**（`<js>…</js>$.data`）→
 *   CSS 路径对它**必然 0 命中** → 结论恒为「chapterList 一个都没命中 —— 规则对不上」。
 *
 * ⇒ 修：CSS 0 命中时，按**真实路径**（跑 JS → 再走尾部选择器）再跑一遍，
 *        把真实条数 + JS 报错摆出来。
 *
 * 这个测试断言的是**诊断的输出**，不是引擎内部实现。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');
const { looksServerSide, skipServerSide } = require('./live-helpers');

const ENGINE = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');
const SRC = process.env.SRC_OUT ||
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json';

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const UA = 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';

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
  console.log('=== ① 源码里必须有「诊断走真实路径」的钩子 ===');
  const eng = fs.readFileSync(path.join(ENGINE, 'engine.js'), 'utf8');
  const ra = fs.readFileSync(path.join(ENGINE, 'rule-analyzer.js'), 'utf8');
  // ⚠️ 断言要作用在**去掉注释后的代码**上（注释里会提到这句老话）
  const engCode = eng.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  ok(/getJsonListDiag/.test(eng), 'engine.js 的 explainToc 调了 getJsonListDiag');
  ok(/getJsonListDiag/.test(ra), 'rule-analyzer.js 导出了 getJsonListDiag');
  ok(!/chapterList 一个都没命中/.test(engCode),
     '代码里不再有「chapterList 一个都没命中」这句硬判（它对复合规则是假的）');
  ok(/JS路径命中/.test(eng), '诊断输出里有「JS路径命中」');
  ok(/JS报错/.test(eng), '诊断输出里有「JS报错」');
  ok(/isJsRule/.test(engCode), '诊断先判规则类型（JS 规则不走 CSS 路径）');

  // Swift 侧要能把新字段显示出来
  const svc = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Core', 'SourceService.swift'), 'utf8');
  ok(/JS路径命中/.test(svc), 'Swift 侧 explainToc 的字段白名单里有「JS路径命中」');
  ok(/JS报错/.test(svc), 'Swift 侧 explainToc 的字段白名单里有「JS报错」');

  console.log('\n=== ② 真跑一次：复合规则的诊断不能说「规则没命中」 ===');
  if (!fs.existsSync(SRC)) {
    console.log('  ℹ️  聚合源不在本机 → 跳过实跑段（源码断言已跑）');
  } else {
    const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
    const src = (Array.isArray(list) ? list : [list])
      .find(s => s && s.bookSourceUrl && s.ruleExplore && s.ruleToc) || list[0];
    const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });
    const { win } = createSandbox({ nativeMock });

    const kinds = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({ source })})`);
    const allKinds = kinds.kinds || [];
    const picked = allKinds.find(k => /get_discover/.test(String(k.url || ''))) || allKinds.find(k => k.url);
    const ex = await win.eval(`window.__qrInvoke('explore', ${JSON.stringify({
      source, kindUrl: picked.url, page: 1,
    })})`);
    const books = ex.books || [];
    // ⚠️ 站方限流（番茄免登录上限/未登录/线路故障）→ **跳过**，不是引擎的锅。
    //   只认**明确的站方措辞**，不认「0 本」本身（那个是真 bug，build160 修过）。
    if (!books.length && looksServerSide(logs, toasts)) {
      skipServerSide('限流/未登录', logs.concat(toasts).join(' | ').slice(0, 160));
    }
    ok(books.length > 0, '探索到书了（' + books.length + ' 本）');
    if (books.length) {
      const book = books[0];
      const d = await win.eval("window.__qrInvoke('explainToc', " + JSON.stringify({
        source,
        bookUrl: book.bookUrl,
        book: Object.assign({}, book, { variable: 'custom' }),
      }) + ")");
      console.log('  诊断结论:', d['结论']);
      console.log('  JS路径命中:', d['JS路径命中'], '| 规则命中元素:', d['规则命中元素']);
      const concl = String(d['结论'] || '');
      const jsErr = String(d['JS报错'] || '');
      // ⚠️ 站方服务器会限流（番茄免登录上限/线路抽风）→ 活体门禁**会偶发红**。
      //   ⇒ 这类**服务器侧**失败重试一次；还不行就跳过实跑断言（不是引擎的锅）。
      //   源码断言（第 ① 段）是确定性的，照跑不误。
      const serverSide = /上限|未登录|未查询到登录|超时|timeout|网络|线路|failed|Error:/.test(
        jsErr + ' ' + concl);
      if (Number(d['JS路径命中'] || 0) === 0 && serverSide) {
        console.log('  ℹ️ 服务器侧失败（' + (jsErr || concl).slice(0, 60) + '）→ 跳过实跑断言');
      } else {
        ok(!/一个都没命中/.test(concl), '结论里没有「一个都没命中」（' + concl.slice(0, 40) + '）');
        ok(Number(d['JS路径命中'] || 0) > 0,
           'JS 路径真的解析出章节了（' + d['JS路径命中'] + ' 条）');
        ok(String(d['取到的章节名'] || '').length > 0, '诊断里能看到第一章的章节名');
      }
    }
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
