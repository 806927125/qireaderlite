// 门禁：⭐⭐⭐⭐⭐ **App 侧「类型撞名 / 引用了不存在的类型」静态兜底**（2026-11-19 CI build296 实证）
//
// 跑法：node test/app-type-sanity.test.js
//
// ⚠️⚠️⚠️ **为什么必须有这条门禁**（2026-11-19 真机实证）：
//   `Core/EngineLogPanel.swift` 里的类被错命名成了 `EngineLog`
//   ⇒ 和 `Core/EngineLog.swift` 里的 `enum EngineLog` **撞名**
//   ⇒ 而全工程 30+ 处引用的是 `EngineLogPanel.shared`
//   ⇒ 结果是满屏「cannot find 'EngineLogPanel' in scope」+「invalid redeclaration of 'EngineLog'」⭐⭐⭐
//   ⇒ 而**沙盒 Linux 门禁完全看不见**（`EngineLogPanel.swift` import UIKit ⇒ 编不到 ⇒ 只留了个 stub）⭐⭐⭐
//   ⇒ **白等两轮 CI 才定位到** ⭐⭐⭐
//
// ⭐⭐⭐ 断言要**可证伪** ⇒ 配套变异对照在同文件末尾（`--mutate` 模式）⭐⭐⭐

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const APP_DIR = path.join(ROOT, 'QiReaderLite');
// ⭐⭐⭐ 引擎源码现在分三处（柴阅模型 / 柴阅引擎 / 我们的适配层）⭐⭐⭐
const ENGINE_DIR = path.join(ROOT, 'LegadoEngine/Sources');

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

function walk(dir, out) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name === '.build' || e.name === 'node_modules') continue; walk(p, out); }
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

// ⭐⭐⭐ **顶层类型**（行首零缩进）⇒ 嵌套类型不算「同名撞车」⭐⭐⭐
const TYPE_DECL_TOP = /^(?:@[\w:]+\s+)*(?:(?:public|internal|private|fileprivate|open|final)\s+)*(class|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/gm;
// ⭐ **任意缩进的类型声明**（含嵌套）⇒ 只用来做「引用能不能解析」的判断 ⭐
const TYPE_DECL_ANY = /(?:^|\n)\s*(?:@[\w:]+\s+)*(?:(?:public|internal|private|fileprivate|open|final)\s+)*(class|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/g;

/**
 * ⭐⭐⭐⭐⭐ **花括号深度剖面**（2026-11-19 实证 —— 这条差点写错）
 *   Swift 的「嵌套」由**花括号**决定，**不由缩进决定**！
 *   ⇒ 用「行首零缩进」判顶层是**错的**：
 *      `final class X {` 后面直接写 `enum Y {`（缩进 0）⇒ Y **仍然是 X 的嵌套类型**
 *      ⇒ 别的文件里 `Y` 根本不可见 ⇒ 「cannot find 'Y' in scope」⭐⭐⭐
 *   ⇒ 所以必须按**括号深度**判：depth==0 才是模块级（别的文件能看见）⭐⭐⭐
 */
function depthProfile(code) {
  const depths = new Int32Array(code.length + 1);
  let depth = 0, inStr = false, inLine = false, inBlock = false;
  for (let i = 0; i < code.length; i++) {
    depths[i] = depth;
    const c = code[i], n = code[i + 1];
    if (inLine) { if (c === '\n') inLine = false; continue; }
    if (inBlock) { if (c === '*' && n === '/') { inBlock = false; i++; } continue; }
    if (inStr) { if (c === '\\') { i++; } else if (c === '"') inStr = false; continue; }
    if (c === '/' && n === '/') { inLine = true; i++; continue; }
    if (c === '/' && n === '*') { inBlock = true; i++; continue; }
    if (c === '"') { inStr = true; continue; }
    if (c === '{') depth++;
    else if (c === '}') depth--;
  }
  depths[code.length] = depth;
  return depths;
}

/** @param topOnly true ⇒ 只收【模块级】类型（花括号深度 0）；false ⇒ 全收（含嵌套） */
function declaredTypes(files, topOnly) {
  const map = new Map(); // name -> [file:line...]
  for (const f of files) {
    const code = fs.readFileSync(f, 'utf8');
    const depths = depthProfile(code);
    const re = TYPE_DECL_ANY;
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(code)) !== null) {
      const kw = m.index + m[0].lastIndexOf(m[1]);   // 类型关键字的位置
      const depth = depths[kw];
      if (topOnly && depth !== 0) continue;           // ⭐ 嵌套类型 ⇒ 别的文件看不见 ⭐⭐⭐
      const name = m[2];
      const line = code.slice(0, m.index).split('\n').length;
      if (!map.has(name)) map.set(name, []);
      map.get(name).push(path.relative(ROOT, f) + ':' + line + (depth ? '(嵌套)' : ''));
    }
  }
  return map;
}

