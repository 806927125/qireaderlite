#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **站方变量感知的 source：宿主侧兜底的【接线】门禁**（2026-10-28）
 *
 * 跑法：node test/station-var-bridge.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **背景（真机 403「无效JWT」的根因）**：
 *
 *   引擎的 `SourceEngine.toc()` / `content()` 会**重建** `sourceObject`：
 *   ```swift
 *   sourceObject = Self.makeSourceObject(source, varBox: varBox, loginInfo: loadLoginInfo())
 *   //                                                       ↑↑↑ 漏传 sourceVariable:
 *   ```
 *   ⇒ 那个对象退回**老语义**：`getVariable()` = **整份 varBox JSON**（一个 map）
 *   ⇒ 站方（✿UAA）`authorization: Bearer ${source.getVariable()}`
 *   ⇒ 请求头变成 `Bearer {"androidId":"…"}` ⇒ 服务端 **403** ⭐⭐⭐
 *   ⇒ 详情 op 传了槽 ⇒ 详情没事；**只有目录 / 正文 403** ⭐
 *
 * ⇒ 宿主侧兜底：**把引擎那个对象包一层**
 *   · `getVariable` / `setVariable` ⇒ 走**站方变量槽**（Legado 语义）
 *   · 其余方法 ⇒ **原样委托**（不重复实现 ⇒ 不会漂）
 *
 * ────────────────────────────────────────────────────────────
 * **本门禁验的是「接线」，不是「引擎修了没」**：
 *   ① `EngineHostAPI` 得提供「站方变量感知的 source」
 *   ② `WebViewJSExecutor` 的 **`run` 和 `runGlobal` 两条路都要换**
 *      （⚠️ `runGlobal` 也不能漏：站方 jsLib 的函数在全局作用域里
 *        ⇒ 它们的 `source.getVariable()` 也走宿主桥 ⇒ 也得是槽感知那份）⭐⭐⭐
 *
 * ⚠️ **为什么用静态断言**：这条链的一头在 `Engine/`（import WebKit ⇒ Linux 编不了）
 *   ⇒ 行为验在第五组（swiftc 真编真跑 + 引擎）⇒ 这里钉**接线**（哪条路都别漏）⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BACKEND = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');
const EXECUTOR = path.join(ROOT, 'QiReaderLite/Engine/WebViewJSExecutor.swift');

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✓ ' + m); } else { fail++; console.log('  ✗ ' + m); } };

/**
 * ⭐⭐⭐ **剥掉注释**（断言要作用在【代码】上，不是注释里的话）
 *
 * ⚠️ 为什么：注释里写着「getVariable = 站方变量那一串」时，
 *   直接 grep 会**命中注释** ⇒ 门禁看着绿，其实代码没改 ⇒ 假绿 ⭐⭐⭐
 *
 * ⚠️ **字符串字面量必须原样保留**（`case "source"` / `methods["getVariable"]` 都要断言）
 *   ⇒ 剥了字符串，断言就打在了「被改过的源码」上 ⇒ 自己把自己测没了 ⭐⭐⭐
 *   ⇒ 大括号配平时**跳过字符串**（字符串里可能有 `{`）⇒ 见 bodyOf
 */
function stripComments(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const c2 = src[i + 1];
    if (c === '/' && c2 === '/') { while (i < n && src[i] !== '\n') i++; continue; }   // 行注释
    if (c === '/' && c2 === '*') { i += 2; while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++; i += 2; continue; } // 块注释
    out += c; i++;
  }
  return out;
}

/**
 * 取某个函数/方法的**函数体**（大括号配平）
 *
 * ⚠️ ① 签名后必须**紧跟** `{` ⇒ 协议里的声明（后面是 `}`）不会误当成实现 ⭐
 * ⚠️ ② **同一个签名可能出现多次**（协议声明 + 实现）⇒ 要找**第一个带函数体的**那个 ⭐
 * ⚠️ ③ 配平大括号时**跳过字符串字面量**（`"{\"a\":1}"` 里的括号不算）⭐
 */
