/* 发现页规则回退（Legado BookList.kt 同款）+ 分类解析
 *
 *   isSearch == true            → ruleSearch
 *   ruleExplore.bookList 为空   → ruleSearch   ★ 回退
 *   否则                         → ruleExplore
 *
 * 回退换的是**整份规则对象**，所以书名/作者/封面也必须跟着换。
 *   跑法：node test/explore-fallback.test.js
 */
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
const SITE = 'https://www.explore-demo.com';
const LIST_HTML = `<!doctype html><html><body>
<div class="book-box">
  <div class="book-item">
    <a class="cover" href="/book/2001.html"><img src="/img/2001.jpg"/></a>
    <div class="info"><h3 class="bookname">凡人修仙传</h3>
    <span class="author">忘语</span>
    <a class="last" href="/book/2001/100.html">第100章 灵药</a></div>
  </div>
  <div class="book-item">
    <a class="cover" href="/book/2002.html"><img src="/img/2002.jpg"/></a>
    <div class="info"><h3 class="bookname">仙逆</h3>
    <span class="author">耳根</span>
    <a class="last" href="/book/2002/200.html">第200章 轮回</a></div>
  </div>
</div>
</body></html>`;

const RANK_HTML = `<!doctype html><html><body>
<div class="rank-item">
  <a class="rank-cover" href="/book/3001.html"><img src="/img/3001.jpg"/></a>
  <span class="rank-name">求魔</span><span class="rank-author">忘语</span>
</div>
</body></html>`;

const pages = {
  [`${SITE}/sort1/1/`]: LIST_HTML,
  [`${SITE}/sort1/2/`]: LIST_HTML,
  [`${SITE}/rank/hot`]: RANK_HTML
};

/* 源 A：ruleExplore 是空的 {} —— 绝大多数「只有发现 URL 没有发现规则」的源长这样 */
const SRC_EMPTY_EXPLORE = {
  bookSourceUrl: SITE,
  bookSourceName: '空发现规则源',
  enabled: true,
  exploreUrl: '玄幻::/sort1/{{page}}/\n仙侠::/sort1/{{page}}/',
  ruleExplore: {},
  ruleSearch: {
    searchUrl: `${SITE}/search?q={{keyword}}`,
    bookList: 'class.book-item',
    name: 'class.bookname@text',
    author: 'class.author@text',
    lastChapter: 'class.last@text',
    coverUrl: 'class.cover@tag.img@src',
    bookUrl: 'class.cover@href'
  }
};

/* 源 B：ruleExplore 自己有 bookList —— 必须用它的，不能被 ruleSearch 抢走 */
const SRC_FULL_EXPLORE = {
  bookSourceUrl: SITE,
  bookSourceName: '完整发现规则源',
  enabled: true,
  exploreUrl: '@js:JSON.stringify([{title:"热门",url:"' + SITE + '/rank/hot"}])',
  ruleExplore: {
    bookList: 'class.rank-item',
    name: 'class.rank-name@text',
    author: 'class.rank-author@text',
    coverUrl: 'class.rank-cover@tag.img@src',
    bookUrl: 'class.rank-cover@href'
  },
  ruleSearch: {
    searchUrl: `${SITE}/search?q={{keyword}}`,
    bookList: 'class.book-item',
    name: 'class.bookname@text',
    author: 'class.author@text',
    coverUrl: 'class.cover@tag.img@src',
    bookUrl: 'class.cover@href'
  }
};

function makeSandbox() {
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
  return { QR, win, requests };
}

(async () => {
  /* ---- 1. 分类解析：纯文本「分类名::URL」 ---- */
  {
    const { win, requests } = makeSandbox();
    const k = await win.__qrInvoke('exploreKinds', { source: SRC_EMPTY_EXPLORE });
    check('分类数量', k.kinds.length, 2);
    check('分类标题', k.kinds[0] && k.kinds[0].title, '玄幻');
    check('分类 URL 补全为绝对地址', k.kinds[0] && k.kinds[0].url, `${SITE}/sort1/{{page}}/`);
  }

  /* ---- 2. ruleExplore 为空 → 回退 ruleSearch，且**整份规则**都跟着换 ---- */
  {
    const { win, requests } = makeSandbox();
    const ex = await win.__qrInvoke('explore', {
      source: SRC_EMPTY_EXPLORE, kindUrl: `${SITE}/sort1/{{page}}/`, page: 1
    });
    truthy('发现页无错误', !ex.error, ex.error);
    check('回退后能出书', ex.books.length, 2);
    check('书名来自 ruleSearch', ex.books[0] && ex.books[0].name, '凡人修仙传');
    check('作者来自 ruleSearch', ex.books[0] && ex.books[0].author, '忘语');
    check('最新章节来自 ruleSearch', ex.books[0] && ex.books[0].lastChapter, '第100章 灵药');
    check('封面来自 ruleSearch', ex.books[0] && ex.books[0].coverUrl, `${SITE}/img/2001.jpg`);
    check('书籍 URL 来自 ruleSearch', ex.books[0] && ex.books[0].bookUrl, `${SITE}/book/2001.html`);
    truthy('{{page}} 被展开成真实页码',
      requests[0].indexOf('/sort1/1/') >= 0 && requests[0].indexOf('{{page}}') < 0,
      '实际请求: ' + requests[0]);
  }

  /* ---- 3. ruleExplore 有 bookList → 用它自己的规则 ---- */
  {
    const { win } = makeSandbox();
    const ex = await win.__qrInvoke('explore', {
      source: SRC_FULL_EXPLORE, kindUrl: `${SITE}/rank/hot`, page: 1
    });
    truthy('发现页无错误', !ex.error, ex.error);
    check('用 ruleExplore 的 bookList', ex.books.length, 1);
    check('书名来自 ruleExplore', ex.books[0] && ex.books[0].name, '求魔');
    check('书籍 URL 来自 ruleExplore', ex.books[0] && ex.books[0].bookUrl, `${SITE}/book/3001.html`);
  }

  /* ---- 4. ruleExplore 非空但 bookList 是空串 → 同样回退 ---- */
  {
    const src = JSON.parse(JSON.stringify(SRC_EMPTY_EXPLORE));
    src.ruleExplore = { name: 'class.bookname@text' };   // 有别的字段，但没有 bookList
    const { win } = makeSandbox();
    const ex = await win.__qrInvoke('explore', { source: src, kindUrl: `${SITE}/sort1/1/`, page: 1 });
    check('只有 bookList 缺失也算回退', ex.books.length, 2);
    check('回退后书名正确', ex.books[0] && ex.books[0].name, '凡人修仙传');
  }

  /* ---- 5. 搜索仍然走 ruleSearch（不能被回退逻辑污染） ---- */
  {
    const src = JSON.parse(JSON.stringify(SRC_EMPTY_EXPLORE));
    src.ruleSearch.searchUrl = `${SITE}/sort1/{{page}}/`;
    const { win } = makeSandbox();
    const s = await win.__qrInvoke('search', { source: src, keyword: '凡人', page: 1 });
    check('搜索出书', s.books.length, 2);
    check('搜索书名', s.books[0] && s.books[0].name, '凡人修仙传');
  }

  console.log(`发现页回退: ${pass} 通过 / ${fail} 失败`);
  if (failures.length) {
    console.log('\n失败明细:');
    failures.forEach(f => console.log('  ✗ ' + f));
    process.exit(1);
  }
})().catch(e => { console.error('测试崩溃:', e); process.exit(1); });
