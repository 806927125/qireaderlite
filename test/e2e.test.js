/* 端到端：用假站点 + 真实书源规则，跑通 搜索→详情→目录→正文
   跑法：node test/e2e.test.js */
const { createSandbox } = require('./harness');

let pass = 0, fail = 0; const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; return; }
  fail++; failures.push(`${name}\n    期望 ${e}\n    实际 ${a}`);
}
function truthy(name, cond, detail) {
  if (cond) { pass++; return; }
  fail++; failures.push(`${name}\n    ${detail || '不成立'}`);
}

/* ---------------- 假站点 ---------------- */
const SITE = 'https://www.99demo-novel.com';
const pages = {
  [`${SITE}/search?q=%E6%96%97%E7%A0%B4&page=1`]: `<!doctype html><html><body>
<div class="search-tip">共 3 条</div>
<div class="book-box">
  <div class="book-item">
    <a class="cover" href="/book/1001.html"><img src="/img/1001.jpg"/></a>
    <div class="info"><h3 class="bookname">斗破苍穹</h3>
    <span class="author">天蚕土豆</span><span class="state">连载中</span>
    <p class="intro">斗破苍穹讲的是少年萧炎如何从废柴成长为强者。</p>
    <a class="last" href="/book/1001/2350.html">第2350章 陨落的天炎</a></div>
  </div>
  <div class="book-item">
    <a class="cover" href="/book/1002.html"><img src="/img/1002.jpg"/></a>
    <div class="info"><h3 class="bookname">遮天</h3>
    <span class="author">辰东</span><span class="state">已完结</span>
    <p class="intro">九龙拉棺，星空彼岸。</p>
    <a class="last" href="/book/1002/1800.html">第1800章 仙路尽头</a></div>
  </div>
  <div class="book-item">
    <a class="cover" href="/book/1003.html"><img src="/img/1003.jpg"/></a>
    <div class="info"><h3 class="bookname">诡秘之主</h3>
    <span class="author">爱潜水的乌贼</span><span class="state">连载中</span>
    <p class="intro">蒸汽与机械的年代。</p>
    <a class="last" href="/book/1003/1394.html">第1394章 愚者</a></div>
  </div>
</div>
<div class="pager"><a href="/search?q=%E6%96%97%E7%A0%B4&amp;page=1">上一页</a><a class="next" href="/search?q=%E6%96%97%E7%A0%B4&amp;page=2">下一页</a></div>
</body></html>`,

  [`${SITE}/book/1001.html`]: `<!doctype html><html><body>
<div id="info">
  <h1 class="title">斗破苍穹</h1>
  <div class="meta"><span>作者：</span><a class="author" href="/author/tdt">天蚕土豆</a>
  <span>状态：</span><span class="status">连载中</span><span>分类：</span><a class="kind" href="/type/xh">玄幻</a></div>
  <img class="cover" src="/img/big/1001.jpg"/>
  <div class="desc">斗破苍穹，网络小说，天蚕土豆著。故事讲述萧炎从少年到强者的逆袭之路。</div>
  <a class="catbtn" href="/list/1001/1.html">开始阅读</a>
</div>
</body></html>`,

  [`${SITE}/list/1001/1.html`]: `<!doctype html><html><body>
<div class="chapter-list">
  <div class="volume">正文卷 第一卷 陨落的天炎</div>
  <ul class="chapter-list">
    <li><a href="/chapter/1001/1.html">第1章 陨落的天炎</a></li>
    <li><a href="/chapter/1001/2.html">第2章 萧炎</a></li>
    <li><a href="/chapter/1001/3.html">第3章 奇才</a></li>
  </ul>
</div>
<div class="pager"><a class="next" href="/list/1001/2.html">下一页</a></div>
</body></html>`,

  [`${SITE}/list/1001/2.html`]: `<!doctype html><html><body>
<ul class="chapter-list">
  <li><a href="/chapter/1001/4.html">第4章 变态</a></li>
  <li><a href="/chapter/1001/5.html">第5章 重生</a></li>
</ul>
</body></html>`,

  [`${SITE}/chapter/1001/1.html`]: `<!doctype html><html><body>
<h1 class="chapter-title">第1章 陨落的天炎</h1>
<div id="content">
  <p>斗气大陆，斗气纵横。</p>
  <p>少年萧炎静静站在演武场中。</p>
  <div class="ad">【广告：请下载九九小说网客户端】</div>
  <p>就在这时，远处传来脚步声。</p>
  <a class="prev" href="/chapter/1001/0.html">上一章</a>
  <a class="next" href="/chapter/1001/2.html">下一章</a>
</div>
</body></html>`,
};

