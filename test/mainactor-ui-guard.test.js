#!/usr/bin/env node
/**
 * ⭐⭐⭐ **主线程门禁：非 @MainActor 的函数里不许出现 UIKit**
 *
 * **事故（2026-10-25 真机闪退）**：build248 给 `java.longToast` 加了宿主实现
 * ⇒ 站方第一次真的调到宿主 ⇒ 引擎在**后台线程**跑
 * ⇒ `Toast.show` 在后台线程建 `UILabel` / 碰 `UIApplication`
 * ⇒ **UIKit 主线程违规 ⇒ 点「发现」就闪退** ⭐⭐⭐
 *
 * ⚠️ **为什么以前没炸**：`java.toast` 走引擎自己那条路（不落宿主）
 * ⇒ `Toast.show` 一直没人从后台调 ⇒ **一颗埋着的雷**
 * ⇒ 一旦新增「走宿主的 API」⇒ 立刻踩雷 ⭐
 *
 * ⇒ 所以要**静态扫全仓库**：任何**不是** `@MainActor` 的函数，只要函数体里碰了 UIKit ⇒ 报 ⭐⭐⭐
 * ⇒ 修法有两条：① 把该函数标 `@MainActor`（**编译器从此强制调用点处理隔离**）
 *              ② 或者在入口自己切主线程（`DispatchQueue.main.async { MainActor.assumeIsolated { … } }`）
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'QiReaderLite');

// ⭐ 只查这些 UIKit 类型（SwiftUI 的 View 不算 ⇒ 不会误报 SwiftUI 页面）
const UIKIT = /\b(UILabel|UIView|UIImageView|UIWindow|UIWindowScene|UIApplication|UIViewController|UIButton|UITextField|UITextView|UIScrollView|UIActivityIndicatorView|UIControl|UIColor|UIImage|UIFont|UIBezierPath|CALayer|CGContext|CGPath|UIAccessibility|UIDevice)\b/;

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

/** 把源码切成「函数」：返回 [{ name, isMainActor, body }] */
function parseFunctions(src) {
  const lines = src.split('\n');
  const funcs = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^\s*(?:(?:public|private|internal|fileprivate|open|static|final|override|mutating|nonisolated|@\w+)\s+)*func\s+(\w+)/);
    if (!m) continue;
    // 往上找最近的非空行 ⇒ 判断有没有 @MainActor
    let isMainActor = false;
    for (let k = i - 1; k >= 0 && k >= i - 4; k--) {
      const t = lines[k].trim();
      if (!t) continue;
      if (t.startsWith('@MainActor')) { isMainActor = true; }
      break;
    }
    // 收集函数体（大括号配平 ⇒ ⭐ 必须忽略「字符串里」和「注释里」的括号，否则会算大 ⭐）
    let depth = 0, started = false, body = '';
    for (let k = i; k < lines.length; k++) {
      const l = lines[k];
      // 去掉行注释 + 字符串字面量里的内容（避免 `\(args["x"])` 这类括号干扰配平）
      let clean = l.replace(/\/\/.*$/, '');
      clean = clean.replace(/"(?:[^"\\]|\\.)*"/g, '""');
      clean = clean.replace(/'(?:[^'\\]|\\.)*'/g, "''");
      for (const ch of clean) {
        if (ch === '{') { depth++; started = true; }
        else if (ch === '}') depth--;
      }
      body += l + '\n';
      if (started && depth <= 0) break;
      if (k - i > 400) break;
    }
    funcs.push({ name: m[1], isMainActor, body, line: i + 1 });
  }
  return funcs;
}

// ⭐⭐⭐ **只扫「宿主桥层」（Core/）** —— UI 层（Reader/ 等）由 UIKit/SwiftUI 框架保证在主线程 ⇒ 扫它全是误报
const HOST_LAYER = path.join(SRC, 'Core');

// ⭐ 框架保证在主线程的上下文（不用报）
const FRAMEWORK_MAIN = new Set([
  'body', 'makeUIView', 'updateUIView', 'makeCoordinator', 'dismantleUIView',
  'layoutSubviews', 'viewDidLoad', 'viewWillAppear', 'viewDidAppear', 'loadView',
  'traitCollectionDidChange', 'drawPage', 'drawBaselines', 'setPage', 'setBackground',
  'scrollViewDidScroll', 'scrollViewDidZoom', 'scrollViewWillBeginDragging',
  'scrollReader', 'pageViewController', 'makeBodyText', 'loadImage', 'appendInlineImages',
  'syncPager', 'hex', 'attributed', 'load', 'topViewController',
]);

const files = walk(HOST_LAYER);
let scanned = 0;
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  const rel = path.relative(ROOT, f);
  for (const fn of parseFunctions(src)) {
    scanned++;
    if (fn.isMainActor) continue;
    if (FRAMEWORK_MAIN.has(fn.name)) continue;
    // ⭐⭐⭐ **自己切了主线程 ⇒ 安全**（`await MainActor.run { … }` / `assumeIsolated` / `DispatchQueue.main`）
    if (/MainActor\.run|assumeIsolated|DispatchQueue\.main|Task\s*\{\s*@MainActor/.test(fn.body)) continue;
    // 函数体里有没有 UIKit？
    if (!UIKIT.test(fn.body)) continue;
    ok(false, `⭐⭐⭐ ${rel}:${fn.line} 函数 \`${fn.name}\` **不是 @MainActor**，却碰了 UIKit `
        + `⇒ 后台线程调到就会闪退 ⭐⭐⭐\n${fn.body.split('\n').slice(0, 6).map(s => '        ' + s).join('\n')}`);
  }
}

ok(scanned > 50, `扫了 ${scanned} 个函数（太少 ⇒ 解析器可能坏了）`);

// ⭐⭐⭐ 专项：`Toast` 的 UIKit 渲染必须在 @MainActor 函数里（这次事故的本体）
const toastFile = path.join(SRC, 'Core/RuleSandbox.swift');
if (fs.existsSync(toastFile)) {
  const src = fs.readFileSync(toastFile, 'utf8');
  const fns = parseFunctions(src);
  const render = fns.find(f => f.name === 'render');
  ok(!!render, 'Toast 里有 `render` 这个 @MainActor 渲染函数（找不到 ⇒ 有人改回去了）');
  if (render) {
    ok(render.isMainActor, '⭐⭐⭐ `Toast.render` 必须标 @MainActor ⇒ 编译器强制调用点处理隔离 ⭐⭐⭐');
  }
  const show = fns.find(f => f.name === 'show');
  ok(!!show && /DispatchQueue\.main|MainActor\.assumeIsolated|Task\s*\{\s*@MainActor/.test(show.body),
     '⭐⭐⭐ `Toast.show` 必须自己切主线程（可能被后台线程调用）⭐⭐⭐');
  // ⭐ 老实现（没切主线程）会被这条抓住
  ok(!!show && !/let lbl = UILabel\(\)/.test(show.body),
     '⭐⭐⭐ `Toast.show` 里不许直接建 UILabel（要交给 @MainActor 的 render）⭐⭐⭐');
}

console.log(`\n主线程门禁：通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
