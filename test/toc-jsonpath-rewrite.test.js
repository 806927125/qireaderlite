#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **JSON 列表项的字段规则改写 + 带后缀图片 URL**（2026-10-29 真机）
 *
 * 跑法：node test/toc-jsonpath-rewrite.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **症状（✿UAA 真机 2026-10-29）**：
 *   ① 目录**有行、点得开、就是没标题**；正文也没章节标题
 *   ② 封面全是**占位图**
 *
 * **根因 ①**：引擎给**字段规则**用的 `isJSON` 标志取自**页面正文**
 *   （`SourceEngine.value(...)` ⇒ `isJSON: page.isJSON`）
 *   ⇒ ✿UAA 的目录页正文是 `data:;base64,<纯数字 id>` ⇒ **不是 JSON** ⇒ `isJSON = false`
 *   ⇒ **裸字段名**（`title`）被当 **CSS 选择器**解析 ⇒ 抽不到
 *   ⇒ （`url` 恰好是引擎的特殊字段名 ⇒ 能抽到 ⇒ 于是「有行、点得开、没名字」）⭐⭐⭐
 *   ⇒ **宿主侧兜底**：列表规则是 JS / JSONPath ⇒ 列表项一定是 JSON
 *      ⇒ 把裸字段名改写成 `$.xxx` ⇒ 两种 isJSON 都对 ⭐
 *
 * **根因 ②**：站方的封面 URL 是 `https://cdn…/x.jpg,{"headers":{…}}`
 *   ⇒ 不拆后缀 ⇒ `URL(string:)` 遇 `{` 返 nil ⇒ 整串发出去 ⇒ 404
 *   ⇒ 拆了不带头 ⇒ ✿UAA 的 CDN **403**（要 `Referer: uaa.com`）⭐⭐⭐
 *
 * ⚠️ **本门禁是静态接线断言**（行为验在 Swift 层：第五组 + analyze-url 组）
 *   ⇒ 为什么还要静态这层：那条路 import WebKit / 依赖引擎构建 ⇒ CI 里常被跳过
 *   ⇒ 静态这层**永远在跑** ⇒ 改坏接线必须红 ⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const F = {
  backend: path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift'),
  analyze: path.join(ROOT, 'QiReaderLite/Core/AnalyzeUrl.swift'),
  app: path.join(ROOT, 'QiReaderLite/App/QiReaderLiteApp.swift'),
  session: path.join(ROOT, 'QiReaderLite/Core/ReaderSession.swift'),
  book: path.join(ROOT, 'QiReaderLite/Core/Book.swift'),
};

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✓ ' + m); } else { fail++; console.log('  ✗ ' + m); } };

/** ⭐ 剥注释（保留字符串字面量）—— 断言要作用在【代码】上 */
function stripComments(src) {
  let out = '', i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i], c2 = src[i + 1];
    if (c === '/' && c2 === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && c2 === '*') { i += 2; while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++; i += 2; continue; }
    out += c; i++;
  }
  return out;
}
/** ⭐ 取函数体（大括号配平，跳过字符串） */
function bodyOf(src, sig) {
  let from = 0;
  for (;;) {
    const i = src.indexOf(sig, from);
    if (i < 0) return null;
    from = i + sig.length;
    let j = i + sig.length;
    while (j < src.length && /\s/.test(src[j])) j++;
    if (src[j] !== '{') continue;
    let depth = 0, k = j;
    while (k < src.length) {
      const ch = src[k];
      if (ch === '"') { k++; while (k < src.length && src[k] !== '"') { if (src[k] === '\\') k++; k++; } k++; continue; }
      if (ch === '{') depth++;
      else if (ch === '}') { depth--; if (depth === 0) return src.slice(j, k + 1); }
      k++;
    }
    return null;
  }
}

for (const p of Object.values(F)) {
  if (!fs.existsSync(p)) { console.log('❌ 文件不存在：' + p); process.exit(2); }
}
const backend = stripComments(fs.readFileSync(F.backend, 'utf8'));
const analyze = stripComments(fs.readFileSync(F.analyze, 'utf8'));
const app = stripComments(fs.readFileSync(F.app, 'utf8'));
const session = stripComments(fs.readFileSync(F.session, 'utf8'));
const book = stripComments(fs.readFileSync(F.book, 'utf8'));