const appFiles = walk(APP_DIR, []);
const engineFiles = walk(ENGINE_DIR, []);

console.log('=== 0. 门禁不是空跑 ===');
check(`扫到 App 文件（${appFiles.length} 个）`, appFiles.length > 20, '扫得太少 ⇒ 门禁失效');
check(`扫到引擎文件（${engineFiles.length} 个）`, engineFiles.length > 5, '扫得太少 ⇒ 门禁失效');

// ─────────────────────────────────────────────────────────────
// ① 同一模块内不许有【同名顶层类型】（撞名 ⇒ invalid redeclaration）
// ─────────────────────────────────────────────────────────────
console.log('\n=== 1. 同一模块内不许有同名顶层类型 ===');
for (const [label, files] of [['App(QiReaderLite)', appFiles], ['引擎(LegadoEngine)', engineFiles]]) {
  const map = declaredTypes(files, true);
  // ⭐⭐⭐ **只查【跨文件】的同名** ⇒ 同一文件里的重复声明多半是 `#if` 平台分支
  //   （如 `JSBridge` 的 Apple 版 / Linux stub ⇒ 互斥 ⇒ 不是撞名）⭐⭐⭐
  // ⭐⭐⭐⭐⭐ **条件互斥豁免**（2026-11-21 移植柴阅实证）⭐⭐⭐
  //   柴阅的 JS 层与我们的 **Linux 桩**故意同名（`JSResponse` / `JSRuntime` /
  //   `JavaBridge` / `JSSymmetricCrypto` / `URLSessionWebSocketTransport`）⭐⭐⭐
  //   ⇒ 但它们分处 `#if canImport(JavaScriptCore)` 与 `#if !canImport(JavaScriptCore)`
  //     **互斥的两侧 ⇒ 永不同时编译 ⇒ 不是撞名** ⭐⭐⭐
  //   ⇒ 正解：**豁免「顶层条件互斥」的同名** ⇒ 真正的撞名仍被抓 ⭐⭐⭐
  // ⚠️⚠️ **要收集【全部】`#if` 条件**，不能只看第一个 ⭐⭐⭐
  //   （`WebSocket.swift` 第一个 `#if` 是 `canImport(CoreFoundation)`，
  //     而真正决定同名类型互斥的是后面的 `canImport(Darwin)`）⭐⭐⭐
  const conditionsOf = (rel) => {
    const code = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    const out = [];
    const re = /^\s*#if\s+(canImport\([^)]*\)(?:\s*&&\s*!os\(Linux\))?|!canImport\([^)]*\))/gm;
    let m;
    while ((m = re.exec(code)) !== null) out.push(m[1].replace(/\s+/g, ''));
    return out;
  };
  const pairExclusive = (ca, cb) => {
    // `canImport(X)` 与 `!canImport(X)` ⇒ 互斥
    const norm = (c) => c.replace(/^!/, '').replace('&&!os(Linux)', '');
    if (norm(ca) !== norm(cb)) return false;
    return ca.startsWith('!') !== cb.startsWith('!');
  };
  const mutuallyExclusive = (a, b) => {
    const ca = conditionsOf(a), cb = conditionsOf(b);
    for (const x of ca) for (const y of cb) if (pairExclusive(x, y)) return true;
    return false;
  };
  const dups = [...map.entries()].filter(([, where]) => {
    const files2 = [...new Set(where.map((w) => w.split(':')[0]))];
    if (files2.length <= 1) return false;
    // ⚠️ **两两互斥**才算豁免（三个文件里有两两互斥、一对不互斥 ⇒ 仍要报）⭐⭐⭐
    for (let i = 0; i < files2.length; i++) {
      for (let j = i + 1; j < files2.length; j++) {
        if (!mutuallyExclusive(files2[i], files2[j])) return true;
      }
    }
    return false;
  });
  check(`${label}：没有跨文件同名的顶层类型（${map.size} 个类型）`, dups.length === 0,
        dups.map(([n, w]) => `${n} ⇒ ${w.join(' / ')}`).join('; '));
}

