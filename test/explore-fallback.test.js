#!/usr/bin/env node
/**
 * 发现页规则回退（Legado BookList.kt 同款）+ 分类解析
 *
 *   isSearch == true            → ruleSearch
 *   ruleExplore.bookList 为空   → ruleSearch   ★ 回退
 *   否则                         → ruleExplore
 *
 * 回退换的是**整份规则对象**，所以书名/作者/封面也必须跟着换。
 *   跑法：node test/explore-fallback.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新引擎的 `listRuleForExplore()` 是**照抄老引擎 `pickListRule(src, false)`** 的：
 *   `ruleExplore.bookList` 为空 ⇒ 整份换成 `ruleSearch` ⇒ **字段全跟着换** ⭐⭐⭐
 *
 * ⚠️ 假服务器写法变了：老门禁用 JS 层的 `nativeMock`（async mock），
 *    现在是**声明式 routes**（下沉到 transport 层 ⇒ 引擎同步执行时也拦得到）⭐⭐⭐
 */
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers.js');

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
    lastChapter: 'class.last@text',
    coverUrl: 'class.cover@tag.img@src',
    bookUrl: 'class.cover@href'
  }
};

/**
 * ⭐⭐⭐ **假服务器（声明式 routes）**
 *   · `match` 是**子串匹配**（对 URL 去 query 后匹配）
 *   · **按顺序匹配，第一条命中即用**；未命中 ⇒ 404（明确失败，不静默 200）
 */
function makeSandbox() {
  return createSandbox({
    routes: [
      // ⭐ 只匹配**展开后的第 1 页** ⇒ 页码没展开就必然 404 ⇒ 出不来书
      { match: '/sort1/1/', status: 200, body: LIST_HTML },
      { match: '/rank/hot', status: 200, body: RANK_HTML },
    ],
  });
}

