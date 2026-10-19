#!/usr/bin/env node
/**
 * CoreText 分页算法的**行为**门禁（不是 grep 源码）
 *
 * 为什么要有这个：用户实机报「每章开头标题还是没有」，查出来是
 * `oneOffFrame` 里 `for _ in 0..<max(1, index)` —— 取第 0 页时循环也跑一次，
 * start 前进到第 1 页末尾 → **返回第 2 页的帧** → 每一页都偏移一页：
 *   · 章首页显示第 2 页内容 → 章节标题永远看不到
 *   · 最后一页 start >= len → nil → 空白页
 *
 * 沙盒没有 CoreText，但**算法逻辑可以照搬**：
 * `paginate` 和 `oneOffFrame` 都是「问 framesetter 从 start 开始能装多少字」。
 * 用一个「每页装 N 字」的假 framesetter 跑两遍，验证两者的页边界一致。
 *
 * ⚠️ 这类 bug grep 源码永远抓不到 —— `0..<max(1, index)` 看起来完全合理。
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const ROOT = path.join(__dirname, '..', 'QiReaderLite', 'Features', 'Reader', 'Paging');
const src = fs.readFileSync(path.join(ROOT, 'ReaderPaginator.swift'), 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/[^\n]*/g, '');

// ── 照搬 Swift 的两段逻辑 ─────────────────────────────────
// 假 framesetter：从 offset 开始最多再装 perPage 个字
function visibleLength(offset, total, perPage) {
  return Math.max(0, Math.min(perPage, total - offset));
}

/** Swift `paginate(_:pageSize:)` 的算法（这一份一直是对的） */
function paginate(total, perPage) {
  const pages = [];
  let start = 0;
  let index = 0;
  while (start < total) {
    const len = visibleLength(start, total, perPage);
    if (len <= 0) break;
    pages.push({ index, start, length: len });
    index++; start += len;
    if (index > 20000) break;
  }
  return pages;
}

/** Swift `oneOffFrame(at:pageSize:attributed:)` 的算法，bound 是循环上界 */
function oneOffRange(total, perPage, target, bound) {
  let start = 0;
  // for _ in 0..<bound   { ... }
  for (let i = 0; i < bound; i++) {
    const len = visibleLength(start, total, perPage);
    if (len <= 0) return null;
    start += len;
    if (start >= total) return null;
  }
  const len = visibleLength(start, total, perPage);
  return len > 0 ? { start, length: len } : null;
}

const FIXED = 0;                       // 0..<max(0, index) → 第 0 页时 0 次
const BUGGY = 1;                       // 0..<max(1, index) → 第 0 页时 1 次

// ── ① 修复后：每页范围必须和 paginate 完全一致 ─────────────
let mismatches = 0;
for (const [total, perPage] of [[1132, 283], [5000, 400], [37, 283], [1, 283], [2, 283]]) {
  const pages = paginate(total, perPage);
  for (let i = 0; i < pages.length; i++) {
    const r = oneOffRange(total, perPage, i, i);   // bound = i
    if (!r || r.start !== pages[i].start || r.length !== pages[i].length) mismatches++;
  }
}
ok(mismatches === 0, `修复后 oneOffFrame 与 paginate 页边界完全一致（${mismatches} 处不符）`);

// ── ② 最后一页必须有帧（修复前会是 nil → 空白页）──────────
{
  const total = 1132, perPage = 283;
  const pages = paginate(total, perPage);
  const last = pages.length - 1;
  ok(oneOffRange(total, perPage, last, last) !== null,
     '最后一页能拿到帧');
  // ⚠️ 「修复前最后一页 nil」只在整章恰好 1 页时才成立
  //    （last=0 → max(1,0)=1 多跳一次 → start>=total → nil）。
  //    多页的章节 last>1，max(1,last)==last，跟修复前一样 —— 所以那条断言是错的。
  {
    const onePageTotal = 100, onePagePer = 283;   // 整章一页装得下
    ok(oneOffRange(onePageTotal, onePagePer, 0, 0) !== null, '单页章节第 0 页有帧（修复后）');
    ok(oneOffRange(onePageTotal, onePagePer, 0, 1) === null,
       '修复前单页章节直接 nil → 整章正文一屏都不显示（连标题一起没了）');
  }
  // 精确机制：max(1, i) 只有在 **i == 0** 时才多跳一次，i>0 时 max(1,i)==i。
  // 所以「每一页都偏移」是错的 —— **只有章首页偏移**：
  //   第 0 页显示第 1 页的内容，而章节标题就在第 0 页 → 永远看不到。
  //   其余页正常 → 正文看着好好的，就是没标题（正是用户看到的现象）。
  {
    let offPages = [];
    for (let i = 0; i < pages.length; i++) {
      const good = oneOffRange(total, perPage, i, i);
      const bad = oneOffRange(total, perPage, i, Math.max(1, i));
      if (!good || !bad) continue;
      if (bad.start !== good.start) offPages.push(i);
    }
    ok(JSON.stringify(offPages) === '[0]',
       `修复前只有章首页偏移（实际偏移页 ${JSON.stringify(offPages)}）—— 标题就在被跳过的那一页`);
  }
}

// ── ③ 第 0 页必须从 0 开始（标题就在这一页）───────────────
{
  const r = oneOffRange(1132, 283, 0, FIXED);
  ok(r && r.start === 0, `第 0 页从字符 0 开始（修复后）`);
  const buggy = oneOffRange(1132, 283, 0, BUGGY);
  ok(buggy && buggy.start !== 0,
     `修复前第 0 页从字符 ${buggy && buggy.start} 开始 —— 标题被跳过了`);
}

// ── ④ 源码别退回 max(1, index) ───────────────────────────
const body = src.slice(src.indexOf('static func oneOffFrame'),
                       src.indexOf('static func oneOffFrame') + 1400);
ok(/0\.\.<max\(0, index\)/.test(body), '源码用 0..<max(0, index)');
ok(!/0\.\.<max\(1, index\)/.test(body), '没退回 0..<max(1, index)（那会让每页偏移一页）');

// ── ⑤ 诊断输出里的插值没被 \\) 截断 ────────────────────────
{
  const pager = fs.readFileSync(path.join(ROOT, 'PagedChapterPager.swift'), 'utf8');
  const line = (pager.match(/.*当前页：.*/) || [''])[0];
  ok(/\\\(spine\[cursor\]\.chapter \+ 1\)/.test(line),
     '诊断的「章 N」插值没被 \\) 提前截断（截断会输出 "章 1+1"）');
  ok(!/\\\(spine\[cursor\]\.chapter\)\+1/.test(line), '没出现裸的 +1 在插值外');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