// ─────────────────────────────────────────────────────────────
// ② `X.shared` 里的 X 必须在工程里有定义（改名了但引用没改 ⇒ 一网打尽）
// ─────────────────────────────────────────────────────────────
console.log('\n=== 2. `X.shared` 的 X 必须有定义 ===');
const SYSTEM_SHARED = new Set([
  'URLSession', 'UserDefaults', 'FileManager', 'NSFileManager', 'WKWebView', 'UIApplication',
  'UIPasteboard', 'NotificationCenter', 'ProcessInfo', 'Bundle', 'Locale', 'Calendar',
  'DateFormatter', 'NumberFormatter', 'JSONDecoder', 'JSONEncoder', 'Task', 'DispatchQueue',
  'NSUbiquitousKeyValueStore', 'CKContainer', 'CLLocationManager', 'UITableView', 'UIView',
  'HTTPCookieStorage', 'URLCache', 'UIScreen', 'UIWindow', 'WKUserContentController',
]);
const allDeclared = new Set([...declaredTypes(appFiles, false).keys(), ...declaredTypes(engineFiles, false).keys()]);
const missing = new Map();
for (const f of [...appFiles, ...engineFiles]) {
  const code = fs.readFileSync(f, 'utf8');
  for (const m of code.matchAll(/\b([A-Z][A-Za-z0-9_]*)\.shared\b/g)) {
    const t = m[1];
    if (allDeclared.has(t) || SYSTEM_SHARED.has(t)) continue;
    if (!missing.has(t)) missing.set(t, []);
    missing.get(t).push(path.relative(ROOT, f));
  }
}
check(`没有引用不存在的 X.shared（检查了 ${appFiles.length + engineFiles.length} 个文件）`,
      missing.size === 0,
      [...missing.entries()].map(([t, fs2]) => `${t}（${[...new Set(fs2)].join(', ')}）`).join('; '));

// ─────────────────────────────────────────────────────────────
// ③ **App 入口文件**里引用的自定义类型必须存在
//    （2026-11-19 CI build296 实证：`EngineLogBootstrap.install()` 这个调用点
//      悬了很久 —— 那个类型在「引擎换血」那轮被删了，可调用点还留着 ⇒ App 编不过 ⭐⭐⭐
//      ⇒ 而入口文件是 SwiftUI ⇒ **沙盒 Linux 门禁够不到** ⇒ 只有 CI 能发现 ⭐⭐⭐）
// ─────────────────────────────────────────────────────────────
console.log('\n=== 3. App 入口文件引用的类型必须存在（沙盒够不到的地方）===');
const ENTRY_FILES = [
  path.join(APP_DIR, 'App', 'QiReaderLiteApp.swift'),
].filter((f) => fs.existsSync(f));