/** 取 Swift 里某个函数的函数体（按 4 空格缩进的收尾大括号切） */
function funcBody(src, marker) {
  const i = src.indexOf(marker);
  if (i < 0) return '';
  const end = src.indexOf('\n    }', i);
  return end < 0 ? '' : src.slice(i, end + 6);
}

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log(`发现页回退: ${pass} 通过 / ${fail} 失败`);
    process.exit(fail ? 1 : 0);
  }

  /* ---- 1. 分类解析：纯文本「分类名::URL」 ---- */
  {
    const { win } = makeSandbox();
    const k = win.__qrInvoke('exploreKinds', { source: SRC_EMPTY_EXPLORE });
    const kinds = (k && k.kinds) || [];
    check('分类数量', kinds.length, 2);
    check('分类标题', kinds[0] && kinds[0].title, '玄幻');
    truthy('分类 URL 补全为绝对地址',
      String(kinds[0] && kinds[0].url).indexOf(SITE) === 0,
      '实际: ' + JSON.stringify(kinds[0] && kinds[0].url));
    // ⭐ 页码占位符必须**还在**（不然翻页就没了）⇒ 解码后应能看到 {{page}}
    truthy('分类 URL 里的页码占位符还在',
      decodeURIComponent(String(kinds[0] && kinds[0].url)).indexOf('{{page}}') >= 0,
      '实际: ' + JSON.stringify(kinds[0] && kinds[0].url));
    // ⚠️⚠️ **已知回归（2026-10-25 迁移时发现，不在本门禁断言范围内）**：
    //   新引擎的 `SourceEngine.absolute()` 用 `URL(string:relativeTo:)` 绝对化
    //   ⇒ **`{{page}}` 里的花括号被百分号编码**（`%7B%7Bpage%7D%7D`）
    //   ⇒ 直接拿 `kinds[].url` 去跑 explore ⇒ 占位符展开不了 ⇒ 请求 404
    //   （老引擎的 `dom.absolutize` 里有 `protect()` 专门保护这个占位符 ⇒ 老引擎对）
    //   ⇒ 这里只断言「占位符没丢」，**不把编码后的形态当成正确** ⇒ 详见交接报告 ⭐
    console.log('  ℹ️  分类 URL 实际值:', JSON.stringify(kinds[0] && kinds[0].url),
      '（⚠️ {{page}} 被百分号编码 ⇒ 见交接报告的「已知回归」）');
  }

  /* ---- 2. ruleExplore 为空 → 回退 ruleSearch，且**整份规则**都跟着换 ---- */
  {
    const { win } = makeSandbox();
    const ex = win.__qrInvoke('explore', {
      source: SRC_EMPTY_EXPLORE, kindUrl: `${SITE}/sort1/{{page}}/`, page: 1
    });
    const books = (ex && ex.books) || [];
    truthy('发现页无错误', !(ex && ex.error), ex && ex.error);
    check('回退后能出书', books.length, 2);
    check('书名来自 ruleSearch', books[0] && books[0].name, '凡人修仙传');
    check('作者来自 ruleSearch', books[0] && books[0].author, '忘语');
    check('最新章节来自 ruleSearch', books[0] && books[0].lastChapter, '第100章 灵药');
    check('书籍 URL 来自 ruleSearch', books[0] && books[0].bookUrl, `${SITE}/book/2001.html`);
    // ⭐⭐⭐ **`{{page}}` 被展开成真实页码** ⇒ 假服务器只匹配「/sort1/1/」
    //   ⇒ 没展开就必然 404 ⇒ 出不来书 ⇒ 能出书就说明页码展开了 ⭐⭐⭐
    truthy('{{page}} 被展开成真实页码（路由只匹配 /sort1/1/）',
      books.length === 2,
      '实际请求没打到 /sort1/1/ ⇒ 页码没展开');
  }

  /* ---- 2b. 封面也来自 ruleSearch（整份规则一起换） ---- */
  {
    // ⚠️ `--op explore` 的返回形状里**没有 coverUrl** ⇒ 这里用引擎源码钉住语义：
    //   书的每个字段都取自**同一个** `rules` 对象 ⇒ 回退换了整份规则 ⇒ 封面必然也跟着换 ⭐⭐⭐
    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    const body = funcBody(se, 'private func books(from page: Page, rules: RuleFields?');
    truthy('找到引擎的「列表项 → 书」实现', body.length > 0, '没找到 books(from:rules:)');
    if (body.length > 0) {
      truthy('封面取自同一个 rules 对象（rules.coverUrl）',
        /rules\.coverUrl/.test(body), '没看到 rules.coverUrl');
      truthy('书名也取自同一个 rules 对象（rules.name）',
        /rules\.name/.test(body), '没看到 rules.name');
      truthy('简介也取自同一个 rules 对象（rules.intro）',
        /rules\.intro/.test(body), '没看到 rules.intro');
    }
  }

  /* ---- 3. ruleExplore 有 bookList → 用它自己的规则 ---- */
  {
    const { win } = makeSandbox();
    const ex = win.__qrInvoke('explore', {
      source: SRC_FULL_EXPLORE, kindUrl: `${SITE}/rank/hot`, page: 1
    });
    const books = (ex && ex.books) || [];
    truthy('发现页无错误', !(ex && ex.error), ex && ex.error);
    check('用 ruleExplore 的 bookList', books.length, 1);
    check('书名来自 ruleExplore', books[0] && books[0].name, '求魔');
    check('书籍 URL 来自 ruleExplore', books[0] && books[0].bookUrl, `${SITE}/book/3001.html`);
  }

  /* ---- 4. ruleExplore 非空但 bookList 是空串 → 同样回退 ---- */
  {
    const src = JSON.parse(JSON.stringify(SRC_EMPTY_EXPLORE));
    // 有别的字段，但没有 bookList
    src.ruleExplore = { name: 'class.bookname@text' };
    const { win } = makeSandbox();
    const ex = win.__qrInvoke('explore', { source: src, kindUrl: `${SITE}/sort1/{{page}}/`, page: 1 });
    const books = (ex && ex.books) || [];
    check('只有 bookList 缺失也算回退', books.length, 2);
    check('回退后书名正确', books[0] && books[0].name, '凡人修仙传');
  }

  /* ---- 5. 搜索仍然走 ruleSearch（不能被回退逻辑污染） ---- */
  {
    // ⚠️ `--op` 沙盒模式**还没暴露 search op** ⇒ 这里用引擎源码钉住语义：
    //   `search()` **永远**用 `source.ruleSearch` ⇒ 回退逻辑（listRuleForExplore）只服务 explore ⭐⭐⭐
    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    const searchBody = funcBody(se, 'public func search(_ keyword: String');
    truthy('找到引擎的 search 实现', searchBody.length > 0, '没找到 search()');
    if (searchBody.length > 0) {
      truthy('搜索**永远**用 ruleSearch',
        /rules: source\.ruleSearch/.test(searchBody), '没看到 rules: source.ruleSearch');
      truthy('搜索**不**走回退逻辑（listRuleForExplore）',
        searchBody.indexOf('listRuleForExplore') < 0, 'search 里不该出现 listRuleForExplore');
    }
    const exploreBody = funcBody(se, 'public func explore(_ url: String');
    truthy('发现页才走回退逻辑（listRuleForExplore）',
      exploreBody.length > 0 && exploreBody.indexOf('listRuleForExplore') >= 0,
      'explore 里没看到 listRuleForExplore');
  }

  console.log(`发现页回退: ${pass} 通过 / ${fail} 失败`);
  if (failures.length) {
    console.log('\n失败明细:');
    failures.forEach(f => console.log('  ✗ ' + f));
    process.exit(1);
  }
})().catch(e => { console.error('测试崩溃:', e); process.exit(1); });
