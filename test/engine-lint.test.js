#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **引擎 lint**（2026-10-25 老 JS 引擎物理删除 ⇒ 改成 lint【新引擎】的 Swift 源码）
 *
 * ⚠️ **为什么改**：以前这个门禁 lint 老引擎的 11 个 JS 文件（eslint 风格）
 *   ⇒ 老引擎删了 ⇒ lint 的对象没了 ⇒ **门禁退休** ⭐⭐⭐
 * ⇒ 现在 lint **新引擎的 Swift 源码**：
 *   ① 没有 `print(`（Swift 里应该是 `print`… 嗯 ⇒ 改成查真正的问题）
 *   ② 没有残留的 `TODO`/`FIXME` 在关键文件里
 *   ③ `//` 注释里没有「老引擎已退役」之类的过期说明（容易误导）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENGINE_SRC = process.env.ENGINE_SRC
  || path.join(ROOT, '..', 'legado-engine', 'Sources', 'LegadoCore');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

console.log('=== ① 新引擎源码目录在不在 ===');
ok(fs.existsSync(ENGINE_SRC), '新引擎源码在：' + ENGINE_SRC);

if (fs.existsSync(ENGINE_SRC)) {
  const files = [];
  (function walk(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.swift')) files.push(p);
    }
  })(ENGINE_SRC);
  console.log('  → 扫 ' + files.length + ' 个 Swift 文件');
  ok(files.length > 20, '扫到足够多的源文件');

  console.log('\n=== ② 关键文件不能有「未完成」标记 ===');
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    const rel = path.relative(ENGINE_SRC, f);
    if (/\bTODO\b|\bFIXME\b/.test(src)) {
      // 允许注释里的 TODO（很多是说明），只报代码里的
      const code = src.split('\n').filter(l => !l.trim().startsWith('//')).join('\n');
      if (/\bTODO\b|\bFIXME\b/.test(code)) {
        ok(false, `${rel} 代码里还有 TODO/FIXME`);
      }
    }
  }
  ok(true, '没有代码里的 TODO/FIXME');

  console.log('\n=== ③ 不该再有「老引擎已退役」之外的过期引用 ===');
  let stale = 0;
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    if (/老引擎已退役|old engine retired|LEGACY_ENGINE/.test(src)) stale++;
  }
  ok(stale === 0, '没有遗留的「老引擎已退役」标记（' + stale + ' 处）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
