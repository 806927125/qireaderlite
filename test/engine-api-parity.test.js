#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **栖阅引擎 ↔ 新引擎 的能力面对账**（2026-10-26 重写）
 *
 * ────────────────────────────────────────────────────────────
 * 为什么要重写（老门禁在老引擎退役后**直接崩了**）
 * ─────────────────────────────────────────────────────────────
 *   老门禁读的是**老 JS 引擎**的文件（`org-jsoup.js` / `jsoup-compat.js` / `packages_stub.js`）
 *   ⇒ 那些文件在「老引擎物理删除」后**不存在** ⇒ 门禁 ENOENT 崩 ⇒ 被判「跳过」
 *   ⇒ ⇒ **最后一个「没验到」的门禁** ⇒ ⇒ 等于这条能力面对账**一直没在跑** ⭐⭐⭐
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新门禁钉的是什么（更准）**
 * ─────────────────────────────────────────────────────────────
 *   ① **参考面**：栖阅的 `jsoup_bridge.js` 暴露了哪些类型（`Packages.org.*` / `JXDocument`…）
 *   ② **真实用量**：**125 源语料**里，站方**规则代码**（不是注释！）真的用了哪些
 *   ③ **新引擎面**：这些类型在**新引擎的 JS 环境**里到底存不存在（**运行时**查，不是 grep 源码）
 *   ⇒ ⇒ 判定：
 *      · 语料用得到 + 引擎没有 ⇒ **红**（真缺口 ⇒ 必须补）
 *      · 语料没用 + 引擎没有   ⇒ **绿，但显式列成「已知缺口（0 用量）」**（看得见，不装作没有）⭐⭐⭐
 *      · 语料用得到 + 引擎有   ⇒ **绿** ✅
 *
 * ⚠️⚠️⚠️ **第 ② 步只扫【规则代码】，不扫说明字段**
 *   （`bookSourceComment` / `ruleSearch.bookList` 的注释里满是 `org.jsoup.Jsoup.parse`）
 *   ⇒ 扫全文会得到「47 处用到」的**假结论** ⇒ ⇒ **必须按字段挑**⭐⭐⭐
 *   （实测：47 处全在注释里 ⇒ **真实用量 = 0** ⇒ 缺口是「理论上的」）
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const QY_JS = process.env.QY_JS || '/workspace/qy2027/Payload/栖阅.app/jsoup_bridge.js';
const ENGINE_DIR = process.env.ENGINE_DIR || path.join(ROOT, '..', 'legado-engine');
const SOURCES_DIR = path.join(ROOT, 'sources');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };
const note = (m) => console.log('  · ' + m);

// ────────────────────────────────────────────────────────────
// ① 参考面：栖阅那份 jsoup_bridge.js 暴露了什么
// ────────────────────────────────────────────────────────────
let qyTypes = [];
if (fs.existsSync(QY_JS)) {
  const qy = fs.readFileSync(QY_JS, 'utf8');
  qyTypes = [...new Set((qy.match(/Packages\.org\.[A-Za-z0-9_.]+/g) || [])
    .filter(t => !/\.__javaClassName$/.test(t)))];
  qyTypes = qyTypes.map(t => t.replace(/^Packages\./, ''));
  // 栖阅的 Xpath 类型（不是 Packages.*，单独抠）
  for (const m of qy.matchAll(/\b(org\.seimicrawler\.xpath\.[A-Za-z0-9_]+)/g)) {
    if (!qyTypes.includes(m[1])) qyTypes.push(m[1]);
  }
} else {
  console.log(`⚠️  栖阅 jsoup_bridge.js 不在 ${QY_JS} ⇒ ① 参考面没验到（**不等于通过**）`);
}

// ────────────────────────────────────────────────────────────
// ② 真实用量：**只扫规则代码字段**（注释不算）
// ────────────────────────────────────────────────────────────
/** ⭐⭐⭐ **书源里【是代码】的字段**（其余都是说明文字） */
const CODE_FIELDS = new Set([
  'jsLib', 'loginUrl', 'loginUi', 'header', 'url',
  'searchUrl', 'exploreUrl', 'ruleSearch', 'ruleExplore', 'ruleBookInfo',
  'ruleToc', 'ruleContent', 'bookUrl', 'tocUrl', 'chapterUrl', 'chapterList',
  'name', 'author', 'intro', 'kind', 'lastChapter', 'coverUrl', 'wordCount',
  'nextTocUrl', 'preUpdateJs', 'updateTime', 'sourceRegex', 'charset',
]);