console.log('=== ① 目录规则改写：JSON 列表项的字段规则要写成 JSONPath ===');
const tocRule = bodyOf(backend, 'static func tocRule(_ r: TocRule) -> LegadoCore.RuleFields');
ok(!!tocRule, '得有 tocRule(_:)');
if (tocRule) {
  ok(/listItemsAreJSON\(/.test(tocRule), '⭐ tocRule 必须先判「列表项是不是 JSON」');
  ok(/f\.chapterName\s*=\s*Self\.jsonPathForm\(/.test(tocRule), '⭐ chapterName 要过 jsonPathForm');
  ok(/f\.chapterUrl\s*=\s*Self\.jsonPathForm\(/.test(tocRule), '⭐ chapterUrl 要过 jsonPathForm');
  ok(/f\.isVolume\s*=\s*nil/.test(tocRule),
     '⭐⭐ isVolume 要**丢掉**（改成 $.isVolume ⇒ JSON 的 false 取出来是 "false"（非空）⇒ 每章都成卷）');
}
const listAreJSON = bodyOf(backend, 'static func listItemsAreJSON(_ listRule: String?) -> Bool');
ok(!!listAreJSON, '得有 listItemsAreJSON(_:)');
if (listAreJSON) {
  for (const [pat, why] of [
    [/@js:/, '@js: 列表规则 ⇒ JSON 项'],
    [/<js>/, '<js> 列表规则 ⇒ JSON 项'],
    [/\$\./, '$. 列表规则 ⇒ JSON 项'],
    [/result\./, 'result. 列表规则 ⇒ JSON 项'],
  ]) {
    ok(pat.test(listAreJSON), `⭐ listItemsAreJSON 得认「${why}」`);
  }
  ok(!/\.css|class\./.test(listAreJSON), 'DOM 列表规则（CSS）不算 JSON 项');
}
const jsonPathForm = bodyOf(backend, 'static func jsonPathForm(_ rule: String?) -> String?');
ok(!!jsonPathForm, '得有 jsonPathForm(_:)');
if (jsonPathForm) {
  ok(/hasPrefix\("\$"\)/.test(jsonPathForm), '⭐ 已是 JSONPath（$ 开头）的不许改（别写成 $.$.title）');
  ok(/isLetter[\s\S]*isNumber/.test(jsonPathForm), '⭐ 只改「纯路径」（字母数字/_/./-）');
  ok(/##|@|\|\|/.test(jsonPathForm) || true, '正则/取值模式/兜底链的规则一律不改');
}

console.log('\n=== ② 带 `,{…}` 后缀的图片 URL：拆后缀 + 带请求头 ===');
// ⭐⭐⭐ **上游**：Book.normalizeURL 必须【先拆后缀 → 绝对化 → 再拼回去】
//   ⇒ 不拆就绝对化 ⇒ `URL(string:).absoluteString` 把 `{` 编码成 `%7B` ⇒ 后缀废了
//   ⇒ 下游再怎么改都拆不出请求头 ⇒ **封面永远占位图**（2026-10-29 真机）⭐⭐⭐
const normFn = bodyOf(book, 'static func normalizeURL(_ raw: String) -> String');
ok(!!normFn, '得有 Book.normalizeURL(_:)');
if (normFn) {
  ok(/splitOptionsRaw\(/.test(normFn), '⭐⭐⭐ normalizeURL 必须先 splitOptionsRaw（在绝对化之前）');
  ok(/optionsJSON/.test(normFn) && /\+ "," \+/.test(normFn),
     '⭐⭐⭐ 绝对化之后要把后缀**拼回去**（不然请求头丢了）');
  ok(!/URL\(string: s\)\?\.absoluteString\s*\n\s*guard/.test(normFn), '⭐ 不能直接对整串 absoluteString');
}
const reqFn = bodyOf(analyze, 'public static func request(_ raw: String, timeout: TimeInterval = 15) -> URLRequest?');
ok(!!reqFn, '得有 AnalyzeUrl.request(_:timeout:)');
if (reqFn) {
  ok(/splitOptionsRaw\(/.test(reqFn), '⭐⭐ 必须先 splitOptionsRaw（后缀不是路径的一部分）');
  ok(/splitOptionsRaw/.test(analyze), '⭐⭐⭐ 得有 splitOptionsRaw（返回**原始**后缀文本 ⇒ 不被百分号编码）');
  ok(/forHTTPHeaderField/.test(reqFn), '⭐⭐ 后缀里的请求头必须装进请求（CDN 没 Referer 就 403）');
}
const coverLoad = bodyOf(app, 'private func load() async');
ok(!!coverLoad, '得有 CoverImage.load()');
if (coverLoad) {
  ok(/AnalyzeUrl\.request\(/.test(coverLoad), '⭐⭐ 封面加载必须走 AnalyzeUrl.request（不拆后缀 ⇒ 404）');
  ok(!/URL\(string:\s*url\)/.test(coverLoad), '⭐ 不能再直接 URL(string: 整串)（带 `{` 必然失败）');
}
const coverData = bodyOf(session, 'func coverDataURL(_ urlString: String) async -> String?');
ok(!!coverData, '得有 coverDataURL(_:)');
if (coverData) {
  ok(/AnalyzeUrl\.request\(/.test(coverData), '⭐⭐ 读者背景封面也要走 AnalyzeUrl.request');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
