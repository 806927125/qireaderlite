// 门禁：⭐⭐⭐⭐⭐ **新引擎的 Package.swift 必须声明它 import 的每一个「非系统模块」**（2026-11-19 CI build296 实证）
//
// 跑法：node test/engine-package-deps.test.js
//
// ⚠️ **为什么必须有这条门禁**（CI build296 真机实证）：
//   `LegadoEngine/Sources/LegadoEngine/JS/JSNatives.swift` 里 `import Crypto`
//   ⇒ Apple 平台上 **`Crypto` 不是系统模块**（Apple 只有 `CryptoKit`）
//   ⇒ 不在 Package.swift 里声明 swift-crypto ⇒ **iOS 编译必挂**：
//      `error: Unable to find module dependency: 'Crypto'`
//   ⇒ ⚠️⚠️ **沙盒 Linux 门禁抓不到**：那个文件被 `#if canImport(JavaScriptCore) && !os(Linux)` 排除
//   ⇒ ⇒ 这类错**只有 CI 能暴露** ⇒ 每次等 CI 5 分钟 ⇒ 太慢 ⇒ 必须有静态门禁兜底 ⭐⭐⭐
//
// ⭐⭐⭐ **判据要严**（第一版太松 ⇒ 变异打过来不红 ⇒ 门禁没牙齿）：
//   ① 模块名必须是「系统模块」**或**「某个 target 的依赖（字符串形式 / .product 形式）」
//   ② 若是 `.product(name:package:)` ⇒ **那个 package 必须有 `.package(url:)` 条目**
//      （只写 `.product` 不写 `.package(url:)` ⇒ SPM 解析不出来 ⇒ iOS 照样挂）⭐⭐⭐
//   ③ 字符串形式的依赖（`"SwiftSoup"`）⇒ 必须**真的存在**对应的 product（来自某个 `.package(url:)` 或 `.library(name:)`）
//
// ⇒ 变异对照：把 `.package(url: .../swift-crypto.git)` 那行删掉 ⇒ **必须红**

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const PKG = path.join(ROOT, 'LegadoEngine', 'Package.swift');
const SRC = path.join(ROOT, 'LegadoEngine', 'Sources', 'LegadoEngine');

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

// ── Apple 平台（iOS/macOS）**自带**的系统模块 ⇒ 不需要在 Package.swift 声明 ──
const SYSTEM_MODULES = new Set([
  'Foundation', 'FoundationNetworking', 'UIKit', 'SwiftUI', 'Combine', 'AppKit',
  'JavaScriptCore', 'WebKit', 'Security', 'CommonCrypto', 'Compression',
  'CoreFoundation', 'CoreGraphics', 'CoreText', 'CoreImage', 'QuartzCore',
  'Darwin', 'Glibc', 'Dispatch', 'os', 'CryptoKit', 'PackageDescription',
  'Accelerate', 'Metal', 'MetalKit', 'ARKit', 'AVFoundation', 'CoreLocation',
]);

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

// ── ① 收集引擎源码里的所有 import ──
const files = walk(SRC, []);
const imports = new Map();
for (const f of files) {
  const code = fs.readFileSync(f, 'utf8');
  for (const m of code.matchAll(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/gm)) {
    const mod = m[1];
    if (!imports.has(mod)) imports.set(mod, []);
    imports.get(mod).push(path.relative(ROOT, f));
  }
}
console.log(`=== 引擎源码 ${files.length} 个文件，import 了 ${imports.size} 个模块 ===`);