// ⚠️ 入口文件会碰到 SwiftUI / Foundation / UIKit 的类型 ⇒ 列一份白名单
const ENTRY_SYSTEM = new Set([
  'View', 'App', 'Scene', 'StateObject', 'ObservedObject', 'State', 'Binding', 'EnvironmentObject',
  'Environment', 'AppStorage', 'WindowGroup', 'Settings', 'ScenePhase', 'Color', 'Font', 'Image',
  'Text', 'VStack', 'HStack', 'ZStack', 'LazyVStack', 'ScrollView', 'List', 'ForEach',
  'NavigationStack', 'NavigationLink', 'Button', 'TextField', 'Toggle', 'Slider', 'Divider', 'Spacer',
  'Group', 'Section', 'Form', 'Picker', 'Menu', 'Label', 'ProgressView', 'AnyView', 'EmptyView',
  'Bundle', 'UserDefaults', 'NotificationCenter', 'DispatchQueue', 'Task', 'MainActor', 'URL',
  'URLSession', 'UIApplication', 'UIScene', 'UIWindowScene', 'UIApplicationDelegate',
  'NSObject', 'ObservableObject', 'Published',
  // Swift 内建类型（入口文件里 `String(...)` / `Int(...)` 这类很常见）
  'String', 'Int', 'Int8', 'Int16', 'Int32', 'Int64', 'UInt', 'UInt8', 'Double', 'Float', 'Bool',
  'Array', 'Dictionary', 'Set', 'Optional', 'Result', 'Date', 'Data', 'Character', 'Any', 'AnyObject',
  'Error', 'Never', 'Void', 'Range', 'Substring',
  // UIKit 里常出现的
  'UIImage', 'RoundedRectangle', 'Rectangle', 'Circle', 'Capsule', 'UIView', 'UIColor', 'UIFont',
]);
for (const f of ENTRY_FILES) {
  const code = fs.readFileSync(f, 'utf8');
  // ⭐⭐⭐ **剥注释** ⇒ 否则 "AnalyzeUrl.swift" 这种路径会被当成 `AnalyzeUrl.swift` 的成员访问 ⭐⭐⭐
  const clean = code.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
  const used = new Set();
  for (const m of clean.matchAll(/\b([A-Z][A-Za-z0-9_]*)\.[a-z_][A-Za-z0-9_]*/g)) used.add(m[1]);
  for (const m of clean.matchAll(/\b([A-Z][A-Za-z0-9_]*)\s*\(/g)) used.add(m[1]);
  // ⭐⭐⭐⭐⭐ **只认【顶层】类型**（2026-11-19 实证）：
  //   `EngineLogBootstrap` 一度被插在 `final class LegadoEngineBackend { … }` **里面**
  //   ⇒ 嵌套类型在别的文件里**根本不可见** ⇒ 入口文件报「cannot find … in scope」
  //   ⇒ 而按「任意缩进」扫的话，这个门禁会以为它存在 ⇒ **放过去** ⭐⭐⭐
  //   ⇒ 所以这里必须用**顶层**声明集 ⭐⭐⭐
  const topDeclared = new Set([...declaredTypes(appFiles, true).keys(),
                               ...declaredTypes(engineFiles, true).keys()]);
  const unknown = [...used].filter((t) => !topDeclared.has(t) && !ENTRY_SYSTEM.has(t));
  check(`${path.basename(f)}：引用的类型都有定义（${used.size} 个）`, unknown.length === 0, unknown.join(', '));
}

// ─────────────────────────────────────────────────────────────
// ③ 变异对照（--mutate）：把「类型撞名」造出来 ⇒ 门禁必须红
// ─────────────────────────────────────────────────────────────
if (process.argv.includes('--mutate')) {
  const { execFileSync } = require('child_process');
  console.log('\n=== 3. 变异对照（造一个同名类型 ⇒ 门禁必须红）===');
  const victim = path.join(APP_DIR, 'Core', 'EngineLogPanel.swift');
  const backup = fs.readFileSync(victim, 'utf8');
  try {
    fs.writeFileSync(victim, backup.replace('final class EngineLogPanel:',
                                            'final class EngineLog:'), 'utf8');
    let rc = 0;
    try {
      execFileSync('node', [__filename], { cwd: ROOT, stdio: 'pipe' });
    } catch (e) { rc = e.status === undefined ? -1 : e.status; }
    check('造出同名类型 ⇒ 门禁红', rc !== 0, `门禁居然是绿的（exit=${rc}）⇒ 这条断言是摆设`);
  } finally {
    fs.writeFileSync(victim, backup, 'utf8');
  }

  // ── 变异 2：把类型藏进别的类型的花括号里（Swift 里仍是嵌套类型 ⇒ 别的文件看不见）──
  console.log('\n=== 4. 变异对照（把类型藏进 class 的花括号里 ⇒ 门禁必须红）===');
  const backend = path.join(APP_DIR, 'Core', 'LegadoEngineBackend.swift');
  const bk = fs.readFileSync(backend, 'utf8');
  try {
    const i = bk.indexOf('enum EngineLogBootstrap {');
    const j = bk.indexOf('\n}\n', i) + 3;
    const block = bk.slice(i, j);
    let mutated = bk.slice(0, i) + bk.slice(j);
    const k = mutated.indexOf('final class LegadoEngineBackend {');
    const at = mutated.indexOf('\n', k) + 1;
    mutated = mutated.slice(0, at) + block + mutated.slice(at);
    fs.writeFileSync(backend, mutated, 'utf8');
    let rc = 0;
    try {
      execFileSync('node', [__filename], { cwd: ROOT, stdio: 'pipe' });
    } catch (e) { rc = e.status === undefined ? -1 : e.status; }
    check('把类型藏进 class 的花括号里 ⇒ 门禁红', rc !== 0, `门禁居然是绿的（exit=${rc}）⇒ 这条断言是摆设`);
  } finally {
    fs.writeFileSync(backend, bk, 'utf8');
  }
}

console.log(`\n通过 ${passed} / 失败 ${failed}`);
process.exit(failed === 0 ? 0 : 1);
