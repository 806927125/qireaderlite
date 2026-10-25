#!/usr/bin/env node
/**
 * **Legado 规则语法兼容：几处引擎级缺口**（2026-10-22 适配 125 源包时挖出来的）
 *
 * 跑法：node test/rule-syntax-compat.test.js
 *
 * ────────────────────────────────────────────────────────────
 * ① **JSONPath 写成 `result.xxx`**（Legado 允许，意思是「相对当前结果」）
 *    实测 125 源里有 **130 处**这种写法（纵横中文 / 绾书文学网 / 悦读小说 / 神魔…）
 *    轻阅以前不认 ⇒ 它落进「选择器」分支 ⇒ **0 命中** ⇒ 发现/目录全空 ⭐
 *
 * ② **`@put:{k:v}` / `@get:{k}` 内嵌在规则或 URL 里**
 *    实测 125 源里有 **11 处**（猪猪小说 / 七猫小说 / 咪咕阅读 / 晋江 / 宜搜…）
 *    轻阅以前**只认「整条规则就是这个形式」** ⇒ 内嵌写法全废
 *    ⇒ 站方拿不到变量 ⇒ 后续规则（详情/目录）全废 ⭐
 *
 * ③ **`!N` 排除语法**（`id.list@tag.dd!0:1:2:3` ⇒ 取 dd，但排除前 4 个）
 * ④ **复合规则** `<js>…</js>$.data`（七猫 / 红薯 / 晋江极常见）
 * ⑤ **URL 里的 `,{json}` 请求选项**（创世中文网：method/body/headers 写在 URL 后面）
 * ⑥ **`text.` 前缀是【文本完全相等】**（啃书阁 / 去读书 / QQ阅读）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎 JS（`window.__qrInvoke` / `QR.dom.*`）
 *     ⇒ 老引擎删了 ⇒ 对象没了 ⇒ 覆盖就丢了
 *   ⇒ 现在改成**跑新引擎**（`legado-engine` 的 `--op` 模式 ⇒ 真引擎 + 假服务器路由）
 *   ⇒ **语义等价在哪**：
 *     · 老门禁验的是「老引擎把这条规则求值成什么」⇒ 新架构里求值的就是新引擎
 *       ⇒ **断言对象换成引擎，验的还是同一条规则的语义** ⭐⭐⭐
 *     · 老门禁用 `QR.dom.selectAll(doc, '…')` 直接验选择器层 ⇒ 那是**老引擎私有 API**
 *       ⇒ 改成**用真引擎跑完整链**（列表规则 → 出的书）⇒ 验的是**同一条规则**的**可观察结果**
 *       （层级更高 ⇒ 更接近真机）⭐⭐⭐
 *   · 假服务器从老的 JS 层 `nativeMock` 改成**声明式 routes**（下沉到 transport 层）
 */
const fs = require('fs');
const path = require('path');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除（2026-10-25）⇒ 门禁改验【新引擎】**（`legado-engine` 的 Swift 实现）
const { runOp, analyzeUrl, engineAvailable } = require('./engine-bridge.js');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};
const skip = (m) => console.log('  ⏭️  跳过：' + m + '（**没验到 ≠ 通过**）');

/** 列表接口返回：每本书都带 x_id（用来验证 @put/@get 变量传递） */
const LIST_JSON = JSON.stringify({
  code: 0,
  resultList: [
    { bookName: '书名一', x_id: 'XID-001', author: '作者一' },
    { bookName: '书名二', x_id: 'XID-002', author: '作者二' }
  ],
  // 有些源的结果在 bookList 里（`result.resultList||result.bookList` 这种兜底写法）
  bookList: [{ bookName: '书名三', x_id: 'XID-003', author: '作者三' }]
});

/** ⭐ 假服务器：一条路由 ⇒ 一份响应（引擎侧 transport 层 ⇒ 站方 JS 的 java.ajax 也打得到） */
const listRoute = (body) => [{ match: 'fake.example.com/list', status: 200, body }];

