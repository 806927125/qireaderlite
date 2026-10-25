#!/usr/bin/env node
/**
 * **站方 `java.startBrowser` 必须同步返回**（不能把 Promise 塞进 URL）
 *
 * 起因（真机 2026-10-21，测书源报告实测）：
 *   站方把 `java.startBrowser(...)` 直接写在 URL 模板里：
 *     "url": '{java.startBrowser("https://fanqienovel.com/","番茄登录");}'
 *   老引擎**稍后**再解析这个 URL 模板时，**已经不在两遍跑上下文里**
 *   ⇒ `QR.__qrAjaxRecord` 不存在 ⇒ 走 `openBrowser` 直连 ⇒ **返回 Promise**
 *   ⇒ 那个 Promise 被字符串化塞进 URL ⇒ 变成 **`[object Promise]`**
 *   ⇒ explore 拿它当 URL 去请求 ⇒「URL 非法: [object Promise]」
 *   ⇒ **整个发现功能直接挂掉**（真机：40 秒白等，最后 ❌）
 *
 *   站方（Legado/栖阅）的 `java.startBrowser` 是**同步**的
 *   ⇒ 轻阅也必须同步返回（空串即可：那个 kind 本来就是「纯动作项」）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新引擎**没有两遍跑** ⇒ 「两遍跑上下文里走录制分支」那套**没有等价物**
 *   ⇒ 换线/换线的语义由**宿主直接实现**：`java.startBrowser`（及它的兄弟们）
 *     **同步返回一个字符串**（本实现是空串）⇒ 绝不会出现 Promise ⭐⭐⭐
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「`java.startBrowser` 不许返回 Promise（否则 URL 变成 [object Promise]）」
 *   新语义「宿主对 `startBrowser` / `startBrowserAwait` / `startBrowserDp` /
 *             `showBrowser` / `showReadingBrowser` **一律同步返回字符串**」
 *   ⇒ 可观测结果一致：**URL 模板里永远不会出现 `[object Promise]`** ⭐⭐⭐
 *
 * ⚠️ **已知缺口（迁移时发现，不在这个门禁的断言范围内，详见交接报告）**：
 *   宿主侧现在对 `java.startBrowser` **只记日志、不弹浏览器**
 *   ⇒ 站方「🍅番茄登录 / 🔐注册书源 / 🏝用户后台 / 📐使用教程」这类**纯动作项**点不动
 *   ⇒ （老引擎是在两遍跑的原生侧弹的 ⇒ 新架构缺了这一步）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  console.log('=== ① startBrowser 不能返回 Promise ===');
  {
    // ⭐⭐⭐ **真跑**：让站方自己调一次 `java.startBrowser` ⇒ 看它到底返回什么
    const { win } = createSandbox({ routes: [] });
    const code = `
var v = java.startBrowser('https://fanqienovel.com/', '番茄登录');
JSON.stringify({
  type: typeof v,
  isPromise: !!(v && typeof v.then === 'function'),
  text: String(v)
})
`;
    const out = String(win.QR.rule.runJs(code, {}));
    console.log('  站方拿到:', out.slice(0, 160));
    let probe = null;
    try { probe = JSON.parse(out); } catch (e) { probe = null; }
    ok(probe !== null, '拿到站方侧的探测结果（不是 ERR）');
    if (probe) {
      ok(probe.isPromise === false,
         'startBrowser 的返回值**不是 Promise**（thenable ⇒ 会变成 [object Promise]）');
      ok(String(probe.text).indexOf('[object Promise]') < 0,
         '字符串化后**不含 [object Promise]**（老 bug 的直接反面）');
      ok(probe.type !== 'object' || probe.type === 'undefined' || probe.type === 'string',
         `返回值是**原始值**（实际 ${probe.type}）⇒ 能安全塞进 URL 模板`);
    }
  }

  console.log('\n=== ② 宿主侧的实现必须是「同步返回」 ===');
  {
    // 宿主实现在 App 侧（`EngineHostAPI`）⇒ 读它的源码
    const app = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
    const m = app.match(/case "startBrowserAwait"[^\n]*:\n([\s\S]{0,900}?)\n {8}case /);
    ok(!!m, '找到宿主对浏览器类方法的实现');
    if (m) {
      const body = m[0];
      ok(/return \.string\(""\)/.test(body),
         '浏览器类方法**同步返回空串**（不是 Promise / 不是 Task）');
      ok(!/Task\s*\{|async |await /.test(body),
         '这条路径上**没有异步等待**（真机上是同步返回）');
    }
  }

  console.log('\n=== ③ 浏览器类调用共享同一套同步语义 ===');
  {
    const app = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
    const line = (app.match(/case "startBrowserAwait"[^\n]*/) || [''])[0];
    ok(line.length > 0, '找到浏览器类的 case 分支');
    for (const m of ['startBrowserAwait', 'startBrowserDp', 'showReadingBrowser', 'showBrowser', 'startBrowser']) {
      ok(line.indexOf('"' + m + '"') >= 0,
         `「${m}」和 startBrowser **走同一个分支**（共享同步语义 ⇒ 不会有一个偷偷返回 Promise）`);
    }
    // ⭐ 契约侧：这 5 个方法都必须在引擎的宿主 API 清单里 ⇒ 包装函数会生成 ⇒ 站方不 TypeError
    const api = engineSwiftSrc('JS/JSHostAPI.swift');
    for (const m of ['startBrowser', 'startBrowserAwait', 'startBrowserDp', 'showBrowser', 'showReadingBrowser']) {
      ok(new RegExp('name: "' + m + '"').test(api),
         `契约里有 java.${m}（包装函数会生成 ⇒ 站方调用不会 TypeError）`);
    }
  }

  console.log('\n=== ④ 「纯动作项」不会把发现页打挂（老 bug 的正面覆盖）===');
  {
    // 老 bug：站方把 `java.startBrowser(...)` 写在 url 模板里
    //   ⇒ 老引擎在**没有两遍跑上下文**时返回 Promise ⇒ URL 变成 "[object Promise]"
    //   ⇒ explore 拿它去请求 ⇒「URL 非法」⇒ **整个发现页打不开**
    const { win } = createSandbox({ routes: [{ match: '/x', status: 200, body: 'ok' }] });
    const kinds = win.__qrInvoke('exploreKinds', {
      source: {
        bookSourceUrl: 'https://source.example.com',
        bookSourceName: 'src',
        exploreUrl: JSON.stringify([
          { title: '登录番茄', url: '{java.startBrowser("https://fanqienovel.com/","番茄登录");}' },
          { title: '玄幻', url: 'https://source.example.com/sort1/{{page}}/' },
        ]),
      },
    });
    const list = (kinds && kinds.kinds) || [];
    console.log('  分类:', JSON.stringify(list.map(k => ({ title: k.title, url: k.url }))));
    ok(list.length === 2, `分类还是 2 个（实际 ${list.length} 个）`);
    const action = list.find(k => k.title === '登录番茄');
    ok(!!action, '「登录番茄」这个纯动作项还在列表里（用户要点它去登录）');
    if (action) {
      ok(String(action.url).indexOf('[object Promise]') < 0,
         '它的 url **不含 [object Promise]**（老 bug 的直接反面）');
    }
    // ⭐ App 侧的保护：默认**不要**选中「没有 url 的纯动作项」⇒ 发现页不会白等 40 秒
    const ui = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Features', 'Explore', 'ExploreView.swift'), 'utf8');
    ok(/let withURL = kinds\.filter \{ !\$0\.url\.isEmpty \}/.test(ui),
       'App 默认不选「没有 url」的分类项（纯动作项不拿去请求）');
    ok(/let pageable = withURL\.filter \{ \$0\.url\.contains\("\{\{page\}\}"\) \}/.test(ui),
       'App 优先选带 {{page}} 的分类（能翻页的那种）');
    ok(/pageable\.isEmpty[\s\S]{0,300}?withURL\.isEmpty \? kinds\.first : withURL\.first/.test(ui),
       '没有可翻页的分类时才退回第一个有 url 的');
  }

  console.log('\n=== ⑤ 老引擎的浏览器兜底实现 ⇒ 已退休 ===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（`mkBrowserLike` 造 browser-like 对象
  //     / `startBrowserAwait` 的两遍跑兜底 / `QR.__qrAjaxRecord` 录制分支）
  //   ⇒ 那些是**实现细节**，不是语义
  //   ⇒ 老引擎退役后**没有等价物**（新引擎没有两遍跑 ⇒ 没有「录制分支」这层补丁）
  //   ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