/* 章节 2 的正文（验证翻页） */
pages[`${SITE}/chapter/1001/2.html`] = `<!doctype html><html><body>
<h1 class="chapter-title">第2章 萧炎</h1>
<div id="content"><p>我叫萧炎。</p><p>这是我第一次认真看着自己的双手。</p></div>
</body></html>`;

/* ---------------- 一份真实写法的书源 ---------------- */
const SOURCE = {
  bookSourceUrl: SITE,
  bookSourceName: '99测试站',
  bookSourceGroup: '测试,演示',
  enabled: true,
  header: JSON.stringify({ 'User-Agent': 'QRLite/1.0', Referer: SITE + '/' }),
  ruleSearch: {
    searchUrl: `${SITE}/search?q={{keyword}}&page={{page}}`,
    bookList: 'class.book-item',
    name: 'tag.h3@text',
    author: 'class.author@text',
    intro: 'class.intro@text',
    kind: 'class.kind@text',
    lastChapter: 'class.last@text',
    coverUrl: 'class.cover@tag.img@src',
    bookUrl: 'class.cover@href',
    wordCount: 'class.word@text'
  },
  ruleExplore: {
    exploreUrl: '@js:JSON.stringify([{title:"热门",url:"' + SITE + '/rank/hot"},{title:"完结",url:"' + SITE + '/rank/done"}])',
    bookList: 'class.book-item',
    name: 'tag.h3@text',
    author: 'class.author@text',
    bookUrl: 'tag.a@href'
  },
  ruleBookInfo: {
    name: 'class.title@text',
    author: 'class.author@text',
    intro: 'class.desc@text',
    kind: 'class.kind@text',
    lastChapter: 'class.chapter a@text',
    coverUrl: 'class.cover@src',
    tocUrl: 'class.catbtn@href'
  },
  ruleToc: {
    chapterList: 'ul.chapter-list@tag.li',
    chapterName: 'tag.a@text',
    chapterUrl: 'tag.a@href',
    nextTocUrl: 'a.next@href'
  },
  ruleContent: {
    title: 'class.chapter-title@text',
    content: 'id.content@html',
    nextContentUrl: 'a.next@href'
  }
};

/* 假站还得能响应发现页 */
pages[`${SITE}/rank/hot`] = pages[`${SITE}/search?q=%E6%96%97%E7%A0%B4&page=1`];