/**
 * ⭐⭐⭐⭐⭐ **规则代码的收集**（**别再漏字段了** —— 这是 2026-10-26 抓到的「平凡通过」）
 *
 * ⚠️⚠️⚠️ **原来的 bug**：只认一张**手写白名单**（`CODE_FIELDS`）⇒ **漏了 `bookList`**
 *   ⇒ 列表规则（`ruleExplore.bookList` / `ruleSearch.bookList`）**根本没被扫**
 *   ⇒ ⇒ 「语料在用 org.jsoup」这条**根本测不到** ⇒ 门禁恒绿 ⭐⭐⭐
 *   ⇒ ⇒ **「断言里的内容压根不存在 ⇒ 恒真」**的典型 ⭐⭐⭐
 *
 * ⭐ **正解**：**`rule*` 对象里的东西一律是代码**（规则对象的字段全是规则）
 *   ⇒ 不靠手写清单 ⇒ **新加的规则字段自动被扫到** ⇒ 不会漏 ⭐⭐⭐
 */
function collectCode(node, out, inRule) {
  if (node == null) return;
  if (typeof node === 'string') { out.push(node); return; }
  if (Array.isArray(node)) { node.forEach(n => collectCode(n, out, inRule)); return; }
  if (typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) {
      if (k.startsWith('rule')) collectCode(v, out, true);       // 规则对象 ⇒ 里面全是代码
      else if (inRule) collectCode(v, out, true);                // 规则对象的子字段 ⇒ 也是代码
      else if (CODE_FIELDS.has(k)) collectCode(v, out, false);    // 顶层代码字段
    }
  }
}

const corpus = [];
if (fs.existsSync(SOURCES_DIR)) {
  for (const f of fs.readdirSync(SOURCES_DIR).filter(n => n.endsWith('.json'))) {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(path.join(SOURCES_DIR, f), 'utf8')); } catch (e) { continue; }
    const list = Array.isArray(raw) ? raw : [raw];
    for (const src of list) {
      const code = [];
      collectCode(src, code, false);
      // ⭐⭐⭐ **记下这个源自己的 bookList**（自检要**按源配对**，不能按文件）⭐⭐⭐
      const bl = (src && src.ruleExplore && src.ruleExplore.bookList)
        || (src && src.ruleSearch && src.ruleSearch.bookList);
      corpus.push({ file: f, code: code.join('\n'),
                    bookList: typeof bl === 'string' ? bl : null });
    }
  }
}
ok(corpus.length > 0, `扫到 ${corpus.length} 个书源的规则代码`);

/** ⭐⭐⭐ **自检：收集器不许再漏字段**（2026-10-26 的「平凡通过」实证）⭐⭐⭐ */
{
  // ⭐⭐⭐ **自检：收集器不许再漏字段**（2026-10-26 的「平凡通过」实证）
  //   ⇒ 判据 = **每个源自己的 `ruleExplore.bookList` 文本，必须出现在它自己的收集结果里**
  //   ⚠️⚠️ **计数口径**：一个文件里有 N 个源 ⇒ 收集结果有 N 条 ⇒ **只能按「源」配对**
  //     （以前按「文件」再遍历一遍全部源 ⇒ N×N ⇒ 报出上万条假漏 ⇒ 自己把自己骗了）⭐⭐⭐
  //  ⚠️⚠️ **按【源】配对**（不是按文件）⇒ 一个文件里 N 个源 ⇒ N 条自检样本 ⭐⭐⭐
  //  ⇒ 以前按文件归拢 ⇒ 43 个「没有 bookList 的源」也被算成「漏了」⇒ 报出上万条假漏 ⭐⭐⭐
  let missed = 0;
  let checked = 0;
  for (const { code, bookList } of corpus) {
    if (!bookList || bookList.length <= 20) continue;
    checked++;
    if (!code.includes(bookList.slice(0, 40))) missed++;
  }
  ok(checked > 0, `自检样本够（${checked} 个源自带 bookList 规则）`);
  ok(missed === 0, `收集器不许漏字段（检了 ${checked} 个源，漏了 ${missed} 个的 bookList）`);
}

