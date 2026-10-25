#!/usr/bin/env node
/**
 * 肉文屋 m.powenxue15.com —— 目录/正文规则的真引擎端到端门禁。
 *
 * 背景（2026-10-18 用户真机报错「目录正文都不行」）：
 *   老书源 ruleToc.chapterList = `#list dl dd||#list dd||#chapterlist dl dd`
 *   但这个站的详情页上 `#list` / `#chapterlist` 根本不存在，
 *   而 `dd` / `dl` 装的是**推荐书单**（<dl><a class="cover">…<dd>简介</dd></dl>），
 *   章节在 PC 是 `a[rel=chapter]`、在 m. 是 `ul > li > a`。
 *   → chapterList 一个都命中不了，toc() 退回整页（engine.js 的 `bases = [page.doc]`），
 *     抓到一堆推荐书当"章节"，目录乱 → 正文自然也进不去。
 *
 * 这里用真页面快照 + 真引擎跑一遍，防止规则再退化。
 * 快照来自 2026-10-18 实抓 www.powenxue15.com/info/136414.html（GB18030 → 已转 UTF-8）。
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 * · 老门禁在 jsdom 里跑老引擎（`__qrInvoke('bookInfo'|'toc'|'content')` + JS 层 `nativeMock` 假服务器）
 *   ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ 覆盖会丢 ⭐⭐⭐
 * · ⇒ 现在：**直接跑新引擎的 op**（`legado-engine` 的 `conformance --op`）
 *   + **声明式 routes 假服务器**（规范 §1.1）⇒ 覆盖不丢，验的是**真正在跑的那份** ⭐⭐⭐
 */
const { createSandbox, engineAvailable } = require('./new-engine-harness.js');
const { evalRule } = require('./engine-gate-helpers.js');
const fs = require('fs');
const path = require('path');

const PAGE_FILE = path.join(__dirname, 'fixtures', 'powenxue-info-136414.html');
const CH_FILE = path.join(__dirname, 'fixtures', 'powenxue-ch-39483902.html');
const BOOK_URL = 'https://m.powenxue15.com/info/136414.html';
const CH1_URL = 'https://m.powenxue15.com/info/136414/39483902.html';

