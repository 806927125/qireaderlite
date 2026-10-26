/**
 * **阅读器排版缓存上限门禁**（2026-10-26 jetsam 6.8GB 实证 ⇒ 闪退的真凶）
 *
 * 真机证据（build265 的内存档案）：
 * ```
 * 18:53:41  op=sourceHosts(清后) 6250 MB
 * 18:53:42  op=— 6507 / op=sourceHosts 6511 / op=exploreKinds 6512 MB
 * ```
 * ⇒ **曲线是平的** ⇒ 6.2GB **早就占着了**（不是这几个 op 涨的）
 *   ⇒ 任何 op 再涨一点就过 jetsam 杀线 ⇒ 现象 =「进发现页/搜索/登录都闪退」⭐⭐⭐
 *
 * ⚠️⚠️ **真凶**：`PagedChapterPager.renders` 每章存一份 `ChapterRender`
 *   ⇒ 里面是 **`ReaderPaginator`：`NSTextStorage` + `NSLayoutManager` + 每页一个
 *     `NSTextContainer`** ⇒ **排版对象极重**（一章几 MB~几十 MB）⭐⭐⭐
 *   ⇒ 以前**永不清** ⇒ 读的书越多内存越大 ⇒ 顶到 GB 级 ⭐⭐⭐
 *   ⇒ ⭐ **老引擎免疫的第二个机制**：老引擎（WKWebView）的排版在**独立进程**里
 *     ⇒ App 进程里没有这些排版对象 ⇒ 所以老引擎一点问题没有 ⭐⭐⭐
 *
 * ⭐⭐⭐ 本门禁钉三件事：
 *   ① 排版缓存**有上限**（且是个小数字）
 *   ② 插入后**真的淘汰**（不是只定义不用）
 *   ③ 淘汰**只动 renders**（`texts` 是目录/spine 的依赖 ⇒ 动了会翻不动页）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const PAGER = path.join(ROOT, 'QiReaderLite/Features/Reader/Paging/PagedChapterPager.swift');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

/** ⭐ 剥注释（注释里的文字不算数 ⇒ 否则门禁假绿） */
function stripComments(src) {
  let out = '', i = 0;
  const n = src.length;
  let inLine = false, inBlock = false, inStr = null;
  while (i < n) {
    const c = src[i], c2 = src.substr(i, 2);
    if (inLine) { if (c === '\n') { inLine = false; out += c; } i++; continue; }
    if (inBlock) { if (c2 === '*/') { inBlock = false; i += 2; continue; } if (c === '\n') out += c; i++; continue; }
    if (inStr) {
      out += c;
      if (c === '\\') { out += src[i + 1] || ''; i += 2; continue; }
      if (c === inStr) inStr = null;
      i++; continue;
    }
    if (c2 === '//') { inLine = true; i += 2; continue; }
    if (c2 === '/*') { inBlock = true; i += 2; continue; }
    if (c === '"' || c === "'") { inStr = c; out += c; i++; continue; }
    out += c; i++;
  }
  return out;
}

console.log('\n── 1. 排版缓存必须有上限（每章一份 CoreText 排版对象 ⇒ 不封顶就 GB 级）──');
ok(fs.existsSync(PAGER), 'PagedChapterPager.swift 在');
const src = fs.existsSync(PAGER) ? stripComments(fs.readFileSync(PAGER, 'utf8')) : '';
ok(/renderCacheLimit\s*=\s*\d+/.test(src), '有排版缓存上限常量');
const limit = Number((src.match(/renderCacheLimit\s*=\s*(\d+)/) || [])[1] || 0);
ok(limit > 0 && limit <= 8, `上限是个小数字（当前 ${limit} ⇒ 内存不随章数涨）`);

console.log('\n── 2. 插入后必须真的淘汰（不是只定义不用）──');
ok(/renders\[c\] = r/.test(src), '有 renders 插入点');
ok(/evictRenders\(\)/.test(src), '有淘汰函数');
const evictCalls = (src.match(/evictRenders\(\)/g) || []).length;
ok(evictCalls >= 2, `淘汰函数**被调用**了（定义 + 调用 ⇒ 现在 ${evictCalls} 处）`);
ok(/touchRender\(/.test(src), '命中缓存时会更新 LRU 顺序');

console.log('\n── 3. 淘汰只动 renders（texts 是目录/spine 的依赖 ⇒ 动了会翻不动页）──');
const evictBody = (src.match(/private func evictRenders\(\)[\s\S]{0,700}?\n    \}/) || [''])[0];
ok(/renders\.removeValue\(forKey:/.test(evictBody), '淘汰时移除 renders');
ok(!/texts\.removeValue\(forKey:/.test(evictBody), '**不许**移除 texts（目录/spine 依赖它）');
ok(/oldest == current/.test(evictBody), '当前章**永不淘汰**（翻页不会突然重排）');

console.log(`\n通过 ${pass} / 失败 ${fail}`);
if (fail > 0) process.exit(1);
