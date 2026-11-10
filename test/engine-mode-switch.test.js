#!/usr/bin/env node
/**
 * 引擎模式门禁（2026-11-10 · 按「阅读2.0（YueduReader）」的架构重做引擎）
 *
 * ⭐ 架构同款点：**规则求值全在 WebView 的 JS 里做**，原生只负责网络/存储/宿主 API
 *   ⇒ 原生与 JS 之间**只过字符串** ⇒ 「执行 JavaScript 返回结果的类型不受支持」这类
 *   **完成值桥接**问题从结构上消失。
 *
 * ⚠️ 两条通路的**返回契约必须一致**：
 *   老引擎返回 `__sourceVars` / `__sourceVariable`，但**不返回** `__sourceVariableChanged`
 *   ⇒ 宿主侧必须**自己判**（回传值 ≠ 灌进去的种子 ⇒ 站方真改过）
 *   ⇒ 否则「站方变量形态证据」变成**自证** ⇒ 存量污染永远清不掉（真机 403 的老坑）。
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const ROOT = path.join(__dirname, '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

/** 剥注释再匹配（注释里写旧文案会误报） */
function stripComments(t) {
  return t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

const modeRaw = read('QiReaderLite/Core/EngineMode.swift');
const svcRaw = read('QiReaderLite/Core/SourceService.swift');
const sheetRaw = read('QiReaderLite/Features/Sources/EngineLogSheet.swift');
const backendRaw = read('QiReaderLite/Core/EngineBackend.swift');

/** ⭐⭐⭐ 门禁本体（可对任意文本跑 ⇒ 变异对照能复用） */
function check({ mode, svc, sheet, backend }) {
  const m = stripComments(mode), s = stripComments(svc), u = stripComments(sheet), b = stripComments(backend || '');
  const p = [];
  if (!/enum EngineMode/.test(m)) p.push('缺 EngineMode');
  if (!/case webView/.test(m) || !/case swiftEngine/.test(m)) p.push('EngineMode 缺两条引擎分支');
  if (!/return \.webView/.test(m)) p.push('默认不是 WebView 引擎（阅读2.0 同款架构）');
  if (!/qr\.engine\.mode/.test(m)) p.push('缺 UserDefaults 键（面板一键切）');
  if (!/EngineMode\.usesWebViewEngine/.test(s)) p.push('invokeEngine 没按引擎模式分流');
  if (!/invokeWebViewEngine/.test(s)) p.push('缺 WebView 引擎通路');
  if (!/RuleSandbox\.shared\.invoke\(op, payload, source: source\)/.test(s)) {
    p.push('WebView 通路没走 RuleSandbox.invoke（规则求值必须在 WebView 里做）');
  }
  if (!/ServiceError\.engineFailed/.test(s)) p.push('WebView 通路没把 {error:…} 翻译成失败（会被当成成功）');
  if (!/__sourceVariableChanged/.test(s)) p.push('WebView 通路没回传「站方变量改没改」');
  if (!/returned != seeded/.test(s)) p.push('「改没改」不是与种子比较（⇒ 证据会自证）');
  if (!/cookieSnapshot/.test(s)) p.push('payload 缺 cookieSnapshot（站方 ajax 要 App 的 cookie 罐）');
  if (/老 JS 引擎已退役/.test(u)) p.push('诊断包还写死「老 JS 引擎已退役」');
  if (!/EngineMode\.label/.test(u)) p.push('诊断包没显示当前引擎');
  if (!/Toggle\(/.test(u) || !/EngineMode\.current = /.test(u)) p.push('自检面板没有引擎切换开关');
  // ⚠️ 开关必须**真的**切（只写 .webView = 摆设 ⇒ 变异会溜过去）
  if (!/EngineMode\.current = \$0 \? \.webView : \.swiftEngine/.test(u)) {
    p.push('自检面板的开关没有真的切换引擎（setter 只会写 .webView）');
  }
  // ⭐⭐⭐ **展示必须跟着真实通路走**（否则界面会撒谎 ⇒ 用户以为还在新引擎）
  if (!/case webView/.test(b)) p.push('EngineBackend 没有 WebView 引擎档位');
  if (/var current: Kind \{ \.swiftNew \}/.test(b)) p.push('EngineBackend.current 仍写死新引擎（界面会撒谎）');
  if (!/EngineMode\.current/.test(b)) p.push('EngineBackend 没读 EngineMode（真相源不唯一 ⇒ 会漂移）');
  if (/@AppStorage\("qr\.engineBackend"\)/.test(u)) p.push('面板还挂着旧的 engineBackend 开关（两个开关并存 ⇒ 会打架）');
  return p;
}

const base = check({ mode: modeRaw, svc: svcRaw, sheet: sheetRaw, backend: backendRaw });
ok(base.length === 0, '基线无问题' + (base.length ? '：' + base.join(' / ') : ' ✓'));
base.forEach(p => ok(false, p));

/* ---------- 变异对照：门禁必须报红（证明有牙齿） ---------- */
const mutations = [
  ['默认改成 swift 引擎', { mode: modeRaw.replace('return .webView', 'return .swiftEngine') }],
  ['分流判断去掉', { svc: svcRaw.replace(/if EngineMode\.usesWebViewEngine \{[\s\S]*?\n        \}/, '') }],
  ['WebView 通路不翻译 error', { svc: svcRaw.replace(/ServiceError\.engineFailed/g, '_ = 0') }],
  ['不判「改没改」', { svc: svcRaw.replace(/returned != seeded/g, 'false') }],
  ['不用 RuleSandbox 求值', { svc: svcRaw.replace(/RuleSandbox\.shared\.invoke\(op, payload, source: source\)/, 'SomeOtherEngine.call(op)') }],
  ['诊断包写死旧文案', { sheet: sheetRaw.replace(/EngineMode\.label/, '"老 JS 引擎已退役"') }],
  ['面板开关去掉', { sheet: sheetRaw.replace(/EngineMode\.current = \$0 \? \.webView : \.swiftEngine/, 'EngineMode.current = .webView') }],
  ['EngineBackend 写死新引擎', { backend: backendRaw.replace(/EngineMode\.current == \.webView \? \.webView : \.swiftNew/, '.swiftNew') }],
  ['旧开关复活', { sheet: sheetRaw.replace('    // ⭐⭐⭐ 2026-11-10：旧的', '    @AppStorage("qr.engineBackend") private var backendKind = ""\n    // ⭐⭐⭐ 2026-11-10：旧的') }],
];
for (const [name, over] of mutations) {
  const p = check({ mode: modeRaw, svc: svcRaw, sheet: sheetRaw, backend: backendRaw, ...over });
  ok(p.length > 0, `变异「${name}」被门禁抓到（${p.length} 项）`);
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
