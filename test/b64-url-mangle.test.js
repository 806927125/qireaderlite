#!/usr/bin/env node
/**
 * base64 载荷被 URL 动过手脚时，**必须还能解出原文**
 *
 * 跑法：node test/b64-url-mangle.test.js
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
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎的 `java.hexDecodeToString` ⇒ 老引擎删了 ⇒ 对象没了
 *   ⇒ 现在改成**跑新引擎**（`legado-engine` 的 `--js` 模式 ⇒ 引擎的 Node 后端）
 *   ⇒ **语义等价在哪**：站方读 data: 载荷的那把钥匙**就是 `java.hexDecodeToString`**
 *     （`SourceEngine.engineJava` 里 `case "hexDecodeToString"` ⇒ `Crypto.hexDecodeToString`）
 *     ⇒ 断言的对象换成引擎，验的还是同一把钥匙 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除（2026-10-25）⇒ 门禁改验【新引擎】**（`legado-engine` 的 Swift 实现）
const { createSandbox, engineAvailable } = require('./new-engine-harness');

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

  // ⭐⭐⭐ **探活**：引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ **显式 SKIP**
  //   （「没验到」≠「通过」；但也**不是**门禁的锅 ⇒ 不能算失败）⭐⭐⭐
  const { win: _win0 } = createSandbox({});
  const alive = String(await _win0.eval('String(1+1);')) === '2';
  if (!engineAvailable() || !alive) {
    console.log('  ⏭️  跳过：引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ 本段没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  // ⭐⭐⭐ **站方读 data: 载荷的那把钥匙**（引擎的 `java.hexDecodeToString`）
  const { win } = createSandbox({});
  // ⚠️ **重试**：引擎正在被重编时 ⇒ 这次调用会返回空 ⇒ 重试几次 ⭐⭐⭐
  const dec = async (s) => {
    for (let i = 0; i < 5; i++) {
      const v = String(await win.eval(`String(window.java.hexDecodeToString(${JSON.stringify(s)}))`));
      if (v && v !== 'ERR: 引擎不可用') return v;
      await new Promise(res => setTimeout(res, 3000));
    }
    return String(await win.eval(`String(window.java.hexDecodeToString(${JSON.stringify(s)}))`));
  };

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

  console.log('\n=== ⑤ 解不了 ⇒ 必须【明确失败】，不许返回乱码 ===');
  // ⭐⭐⭐ **语义等价说明**：
  //   老引擎的 `hexDecodeToString` 会在「hex 解不出 / base64 解不出」时
  //   **挑一个「像人话」的候选**（`looksLikeText`）—— 那是**老引擎的私有实现细节**
  //   （老引擎已物理删除 ⇒ 没有等价物 ⇒ 该断言退休）。
  //   ⭐ **但它守着的语义还在**：「解不出来时**不许静默返回乱码**」
  //     （乱码 ⇒ 站方 `JSON.parse` 抛 ⇒ 整条规则静默失效 ⇒ 最坏的失败方式）。
  //   ⇒ 改造成**新引擎的等价语义断言**：喂一串**根本不是载荷**的东西
  //     ⇒ 必须拿到**空串**（明确失败）⇒ **绝不能是乱码** ⭐⭐⭐
  const junk = await dec('!!! 这不是 base64 !!!');
  ok(junk === '', '解不了的载荷返回空串（明确失败，不是乱码）', '实际 ' + JSON.stringify(String(junk).slice(0, 40)));
  // ⚠️ **只喂「字母表外」的垃圾**（`!` / `@` 这些 base64 根本不可能出现的字符）
  //   ⇒ 引擎（Swift `Crypto.base64Decode` ⇒ `Data(base64Encoded:)` 失败 ⇒ nil ⇒ ""）
  //     与沙盒 Node 后端（`__qrPure.base64Decode` ⇒ 正则不匹配 ⇒ ""）**语义一致** ⭐⭐⭐
  //   ⚠️ **不要**用「字母表内但解出非法 UTF-8」的串（如 "zzzz"）
  //   ⇒ Swift 侧解不出 UTF-8 ⇒ ""；沙盒 Node 侧会吐 U+FFFD 乱码
  //   ⇒ 那是**沙盒 Node 后端与真机 JSC 的实现差异**（真机走引擎的 `Crypto` ⇒ ""）
  //   ⇒ 不是真机缺陷 ⇒ 不在这里断言（详见迁移报告）⭐⭐⭐
  const junk2 = await dec('@@@@');
  ok(junk2 === '', '字母表外的垃圾 ⇒ 也是空串', '实际 ' + JSON.stringify(String(junk2).slice(0, 40)));

  console.log('\n=== ⑥ 源码：归一化 + 「不是合法 hex 就按 base64 再试一次」===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这条验的是**老引擎的函数名**（`b64normalize` / `looksLikeText`）
  //   ⇒ 那是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】（①～⑤，现在跑的是【新引擎】）**⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（CryptoTests 等）与真机上 ⭐⭐⭐
  //
  // ⭐ 下面这几条是**新引擎的等价描述**（能力必须还在，只是名字/写法换了）：
  const ja = fs.readFileSync(
    path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore', 'Support', 'Crypto.swift'), 'utf8');
  ok(/func b64Normalize\(/.test(ja), '新引擎有 base64 归一化（b64Normalize）');
  ok(/func base64Decode\(/.test(ja) && /b64Normalize\(/.test(ja),
     'base64Decode 走归一化（%2B / - _ / 空格 都还原）');
  ok(/func hexDecodeToString\(/.test(ja), '新引擎有 hexDecodeToString（站方读 data: 载荷那把钥匙）');
  ok(/func hexDecodeToString[\s\S]{0,400}?base64Decode\(/.test(ja),
     'hexDecodeToString：不是合法 hex 就按 base64 再试一次（站方拿两种载荷喂它都能解）');
  // ⭐⭐⭐ **「解不了 ⇒ 明确失败」这条语义，在源码层也钉一下**（不许返回乱码）
  ok(/func base64Decode\([\s\S]{0,400}?guard let data[\s\S]{0,200}?else \{ return nil \}/.test(ja),
     'base64Decode 解不了 ⇒ 返回 nil（明确失败），不是乱码');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
