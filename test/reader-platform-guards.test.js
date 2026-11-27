#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：`ChaiyueReader` 模块的【平台守卫】必须自洽**（2026-11-26 · CI333c 实锤）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **背景** ⭐⭐⭐：
 *   `LegadoEngine`（宿主门面模块）为了转发柴阅的浮层浏览器，**依赖了 `ChaiyueReader`** ⇒
 *   ⇒ ⇒ **macOS / Linux 上现在也会编译 `ChaiyueReader` 模块**（以前只有 iOS 编 ⇒ 一直没暴露）⭐⭐⭐
 *   ⇒ 于是暴露了模块内部一个**老问题**：
 *     **有守卫的文件**（`#if os(iOS)`）里的类型，被**没守卫的文件**引用
 *     ⇒ macOS 上「找不到类型」⇒ **整包编译失败** ⭐⭐⭐
 *   ⇒ CI333c 实锤错误：`cannot find type 'VoiceCatalog' / 'ReaderSettings' / 'AppearanceStore' …`⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据**⭐⭐⭐⭐⭐：
 *   对每个**没有平台守卫**的 `.swift` 文件：
 *   它引用的类型里，**不允许**出现「定义在有守卫文件里」的类型 ⇒ 否则 macOS/Linux 上必挂 ⭐⭐⭐
 *
 * ⭐⭐⭐ **为什么这条门禁值钱** ⭐⭐⭐：
 *   iOS 界面层**只有 CI 能验编译**（沙盒 Linux 编不了 SwiftUI/UIKit）
 *   ⇒ 这类「跨平台守卫不自洽」的问题**平时根本看不见** ⇒ 只能靠静态扫描提前抓 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const READER = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueReader');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const files = [];
(function walk(d) {
  let entries;
  try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (_) { return; }
  for (const e of entries) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.swift')) files.push(p);
  }
})(READER);

const head = (f) => fs.readFileSync(f, 'utf8').slice(0, 500);
const isGuarded = (f) => {
  const h = head(f);
  return h.includes('#if os(iOS)') || h.includes('#if canImport') || h.includes('#if !os(Linux)');
};
const body = (f) => fs.readFileSync(f, 'utf8');

// 有守卫文件里定义的类型 → 定义文件
const guardedTypes = new Map();
for (const f of files) {
  if (!isGuarded(f)) continue;
  const src = body(f);
  const re = /\b(?:struct|class|enum|protocol|actor)\s+([A-Z][A-Za-z0-9_]*)/g;
  let m;
  while ((m = re.exec(src)) !== null) if (!guardedTypes.has(m[1])) guardedTypes.set(m[1], f);
}

console.log('\n── ① 无守卫文件不得引用「有守卫文件里定义」的类型 ──');
{
  ok(files.length > 0, `① 扫到 ${files.length} 个 swift 文件（其中 ${files.filter(isGuarded).length} 个有平台守卫）`);
  const violations = [];
  for (const f of files) {
    if (isGuarded(f)) continue;
    const src = body(f);
    const hits = [];
    for (const [t, def] of guardedTypes) {
      if (new RegExp('\\b' + t + '\\b').test(src)) hits.push(`${t}@${path.relative(READER, def)}`);
    }
    if (hits.length) violations.push(`${path.relative(READER, f)} ⇒ ${hits.slice(0, 5).join(', ')}`);
  }
  ok(violations.length === 0,
     '① 守卫自洽（⇒ macOS/Linux 上编译 `ChaiyueReader` 不会「找不到类型」）',
     violations.slice(0, 6).join(' | '));
}

console.log('\n── ② `LegadoEngine` 依赖 `ChaiyueReader` ⇒ 转发文件必须自带 iOS 守卫 ──');
{
  const pkg = body(path.join(ROOT, 'LegadoEngine/Package.swift'));
  const depends = /dependencies:\s*\[[^\]]*"ChaiyueReader"/.test(pkg);
  ok(depends, '② Package.swift 声明了 LegadoEngine → ChaiyueReader 依赖');

  const bridgePath = path.join(ROOT, 'LegadoEngine/Sources/LegadoEngine/ChaiyueBrowserOverlayBridge.swift');
  if (fs.existsSync(bridgePath)) {
    ok(isGuarded(bridgePath),
       '② 门面转发文件有 #if os(iOS) 守卫（ChaiyueReader 的内容全是 iOS 守卫 ⇒ 非 iOS 上不存在）');
  } else {
    ok(true, '② 没有门面转发文件（不需要转发）');
  }

  // ⭐⭐⭐ 宿主**可以** import ChaiyueReader（既有代码就这么干 ⇒ 阅读器那几屏需要柴阅的视图类型）⭐⭐⭐
  //   ⚠️ 但**绝不能出现裸 `Book` / `BookSource` / `BookChapter`**：
  //     `@_exported import ChaiyueModels` ⇒ 柴阅的同名类型进了命名空间 ⇒ 裸写就 ambiguous ⭐⭐⭐
  //   ⇒ 宿主一律用 `QiBook` / `QiChapter` / `LegadoEngineHost.BookModel` ⭐⭐⭐
  const hostFiles = [];
  (function walk(d) {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (_) { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.swift')) hostFiles.push(p);
    }
  })(path.join(ROOT, 'QiReaderLite'));

  /** 剥掉注释行（注释里的「Book」只是说明文字 ⇒ 不算撞名）⭐⭐⭐ */
  const codeOf = (f) => body(f).split('\n').filter(l => {
    const t = l.trim();
    return !(t.startsWith('//') || t.startsWith('*') || t.startsWith('/*'));
  }).join('\n');

  const bare = [];
  for (const f of hostFiles) {
    if (!/^import ChaiyueReader$/m.test(body(f))) continue;
    const code = codeOf(f);
    for (const t of ['Book', 'BookSource', 'BookChapter']) {
      // ⭐ 前面不能是字母/数字/下划线（排除 QiBook / LegadoEngineHost.BookModel 里的 BookModel）⭐
      const re = new RegExp('(^|[^A-Za-z0-9_.])' + t + '([^A-Za-z0-9_]|$)');
      if (re.test(code)) bare.push(`${path.relative(ROOT, f)}:${t}`);
    }
  }
  ok(bare.length === 0,
     '② import ChaiyueReader 的文件里没有裸 Book/BookSource/BookChapter（裸写 ⇒ 与宿主同名类型 ambiguous）',
     bare.slice(0, 6).join(' / '));
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
