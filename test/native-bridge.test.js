#!/usr/bin/env node
/**
 * 原生 → JS 的返回值桥接契约（沙盒测不出来的那一类，必须静态+真跑都验）
 *
 * 背景：真机报「引擎调用 exploreKinds 失败: 执行 JavaScript 返回结果的类型不受支持」
 *      = WKError.resultTypeIsUnsupported。
 *
 * 根因不是规则写错，是 **桥接**：
 *   callAsyncJavaScript 会把 Promise 的 resolved value 直接桥接成 Foundation 对象。
 *   返回值里出现下面任意一个就抛：
 *     · 属性值 undefined（哪怕对象还有别的键）
 *     · 函数 / Symbol / BigInt / DOM 节点
 *   而 `return {kinds: [...]}` 这种对象 —— 只要某条分支少给个键、或写了
 *   `error: undefined`，真机就整页报错。
 *
 * ⚠️ **jsdom 测不出来**：`vm.runInContext` 会直接把完成值给你，
 *    没有「桥接回 Swift」这一步，所以沙盒看着一切正常。
 *    这跟「evaluateJavaScript 完成值要 void 0」是同一类盲区。
 *
 * 修法：JS 侧一律 JSON.stringify 成字符串，Swift 侧再解析 —— 字符串永远桥接得过去。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const swift = fs.readFileSync(
  path.join(__dirname, '..', 'QiReaderLite', 'Core', 'RuleSandbox.swift'), 'utf8');

/* ---------- ① Swift 侧：invoke 必须走 JSON 字符串桥 ---------- */

const invoke = swift.slice(swift.indexOf('func invoke(_ op: String'),
                             swift.indexOf('static func bridgeJSON'));
ok(/JSON\.stringify\(v === undefined \? null : v\)/.test(invoke),
   'invoke 里把返回值 JSON.stringify 了（不给 JS 对象直接过桥）');
ok(/await window\.__qrInvoke/.test(invoke),
   '显式 await 了 __qrInvoke —— 不 await 的话 JSON.stringify(Promise) 得到 "{}"');
ok(/catch \(e\)[\s\S]{0,160}JSON\.stringify\(\{ error:/.test(invoke),
   'JS 侧 try/catch 自己兜成 {error}，不让异常走桥接层变成不可诊断的 WKError');
ok(/if let text = r as\? String/.test(invoke), 'Swift 侧识别字符串结果');
ok(/static func bridgeJSON/.test(swift), '有 bridgeJSON 解析器');
ok(/catch let e as WKError/.test(invoke) && /e\.code\.rawValue/.test(invoke),
   'WKError 分支带上 code，原来的 localizedDescription 太笼统查不出问题');

// ⚠️ 普通 String 插值不支持 `\(v, privacy: .public)` —— 那是 SwiftUI Text 的插值语法。
//    在字符串里写会报两句跟真正原因完全不沾边的错：
//      cannot infer contextual base in reference to member 'public'
//      extra argument 'privacy' in call
// ⚠️ 必须先剥注释再查 —— 我自己写的那条「反例说明」注释里就带着
//    `\(v, privacy: .public)` 这段文本，不剥会把注释当成代码（同一个坑踩第二次）。
const swiftNoComment = swift
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/[^\n]*/g, '');
ok(!/\\\([^)]*privacy\s*:/.test(swiftNoComment),
   '普通 String 插值里没用 privacy:（剥掉注释后查，否则被注释里的反例文本误报）');
ok(!/Text\s*\(\s*"[^"]*\bprivacy\s*:/.test(swiftNoComment), '也没在 Text() 里混用');

/* ---------- ② 真跑：证明 JSON 字符串桥本身能还原原对象 ---------- */

{
  const { win } = createSandbox({ origin: 'https://cxb-pro.cread.com/' });
  const pack = JSON.parse(fs.readFileSync(
    process.env.SRC_PACK || '/workspace/out/配置文件125个-轻阅适配版.json', 'utf8'));
  const mfzs = pack.find(s => /免费追书/.test(s.bookSourceName));
  ok(!!mfzs, '在 125 源包里找到「免费追书」');

  (async () => {
    // 复现真机那条路：await + JSON.stringify
    const text = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({ source: mfzs })})
      .then(function (v) { return JSON.stringify(v === undefined ? null : v); })`);
    ok(typeof text === 'string', 'JSON.stringify 之后是字符串（字符串一定桥接得过）');
    const back = JSON.parse(text);
    ok(Array.isArray(back.kinds), '字符串能还原出 {kinds:[…]}');
    ok(back.kinds.length > 0, `分类非空（${back.kinds.length} 个）`);
    ok(back.kinds.every(k => typeof k.title === 'string' && typeof k.url === 'string'),
       '每个 kind 的字段都是字符串（无 undefined / 函数 / Symbol）');

    // ★ 反证：直接返回对象在真机是会炸的，这里断言它「不是字符串」
    const direct = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({ source: mfzs })}).then(v => typeof v)`);
    ok(direct === 'object',
       `不 stringify 的话完成值是 ${direct} —— 这正是 WKWebView 桥接失败的那一类（jsdom 却给得干干净净）`);

    // ★ 真证：给对象塞一个 undefined 属性，看 stringify 之后是否干净
    const dirty = await win.eval(`(function () {
      var o = { a: 1, b: undefined, c: function () {}, d: Symbol('x') };
      return JSON.stringify(o);
    })()`);
    const parsed = JSON.parse(dirty);
    ok(!('b' in parsed) && !('c' in parsed) && !('d' in parsed),
       `undefined/函数/Symbol 被 stringify 吃掉（得到 ${dirty}）—— 这就是桥接失败的三个杀手`);

    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  })();
}
