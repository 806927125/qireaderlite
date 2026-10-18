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
 */
const { createSandbox } = require('./harness');
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

(async () => {
  const infoHtml = fs.readFileSync(PAGE_FILE, 'utf8');
  const chHtml = fs.readFileSync(CH_FILE, 'utf8');

  const pages = {};
  pages[BOOK_URL] = infoHtml;
  pages[CH1_URL] = chHtml;

  const { QR, win } = createSandbox({
    nativeMock: async (fn, args) => {
      if (fn === 'request') {
        const body = pages[args.url];
        if (body === undefined) return { ok: false, error: '404 mock: ' + args.url };
        return {
          ok: true, code: 200, url: args.url, redirectUrl: args.url,
          headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: body, bytes: body.length
        };
      }
      return { ok: true, value: '' };
    }
  });

  const invoke = (op, payload) => win.__qrInvoke(op, payload);

  console.log('\n── 1. bookInfo ──');
  const bi = await invoke('bookInfo', { source: SOURCE, bookUrl: BOOK_URL, book: { name: '私生活' } });
  ok(bi && bi.book, '详情页能解析出 book');
  if (bi && bi.book) {
    ok(!!bi.book.name, '书名非空', JSON.stringify(bi.book.name));
    // tocUrl 留空 → 引擎应回落到 bookUrl 本身（章节就在详情页上）
    ok(/136414/.test(bi.book.tocUrl || ''), 'tocUrl 回落到详情页而非垃圾片段', bi.book.tocUrl);
    ok(!/list$/.test(bi.book.tocUrl || ''), 'tocUrl 不是 "list" 这种垃圾', bi.book.tocUrl);
  }

  console.log('\n── 2. toc（老规则会 0 命中 → 整页兜底 → 抓到推荐书）──');
  const toc = await invoke('toc', {
    source: SOURCE, tocUrl: BOOK_URL, bookUrl: BOOK_URL, maxPages: 5
  });
  const chs = (toc && toc.chapters) || [];
  ok(chs.length > 0, `目录非空`, `拿到 ${chs.length} 章`);
  // PC 快照的 div.all 有 15 个 li，但站方每隔一个就发一个纯文本 <li>标题</li>（无 <a>），
  // 引擎应当把没 URL 的剔掉 → 只剩 8 条真链接。m. 版据实是 15 条全带链接。
  ok(chs.length >= 8 && chs.length <= 16, `章数合理（PC 快照站方缺 7 条链接 → 8；m. 应为 15）`, `实际 ${chs.length}`);
  ok(chs.length !== 1, '不是"整页兜底"的 1 章', `实际 ${chs.length} 章`);

  // build 15 回归：曾经用 absolutizeMaybe(v[1], '') 判空，
  // 导致站方的**相对**章节地址不被展开 → WKWebView「不支持的URL」。
  const relative = chs.filter(c => c.url && !/^https?:\/\//.test(c.url));
  ok(relative.length === 0, '所有章节 URL 都已展开成绝对地址（相对 /info/… 必须补全 host）',
     `${relative.length} 条仍是相对，例：${JSON.stringify((relative[0]||{}).url)}`);

  const bad = chs.filter(c => !/\/info\/136414\/\d+\.html$/.test(c.url || ''));
  ok(bad.length === 0, '每章 URL 都是本章的 /info/<书号>/<章号>.html',
     bad.length ? `${bad.length} 条不合格，例：${JSON.stringify(bad[0].url)}` : '');

  const junk = chs.filter(c => !c.title || !c.title.trim());
  ok(junk.length === 0, '没有空标题', `${junk.length} 条空`);
  const noUrl = chs.filter(c => !c.url || !c.url.trim());
  ok(noUrl.length === 0, '没有 URL 为空的章节（引擎必须剔掉站方纯文本 <li>）', `${noUrl.length} 条`);
  const samePage = chs.filter(c => /\/info\/136414\.html$/.test(c.url || ''));
  ok(samePage.length === 0, '没有指向详情页本身的假章节（旧逻辑会把空 URL 回落成详情页）', `${samePage.length} 条`);

  // 站方原序是倒序吗？这本书章节号是递增的（39483902 → …16），正序。
  const nums = chs.map(c => (c.url || '').match(/(\d+)\.html$/)).filter(Boolean).map(m => +m[1]);
  const ascending = nums.every((v, i) => i === 0 || v > nums[i - 1]);
  ok(ascending, '章号递增（`-` 前缀把站方的倒序反转回阅读顺序）', nums.slice(0, 4).join(','));
  ok(/39483902\.html$/.test(chs[0].url || ''), '第 1 章是真·第一章', chs[0] && chs[0].url);

  console.log('\n── 3. content ──');
  const c1 = await invoke('content', { source: SOURCE, chapterUrl: CH1_URL, book: { name: '私生活' } });
  const ctext = (c1 && c1.content) || '';
  ok(ctext.length > 50, `正文非空`, `${ctext.length} 字符`);
  ok(/于嫣/.test(ctext), '正文含首章实际文字（不是推荐书简介）', ctext.slice(0, 40));
  ok(!/记住最新网址|请记住本书首发域名|推荐书/.test(ctext), '正文没有混入站点推广文案');

  console.log('\n── 4. nextContentUrl ──');
  const nc = (c1 && (c1.nextUrl || c1.nextContentUrl)) || '';
  ok(/\/info\/136414\/39483903\.html/.test(nc), '下一章 URL 算对', nc || '(空)');

  console.log('\n── 5. 回归：build 15 用户真机踩到的两个坑 ──');
  {
    // 坑 1：裸词被当字面量。`chapterName: 'a@text || text'` 的兜底 `text`
    //       曾经直接返回字符串 "text"，目录里出现一排字面写着 "text" 的章节。
    //       规则按 Legado 语义，裸 `text` 应该取**当前节点自己的文本**。
    const d1 = QR.dom.parseHTML('<li><a href="/x/1.html">第一章</a></li>', 'https://a.com/');
    const n1 = QR.dom.selectAll(d1, 'li')[0];
    const d2 = QR.dom.parseHTML('<li>纯文本标题</li>', 'https://a.com/');
    const n2 = QR.dom.selectAll(d2, 'li')[0];
    const ctx = { baseUrl: 'https://a.com/', source: {}, book: {} };

    const bare = await QR.rule.getValue('text', n2, ctx);
    ok(bare === '纯文本标题', '裸 `text` 取节点自身文本，不是字面量 "text"', JSON.stringify(bare));
    const fb = await QR.rule.getValue('a@text || text', n2, ctx);
    ok(fb === '纯文本标题', '`a@text || text` 兜底不再是字面量', JSON.stringify(fb));
    const withA = await QR.rule.getValue('a@text || text', n1, ctx);
    ok(withA === '第一章', '有 <a> 时优先取 a@text', JSON.stringify(withA));
    const bareHref = await QR.rule.getValue('href', n1, ctx);
    ok(bareHref === '', '裸 `href` 不再返回字面量 "href"', JSON.stringify(bareHref));
    // 插值分支不能被这次收紧误伤
    const interp = await QR.rule.getValue('{{1+1}}', n1, ctx);
    ok(interp === '2', '{{}} 插值仍然原样返回', JSON.stringify(interp));
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('测试崩了:', e); process.exit(1); });
