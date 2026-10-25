#!/usr/bin/env node
/**
 * **@js: 规则里不要做 `{{}}` 插值**（2026-10-22 实测 NovelHub 聚合源炸在这）
 *
 * 跑法：node test/js-no-interpolate.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * Legado / 栖阅的语义：**`@js:` 是 JS 源码，里面的 `{{}}` 原样保留**
 * （插值只发生在「URL 模板」规则上，比如 `searchUrl: "https://x?q={{keyword}}"`）
 *
 * 轻阅以前在 `exploreKinds` 里对 `@js:` 源码做了 interpolate ⇒ 踩了两个坑：
 *   ① `{{...}}`（**JS 对象展开语法**）被 evalExpr 求值失败 → 吃成空串
 *      ⇒ **整个 JS 语法坏掉** ⇒ 「Invalid or unexpected token」⭐
 *   ② `{{page+1}}` / `{{(page-1)*30}}` 被算成**固定数字**
 *      ⇒ 站方 JS 拼出来的分类 URL 的 page 写死 ⇒ **发现页翻页失效** ⭐
 *
 * 真实受害源：🍒NovelHub聚合小说（exploreUrl 是 168KB 的 `@js:`，含 750 个 `{{page}}`）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/engine.js`）⇒ 已删 ⇒ 门禁的对象没了。
 *   ⇒ 老门禁第 1 段是**读老引擎 JS 源码**的静态断言（`exploreKinds: function` / `stripJsWrapper`）
 *     ⇒ 那些是**老引擎的实现细节** ⇒ 退休 ⇒ 改按【新引擎 Swift 源码】+【真跑】来验 ⭐⭐⭐
 * · 现在：**直接调新引擎**（`legado-engine --op exploreKinds`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（本门禁全程离线 ⇒ 路由兜底挡网络）。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（`exploreKinds: function` /
//     `rule.interpolate(rule.stripJsWrapper(spec), scope)` / `stripJsWrapper`）⇒ 那是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
//   ⇒ 语义等价在哪：**引擎仓 `docs/legado-semantics.md` §S-KIND-01**「`@js:` 里不做 `{{}}` 插值」
//     + 下面的【真跑段】（合成的 `{{...}}` / `{{page}}` / `{{page+1}}` 三条）+【真源段】（NovelHub 169KB）⭐⭐⭐

/** 取 Swift 某个函数的函数体（按大括号配对 ⇒ 不用猜行号） */
function swiftFuncBody(src, sig) {
  const i = src.indexOf(sig);
  if (i < 0) return '';
  let depth = 0, started = false;
  for (let j = src.indexOf('{', i); j < src.length; j++) {
    const c = src[j];
    if (c === '{') { depth++; started = true; }
    else if (c === '}') { depth--; if (started && depth === 0) return src.slice(i, j + 1); }
  }
  return '';
}

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  // ⭐⭐⭐ **假服务器 = 声明式 routes**：`match: ''` ⇒ 匹配一切 ⇒ **彻底挡住网络**（全程离线）
  const { win } = createSandbox({
    routes: [{ match: '', status: 200, body: '{"code":0,"data":[]}' }],
  });

  console.log('=== 1. 源码（新引擎）：exploreKinds 的 @js: 分支不插值 ===');
  {
    const engineSrc = engineSwiftSrc('Pipeline/SourceEngine.swift');
    const body = swiftFuncBody(engineSrc, 'public func exploreKinds()');
    console.log('  exploreKinds 函数体长度:', body.length);
    ok(body.length > 0, '找到新引擎的 exploreKinds 实现');
    ok(body.indexOf('TemplateEngine.render') < 0,
       '⭐ exploreKinds 里**没有**对规则做模板渲染（`{{}}` 不该被吃掉）');
    ok(body.indexOf('interpolate') < 0,
       '⭐ exploreKinds 里**没有** interpolate（`{{...}}` 是 JS 展开语法 ⇒ 插值就坏）');
    ok(/js\.run\(jsCode|js\.run\(code/.test(body),
       '⭐ exploreKinds 的 JS 分支是**原样**把 JS 源码交给引擎跑');
  }

  console.log('\n=== 2. 活体（离线）：@js: 里的 `{{...}}`（JS 展开语法）不被吃掉 ===');
  {
    // `{{...o}}` 是 **JS 对象展开语法** ⇒ 一旦被当模板插值 ⇒ 语法坏 ⇒ 整条规则失败
    const js = '@js: (function(){ var o = {a:1}; var s = JSON.stringify({...o}); '
      + ' return [{title: "分类" + s, url: "https://x.example/list"}]; })()';
    const r = win.__qrInvoke('exploreKinds', {
      source: { bookSourceUrl: 'https://x.example/', bookSourceName: '假源', enabled: true, exploreUrl: js },
    });
    const kinds = (r && r.kinds) || [];
    console.log('  分类:', JSON.stringify(kinds.map(k => k.title)), '| error:', (r && r.error) || '(无)');
    ok(kinds.length === 1, '规则跑起来了（没报语法错）', r && r.error);
    ok(kinds[0] && kinds[0].title === '分类{"a":1}',
       '⭐⭐ `{{...o}}` 被**JS 自己**展开了（说明源码原样进了引擎）', kinds[0] && kinds[0].title);
  }

  console.log('\n=== 3. 活体（离线）：`{{page}}` / `{{page+1}}` 原样活到分类 URL 里 ===');
  {
    const js = '@js: (function(){ return [{title: "T", url: "https://x.example/list?page={{page}}&p={{page+1}}"}]; })()';
    const r = win.__qrInvoke('exploreKinds', {
      source: { bookSourceUrl: 'https://x.example/', bookSourceName: '假源', enabled: true, exploreUrl: js },
    });
    const kinds = (r && r.kinds) || [];
    const url = (kinds[0] && kinds[0].url) || '';
    console.log('  分类 URL:', url);
    ok(url.indexOf('{{page}}') >= 0, '⭐ `{{page}}` **原样保留**（没被插成数字）', url);
    ok(url.indexOf('{{page+1}}') >= 0,
       '⭐⭐ `{{page+1}}` **原样保留**（没被算成固定数字 ⇒ 站方翻页不会写死）', url);
  }

  console.log('\n=== 4. 活体（离线·真源）：NovelHub 聚合源的 169KB exploreUrl 能编译 ===');
  {
    const NH = path.join(__dirname, '..', 'sources', 'NovelHub聚合小说-轻阅版.json');
    if (!fs.existsSync(NH)) {
      console.log('  ⏭️  跳过（环境）：本地没有 NovelHub 源文件 ⇒ 本条**没验到**（≠ 通过）');
    } else {
      const raw = JSON.parse(fs.readFileSync(NH, 'utf8'));
      const s = (Array.isArray(raw) ? raw : [raw])[0];
      const code = String(s.exploreUrl || '');
      const nPage = (code.match(/\{\{page\}\}/g) || []).length;
      const nSpread = (code.match(/\{\{\.\.\.\}\}/g) || []).length;
      console.log('  站方 exploreUrl 长度:', code.length,
        '| {{page}} ×', nPage, '| {{...}} ×', nSpread);
      // ⚠️ **payload 有 290KB** ⇒ 超过 argv 上限 ⇒ 门禁沙盒会自动改走临时文件（引擎 `--op` 支持读文件）⭐⭐⭐
      const r = win.__qrInvoke('exploreKinds', {
        source: {
          bookSourceUrl: s.bookSourceUrl, bookSourceName: s.bookSourceName, exploreUrl: code,
        },
        jsLib: s.jsLib,
      });
      const err = String((r && r.error) || '');
      console.log('  engine:', r && r.ok ? 'ok' : ('error = ' + err));
      ok(!/Invalid or unexpected token/i.test(err),
         '⭐⭐ **不报**「Invalid or unexpected token」（`{{...}}` 被吃掉 ⇒ 语法坏）', err);
      ok(!/jsError|JS 执行失败|Unexpected token/i.test(err),
         '⭐ **不报** JS 执行失败（169KB 的站方 JS 整体能编译）', err);
    }
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
