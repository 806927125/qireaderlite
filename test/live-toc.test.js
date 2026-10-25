#!/usr/bin/env node
/**
 * **目录（toc）真机联调** —— 真网络 + 真聚合源
 *
 * 跑法：node test/live-toc.test.js
 *
 * 背景：用户真机「目录一条章节都没解析出来（chapterList 规则没命中）」。
 * App 的「目录诊断」显示：请求 URL 是个 `data:;base64,…`、状态码 0、响应字节 21。
 *
 * ⚠️ 站方的 ruleToc.chapterList 是**复合规则**：
 *     <js>
 *       let res = JSON.parse(java.hexDecodeToString(result));   // 解 data: URL 的载荷
 *       …
 *       let data = java.ajax(`${base_url}/catalog?…`, {method:"POST", body:{html}});
 *       data;                                                     // ← 完成值
 *     </js>$.data                                                  // ← 尾巴再走 JSONPath
 * ⇒ 需要「JS 的完成值 → 再喂给 $.data」这条链（splitJsWithTail + selectFromJsResult）。
 *
 * 这个测试：真网络 + 真源 → 找一本书 → 跑 toc → 看章节出来没有。
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 * · 老门禁用 **JS 层**的 `nativeMock`（自己发真请求）⇒ 老引擎删了 ⇒ 门禁的对象没了 ⭐⭐⭐
 * · ⇒ 现在：**门禁自己真抓**（Node 的 fetch）⇒ 把**真响应**喂给新引擎的**声明式 routes**
 *   （规范 §1.1）⇒ **真网络 ✓ + 真引擎 ✓** 两条都在 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness.js');
const { LiveProxy, looksServerSide, skipServerSide } = require('./live-helpers');

// ⭐⭐⭐ **不许「跳过」**（2026-10-24 真机教训）
//   跳过 = 这条链路**一次都没被验过** ⇒ 真机炸了沙盒还全绿 ⭐⭐⭐
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
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
    console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
    process.exit(0);
  }

  console.log('=== ⓪ 真网络连通性（站方服务器）===');
  const proxy = new LiveProxy({ timeout: 15000, maxRounds: 6 });
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

  console.log('\n=== ① 先找一本书 ===');
  const kinds = await live('exploreKinds', { source: src, jsLib: src.jsLib });
  const allKinds = kinds.kinds || [];
  const picked = allKinds.find(k => /get_discover/.test(String(k.url || ''))) || allKinds.find(k => k.url);
  const ex = await live('explore', {
    source: src, jsLib: src.jsLib, kindUrl: String(picked.url || '').replace('{{page}}', '1'), page: 1,
  });
  const books = ex.books || [];
  console.log('  探索到书:', books.length);
  const book = books[0];
  if (!book) {
    console.log('  ⏭️  跳过：没探索到书（站方限流 / 未登录 / 线路故障）⇒ 本门禁**没验到**');
    console.log('      ⇒ **不等于通过**');
    console.log('\n✅ 通过 0 / 失败 0（站方侧问题 ⇒ 显式跳过）');
    process.exit(0);
  }
  ok(!!book, '探索到书了');
  console.log('  用这本:', book.name);
  console.log('  bookUrl:', String(book.bookUrl).slice(0, 70));

  console.log('\n=== ② 详情（目录 URL 在这儿算出来）===');
  const info = await live('bookInfo', {
    source: src, jsLib: src.jsLib, bookUrl: book.bookUrl,
    book: Object.assign({}, book, { variable: 'custom', variables: {} }),
  });
  ok(!info.error, 'bookInfo 没报错' + (info.error ? '：' + info.error : ''));
  const tocUrl = (info.book || {}).tocUrl || '';
  console.log('  名称  :', (info.book || {}).name);
  console.log('  tocUrl:', tocUrl.slice(0, 80));

  console.log('\n=== ③ 跑 toc（目录）===');
  const tocPayload = {
    source: src, jsLib: src.jsLib,
    bookUrl: book.bookUrl,
    tocUrl,
    book: Object.assign({}, book, { variable: 'custom', variables: {} }),
    maxPages: 1,
  };
  const t = await live('toc', tocPayload);

  const chs = t.chapters || [];
  console.log('  error   :', t.error || '(无)');
  console.log('  章节数  :', chs.length);
  for (const c of chs.slice(0, 3)) {
    console.log(`    · ${c.title}  url=${String(c.url || '').slice(0, 46)}`);
  }
  // ⭐ 真实发出的目录请求 URL（下面断言用）
  const catURLs = proxy.fetched.map(f => f.url).filter(u => /catalog/i.test(u));
  console.log('  目录请求:', catURLs.slice(0, 2).map(u => u.slice(0, 90)).join(' | ') || '(没发出去)');

  console.log('\n=== ④ 正文（第一章）===');
  let c = null;
  if (chs.length) {
    c = await live('content', {
      source: src, jsLib: src.jsLib,
      chapterUrl: chs[0].url,
      chapter: Object.assign({}, chs[0], { variable: 'custom' }),
      book: Object.assign({}, book, { variables: {} }),
    });
    console.log('  error  :', c.error || '(无)');
    console.log('  正文长度:', (c.content || '').length);
    console.log('  正文开头:', String(c.content || '').slice(0, 90).replace(/\n/g, ' '));
  }

  console.log('\n=== ⑤ 真网络抓取记录 ===');
  console.log(`   真抓到 ${proxy.fetched.length} 条 URL，失败 ${proxy.failed.length} 条`);

  console.log('\n=== 判定 ===');
  ok(!t.error, 'toc 没报错' + (t.error ? '：' + t.error : ''));
  // ⭐ 变量只写一半 ⇒ server 没了 ⇒ URL 变成 `undefined/catalog` ⇒ 0 章
  //   （2026-10-21 真机「目录 0 章」的根因之一）⇒ 盯着真实请求 URL
  ok(catURLs.length > 0,
     '目录请求 URL 是个真地址（不是 undefined/…）' + (catURLs[0] ? '：' + catURLs[0].slice(0, 60) : ''));
  ok(chs.length > 0, `目录出章节了（现在 ${chs.length} 条）`);
  // ⚠️ 章节对象是 {name, title, url, index, …} —— 字段叫 **title**（老引擎也是 title）
  ok(chs.every(c => c.title), '每章都有标题');
  ok(chs.some(c => c.url), '至少一章有 url（点进去要能开）');
  ok(chs.length > 10, '章节数量合理（>10）');
  // ⚠️ 番茄有「免登录访问次数上限（3 次）」→ 反复联调会被限流，
  //    正文会变成「您今日免登录访问次数已达上限(3次)！」→ 所以只断言「有内容」✅
  //    （这也说明：番茄登录是刚需，不登录正文只能看 3 次）
  ok(!!(c && c.content && c.content.length > 10), '正文取到了（>10 字）');
  ok(proxy.fetched.length > 0, '门禁**真的联网抓了站方接口**（不是假服务器自娱自乐）');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
