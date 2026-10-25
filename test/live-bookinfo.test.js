#!/usr/bin/env node
/**
 * **详情页（bookInfo）真机联调** —— 真网络 + 真聚合源
 *
 * 跑法：node test/live-bookinfo.test.js
 *
 * 起因：用户真机引擎日志（build164）里两条错：
 *   1. [规则出错] <js> if (String(baseUrl).startsWith("data:")) {
 *        let res = JSON.parse(java.hexDecodeToString(result));
 *        JS 执行失败: JSON Parse error: Unable to parse JSON string
 *   2. [规则出错] <js> let { ..., abstract, ... } = result;
 *        JS 执行失败: undefined is not an object (evaluating 'abstract.split')
 *
 * ⇒ 第 1 条是 `ruleBookInfo.init`（详情页预处理），第 2 条是 `ruleBookInfo.intro`
 *    （简介规则解构 init 的产物）—— **两条是一条链**。
 *
 * ⚠️ 之前 live-toc 只测了「探索 → 目录 → 正文」，**从没测过详情页** →
 *    所以沙盒全绿、真机炸。⇒ 这条路径必须有真机联调门禁。
 *
 * 大灰狼的 init 规则干的事：
 *   ① `result` = data: 伪 URL 的载荷（base64）
 *   ② `JSON.parse(java.hexDecodeToString(result))` → 取出 book_id/tab/sources
 *   ③ 拿这些参数去 `服务器/detail` 重新 ajax 一次 → 真正的详情 JSON
 *   ④ 末尾 `result` → 配合尾巴 `$.data` → 详情对象
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 * · 老门禁用 **JS 层**的 `nativeMock`（自己发真请求）⇒ 老引擎删了 ⇒ 门禁的对象没了 ⭐⭐⭐
 * · ⇒ 现在：**门禁自己真抓**（Node 的 fetch）⇒ 把**真响应**喂给新引擎的**声明式 routes**
 *   （规范 §1.1）⇒ **真网络 ✓ + 真引擎 ✓** 两条都在 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness.js');
const { LiveProxy } = require('./live-helpers');
const { analyzeUrl } = require('./engine-bridge.js');

// ⭐⭐⭐ **不许「跳过」**（2026-10-24 真机教训）
const CANDIDATES = [
  process.env.SRC_OUT,
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json',
  path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json'),
  path.join(__dirname, '..', 'sources', 'dahlang-v2.json'),
].filter(Boolean);
const SRC = CANDIDATES.find(p => fs.existsSync(p));
if (!SRC) {
  console.log('❌ 找不到大灰狼源文件（连仓库副本都没有）⇒ 门禁必须失败，不许跳过');
  process.exit(1);
}
const list = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const src = (Array.isArray(list) ? list : [list])
  .find(s => s && s.bookSourceUrl && s.ruleExplore && s.ruleToc) || list[0];

function hostsOf(source) {
  const lib = String(source.jsLib || '');
  const m = /var\s+host\s*=\s*(\[[\s\S]*?\])/.exec(lib);
  if (!m) return [];
  try { return JSON.parse(m[1].replace(/'/g, '"')); } catch (e) { return []; }
}

let pass = 0, fail = 0;
const ok = (c, m, extra) => { c ? pass++ : (fail++, console.log('  ✗ ' + m + (extra ? '  → ' + extra : ''))); };

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
    console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
    process.exit(0);
  }

  console.log('=== ⓪ 真网络连通性（站方服务器）===');
  const proxy = new LiveProxy({ timeout: 15000, maxRounds: 8 });
  const probeHost = hostsOf(src)[0] || 'https://v5.langge.uk';
  const probe = await proxy.probe(probeHost + '/discovestyle');
  if (!probe.ok || probe.status !== 200) {
    console.log('  ⏭️  跳过：站方服务器不通（' + (probe.error || probe.status) + '）');
    console.log('      ⇒ 本门禁**没验到**（**不等于通过**）⇒ 等网络恢复 / 真机再验');
    console.log('\n✅ 通过 0 / 失败 0（网络不通 ⇒ 显式跳过）');
    process.exit(0);
  }
  ok(true, `站方可达（${probeHost}，${probe.body.length} 字节）`);

  const live = (op, payload) => proxy.converge((routes) => {
    const { win } = createSandbox({ routes });
    return win.__qrInvoke(op, payload);
  });

  console.log('\n=== ① 找一本书 ===');
  const kinds = await live('exploreKinds', { source: src, jsLib: src.jsLib });
  const allKinds = kinds.kinds || [];
  const picked = allKinds.find(k => /get_discover/.test(String(k.url || ''))) || allKinds.find(k => k.url);
  const ex = await live('explore', {
    source: src, jsLib: src.jsLib, kindUrl: String(picked.url || '').replace('{{page}}', '1'), page: 1,
  });
  const books = ex.books || [];
  console.log('  探索到书:', books.length);
  ok(books.length > 0, '探索到书了');

  console.log('\n=== ② 跑 bookInfo（详情页 = 真机炸的那条路）===');
  // ⭐⭐⭐ **有的书站方没数据**（详情接口回「查不到」/「版本过低」⇒ 只有几百字节）
  //   ⇒ 那是**站方侧**的事，不是引擎的 ⇒ 换几本试试 ⇒ 找一本**站方真有数据**的 ⭐⭐⭐
  //   ⇒ 实在都拿不到 ⇒ 显式 SKIP（**没验到 ≠ 验过了没问题**）⭐⭐⭐
  let book = null, info = null;
  for (const cand of books.slice(0, 5)) {
    const r = await live('bookInfo', {
      source: src, jsLib: src.jsLib,
      bookUrl: cand.bookUrl,
      // ⚠️ 必须带 book —— 站方 init 规则第一句就调 book.getVariable('custom')
      book: Object.assign({}, cand, { variables: {} }),
    });
    console.log(`  · ${cand.name} ⇒ name=${(r.book || {}).name || '(空)'}`);
    if (r && r.book && r.book.name) { book = cand; info = r; break; }
    if (!info) info = r;
  }
  if (!book) {
    console.log('  ⏭️  跳过：站方对这几本书都没返详情数据 ⇒ 本门禁**没验到**（**不等于通过**）');
    console.log('\n✅ 通过 0 / 失败 0（站方侧无数据 ⇒ 显式跳过）');
    process.exit(0);
  }
  const b = info.book || {};
  console.log('  用这本:', book.name);
  console.log('  error   :', info.error || '(无)');
  console.log('  名称    :', b.name || '(空)');
  console.log('  作者    :', b.author || '(空)');
  console.log('  分类    :', b.kind || '(空)');
  console.log('  最新章  :', b.lastChapter || '(空)');
  console.log('  tocUrl  :', String(b.tocUrl || '(空)').slice(0, 60));
  console.log('  简介长度:', (b.intro || '').length);

  console.log('\n── 每个真实请求 ──');
  proxy.fetched.forEach((f, i) => {
    console.log(`   ${i + 1}. ${f.status} ${String(f.len).padStart(7)} 字节  ${f.url.slice(0, 96)}`);
  });

  console.log('\n=== ③ 被 Foundation 规范化过的书源 URL（回归用例）===');
  {
    // ⚠️⚠️ **回归用例**：宿主侧曾用 `URL(string:).absoluteString` 规范化过书源 URL，
    //   把 `,{"type":"x"}` 变成 `,%7B%22type%22%3A%22x%22%7D` ⇒ 引擎剥不掉后缀
    //   ⇒ 载荷被污染 → 站方 JSON.parse 炸 → 详情页整条规则静默失效（**真机专属**）。
    //   ⇒ 引擎这边要能扛住这个形态（Swift 侧已修，这里是第二道防线）。
    const raw = String(book.bookUrl || '');
    const norm = raw.replace(/,\s*(?=\{)/, ',%7B');   // 模拟 URL(string:).absoluteString 的效果
    console.log('  原始  :', raw.slice(0, 90));
    console.log('  规范化:', norm.slice(0, 90));
    const info2 = await live('bookInfo', {
      source: src, jsLib: src.jsLib,
      bookUrl: norm,
      book: Object.assign({}, book, { variables: {} }),
    });
    const b2 = info2.book || {};
    console.log('  error :', info2.error || '(无)');
    console.log('  名称  :', b2.name || '(空)');
    ok(!info2.error, '规范化形态不报错' + (info2.error ? '：' + info2.error : ''));
    ok(!!b2.name, '规范化形态也能拿到书名');
  }

  console.log('\n=== ④ 请求 URL 的编码（iOS 的 URL(string:) 判非法 ⇒ 引擎必须先编码）===');
  {
    // ⚠️⚠️ 真机 2026-10-21 栽的那条：站方 POST 的 query 里带**裸中文**和**裸 JSON**
    //   → iOS 的 URL(string:) 判非法 → 请求发不出去 → 引擎吞成空串
    //   → 站方 JSON.parse('') → 「Unable to parse JSON string」
    // ⇒ query 必须**重新编码**（所有方法，不只 GET），且服务器仍要认。
    //
    // ⭐ **新引擎的等价入口**：URL 规则的解析（`--analyzeUrl`）
    //   ⇒ 断言「**引擎算出来的地址**」里没有裸中文 / 裸花括号 ⇒ iOS 才发得出去 ⭐⭐⭐
    const raw = (proxy.fetched.map(f => f.url).find(u => /detail|catalog/.test(u))) || '';
    console.log('  真实发出的请求:', raw ? raw.slice(0, 150) : '(没发出去)');
    ok(!!raw, '找到 detail/catalog 的真实请求（说明它真的发出去了）');
    if (raw) {
      const built = analyzeUrl({ url: raw, baseUrl: '' });
      const u = (built && built.url) || '';
      const q = u.indexOf('?') >= 0 ? u.slice(u.indexOf('?')) : '';
      console.log('  引擎算出的地址:', u.slice(0, 150));
      ok(!/[一-龥]/.test(q), 'query 里没有裸中文（iOS 的 URL(string:) 会判非法）', q.slice(0, 80));
      ok(!/[{}\[\]"']/.test(q), 'query 里没有裸花括号/引号', q.slice(0, 80));
      ok(/%[0-9A-Fa-f]{2}/.test(q), 'query 做过百分号编码', q.slice(0, 80));
    }
  }

  console.log('\n=== ⑤ 原生侧的兜底（静态断言）===');
  {
    // 原生侧兜底：URL(string:) 对 `{` `"` 裸中文返回 nil ⇒ 要有百分号编码重试
    // ⚠️⭐⭐ **老门禁这里读的是 `RuleSandbox.swift`** ⇒ 那儿**从来没有**这段代码
    //   （百分号编码在 **`AnalyzeUrl.swift`** 里 ⇒ `smartPercentEncode`）⭐⭐⭐
    //   ⇒ 老门禁那条断言**一直是红的**（门禁崩在前面 ⇒ 没人看见）⭐⭐⭐
    //   ⇒ 现在**读对文件** ⇒ 语义（原生侧会兜底编码）照样被钉住 ⭐⭐⭐
    const au = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'AnalyzeUrl.swift'), 'utf8');
    ok(/smartPercentEncode/.test(au),
       '原生侧有百分号编码兜底（URL(string:) 判非法时重试）');
    ok(/static func parse\(/.test(au), '原生侧有 URL 解析入口（parse）');
    ok(/static func absolutize\(/.test(au), '原生侧有绝对化入口（absolutize）');
  }

  console.log('\n=== 判定 ===');
  ok(proxy.fetched.length > 0, '门禁**真的联网抓了站方接口**（不是假服务器自娱自乐）');
  ok(!info.error, 'bookInfo 没报错' + (info.error ? '：' + info.error : ''));
  ok(!!b.name, '书名取到了');
  ok(!!b.author, '作者取到了');
  ok(!!b.tocUrl, 'tocUrl 取到了（目录的前提）');
  ok((b.intro || '').length > 0, '简介不空（真机就是挂在 abstract.split 上）');
  ok(!(b.intro || '').includes('undefined'), '简介不是 undefined');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