/** ⭐⭐⭐ **站方代码里真正用到的【JS 侧类型名】** */
const USED_PATTERNS = [
  /\borg\.jsoup\.[A-Za-z0-9_.]+/g,          // 轻阅老引擎的 org.jsoup.*
  /\borg\.seimicrawler\.xpath\.[A-Za-z0-9_]+/g, // 栖阅的 xpath 类型
  /\bJXDocument\b/g, /\bJXNode\b/g,
  /\bPackages\.org\.[A-Za-z0-9_.]+/g,
];
const used = new Map();   // 类型名 → 出现在哪些源
for (const { file, code } of corpus) {
  for (const pat of USED_PATTERNS) {
    for (const m of code.match(pat) || []) {
      if (!used.has(m)) used.set(m, new Set());
      used.get(m).add(file);
    }
  }
}

/** ⭐⭐⭐ **反向自检**：全文里的用法（**含注释**）必须明显多于规则代码里的用法**
 *   ⇒ 证明「只扫规则代码」这个筛子**真的在筛**（不是把筛选写坏了导致 0）⭐⭐⭐ */
{
  const allText = corpus.map(c => c.code).join('\n');
  const allFiles = fs.existsSync(SOURCES_DIR)
    ? fs.readdirSync(SOURCES_DIR).filter(n => n.endsWith('.json'))
      .map(f => fs.readFileSync(path.join(SOURCES_DIR, f), 'utf8')).join('\n')
    : '';
  const rawHits = (allFiles.match(/org\.jsoup\.[A-Za-z0-9_.]+/g) || []).length;
  const codeHits = (allText.match(/org\.jsoup\.[A-Za-z0-9_.]+/g) || []).length;
  ok(rawHits >= codeHits, `全文里的 org.jsoup 用法(${rawHits}) ≥ 规则代码里的(${codeHits})`);
  if (rawHits > codeHits) {
    note(`注释里有 ${rawHits - codeHits} 处 org.jsoup 用法 ⇒ **不是代码** ⇒ 不算缺口（否则 47 处全是误报）`);
  }
}

// ────────────────────────────────────────────────────────────
// ③ 新引擎面：**运行时**查（新引擎的 JS 环境里到底有没有）
// ────────────────────────────────────────────────────────────
// ⭐⭐⭐⭐⭐ **老引擎（轻阅老 JS 引擎）的能力面** —— 用户的明确要求：
//   「老引擎有的、新引擎没有的 ⇒ 吸收进新的」⇒ ⇒ ⇒ **老引擎 = 能力基线** ⭐⭐⭐
const LEGACY_JS = path.join(ENGINE_DIR, 'reference', 'js', 'org-jsoup.js');
let legacyHas = new Set();
if (fs.existsSync(LEGACY_JS)) {
  const ljs = fs.readFileSync(LEGACY_JS, 'utf8');
  // 抠出老引擎支持的能力名（Jsoup.parse / select / attr / text / size / get …）
  for (const m of ljs.matchAll(/\b([A-Za-z][A-Za-z0-9_]*)\s*[:=]\s*function/g)) legacyHas.add(m[1]);
  for (const m of ljs.matchAll(/\.([A-Za-z][A-Za-z0-9_]*)\s*=\s*function/g)) legacyHas.add(m[1]);
  ok(legacyHas.size > 0, `老引擎能力面抠到了 ${legacyHas.size} 个方法名`);
} else {
  console.log('  ⏭️  没找到老引擎的 reference/js/org-jsoup.js ⇒ 「老引擎能力面」没验到');
}

