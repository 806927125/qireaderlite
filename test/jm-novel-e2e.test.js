#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **JM小说 · 端到端门禁**（2026-10-26 真机回归实证）
 *
 * ────────────────────────────────────────────────────────────
 * 症状
 * ────────────────────────────────────────────────────────────
 *   发现页有「选分类」下拉（分类出来了）· 点进去 **0 本书**（真机截图）
 *   ⇒ 老引擎（WKWebView）能加载 · 去掉老引擎后不行 ⇒ **回归**
 *
 * ────────────────────────────────────────────────────────────
 * 根因（JSC 后端）
 * ────────────────────────────────────────────────────────────
 *   站方 jsLib 定义了 `hjmDec`（base64 + 字节反转 + 二次解码）
 *   ⇒ 站方 `ruleExplore.bookList` 里**直接调** `hjmDec`
 *   ⇒ 若 jsLib 的全局在**规则求值时不可见** ⇒ `hjmDec is not a function`
 *   ⇒ 站方 `catch(e){return []}` **把真凶吞掉** ⇒ **0 本书** ⭐⭐⭐
 *   ⇒ 症状离真凶极远（看着像「引擎没跑」）⭐⭐⭐
 *
 * ⚠️ **这个门禁跑在 Node 后端**（Linux 沙盒）⇒ 验的是「导出 + 基线 + 全局治理」这条链
 *   ⭐ **JSC 侧的真机行为由【引擎仓的 LiveSourceJSCTests】验**（只有 macOS CI 能跑）⭐⭐⭐
 *
 * ────────────────────────────────────────────────────────────
 * fixture
 * ────────────────────────────────────────────────────────────
 *   · `sources/JM小说.json` ⇒ 真源的 jsLib + ruleExplore
 *   · 假服务器 ⇒ 用站方真实响应（`data` 字段是**加密串**）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'sources', 'JM小说.json');
const RESP = path.join(__dirname, 'fixtures', 'jm-novel-response.json');

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️ 跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  console.log('=== ① fixture 在吗 ===');
  ok(fs.existsSync(SRC), 'sources/JM小说.json 在');
  ok(fs.existsSync(RESP), 'test/fixtures/jm-novel-response.json 在');
  if (!fs.existsSync(SRC) || !fs.existsSync(RESP)) {
    console.log(`\n❌ 通过 ${pass} / 失败 ${fail}`);
    process.exit(1);
  }

  const raw = JSON.parse(fs.readFileSync(SRC, 'utf8'));
  const src = Array.isArray(raw) ? raw[0] : raw;
  const response = fs.readFileSync(RESP, 'utf8');

  console.log('\n=== ② 站方 jsLib 必须能加载（它定义 hjmDec）===');
  ok(typeof src.jsLib === 'string' && src.jsLib.includes('function hjmDec'),
     '真源的 jsLib 里有 hjmDec');

  console.log('\n=== ③ 发现页的分类（站方 exploreUrl 是纯 <js> 块，返回 JSON.stringify(ui)）===');
  // ⭐ 假服务器：站方真实响应（data 字段是加密串）
  const { win, sandbox } = createSandbox({
    routes: [{ match: 'cof03.bahfn.cn', status: 200, body: response }],
  });
  const kindsRes = win.__qrInvoke('exploreKinds', {
    source: {
      bookSourceUrl: src.bookSourceUrl,
      bookSourceName: src.bookSourceName,
      exploreUrl: src.exploreUrl,
      ruleExplore: src.ruleExplore,
    },
    jsLib: src.jsLib,
  });
  console.log('  error:', kindsRes.error || '(无)');
  const kinds = kindsRes.kinds || [];
  console.log('  分类数:', kinds.length, kinds.slice(0, 3).map(k => k.title).join(' , '));
  ok(!kindsRes.error, 'exploreKinds 不报错');
  ok(kinds.length >= 10, `分类数 ≥ 10（实际 ${kinds.length}）⇒ 纯 <js> 块的 JSON 字符串被正确解析成数组`);
  ok(kinds.every(k => typeof k.url === 'string' && k.url.length > 0),
     '每个分类都有 url（站方 jsLib 生成的）');

  console.log('\n=== ④ 点进分类 ⇒ 必须出书（真机症状：0 本）===');
  const pick = kinds.find(k => (k.url || '').includes('/onetab/')) || kinds[0];
  ok(!!pick, '挑得到一个分类');
  if (pick) {
    const booksRes = win.__qrInvoke('explore', {
      source: {
        bookSourceUrl: src.bookSourceUrl,
        bookSourceName: src.bookSourceName,
        exploreUrl: src.exploreUrl,
        ruleExplore: src.ruleExplore,
      },
      jsLib: src.jsLib,
      kindUrl: pick.url.replace('{{page}}', '1'),
      page: 1,
    });
    console.log('  error:', booksRes.error || '(无)');
    const books = booksRes.books || [];
    console.log('  书数:', books.length, books.slice(0, 3).map(b => b.name).join(' , '));
    ok(!booksRes.error, 'explore 不报错');
    ok(books.length > 0, `必须出书（实际 ${books.length} 本）⇒ hjmDec 必须在规则求值时可见`);
    ok(books.every(b => b.name && b.name.length > 0), '每本书都有书名');
  }

  console.log('\n=== ⑤ 站方 jsLib 的全局不能污染别的源（切源要清）===');
  // ⭐ 这一条验「全局治理」还在工作（不是把保护拆了）
  const kinds2 = win.__qrInvoke('exploreKinds', {
    source: {
      bookSourceUrl: src.bookSourceUrl,
      bookSourceName: src.bookSourceName,
      exploreUrl: '<js>JSON.stringify([{title:"只有一个",url:"https://x/1"}])</js>',
      ruleExplore: src.ruleExplore,
    },
    jsLib: src.jsLib,
  });
  ok((kinds2.kinds || []).length === 1, '换一个源 ⇒ 分类只有 1 个（没被上一个源的 jsLib 污染）');

  console.log('');
  console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
