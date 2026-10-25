#!/usr/bin/env node
/**
 * 微基准：**每章 URL 求值**的耗时（把网络完全排除在外）
 *
 * 跑法：node test/bench-chapterurl.js --src <书源.json> [--n 2566]
 *
 * 为什么要它：
 *   大灰狼的 chapterUrl 是每章一次 <js>（base64 + JSON.stringify）。
 *   目录 2000+ 章 → 2000+ 次 JS 求值。**这才是真机「目录转不出来」的主嫌**。
 *   v2 把它挪到列表阶段一次算完 → 每章 0 次 JS（只剩一条 JSONPath）。
 *   ⇒ 用同一批章节对象，分别量 v1 规则 和 v2 规则 的求值耗时。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const args = process.argv.slice(2);
function arg(name, dflt) {
  const i = args.indexOf('--' + name);
  return i >= 0 ? args[i + 1] : dflt;
}
const SRC = arg('src', '/workspace/out/dhl-adapt-v1.json');
const N = parseInt(arg('n', '2566'), 10);

const UA = 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';

async function nativeMock(fn, args) {
  switch (fn) {
    case 'toast': case 'log': return { ok: true, value: '' };
    case 'deviceID': return { ok: true, value: 'test-device' };
    case 'getWebViewUA': return { ok: true, value: UA };
    default: return { ok: true, value: '' };
  }
}

(async () => {
  const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
  const src = (Array.isArray(list) ? list : [list])
    .find(s => s && s.bookSourceUrl && s.ruleToc) || list[0];

  const { win } = await createSandbox({ nativeMock });
  const source = Object.assign({}, src, { __variables: '', __loginInfo: {} });

  // 造一批「像真目录」的章节对象
  const chapters = [];
  for (let i = 0; i < N; i++) {
    chapters.push({
      item_id: 'MzQ' + (90000000 + i),
      title: '第' + (i + 1) + '章 测试标题',
      tab: '小说',
      source: '番茄小说',
      toc_url: 'https://example.invalid/ch/' + (i + 1),
    });
  }

  // 站方 chapterList 里 java.put('book_id', ...) 的值 —— chapterUrl 会 java.get 它
  await win.eval("window.__qrInvoke('noop', {})").catch(() => {});
  await win.eval(`(function(){ if (window.QR) { QR.runtime = QR.runtime || {}; QR.runtime.vars = QR.runtime.vars || {}; QR.runtime.vars['book_id'] = 'NzQ5OTk5OTk5OTk5'; } })()`);

  const rule = (src.ruleToc || {}).chapterUrl;
  const ctx = { baseUrl: 'https://example.invalid/', source, book: { variables: {} } };

  console.log('源      :', path.basename(SRC));
  console.log('章节数  :', N);
  console.log('chapterUrl 规则长度:', String(rule).length);

  // 先热身（排除 JIT / 首次 new Function 的开销）
  await win.eval(`window.__qrBench = (async function(){
     var out = [];
     for (var i = 0; i < 5; i++) {
       out.push(await QR.rule.getValue(${JSON.stringify(rule)}, ${JSON.stringify(chapters[0])}, ${JSON.stringify(ctx)}));
     }
     return out;
  })()`);

  const t0 = Date.now();
  const res = await win.eval(`window.__qrBench = (async function(){
     var __chs = ${JSON.stringify(chapters)};
     var out = [];
     for (var i = 0; i < ${N}; i++) {
       out.push(await QR.rule.getValue(${JSON.stringify(rule)}, __chs[i], ${JSON.stringify(ctx)}));
     }
     return out;
  })()`);
  const ms = Date.now() - t0;
  const arr = res && res.result !== undefined ? res.result : res;
  const vals = Array.isArray(arr) ? arr : [];
  const okCount = vals.filter(v => v && String(v).length > 10).length;
  console.log('耗时    :', ms, 'ms  (', (ms / N).toFixed(3), 'ms/章 )');
  console.log('有值的  :', okCount, '/', N);
  console.log('样例    :', String(vals[0] || '').slice(0, 60));
  process.exit(0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
