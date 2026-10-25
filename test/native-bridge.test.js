#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **引擎 ⇄ 原生的「返回值边界」门禁**（老 WKWebView 桥接已退役）
 *
 * 跑法：node test/native-bridge.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 这个门禁原来验的是什么（老架构）
 *
 *   真机报「引擎调用 exploreKinds 失败: 执行 JavaScript 返回结果的类型不受支持」
 *   = WKError.resultTypeIsUnsupported。
 *   根因不是规则写错，是 **WKWebView 的桥接**：
 *     · callAsyncJavaScript 会把 Promise 的 resolved value 直接桥接成 Foundation 对象
 *     · 返回值里出现 undefined / 函数 / Symbol / BigInt / DOM 节点 ⇒ 直接抛
 *   修法：JS 侧一律 JSON.stringify 成字符串，Swift 侧再解析。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **现在（老引擎物理删除后）这条边界长什么样**
 *
 *   老架构：App ⇄ WKWebView ⇄ JS      ⇒ 桥接会炸 ⇒ 必须 JSON.stringify
 *   新架构：App ⇄ **Swift 引擎（进程内）** ⇄ JS
 *          ⇒ **没有 WKWebView 桥接** ⇒ 「桥接炸」这个失败模式**不存在了**
 *          ⇒ 但**语义没消失**：引擎 → App 的值**仍然是 JSON**（引擎把 JS 值转成 JSON 再解码）
 *          ⇒ 「返回值里混进 undefined / 函数 / Symbol ⇒ 对面拿不到干净的值」**照样会出事**
 *          （只是症状从「WKError 抛异常」变成「字段静默丢失 / 解析失败」）⭐⭐⭐
 *
 * ⇒ 所以这里保留**语义**、退休**实现**：
 *   ① 静态：老桥接（callAsyncJavaScript / WKError / bridgeJSON）**不许有残留**
 *      （老引擎物理删除的**可执行证据** ⇒ 比注释可靠）⭐⭐⭐
 *   ② 静态：新的边界是「**从 JSON 解出来**」⇒ App 侧必须有解码路径
 *   ③ 真跑：真跑一个 op ⇒ payload **能 JSON 往返**、字段全是字符串
 *      （老门禁的核心断言：一个 kind 少个字段 ⇒ 真机就炸）⭐⭐⭐
 *   ④ 真跑：JS 层「JSON.stringify 吃掉 undefined/函数/Symbol」⇒ 三个杀手
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const ROOT = path.join(__dirname, '..');
const readCode = (p) => fs.readFileSync(p, 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/[^\n]*/g, '');           // ⚠️ 必须剥注释：注释里的「反例」会假红

const sandboxSwift = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'RuleSandbox.swift'));
const backendSwift = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'));

// ───────── ① 老桥接不许有残留（老引擎物理删除的可执行证据）─────────
console.log('=== 1. 老 WKWebView 桥接不许有残留 ===');

ok(!/callAsyncJavaScript/.test(sandboxSwift),
   'RuleSandbox 里没有 callAsyncJavaScript（老 WKWebView 桥接已退役）');
ok(!/WKError/.test(sandboxSwift),
   'RuleSandbox 里没有 WKError 分支（老桥接的错误分类已退役）');
ok(!/bridgeJSON/.test(sandboxSwift),
   'RuleSandbox 里没有 bridgeJSON（老桥接的 JSON 解析器已退役）');
ok(!/evaluateJavaScript/.test(sandboxSwift),
   'RuleSandbox 里没有 evaluateJavaScript（老引擎的求值入口已退役）');

// ⚠️ 老门禁的「反例说明」曾经写在注释里 ⇒ 剥完注释再查（同一个坑踩过两次）
ok(!/\\\([^)]*privacy\s*:/.test(sandboxSwift),
   '普通 String 插值里没用 privacy:（剥掉注释后查，否则被注释里的反例文本误报）');
