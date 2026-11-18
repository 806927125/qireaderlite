#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **`@js:` 规则不许在正文里被「尾部 JS」腰斩**（2026-11-18 真机真凶）
 *
 * 跑法：node test/js-rule-tail-contract.test.js
 * 可选：QR_ENGINE_DIR=<引擎目录> ⇒ 指向别的引擎副本（给基座/变异对照用）
 *
 * ────────────────────────────────────────────────────────────
 * 症状（真机）
 *
 *   聚合源（🍒NovelHub）的**详情字段**（name / author / kind / lastChapter /
 *   coverUrl / wordCount）在轻阅的老 WebView 引擎上**全是空的**
 *   ⇒ 详情页「书名/作者/分类」都拿不到 ⇒ 整条详情链废
 *
 * 根因（三层，缺一不可）
 *
 *   ① 站方的 `ruleBookInfo.*` 是**超长 `@js:` 规则**（15~20KB）
 *   ② 这些规则的**注释里提到了 `@js:`**（例如：
 *      `// 命中就覆盖 out（不 return —— @js: 是 evaluateString 语义，顶层 return 会抛）`）
 *   ③ 老引擎 `rule-analyzer.js` 的 `findJsTail()` 用 `indexOf('@js:', 4)`
 *      找「尾部 JS 后处理」⇒ **在注释那一处把规则腰斩** ⭐⭐⭐
 *      ⇒ 腰斩后 `try { … }` 失去 `catch`
 *      ⇒ `SyntaxError: Missing catch or finally after try`
 *      ⇒ **整条规则死** ⇒ 6 个字段一起空 ⭐⭐⭐
 *
 * ⭐ **正确口径**（与栖阅 AnalyzeRule 一致、也与自研引擎 `RuleParser` ②' 一致）：
 *   **`@js:` 前缀 ⇒ 整条规则就是 JS 代码 ⇒ 不取尾部、不按 `||`/`&&` 拆**
 *
 * ⚠️ 这个门禁的「活体」部分**不联网**（页面走 mock）⇒ 3 秒跑完
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? (pass++, console.log('  ✓ ' + m)) : (fail++, console.log('  ✗ ' + m)); };

const root = path.join(__dirname, '..');
const engineDir = process.env.QR_ENGINE_DIR || path.join(root, 'QiReaderLite', 'Resources', 'engine');
const analyzerSrc = fs.readFileSync(path.join(engineDir, 'rule-analyzer.js'), 'utf8');

/** 站方详情页的 JSON（起点聚合形态）—— 用作 mock 响应 */
const DETAIL_JSON = JSON.stringify({
  name: '天渊', author: '沐潇三生', tag: '番茄',
  coverUrl: 'https://example.com/c.jpg',
  intro: '百年前，陈青源进入了一个名为天渊的禁区……',
  kind: '传统玄幻', lastChapter: '第3091章 客卿，道别',
});

/** 一条「注释里提到 @js:」的 `@js:` 规则（老引擎会在注释处腰斩 ⇒ try 失去 catch） */
const RULE_WITH_JS_IN_COMMENT = [
  '@js:',
  '(function(){',
  '  var out = "";',
  '  try {',
  '    out = "OK-VALUE";',
  '    // 命中就覆盖 out（不 return —— @js: 是 evaluateString 语义，顶层 return 会抛）',
  '  } catch (e) { out = "ERR"; }',
  '  return out;',
  '})()',
].join('\n');

function makeSource(nameRule) {
  return {
    bookSourceUrl: 'https://example.com/',
    bookSourceName: '门禁用源',
    searchUrl: '',
    ruleSearch: { name: '', bookUrl: '' },
    ruleBookInfo: {
      name: nameRule, author: '', intro: '', kind: '',
      lastChapter: '', coverUrl: '', tocUrl: '', wordCount: '',
    },
    ruleToc: { chapterList: '' },
    ruleContent: { content: '' },
  };
}

async function runBookInfo(source, bookUrl) {
  const { win } = createSandbox({
    origin: 'https://example.com',
    nativeMock: async (fn, args) => {
      if (fn === 'request') {
        const u = String(args.url || '');
        if (u.indexOf('moyue.app') >= 0 || u.indexOf('example.com') >= 0) {
          return { ok: true, code: 200, body: DETAIL_JSON };
        }
        return { ok: false, error: 'no-fixture ' + u.slice(0, 60) };
      }
      return { ok: true, code: 200, body: '' };
    },
  });
  const payload = {
    source,
    bookUrl,
    book: { bookUrl, name: '', author: '', intro: '' },
  };
  return await win.eval(`window.__qrInvoke('bookInfo', ${JSON.stringify(payload)})`);
}