function bodyOf(src, signature) {
  let from = 0;
  for (;;) {
    const i = src.indexOf(signature, from);
    if (i < 0) return null;
    from = i + signature.length;
    let j = i + signature.length;
    while (j < src.length && /\s/.test(src[j])) j++;
    if (src[j] !== '{') continue;          // 不是实现 ⇒ 继续找下一个
    // ⭐ 从这个 `{` 开始配平（跳过字符串）
    let depth = 0;
    let k = j;
    while (k < src.length) {
      const ch = src[k];
      if (ch === '"') {                     // 跳过整个字符串
        k++;
        while (k < src.length && src[k] !== '"') { if (src[k] === '\\') k++; k++; }
        k++;
        continue;
      }
      if (ch === '{') depth++;
      else if (ch === '}') { depth--; if (depth === 0) return src.slice(j, k + 1); }
      k++;
    }
    return null;
  }
}

for (const p of [BACKEND, EXECUTOR]) {
  if (!fs.existsSync(p)) { console.log('❌ 文件不存在：' + p); process.exit(2); }
}
const backend = stripComments(fs.readFileSync(BACKEND, 'utf8'));
const executor = stripComments(fs.readFileSync(EXECUTOR, 'utf8'));

console.log('=== ① 宿主 API：得提供「站方变量感知的 source」===');
ok(/class\s+EngineHostAPI\s*:[^{]*\bStationVariableSourceProviding\b/.test(backend),
   'EngineHostAPI 得声明「站方变量感知」协议');
ok(/protocol\s+StationVariableSourceProviding/.test(backend),
   '协议 StationVariableSourceProviding 得在（App 侧自有 ⇒ 不用改引擎协议）');

const slotAware = bodyOf(backend, 'func stationVariableSourceObject() -> HostObject?');
ok(!!slotAware, '得有 stationVariableSourceObject() 的实现（不是只有协议声明）');
if (slotAware) {
  // ⭐⭐⭐ 核心：getVariable 必须读**站方变量槽**，不能读 varBox
  ok(/methods\["getVariable"\]\s*=\s*\{[^}]*\.string\(slot\.text\)/s.test(slotAware),
     '⭐⭐ getVariable 必须返回站方变量槽（slot.text）—— 不是整份 varBox');
  ok(!/methods\["getVariable"\]\s*=\s*\{\s*_\s+in\s+\.string\(Self\.varsJSON/.test(slotAware),
     '⭐⭐ getVariable 不许退回 varsJSON（那正是 403 的老语义）');
  ok(/methods\["setVariable"\]/.test(slotAware), 'setVariable 也得覆盖（老语义会把书源变量整份冲掉）');
  ok(/HostObject\(name:\s*base\.name,\s*methods:\s*methods,\s*properties:\s*base\.properties\)/.test(slotAware),
     '⭐ 其余方法/属性原样委托给引擎那个对象（不重复实现 ⇒ 不会漂）');
}

// hostObject(named:) 的 "source" 分支 ⇒ 必须用槽感知那份
const hostObjectFn = bodyOf(backend, 'func hostObject(named name: String) -> HostObject?');
ok(!!hostObjectFn, '得有 hostObject(named:)');
if (hostObjectFn) {
  ok(/case\s+"source"\s*:\s*return\s+stationVariableSourceObject\(\)/.test(hostObjectFn),
     '⭐ hostObject("source") 必须返回「站方变量感知」那份（否则回退路径仍是老语义）');
}

console.log('\n=== ② JS 执行器：run / runGlobal 两条路都要换 ===');
const applyFn = bodyOf(executor, 'private func applyStationVariableSource()');
ok(!!applyFn, '得有 applyStationVariableSource()');
if (applyFn) {
  ok(/currentHostObjects\["source"\]\s*=\s*s/.test(applyFn),
     '⭐⭐ 必须把 currentHostObjects["source"] 换成槽感知那份');
  ok(/StationVariableSourceProviding/.test(applyFn),
     '⭐ 得从宿主 API 拿那份（不是自己再造一个）');
}
const runFn = bodyOf(executor, 'func run(_ code: String, context: JSRunContext) throws -> JSONValue');
ok(!!runFn, '得有 run(_:context:)');
if (runFn) ok(/applyStationVariableSource\(\)/.test(runFn), '⭐⭐ run() 必须调 applyStationVariableSource()');
const runGlobalFn = bodyOf(executor, 'func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue');
ok(!!runGlobalFn, '得有 runGlobal(_:context:)');
if (runGlobalFn) {
  ok(/applyStationVariableSource\(\)/.test(runGlobalFn),
     '⭐⭐ runGlobal() 也必须调（站方 jsLib 的函数在全局作用域里 ⇒ 同样走宿主桥）');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