let pass = 0, fail = 0;
function ok(cond, label, extra) {
  if (cond) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

// 修正后的规则（跟 out/ 目录里交付的 JSON 保持一致）
const SOURCE = {
  bookSourceUrl: 'https://m.powenxue15.com',
  bookSourceName: '肉文屋（规则修复版）',
  ruleBookInfo: {
    name: '#content h1@text||h1@text',
    author: '#content p.0@text##作者：##||id.infobox@text##作者：##||#info p.0@text##作者：##',
    intro: '#intro@text||#content p.3@text||class.book_des@text',
    kind: '#content p.1@text##状态：##||#info p.1@text##状态：##',
    lastChapter: '#content p.2@a@text||#content p.3@a@text',
    coverUrl: '#content img@data-original||#content img@src',
    // 章节就在详情页上 —— 留空让引擎回落到 bookUrl。
    // 原来的 `#list||#chapterlist||id.list@id` 取到的是**文本片段**或 "list"，
    // 根本不是 URL，absolutize 之后变成 .../info/list 这种垃圾。
    tocUrl: ''
  },
  ruleToc: {
    // 站方真实结构（2026-10-18 实抓 www 版快照）：
    //   div.chapterlist
    //     ├─ div.last  最近 8 章（跟 div.all 重复）
    //     └─ div.all   全部章节，li 升序 ← 要的是这个
    // 不能用 a[rel=chapter]：①「最新章节」那个链接也带 rel=chapter（多一条）
    //                          ②隔一个的 li 没有 rel（漏 7 条）
    chapterList: 'div.all li || a[rel=chapter] || li a[href*="/info/"]',
    chapterName: 'a@text || text',
    chapterUrl: 'a@href || @href',
    nextTocUrl: ''
  },
  ruleContent: {
    content: '#booktxt@html || #content@html || id.content@html || class.content@html',
    title: '#content h1@text',
    nextContentUrl: 'a:contains(下一章)@href || class.next@href || a#next_url@href'
  }
};

if (!engineAvailable()) {
  console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
  console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
  process.exit(0);
}

(async () => {
  const infoHtml = fs.readFileSync(PAGE_FILE, 'utf8');
  const chHtml = fs.readFileSync(CH_FILE, 'utf8');

  // ⭐⭐⭐ **假服务器 = 声明式 routes**（规范 §1.1）
  //   ⚠️ `match` 是**子串匹配** ⇒ 两条路径要写得能区分开：
  //     `/info/136414.html` 与 `/info/136414/39483902.html` 互不包含 ✓
  //   ⚠️ **下一章也要给路由**：新引擎的正文是**多页拼接**语义（Legado：`nextContentUrl` ⇒ 拼起来）
  //     ⇒ 老引擎的 content op **不跟下一章**（下一章由 App 翻页时再取）⭐⭐⭐
  //     ⇒ 语义等价点：**正文包含第一页 + 下一页**（下面有断言）⭐⭐⭐
  //   ⚠️ 注意：假下一页的正文**不能含**「上一章/下一章/广告/www.」这些词
  //     ⇒ 引擎的正文清洗会**把含这些词的短行删掉**（站方推广文案的过滤）⇒ 断言就假红了⭐⭐⭐
  const NEXT_HTML = '<html><body><div id="booktxt">第二章的正文内容（多页拼接验证）</div></body></html>';
  const { win, sandbox } = createSandbox({
    routes: [
      { match: '/info/136414.html', status: 200, body: infoHtml },
      { match: '/info/136414/39483902.html', status: 200, body: chHtml },
      { match: '/info/136414/39483903.html', status: 200, body: NEXT_HTML },
    ],
  });

  const invoke = (op, payload) => win.__qrInvoke(op, payload);

  console.log('\n── 1. bookInfo ──');
  const bi = invoke('bookInfo', { source: SOURCE, bookUrl: BOOK_URL, book: { name: '私生活' } });
  ok(bi && bi.book, '详情页能解析出 book', JSON.stringify(bi || {}).slice(0, 160));
  if (bi && bi.book) {
    ok(!!bi.book.name, '书名非空', JSON.stringify(bi.book.name));
    // ⭐⭐⭐ **「站方没给 tocUrl」的语义**：
    //   · 老引擎（轻阅）：bookInfo **自己**把 tocUrl 回落到 bookUrl ⇒ 字段里能看到 136414 ⭐⭐⭐
    //   · 新引擎（Legado 语义）：**tocUrl 留空** ⇒ 「目录规则跑在详情页上」（`engine.toc` 内部回落）⭐⭐⭐
    //   ⇒ **语义等价点**：**目录确实是从详情页上解析出来的**（下面第 2 段用请求记录验）⭐⭐⭐
    ok(!/list$/.test(bi.book.tocUrl || ''), 'tocUrl 不是 "list" 这种垃圾', bi.book.tocUrl);
    ok(!bi.book.tocUrl || /136414/.test(bi.book.tocUrl),
       'tocUrl 要么空（⇒ 目录跑详情页），要么是本章地址', bi.book.tocUrl);
  }

  console.log('\n── 2. toc（老规则会 0 命中 → 整页兜底 → 抓到推荐书）──');
  const toc = invoke('toc', {
    source: SOURCE, tocUrl: BOOK_URL, bookUrl: BOOK_URL, maxPages: 5
  });
  const chs = (toc && toc.chapters) || [];
  ok(chs.length > 0, `目录非空`, `拿到 ${chs.length} 章`);
  // ⭐⭐⭐ **「tocUrl 留空 ⇒ 目录跑在详情页上」**（新引擎的回落语义）
  //   ⇒ 用**请求记录**验：目录那一步真的抓的是详情页（不是某个垃圾地址）⭐⭐⭐
  const reqAfterToc = (sandbox.__requests || []).filter(u => /136414/.test(String(u)));
  ok(reqAfterToc.some(u => /\/info\/136414\.html$/.test(String(u))),
     '目录确实是从**详情页**上解析出来的（tocUrl 空 ⇒ 回落 bookUrl）',
     reqAfterToc.map(u => String(u).slice(0, 60)).join(' | '));
  // PC 快照的 div.all 有 15 个 li，但站方每隔一个就发一个纯文本 <li>标题</li>（无 <a>），
  // 引擎应当把没 URL 的剔掉 → 只剩 8 条真链接。m. 版据实是 15 条全带链接。
  ok(chs.length >= 8 && chs.length <= 16, `章数合理（PC 快照站方缺 7 条链接 → 8；m. 应为 15）`, `实际 ${chs.length}`);
  ok(chs.length !== 1, '不是"整页兜底"的 1 章', `实际 ${chs.length} 章`);

  // build 15 回归：曾经用 absolutizeMaybe(v[1], '') 判空，
  // 导致站方的**相对**章节地址不被展开 → WKWebView「不支持的URL」。
  const relative = chs.filter(c => c.url && !/^https?:\/\//.test(c.url));
  ok(relative.length === 0, '所有章节 URL 都已展开成绝对地址（相对 /info/… 必须补全 host）',
     `${relative.length} 条仍是相对，例：${JSON.stringify((relative[0]||{}).url)}`);

  const bad = chs.filter(c => c.url && !/\/info\/136414\/\d+\.html$/.test(c.url));
  ok(bad.length === 0, '**有 URL 的**章节 URL 都是本章的 /info/<书号>/<章号>.html',
     bad.length ? `${bad.length} 条不合格，例：${JSON.stringify(bad[0].url)}` : '');

  const junk = chs.filter(c => !c.title || !c.title.trim());
  ok(junk.length === 0, '没有空标题', `${junk.length} 条空`);
  // ⭐⭐⭐ **「站方纯文本 <li>（没有 <a> ⇒ 没有 URL）」的处理**：
  //   · 老引擎（轻阅）：**直接剔掉**（老门禁断言「没有 URL 为空的章节」）⭐⭐⭐
  //   · 新引擎（Legado 语义）：**保留**，但标成**卷标题**（`isVolume`）⇒ 目录里当卷名显示 ⭐⭐⭐
  //   ⇒ **语义等价点**：**它不是「可点的章节」**（不能被点开、不会进正文）
  //   ⇒ 断言改成：**空 URL 的项必须都被标成卷标题**（`isVolume`）⇒ 不会被当章节点开 ⭐⭐⭐
  const noUrl = chs.filter(c => !c.url || !c.url.trim());
  ok(noUrl.every(c => c.isVolume === true),
     '没有 URL 的项都被标成**卷标题**（不是可点的章节）',
     `${noUrl.filter(c => !c.isVolume).length} 条既没 URL 也没标卷标题`);
  ok(chs.filter(c => c.url && c.url.trim()).length > 0, '有 URL 的章节还在（没被误剔）',
     `${chs.filter(c => c.url && c.url.trim()).length} 条`);
  const samePage = chs.filter(c => /\/info\/136414\.html$/.test(c.url || ''));
  ok(samePage.length === 0, '没有指向详情页本身的假章节（旧逻辑会把空 URL 回落成详情页）', `${samePage.length} 条`);

  // 站方原序是倒序吗？这本书章节号是递增的（39483902 → …16），正序。
  const nums = chs.map(c => (c.url || '').match(/(\d+)\.html$/)).filter(Boolean).map(m => +m[1]);
  const ascending = nums.every((v, i) => i === 0 || v > nums[i - 1]);
  ok(ascending, '章号递增（`-` 前缀把站方的倒序反转回阅读顺序）', nums.slice(0, 4).join(','));
  ok(/39483902\.html$/.test(chs[0].url || ''), '第 1 章是真·第一章', chs[0] && chs[0].url);

  console.log('\n── 3. content ──');
  const c1 = invoke('content', { source: SOURCE, chapterUrl: CH1_URL, book: { name: '私生活' } });
  const ctext = (c1 && c1.content) || '';
  ok(ctext.length > 50, `正文非空`, `${ctext.length} 字符`);
  ok(/于嫣/.test(ctext), '正文含首章实际文字（不是推荐书简介）', ctext.slice(0, 40));
  ok(!/记住最新网址|请记住本书首发域名|推荐书/.test(ctext), '正文没有混入站点推广文案');
  // ⭐⭐⭐ **新引擎的正文是「多页拼接」**（Legado 语义：`nextContentUrl` ⇒ 把下一页也拼上）
  //   ⇒ 老引擎的 content op **只取第一页**（下一章由 App 翻页时再取）⭐⭐⭐
  //   ⇒ 语义等价点：**正文 = 第一页 + 下一页**（这里验的就是「拼起来了」）⭐⭐⭐
  ok(/第二章的正文内容/.test(ctext), '正文把下一页也拼上了（多页正文语义）', ctext.slice(-60));

  console.log('\n── 4. nextContentUrl ──');
  // ⭐⭐⭐ **新引擎的 `content` op 不返回 `nextUrl`**（它把多页正文**拼起来**⇒ 用不上 nextUrl）
  //   ⇒ **语义等价点**：这是**站方规则**（`ruleContent.nextContentUrl`）
  //   ⇒ 用新引擎的求值器**在章节页上跑同一条规则**来验（同一份规则 + 同一个引擎）⭐⭐⭐
  const ncR = evalRule(SOURCE.ruleContent.nextContentUrl, { base: chHtml, baseUrl: CH1_URL });
  const nc = (ncR && ncR.first) || '';
  ok(/\/info\/136414\/39483903\.html/.test(nc), '下一章 URL 算对', nc || '(空)');

  console.log('\n── 5. 回归：build 15 用户真机踩到的两个坑 ──');
  {
    // 坑 1：裸词被当字面量。`chapterName: 'a@text || text'` 的兜底 `text`
    //       曾经直接返回字符串 "text"，目录里出现一排字面写着 "text" 的章节。
    //       规则按 Legado 语义，裸 `text` 应该取**当前节点自己的文本**。
    // ⭐ 两个 li 拆成两份 HTML ⇒ 条目级基准（`baseType:"node"` + `selector`）能精确取到那一个 ⭐⭐⭐
    const HTML_WITH_A = '<ul><li class="i"><a href="/x/1.html">第一章</a></li></ul>';
    const HTML_PLAIN = '<ul><li class="i">纯文本标题</li></ul>';
    const at = (rule, base, selector) => {
      const r = evalRule(rule, { baseType: 'node', selector, base, baseUrl: 'https://a.com/' });
      return r && r.ok !== false ? r.first : `ERR:${r && r.error}`;
    };
    const bare = at('text', HTML_PLAIN, 'li.i');
    ok(bare === '纯文本标题', '裸 `text` 取节点自身文本，不是字面量 "text"', JSON.stringify(bare));
    const fb = at('a@text || text', HTML_PLAIN, 'li.i');
    ok(fb === '纯文本标题', '`a@text || text` 兜底不再是字面量', JSON.stringify(fb));
    const withA = at('a@text || text', HTML_WITH_A, 'li.i');
    ok(withA === '第一章', '有 <a> 时优先取 a@text', JSON.stringify(withA));
    const bareHref = at('href', HTML_WITH_A, 'li.i');
    ok(bareHref === '', '裸 `href` 不再返回字面量 "href"', JSON.stringify(bareHref));
    // 插值分支不能被这次收紧误伤
    const interp = at('{{1+1}}', HTML_WITH_A, 'li.i');
    ok(interp === '2', '{{}} 插值仍然原样返回', JSON.stringify(interp));
  }

  console.log('\n── 6. 请求记录（引擎真的发请求了吗）──');
  const reqs = sandbox.__requests || [];
  console.log('  请求：', reqs.map(u => String(u).slice(0, 70)).join(' | '));
  ok(reqs.length >= 2, '引擎真的发了请求（详情页 + 章节页）', `${reqs.length} 条`);

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('测试崩了:', e); process.exit(1); });