(async () => {
  console.log('=== 1. 静态：老引擎有「`@js:` 前缀 ⇒ 不取尾部」的保护 ===');
  ok(/isJsPrefixed/.test(analyzerSrc), 'rule-analyzer.js 里有 `isJsPrefixed` 标记');
  ok(/if\s*\(!isJsPrefixed\)/.test(analyzerSrc), '取尾部的代码被 `if (!isJsPrefixed)` 包住');
  ok(/findJsTail/.test(analyzerSrc), '（findJsTail 仍在，用于非 @js: 规则的复合形态）');

  console.log('\n=== 2. 活体：`@js:` 规则正文里提到 `@js:` ⇒ 整条规则仍能求值 ===');
  {
    const src = makeSource(RULE_WITH_JS_IN_COMMENT);
    const r = await runBookInfo(src, 'https://example.com/detail');
    const name = (r && r.book && r.book.name) || '';
    // ⚠️ **不要打印引擎原始报错**：里面会有「SyntaxError: ...」字样
    //   ⇒ run-all-gates.sh 的崩溃探测器（grep SyntaxError）会把**好门禁**误判成「崩了」⭐⭐⭐
    console.log('  book.name =', JSON.stringify(name), '| 有 error =', !!(r && r.error));
    ok(name === 'OK-VALUE',
       '规则没被腰斩（`try{}` 保住 catch ⇒ 整条求值 ⇒ 拿到 OK-VALUE）');
  }

  console.log('\n=== 3. 活体：长规则（>8KB）+ 注释里的 `@js:` ⇒ 也要能求值 ===');
  {
    // 把同样的结构撑到 8KB 以上（模拟聚合源那种超长规则）
    const filler = Array.from({ length: 400 },
      (_, i) => `  // 填充行 ${i}：占位注释，用于把规则撑长（模拟聚合源那种 15~20KB 的超长规则）`).join('\n');
    const longRule = [
      '@js:',
      '(function(){',
      '  var out = "";',
      '  try {',
      filler,
      '    out = "OK-LONG";',
      '    // 注释里提到 @js:（老引擎会在这里腰斩）',
      '  } catch (e) { out = "ERR"; }',
      '  return out;',
      '})()',
    ].join('\n');
    const src = makeSource(longRule);
    const r = await runBookInfo(src, 'https://example.com/detail');
    const name = (r && r.book && r.book.name) || '';
    console.log('  规则长度 =', longRule.length, '| book.name =', JSON.stringify(name));
    ok(name === 'OK-LONG', '超长规则也没被腰斩');
  }

  console.log('\n=== 4. 回归：真源（本地 NovelHub 聚合源）的详情规则含第二个 `@js:` ===');
  {
    const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
    if (!fs.existsSync(NH)) {
      console.log('  (跳过：本地没有 NovelHub 源文件)');
    } else {
      const src = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];
      const fields = ['name', 'author', 'kind', 'lastChapter', 'coverUrl', 'wordCount'];
      let withSecond = 0;
      for (const f of fields) {
        const t = String((src.ruleBookInfo || {})[f] || '');
        if (t.indexOf('@js:', 4) >= 0) withSecond++;
      }
      console.log('  含第二个 `@js:` 的详情字段数 =', withSecond, '/', fields.length);
      ok(withSecond > 0,
         '这个源确实踩这个坑（字段正文里提到了 @js: ⇒ 以前会被腰斩）');

      // 活体：把解锁态按源里自己的出厂哈希注入，跑一次真实详情规则
      const lib = String(src.jsLib || '');
      const m = lib.match(/var NH_PWD_HASH\s*=\s*"([0-9a-f]+)"/);
      const hash = m ? m[1] : '';
      const s2 = Object.assign({}, src, {
        __variables: JSON.stringify({ nhAuthed: hash }),
        __variable: JSON.stringify({ nhAuthed: hash }),
      });
      const bookUrl = 'https://moyue.app/legado/detail?url=NzEzODI0OTMxODkwOTA4NjcyNw%40%E7%95%AA%E8%8C%84';
      const r = await runBookInfo(s2, bookUrl);
      const b = (r && r.book) || {};
      console.log('  真源详情：name =', JSON.stringify(b.name), '| author =', JSON.stringify(b.author),
                  '| kind =', JSON.stringify(b.kind));
      ok(String(b.name || '').length > 0, '真源详情：**书名**能取到（以前被腰斩 ⇒ 空）');
      ok(String(b.author || '').length > 0, '真源详情：**作者**能取到');
      ok(String(b.kind || '').length > 0, '真源详情：**分类**能取到');
    }
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