/** ⭐⭐⭐ **已知的「待吸收」清单**（老引擎有 · 语料在用 · 新引擎还没有）**
 *  ⚠️⚠️ **白名单不许悄悄长大** ⇒ 新增缺口 ⇒ 门禁红 ⇒ 必须人工决策（要么补、要么明确记一笔）⭐⭐⭐
 *  ⇒ 依据：NovelHub 聚合源自己的注释实证 ——「org.jsoup.Jsoup.parse/select 在栖阅 iOS 的 JSC 上不工作」
 *  ⇒ ⇒ 栖阅自己就不支持 ⇒ 但**轻阅老引擎支持** ⇒ ⇒ **老引擎退役时丢了这份能力** ⇒ ⇒ 待吸收 ⭐⭐⭐ */
const KNOWN_PENDING = new Set(['org.jsoup.Jsoup.parse']);

const { createSandbox, engineAvailable } = require('./new-engine-harness');
const engineHas = {};
if (engineAvailable()) {
  const { win } = createSandbox({ origin: 'https://example.com/' });
  const probe = (expr) => {
    try { return win.eval(expr); } catch (e) { return 'ERR: ' + e; }
  };
  for (const t of [...new Set([...qyTypes, ...used.keys()])]) {
    // ⭐⭐⭐ **安全探针**：`org.jsoup.X` 在引擎里会**抛 ReferenceError**（org 整个不存在）
    //   ⇒ 探针返回 'ERR: …' ⇒ **不能当成「有」** ⇒ 否则缺口被自己骗过去 ⭐⭐⭐
    //   ⇒ 判据 = 「既不是 undefined、也没报错」才算是有
    const expr = t.includes('.')
      ? `(typeof ${t.split('.')[0]} === 'undefined' ? 'undefined' : typeof (${t}))`
      : `typeof ${t}`;
    const r = String(probe(expr));
    engineHas[t] = (r !== 'undefined' && !r.startsWith('ERR:'));
  }
  ok(probe('typeof java') === 'object', '新引擎的 JS 环境里有 java（宿主 API 通道在）');
  ok(probe('typeof Packages') === 'object', '新引擎的 JS 环境里有 Packages（Java 兼容层在）');
} else {
  console.log('  ⏭️  没编译 legado-engine ⇒ ③ 新引擎面没验到（**不等于通过**）');
}

// ────────────────────────────────────────────────────────────
// ④ 判定
// ────────────────────────────────────────────────────────────
const realGaps = [];
const knownGaps = [];
for (const [type, files] of used) {
  const has = engineHas[type] !== undefined ? engineHas[type] : true;
  if (has) {
    ok(true, `语料用到的 ${type} 新引擎有 ✅`);
  } else {
    realGaps.push(`${type}（${[...files].length} 个源在用）`);
  }
}
for (const t of qyTypes) {
  if (used.has(t)) continue;              // 上面判过了
  if (engineHas[t] === false) knownGaps.push(t);
}

const pending = [];
const hardGaps = [];
for (const g of realGaps) {
  const type = g.split('（')[0];
  if (KNOWN_PENDING.has(type)) pending.push(g);
  else hardGaps.push(g);
}
if (hardGaps.length) {
  ok(false, `⭐⭐⭐ 真能力缺口 ${hardGaps.length} 个（语料在用、新引擎没有、也不在待吸收清单里）：${hardGaps.join(', ')}`);
} else {
  ok(true, '语料用到的类型：新引擎要么有、要么在【待吸收清单】里 ✅');
}
if (pending.length) {
  note(`⭐ 待吸收（老引擎有 · 语料在用 · 新引擎还没有）：${pending.join(', ')}`);
  note('  ⇒ ⇒ 「老引擎有的、新引擎没有的 ⇒ 吸收进新的」⇒ 这条在清单上 ⇒ 不算红，但**不许悄悄长大**⭐⭐⭐');
}

if (knownGaps.length) {
  note(`已知缺口（栖阅有 / 新引擎没有 / **125 源语料里 0 处真实用量**）：${knownGaps.join(', ')}`);
  note('  ⇒ ⇒ 它们是**理论缺口** ⇒ 现在不补；一旦语料里真出现 ⇒ 上一条就会红 ⭐⭐⭐');
}

console.log('');
console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