ok(!/Text\s*\(\s*"[^"]*\bprivacy\s*:/.test(sandboxSwift), '也没在 Text() 里混用');

// ───────── ② 新的边界：值是「从 JSON 解出来的」─────────
console.log('\n=== 2. 新的边界：引擎回的值是解出来的，不是活的 JS 对象 ===');

ok(/func invoke\(_ op: String/.test(backendSwift),
   'LegadoEngineBackend 有 invoke（App 侧调引擎的统一入口）');
ok(/JSONSerialization\.jsonObject|JSONDecoder/.test(backendSwift),
   'App 侧从 JSON 解出引擎的值（不是直接拿一个活的 JS 对象过桥）');

// 关键 op 都要接上（漏一个 ⇒ 那个 op 静默返回 nil ⇒ 页面空白）
for (const op of ['explore', 'exploreKinds', 'bookInfo', 'toc', 'content', 'login', 'loginProbe']) {
  ok(new RegExp(`case "${op}"`).test(backendSwift), `invoke 接了 op：${op}`);
}

// ───────── ③ 真跑：payload 必须能 JSON 往返、字段全是字符串 ────────
console.log('\n=== 3. 真跑 exploreKinds（返回值边界）===');

if (!engineAvailable()) {
  console.log('  ⚠️  引擎不可用 ⇒ 跳过真跑段（本次没验到，不算通过）');
} else {
  const packFile = process.env.SRC_PACK || [
    '/workspace/out/配置文件125个-轻阅适配版.json',
    path.join(ROOT, 'sources', '配置文件125个-轻阅适配版.json'),
  ].find(p => fs.existsSync(p));
  const pack = packFile ? JSON.parse(fs.readFileSync(packFile, 'utf8')) : [];
  const mfzs = pack.find(s => /免费追书/.test(s.bookSourceName));
  ok(!!mfzs, '在 125 源包里找到「免费追书」');

  if (mfzs) {
    const { win } = createSandbox({});
    const res = win.__qrInvoke('exploreKinds', { source: mfzs });
    ok(res && !res.error, `exploreKinds 没报错${res && res.error ? '：' + res.error : ''}`);

    const kinds = (res && res.kinds) || [];
    ok(Array.isArray(kinds), '返回里有 kinds 数组');
    ok(kinds.length > 0, `分类非空（${kinds.length} 个）`);
    ok(kinds.every(k => typeof k.title === 'string' && typeof k.url === 'string'),
       '每个 kind 的字段都是字符串（undefined / 函数 / Symbol 混进来 ⇒ 对面拿不到干净的值）');

    // ⭐⭐⭐ **JSON 往返**：引擎给 App 的值必须是「干净的 JSON」
    //    （老门禁的核心：老架构里 JSON.stringify 是**桥接的前提**；
    //     新架构里它是**值能被解出来的前提** ⇒ 语义等价，只是换了机制）⭐⭐⭐
    const round = JSON.parse(JSON.stringify(res));
    ok(round && Array.isArray(round.kinds) && round.kinds.length === kinds.length,
       '整个 payload 能 JSON 往返（没有 undefined / 函数 / Symbol 漏出来）');
  }
}

// ───────── ④ JS 层：JSON.stringify 吃掉三个杀手 ────────
console.log('\n=== 4. JSON.stringify 吃掉 undefined / 函数 / Symbol（三个杀手）===');
{
  const { win } = createSandbox({});
  const dirty = win.eval(`JSON.stringify({ a: 1, b: undefined, c: function () {}, d: Symbol('x') })`);
  let parsed = null;
  try { parsed = JSON.parse(dirty); } catch (e) { parsed = null; }
  ok(parsed && !('b' in parsed) && !('c' in parsed) && !('d' in parsed),
     `undefined/函数/Symbol 被 stringify 吃掉（得到 ${dirty}）—— 这就是边界上会炸的三个东西`);
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
