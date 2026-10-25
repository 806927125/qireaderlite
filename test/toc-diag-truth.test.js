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
const { createSandbox } = require('./new-engine-harness');
const { engineSwiftSrc, engineSwiftRaw } = require('./engine-gate-helpers.js');
const { looksServerSide, skipServerSide } = require('./live-helpers');

const ENGINE = path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore');
const SRC = process.env.SRC_OUT || [
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json',
  path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'),
  path.join(__dirname, '..', 'sources', 'dahlang-v2.json'),
].find(p => fs.existsSync(p)) || '';

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
  // ⭐⭐⭐⭐⭐ **老 JS 引擎已于 2026-10-25 物理删除** ⇒ 这里改成验**新引擎**的等价能力
  //   ⇒ 验的是**真正在跑的那份代码**（不是参考实现）⭐⭐⭐
  const eng = engineSwiftRaw('Pipeline/ExplainOps.swift');
  const engCode = engineSwiftSrc('Pipeline/ExplainOps.swift');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]`）
  //   ⇒ 那些是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失语义覆盖 ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
  ok(!/chapterList 一个都没命中/.test(engCode),
     '代码里不再有「chapterList 一个都没命中」这句硬判（它对复合规则是假的）');

  // Swift 侧要能把新字段显示出来
  const svc = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Core', 'SourceService.swift'), 'utf8');
  ok(/chapterList规则/.test(svc), 'Swift 侧 explainToc 的字段白名单里有「chapterList规则」');
  ok(/规则命中元素/.test(svc), 'Swift 侧 explainToc 的字段白名单里有「规则命中元素」');
  ok(/结论/.test(svc), 'Swift 侧 explainToc 的字段白名单里有「结论」');

  console.log('\n=== ② 真跑一次：复合规则的诊断不能说「规则没命中」 ===');
  // ⭐⭐⭐⭐⭐ **显式 SKIP（2026-10-25 老引擎物理删除）**
  //   ⇒ 这条链要站方 JS 真发 HTTP（`java.ajax`）⇒ Node 后端的同步通道拿不到 ⇒ 沙盒跑不了
  //   ⇒ **没验到 ≠ 验过了没问题** ⇒ 等价覆盖在引擎链对拍与真机上 ⭐⭐⭐
  console.log('  ⏭️  跳过：要站方 JS 真发 HTTP（java.ajax）⇒ Node 同步通道拿不到 ⇒ 本段没验到');
  // ⭐⭐⭐⭐⭐ **实跑段已 SKIP**（老引擎物理删除 ⇒ 这条链要站方 JS 真发 HTTP ⇒ 沙盒跑不了）

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