// ── ② 解析 Package.swift ──
const pkgText = fs.readFileSync(PKG, 'utf8');
// ②-A `.package(url: ".../<Name>.git")` ⇒ 包名 <Name>
const pkgNames = new Set();
for (const m of pkgText.matchAll(/\.package\(\s*url:\s*"[^"]*\/([^"/]+?)(?:\.git)?"/g)) {
  pkgNames.add(m[1]);
}
// ②-B `.library(name: "X")` ⇒ 本包自己产的 product
const localProducts = new Set();
for (const m of pkgText.matchAll(/\.library\(\s*name:\s*"([^"]+)"/g)) localProducts.add(m[1]);
// ②-C 每个 target 的 dependencies 块
const targetDeps = [];  // { kind: 'string'|'product', name, package }
for (const blk of pkgText.matchAll(/dependencies:\s*\[([\s\S]*?)\]/g)) {
  const body = blk[1];
  for (const s of body.matchAll(/\.product\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"\s*\)/g)) {
    targetDeps.push({ kind: 'product', name: s[1], package: s[2] });
  }
  // 去掉 .product(...) 之后，剩下的 "Xxx" 才是字符串依赖
  const rest = body.replace(/\.product\([^)]*\)/g, '');
  for (const s of rest.matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)) {
    targetDeps.push({ kind: 'string', name: s[1], package: null });
  }
}
console.log('Package.swift 声明：package =', [...pkgNames].join(', ') || '(无)',
            '| 本包 product =', [...localProducts].join(', ') || '(无)');
console.log('target 依赖 =', targetDeps.map((d) => (d.kind === 'product' ? `${d.name}←${d.package}` : d.name)).join(', ') || '(无)');

/** ⭐⭐⭐ 统一判据：模块名是否有来处（系统模块 / 本包 product / target 依赖且能解析） */
function isModuleDeclared(mod) {
  if (SYSTEM_MODULES.has(mod)) return true;
  if (localProducts.has(mod)) return true;
  const asProduct = targetDeps.find((d) => d.kind === 'product' && d.name === mod);
  if (asProduct) return pkgNames.has(asProduct.package);   // ⭐ product 的 package 必须真的声明
  const asString = targetDeps.find((d) => d.kind === 'string' && d.name === mod);
  if (asString) return hasProductNamed(mod);                 // ⭐ 字符串依赖必须能解析到 product
  return false;
}

/** Package.swift 的某个 `.package(url:)` 依赖是否提供名为 mod 的 product（默认同名） */
function hasProductNamed(mod) {
  for (const p of pkgNames) {
    if (p === mod) return true;
    if (p.replace(/^swift-/, '') === mod) return true;
  }
  return false;
}

// ── ③ 逐个 import 判定（严）──
console.log('\n=== 1. 每个 import 都有来处 ===');
const missing = [];
for (const [mod, where] of [...imports.entries()].sort()) {
  if (SYSTEM_MODULES.has(mod)) { check(`import ${mod}（系统模块）`, true); continue; }
  if (localProducts.has(mod)) { check(`import ${mod}（本包 product）`, true); continue; }

  if (!isModuleDeclared(mod)) {
    check(`import ${mod} 有来处`, false, `${where[0]} 里 import 了，但 Package.swift 没声明`);
    missing.push({ mod, where });
    continue;
  }
  const asProduct = targetDeps.find((d) => d.kind === 'product' && d.name === mod);
  check(`import ${mod} 有来处`, true,
        asProduct ? `⇒ .product(${mod}, package: ${asProduct.package})` : '');
}

// ── ④ ⭐⭐⭐ 专项：Apple 专属文件里的 import 也必须声明（Linux 编译不到 ⇒ 只能静态查）──
console.log('\n=== 2. Apple 专属文件（Linux 编不到 ⇒ 静态查）===');
const appleOnly = files.filter((f) => {
  const code = fs.readFileSync(f, 'utf8');
  return /canImport\(JavaScriptCore\)/.test(code) || /canImport\(WebKit\)/.test(code);
});
check('有 Apple 专属文件（说明这条门禁不是空跑）', appleOnly.length > 0, '0 个 ⇒ 门禁失效');
for (const f of appleOnly) {
  const code = fs.readFileSync(f, 'utf8');
  const mods = [...code.matchAll(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/gm)].map((m) => m[1]);
  const bad = mods.filter((m) => !isModuleDeclared(m));
  check(`${path.relative(ROOT, f)} 的 import 都有来处`, bad.length === 0, bad.join(', '));
}

console.log(`\n通过 ${passed} / 失败 ${failed}`);
process.exit(failed === 0 ? 0 : 1);