(async () => {
  const requests = [];
  const { QR, win } = createSandbox({
    nativeMock: async (fn, args) => {
      if (fn === 'request') {
        requests.push(args.url);
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

  const invoke = async (op, payload) => {
    const r = await win.__qrInvoke(op, payload);
    if (r && r.error) console.log(`  [${op}] 返回错误: ${r.error}`);
    return r;
  };

  /* ---- 1. 搜索 ---- */
  const s = await invoke('search', { source: SOURCE, keyword: '斗破', page: 1 });
  console.log('  [DBG]', JSON.stringify(s).slice(0, 300));
  check('搜索条数', s.books.length, 3);
  check('搜索无错误', s.error, undefined);
  check('第一本书名', s.books[0] && s.books[0].name, '斗破苍穹');
  check('作者', s.books[0] && s.books[0].author, '天蚕土豆');
  check('简介', s.books[0] && s.books[0].intro, '斗破苍穹讲的是少年萧炎如何从废柴成长为强者。');
  check('状态', s.books[0] && s.books[0].lastChapter, '第2350章 陨落的天炎');
  check('封面补全为绝对地址', s.books[0] && s.books[0].coverUrl, `${SITE}/img/1001.jpg`);
  check('书籍 URL 补全', s.books[0] && s.books[0].bookUrl, `${SITE}/book/1001.html`);
  check('第三本也在', s.books[2] && s.books[2].name, '诡秘之主');
  truthy('中文关键词正确编码', requests[0].indexOf('%E6%96%97%E7%A0%B4') > 0, '实际请求: ' + requests[0]);

  /* ---- 2. 详情 ---- */
  check('搜索至少 1 条', s.books.length > 0, true);
  const info = await invoke('bookInfo', { source: SOURCE, bookUrl: (s.books[0] || {}).bookUrl });
  truthy('详情无错误', !info.error, info.error);
  check('详情书名', info.book && info.book.name, '斗破苍穹');
  check('详情作者', info.book && info.book.author, '天蚕土豆');
  check('详情分类', info.book && info.book.kind, '玄幻');
  check('详情封面', info.book && info.book.coverUrl, `${SITE}/img/big/1001.jpg`);
  check('详情 tocUrl', info.book && info.book.tocUrl, `${SITE}/list/1001/1.html`);
  truthy('详情简介非空', info.book && info.book.intro.length > 10);

  /* ---- 3. 目录（跨两页）---- */
  const t = await invoke('toc', {
    source: SOURCE, bookUrl: (s.books[0] || {}).bookUrl, tocUrl: (info.book || {}).tocUrl, maxPages: 4
  });
  truthy('目录无错误', !t.error, t.error);
  check('目录跨页总数', t.chapters.length, 5);
  check('第一章标题', t.chapters[0] && t.chapters[0].title, '第1章 陨落的天炎');
  check('跨页后下标累计', t.chapters.map(c => c.index), [0, 1, 2, 3, 4]);
  check('章节 URL 补全', t.chapters[0] && t.chapters[0].url, `${SITE}/chapter/1001/1.html`);
  check('下一页章节来自第 2 页', t.chapters[4] && t.chapters[4].title, '第5章 重生');
  check('下一页章节 URL', t.chapters[4] && t.chapters[4].url, `${SITE}/chapter/1001/5.html`);
  truthy('没有死循环', requests.filter(u => /\/list\/1001\//.test(u)).length <= 3,
    '目录页请求了 ' + requests.filter(u => /\/list\/1001\//.test(u)).length + ' 次');

  /* ---- 4. 正文 ---- */
  const c = await invoke('content', { source: SOURCE, chapterUrl: (t.chapters[0] || {}).url });
  truthy('正文无错误', !c.error, c.error);
  check('正文章节名', c.title, '第1章 陨落的天炎');
  truthy('正文有内容', c.content.indexOf('斗气大陆，斗气纵横') >= 0, c.content.slice(0, 80));
  truthy('广告行被过滤', c.content.indexOf('广告') < 0, c.content);
  truthy('正文换行保留', c.content.indexOf('\n') > 0);
  check('下一章 URL', c.nextUrl, `${SITE}/chapter/1001/2.html`);

  /* ---- 5. 发现页分类 ---- */
  const k = await invoke('exploreKinds', { source: SOURCE });
  check('分类数量', k.kinds.length, 2);
  check('分类标题', k.kinds[0] && k.kinds[0].title, '热门');
  check('分类 URL', k.kinds[0] && k.kinds[0].url, `${SITE}/rank/hot`);

  /* ---- 6. 发现页列表 ---- */
  const ex = await invoke('explore', { source: SOURCE, kindUrl: k.kinds[0].url, page: 1 });
  check('发现页条数', ex.books.length, 3);
  check('发现页书名', ex.books[0] && ex.books[0].name, '斗破苍穹');

  /* ---- 报告 ---- */
  console.log('\n--- 请求序列 ---');
  requests.forEach((u, i) => console.log(`  ${i + 1}. ${u}`));
  console.log(`\n端到端全链路: ${pass} 通过 / ${fail} 失败`);
  if (failures.length) {
    console.log('\n失败明细:');
    failures.forEach(f => console.log('  ✗ ' + f));
    process.exit(1);
  }
})().catch(e => { console.error('测试崩溃:', e); process.exit(1); });