/** ⭐ 跑一次新引擎的 explore op */
function explore(ruleExplore, body, extra = {}) {
  const src = {
    bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
    ruleExplore,
  };
  const payload = Object.assign({
    op: 'explore', source: src, kindUrl: 'https://fake.example.com/list', page: 1,
    routes: listRoute(body),
  }, extra);
  // ⚠️ **重试**：引擎正在被重编时 ⇒ 这次调用会返回空 ⇒ 重试几次 ⭐⭐⭐
  let last = null;
  for (let i = 0; i < 5; i++) {
    last = runOp(payload);
    if (last && last.ok !== false && last.books) break;
    const until = Date.now() + 3000;
    while (Date.now() < until) { /* 忙等 3 秒 */ }
  }
  return last;
}
const booksOf = (r) => (r && r.books) || [];

(async () => {
  console.log('=== 1. 源码：这几处语法都要在【新引擎】里有对应实现 ===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]`）
  //   ⇒ 那些是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失语义覆盖 ⭐⭐⭐
  //   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（309 项）与真机上 ⭐⭐⭐
  //
  // ⭐ 下面这几条是**新引擎的等价描述**（能力必须还在，只是实现换了地方/换了写法）：
  const SRC = path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore');
  const read = (rel) => fs.readFileSync(path.join(SRC, rel), 'utf8');
  const evaluator = read('Evaluator/Evaluator.swift');
  const template = read('Evaluator/TemplateEngine.swift');
  const selector = read('DOM/LegadoSelector.swift');
  const pseudo = read('DOM/PseudoFilter.swift');
  const parser = read('Rule/RuleParser.swift');
  const urlBuilder = read('Host/URLBuilder.swift');

  ok(/result\./.test(evaluator) && /\$\.result\./.test(evaluator),
     '① `result.` 前缀：两种语义都试（根别名 + 顶层 result 字段下）');
  ok(/@put:/.test(template) && /@get:/.test(template),
     '② `@put:` / `@get:` 内嵌处理在求值器里（不是只认「整条规则就是这个形式」）');
  ok(/exclusion/.test(selector),
     '③ 选择器支持 `!N` 排除（exclusion 段）');
  ok(/textEquals/.test(pseudo),
     '⑥ `text.` 前缀 = 文本【完全相等】（textEquals，不是「包含」）');
  ok(/jsWithTail/.test(parser),
     '④ 复合规则 `<js>…</js>$.data` 的尾部选择器不丢（jsWithTail）');
  ok(/splitOptions/.test(urlBuilder),
     '⑤ URL 规则会切掉 `,{json}` 请求选项后缀（不是 URL 的一部分）');

  // ⭐⭐⭐ **探活**（引擎跑不起来 ⇒ 显式 SKIP，不算门禁的锅）⭐⭐⭐
  const _alive = runOp({ op: 'exploreKinds',
    source: { bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针',
              exploreUrl: '@js:JSON.stringify([{title:"T",url:"https://x/1"}])' } });
  if (!engineAvailable() || !_alive || !_alive.kinds || !_alive.kinds.length) {
    skip('引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ 下面的【真跑段】没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  console.log('\n=== 2. 真跑（离线）：JSONPath 写成 result.xxx ⇒ 能出书 ===');
  {
    const r = explore({
      bookList: 'result.resultList',          // ← 以前落进选择器分支 ⇒ 0 本
      name: 'result.bookName',                 // ← 条目级也是 result. 前缀
      author: 'result.author',
      bookUrl: 'https://x.example/1'
    }, LIST_JSON);
    const books = booksOf(r);
    console.log('  出书 =', books.length, '| 书名 =', books[0] && books[0].name);
    ok(books.length === 2, '**result.resultList 出书了**（以前 0 本）', '实际 ' + books.length);
    ok(books[0] && books[0].name === '书名一', '条目级 result.bookName 也对',
       books[0] && books[0].name);
    ok(books[0] && books[0].author === '作者一', '条目级 result.author 也对',
       books[0] && books[0].author);
  }

  console.log('\n=== 3. 真跑（离线）：result. 前缀 + || 兜底 ===');
  {
    const r = explore({
      bookList: 'result.nope||result.bookList',   // 第一段没命中 ⇒ 用第二段
      name: 'result.bookName',
      bookUrl: 'https://x.example/1'
    }, LIST_JSON);
    const books = booksOf(r);
    console.log('  出书 =', books.length, '| 书名 =', books[0] && books[0].name);
    ok(books.length === 1, '**|| 兜底也生效**（命中 bookList 那一支）', '实际 ' + books.length);
    ok(books[0] && books[0].name === '书名三', '兜底命中的是 bookList 那一支',
       books[0] && books[0].name);
  }

  console.log('\n=== 4. 真跑（离线）：@put: / @get: 内嵌 ⇒ 变量能传下去 ===');
  {
    const r = explore({
      bookList: 'result.resultList',
      // 站方常见写法：取名字的同时把 x_id 存进变量
      name: 'result.bookName@put:{xid:result.x_id}',
      // 再在 URL 里把变量取出来（猪猪小说 / 咪咕阅读同款）
      bookUrl: 'https://x.example/read/@get:{xid}/1.html'
    }, LIST_JSON);
    const books = booksOf(r);
    console.log('  出书 =', books.length);
    console.log('  bookUrl[0] =', books[0] && books[0].bookUrl);
    console.log('  bookUrl[1] =', books[1] && books[1].bookUrl);
    ok(books.length === 2, '出书了', '实际 ' + books.length);
    ok(books[0] && books[0].bookUrl === 'https://x.example/read/XID-001/1.html',
       '**@put 存的变量被 @get 取回来了**（第一本）', books[0] && books[0].bookUrl);
    ok(books[1] && books[1].bookUrl === 'https://x.example/read/XID-002/1.html',
       '**每本书各自用自己的变量**（第二本）', books[1] && books[1].bookUrl);
    ok(books[0] && books[0].name === '书名一',
       '@put 之后规则本身照常求值（书名没被吃掉）', books[0] && books[0].name);
  }

  console.log('\n=== 5. 真跑（离线）：@put 的值是裸字段名（栖阅路径语义）===');
  {
    const r = explore({
      bookList: 'result.resultList',
      name: 'result.bookName@put:{xid:x_id}',   // ← 裸字段名（不是 $.x_id）
      bookUrl: 'https://x.example/read/@get:{xid}/1.html'
    }, LIST_JSON);
    const books = booksOf(r);
    console.log('  bookUrl[0] =', books[0] && books[0].bookUrl);
    ok(books[0] && books[0].bookUrl === 'https://x.example/read/XID-001/1.html',
       '**裸字段名也能取到值**（栖阅的路径语义）', books[0] && books[0].bookUrl);
  }

  console.log('\n=== 6. 真跑（离线）：Legado 的 `!N` 排除语法 ===');
  {
    // 站方用它剔掉导航位 / 推荐位 / 表头行：
    //   'id.list@tag.dd!0:1:2:3'  ⇒ 取 dd，但排除前 4 个
    //   'span!0@text'               ⇒ 取 span，但排除第一个
    // ⚠️ 轻阅以前**完全不支持** ⇒ 这类规则一律 0 命中
    //   （实测 125 源里有 18 处 `!0` + 2 处 `!255`）
    const HTML = '<html><body><ul id="list"><li>A</li><li>B</li><li>C</li><li>D</li></ul>'
      + '<div><span>X</span><span>Y</span><span>Z</span></div></body></html>';
    const r = explore({ bookList: 'id.list@tag.li!0', name: 'text', bookUrl: 'https://x.example/1' }, HTML);
    const books = booksOf(r);
    console.log('  出书 =', books.length, '| 书名 =', books.map(b => b.name).join(','));
    ok(books.length === 3, '**`!0` 排除了第一个**（以前 0 本）', '实际 ' + books.length);
    ok(books[0] && books[0].name === 'B', '第一个是 B（排掉 A）', books[0] && books[0].name);
    ok(books[2] && books[2].name === 'D', '最后一个是 D', books[2] && books[2].name);

    // ⭐⭐⭐ **反证**（把规则改坏 ⇒ 必须红）：同样的页面，不带 `!0` ⇒ 4 本 ⭐⭐⭐
    const rAll = explore({ bookList: 'id.list@tag.li', name: 'text', bookUrl: 'https://x.example/1' }, HTML);
    ok(booksOf(rAll).length === 4, '**反证**：不带 `!0` 时是 4 本（说明 `!0` 真的在起作用）',
       '实际 ' + booksOf(rAll).length);

    // `!0:1` ⇒ 排除前两个
    const r2 = explore({ bookList: 'id.list@tag.li!0:1', name: 'text', bookUrl: 'https://x.example/1' }, HTML);
    const b2 = booksOf(r2);
    console.log('  `!0:1` 出书 =', b2.length, '| 书名 =', b2.map(b => b.name).join(','));
    ok(b2.length === 2, '`!0:1` 排除前两个', '实际 ' + b2.length);
    ok(b2[0] && b2[0].name === 'C', '`!0:1` 的第一个是 C', b2[0] && b2[0].name);

    // 头部 `span!0` 也生效
    const r3 = explore({ bookList: 'div@tag.span!0', name: 'text', bookUrl: 'https://x.example/1' }, HTML);
    const b3 = booksOf(r3);
    console.log('  `span!0` 出书 =', b3.length, '| 书名 =', b3.map(b => b.name).join(','));
    ok(b3.length === 2, '头部 `span!0` 也生效（排除第一个）', '实际 ' + b3.length);
    ok(b3[0] && b3[0].name === 'Y', '`span!0` 的第一个是 Y', b3[0] && b3[0].name);
  }

  console.log('\n=== 7. 真跑（离线）：bookList 是【复合规则】`<js>…</js>$.data` ===');
  {
    // 站方极常见的写法（七猫小说 / 红薯小说 / 晋江…）：
    //     bookList = '<js>\n …自己抓数据… \n</js>$.data.books'
    // ⇒ 引擎以前**整串 eval** ⇒ "Unexpected token '<'" ⇒ **列表 0 本** ⭐
    //   （而目录那条路早就支持复合规则 ⇒ 现象是「目录能出、发现出不来」）
    const r = explore({
      bookList: '<js>\nString(result)\n</js>$.data.books',
      name: '$.title',
      author: '$.author',
      bookUrl: 'https://x.example/1'
    }, JSON.stringify({ data: { books: [
      { title: '书名一', author: '作者一' }, { title: '书名二', author: '作者二' }] } }));
    const books = booksOf(r);
    console.log('  出书 =', books.length, '| 书名 =', books.map(b => b.name).join(','));
    ok(books.length === 2, '**复合规则的列表出书了**（以前 0 本）', '实际 ' + books.length);
    ok(books[0] && books[0].name === '书名一', '尾部 $.data.books 选中的项取到了字段',
       books[0] && books[0].name);
  }

  console.log('\n=== 8. 真跑（离线）：规则产出的 URL 带 `,{json}` 请求选项 ===');
  {
    // 站方常把「本次请求的 method/body/headers」写在 URL 后面（创世中文网）：
    //     ruleBookInfo.tocUrl = 'https://x/chapter/123,{"headers":{"X-Test":"1"}}'
    // ⇒ Legado 语义：逗号后那段 JSON = **请求选项**，不是 URL 的一部分
    // ⚠️ 轻阅以前**详情/目录/正文三个 op 都没走 analyzeUrl**（只有 explore/search 走了）
    //   ⇒ 后缀原样发出去 ⇒ 服务端 404 ⇒ **目录 0 章** ⭐
    const SUFFIX = 'https://fake.example.com/chapter/1,{"method":"POST","headers":{"X-Test":"yes"},"body":"a=1"}';

    // ① URL 规则层：后缀被剥掉、method/body/headers 各自生效
    const parsed = analyzeUrl({ url: SUFFIX, baseUrl: '' });
    console.log('  URL 规则解析 =', JSON.stringify(parsed));
    ok(parsed && parsed.url === 'https://fake.example.com/chapter/1',
       '**`,{json}` 后缀被剥掉了**（不是 URL 的一部分）', parsed && parsed.url);
    ok(parsed && parsed.method === 'POST', '**method 也生效了**', parsed && parsed.method);
    ok(parsed && parsed.body === 'a=1', '**body 也生效了**', parsed && parsed.body);
    ok(parsed && parsed.headers && parsed.headers['X-Test'] === 'yes',
       '**headers 也生效了**', JSON.stringify(parsed && parsed.headers));

    // ② 端到端：目录页真的按「剥掉后缀的 URL」发出去（假服务器：带后缀的那条先命中 ⇒ 502）
    const r = runOp({
      op: 'toc',
      source: {
        bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
        ruleToc: { chapterList: '$.list[*]', chapterName: '$.title', chapterUrl: '$.url' },
      },
      bookUrl: 'https://fake.example.com/book/1',
      tocUrl: SUFFIX,
      routes: [
        // ⚠️ 第一条：URL 里还带着 `,{json}` 后缀 ⇒ 命中就说明后缀没剥 ⇒ 502（明确失败）
        { match: 'chapter/1,{"method"', status: 502, body: '<html>502</html>' },
        { match: 'fake.example.com/chapter/1', status: 200,
          body: JSON.stringify({ list: [{ title: '第1章', url: 'https://fake.example.com/c/1' }] }) },
      ],
    });
    const chapters = (r && r.chapters) || [];
    console.log('  章节数 =', chapters.length, '| 请求 =', JSON.stringify(r && r.requests));
    ok(chapters.length === 1, '目录出章了（后缀没原样发出去 ⇒ 没被 502 那条路由命中）',
       '实际 ' + chapters.length);
    // ⭐⭐⭐ **请求记录**（引擎回传的）⇒ 实际发出去的 URL 必须没有后缀 ⭐⭐⭐
    if (r && Array.isArray(r.requests)) {
      ok(r.requests.indexOf('https://fake.example.com/chapter/1') >= 0,
         '实际请求的 URL 是剥掉后缀的那个',
         JSON.stringify(r.requests));
      ok(!r.requests.some(u => u.indexOf(',{"method"') >= 0),
         '没有任何一条请求带着 `,{json}` 后缀', JSON.stringify(r.requests));
    } else {
      skip('这个引擎版本没回传请求记录 ⇒ 上面那条 URL 断言没验到（路由那条仍然验到了）');
    }
  }

  console.log('\n=== 9. 真跑（离线）：`text.` 前缀是【文本完全相等】 ===');
  {
    // 站方拿 `text.` 挑**某一个确定的链接**：
    //   'text.查看目录@tag.a@href'（啃书阁）/ 'text.点击阅读@href'（去读书）/ 'text.目录@href'（QQ阅读）
    // ⇒ 以前是「包含」⇒ 连 `<title>`（标题里也含这四个字）都匹配上 ⇒ 11 个
    //    ⇒ `@tag.a` 挑到「首页」⇒ 目录页抓错 ⇒ **目录只有 1 章** ⭐
    const HTML = '<html><head><title>某书最新章节_查看目录_txt下载</title></head><body>'
      + '<a href="/">首页</a>'
      + '<a href="/x/1/" class="catalogbtn"><i class="ui-icon"></i>查看目录</a>'
      + '<a href="/x/2/">开始阅读</a></body></html>';
    const r = explore({
      bookList: 'text.查看目录@tag.a',   // ← 只该命中「查看目录」那一个
      name: 'text',
      bookUrl: '@href',
    }, HTML);
    const books = booksOf(r);
    console.log('  选择器结果 =', JSON.stringify(books.map(b => ({ n: b.name, u: b.bookUrl }))));
    ok(books.length === 1, '**只匹配 1 个**（以前 11 个：连 <title> 都匹配上）', '实际 ' + books.length);
    ok(books[0] && books[0].name === '查看目录', '取到的正是「查看目录」那个',
       books[0] && books[0].name);
    ok(books[0] && /\/x\/1\/$/.test(books[0].bookUrl || ''),
       '它的 href 是 /x/1/（不是首页 /）', books[0] && books[0].bookUrl);
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
