#!/usr/bin/env node
/**
 * base64 载荷被 URL 动过手脚时，**必须还能解出原文**
 *
 * 起因（真机 2026-10-21）：
 *   🍅大灰狼的 bookUrl 是 `data:;base64,<载荷>`，载荷里**有 + 和 /**（中文 base64 出来的）。
 *   这串当 URL 走一圈，'+' 可能被 URL 解码成**空格**、或被转义成 **%2B**。
 *   而老的 b64decode：空格**直接删掉**、非法字符**静默跳过** →
 *   解出来是**乱码而且不报错** → 站方 `JSON.parse(...)` 抛
 *   「Unable to parse JSON string」→ 详情页整条规则静默失效。
 *
 * ⚠️ 静默跳过是最坏的失败方式：看起来像「服务器返回了坏数据」。
 *
 * 这个测试直接打 java.hexDecodeToString（站方读 data: 载荷的那把钥匙）。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 造一个 base64 里带 '+' 和 '/' 的中文 JSON（必须有，才测得出转义坑） */
function makePayload() {
  for (let i = 0; i < 5000; i++) {
    const obj = { book_id: 'MzQ' + i, sources: '番茄小说', tab: '小说',
                  title: '第' + i + '章 病娇九千岁他又来爬床了', url: '' };
    const json = JSON.stringify(obj);
    const b64 = Buffer.from(json, 'utf8').toString('base64');
    if (b64.includes('+') && b64.includes('/')) return { json, b64 };
  }
  return null;
}

(async () => {
  const p = makePayload();
  ok(!!p, '造出了带 + 和 / 的 base64 载荷');
  if (!p) { console.log(`\n❌ 通过 ${pass} / 失败 ${fail}`); process.exit(1); }
  console.log('  载荷片段:', p.b64.slice(0, 48), '…');
  console.log('  含 + :', p.b64.includes('+'), '| 含 / :', p.b64.includes('/'));

  const { win } = createSandbox({});
  const dec = (s) => win.eval(`String(window.java.hexDecodeToString(${JSON.stringify(s)}))`);

  console.log('\n=== ① 原样 ===');
  const a = await dec(p.b64);
  ok(a === p.json, '原样 base64 能解回原文');
  if (a !== p.json) console.log('    实际:', String(a).slice(0, 120));

  console.log('\n=== ② 被转义成 %2B / %2F ===');
  const esc = p.b64.replace(/\+/g, '%2B').replace(/\//g, '%2F');
  const b = await dec(esc);
  ok(b === p.json, '百分号转义后还能解回原文');
  if (b !== p.json) console.log('    实际:', String(b).slice(0, 120));

  console.log('\n=== ③ 加号被 URL 解码成空格 ===');
  const sp = p.b64.replace(/\+/g, ' ');
  const c = await dec(sp);
  ok(c === p.json, '加号变空格后还能解回原文');
  if (c !== p.json) console.log('    实际:', String(c).slice(0, 120));

  console.log('\n=== ④ URL 安全字符（- 和 _）===');
  const safe = p.b64.replace(/\+/g, '-').replace(/\//g, '_');
  const d = await dec(safe);
  ok(d === p.json, 'URL 安全 base64 能解回原文');
  if (d !== p.json) console.log('    实际:', String(d).slice(0, 120));

  console.log('\n=== ⑤ 源码里要有归一化和「像人话」判定 ===');
  const ja = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine', 'java-api.js'), 'utf8');
  ok(/function b64normalize/.test(ja), '有 b64normalize');
  ok(/function looksLikeText/.test(ja), '有 looksLikeText（乱码要能认出来）');
  ok(/b64normalize\(s\)/.test(ja), 'b64decode 走归一化');
  ok(/looksLikeText\(b64\)/.test(ja), 'hexDecodeToString 会挑「像人话」的那个');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
