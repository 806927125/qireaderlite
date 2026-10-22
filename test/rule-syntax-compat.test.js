#!/usr/bin/env node
/**
 * **Legado 规则语法兼容：两处引擎级缺口**（2026-10-22 适配 125 源包时挖出来的）
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
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

const root = path.join(__dirname, '..');
const RULE_SRC = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'rule-analyzer.js'), 'utf8');

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

const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    return { ok: true, code: 200, url: String(args.url || ''), headers: {}, body: LIST_JSON };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  return { ok: true, value: '' };
};

(async () => {
  console.log('=== 1. 源码：两处语法都要在引擎里有对应实现 ===');
  ok(/function rewriteResultPath/.test(RULE_SRC), '有 rewriteResultPath（result. → $）');
  ok(/result\\s\*\[\.\\[]/.test(RULE_SRC) || /result\\s\*\[/.test(RULE_SRC),
     'classify 里认 result. 前缀（当 JSONPath）');
  ok(/function evalVarExpr/.test(RULE_SRC), '有 evalVarExpr（@put 的值怎么求值）');
  ok(/@put:\\\{\(\[\^\\\]\]\*\\\)\\\}/.test(RULE_SRC) || /@put:/.test(RULE_SRC),
     'applyGetPut 处理内嵌 @put:');

  const { win } = createSandbox({ nativeMock });
  const call = (op, p) => win.eval("window.__qrInvoke('" + op + "', " + JSON.stringify(p) + ")");

  console.log('\n=== 2. 活体（离线）：JSONPath 写成 result.xxx ⇒ 能出书 ===');
  {
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: 'result.resultList',          // ← 以前落进选择器分支 ⇒ 0 本
        name: 'result.bookName',                 // ← 条目级也是 result. 前缀
        author: 'result.author',
        bookUrl: 'https://x.example/1'
      }
    };
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 书名 =', books[0] && books[0].name);
    ok(books.length === 2, '**result.resultList 出书了**（以前 0 本）', '实际 ' + books.length);
    ok(books[0] && books[0].name === '书名一', '条目级 result.bookName 也对',
     books[0] && books[0].name);
  }

  console.log('\n=== 3. 活体（离线）：result. 前缀 + || 兜底 ===');
  {
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: 'result.nope||result.bookList',   // 第一段没命中 ⇒ 用第二段
        name: 'result.bookName',
        bookUrl: 'https://x.example/1'
      }
    };
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 书名 =', books[0] && books[0].name);
    ok(books.length === 1, '**|| 兜底也生效**（命中 bookList 那一支）', '实际 ' + books.length);
  }

  console.log('\n=== 4. 活体（离线）：@put: / @get: 内嵌 ⇒ 变量能传下去 ===');
  {
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: 'result.resultList',
        // 站方常见写法：取名字的同时把 x_id 存进变量
        name: 'result.bookName@put:{xid:result.x_id}',
        // 再在 URL 里把变量取出来（猪猪小说 / 咪咕阅读同款）
        bookUrl: 'https://x.example/read/@get:{xid}/1.html'
      }
    };
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
    const books = (r && r.books) || [];
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

  console.log('\n=== 5. 活体（离线）：@put 的值是裸字段名（栖阅路径语义）===');
  {
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: 'result.resultList',
        name: 'result.bookName@put:{xid:x_id}',   // ← 裸字段名（不是 $.x_id）
        bookUrl: 'https://x.example/read/@get:{xid}/1.html'
      }
    };
    const r = await call('explore', { source: src, kindUrl: 'https://fake.example.com/list', page: 1 });
    const books = (r && r.books) || [];
    console.log('  bookUrl[0] =', books[0] && books[0].bookUrl);
    ok(books[0] && books[0].bookUrl === 'https://x.example/read/XID-001/1.html',
       '**裸字段名也能取到值**（栖阅的路径语义）', books[0] && books[0].bookUrl);
  }

  console.log('\n=== 6. 活体（离线）：Legado 的 `!N` 排除语法 ===');
  {
    // 站方用它剔掉导航位 / 推荐位 / 表头行：
    //   'id.list@tag.dd!0:1:2:3'  ⇒ 取 dd，但排除前 4 个
    //   'span!0@text'               ⇒ 取 span，但排除第一个
    // ⚠️ 轻阅以前**完全不支持** ⇒ 这类规则一律 0 命中
    //   （实测 125 源里有 18 处 `!0` + 2 处 `!255`）
    const HTML = '<html><body><ul id="list"><li>A</li><li>B</li><li>C</li><li>D</li></ul>'
      + '<div><span>X</span><span>Y</span><span>Z</span></div></body></html>';
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        bookList: 'id.list@tag.li!0',      // 排除第一个 li
        name: 'text',                      // 相对条目本身取文本
        bookUrl: 'https://x.example/1'
      }
    };
    const w2 = createSandbox({
      nativeMock: async (fn, args) => {
        if (fn === 'request') {
          return { ok: true, code: 200, url: String(args.url || ''), headers: {}, body: HTML };
        }
        if (fn === 'log' || fn === 'toast') return { ok: true };
        return { ok: true, value: '' };
      }
    });
    const r = await w2.win.eval("window.__qrInvoke('explore', " + JSON.stringify({
      source: src, kindUrl: 'https://fake.example.com/list', page: 1
    }) + ")");
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 书名 =', books.map(b => b.name).join(','));
    ok(books.length === 3, '**`!0` 排除了第一个**（以前 0 本）', '实际 ' + books.length);
    ok(books[0] && books[0].name === 'B', '第一个是 B（排掉 A）', books[0] && books[0].name);
    ok(books[2] && books[2].name === 'D', '最后一个是 D', books[2] && books[2].name);

    // 直接验选择器层：`!0:1` 要排除前两个
    const sel = await w2.win.eval(`(function(){
      var doc = QR.dom.parseHTML(${JSON.stringify(HTML)}, 'https://x');
      function t(s){ return QR.dom.selectAll(doc, s).map(function(n){ return n.textContent; }).join(','); }
      return JSON.stringify({ a: t('id.list@tag.li'), b: t('id.list@tag.li!0'),
                              c: t('id.list@tag.li!0:1'), d: t('span!0') });
    })()`);
    const s = JSON.parse(sel);
    console.log('  选择器层 =', JSON.stringify(s));
    ok(s.a === 'A,B,C,D', '不带 ! 时全选', s.a);
    ok(s.b === 'B,C,D', '`!0` 排除第一个', s.b);
    ok(s.c === 'C,D', '`!0:1` 排除前两个', s.c);
    ok(s.d === 'Y,Z', '头部 `span!0` 也生效', s.d);
  }

  console.log('\n=== 7. 活体（离线）：bookList 是【复合规则】`<js>…</js>$.data` ===');
  {
    // 站方极常见的写法（七猫小说 / 红薯小说 / 晋江…）：
    //     bookList = '<js>\n …自己抓数据… \n</js>$.data.books'
    // ⇒ 引擎以前**整串 eval** ⇒ "Unexpected token '<'" ⇒ **列表 0 本** ⭐
    //   （而目录那条路早就支持复合规则 ⇒ 现象是「目录能出、发现出不来」）
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleExplore: {
        // 站方的真实形态：JS 算出/抓来一段 JSON，尾部再取字段
        bookList: '<js>\nString(result)\n</js>$.data.books',
        name: '$.title',
        author: '$.author',
        bookUrl: 'https://x.example/1'
      }
    };
    const w3 = createSandbox({
      nativeMock: async (fn, args) => {
        if (fn === 'request') {
          return { ok: true, code: 200, url: String(args.url || ''), headers: {},
                   body: JSON.stringify({ data: { books: [
                     { title: '书名一', author: '作者一' }, { title: '书名二', author: '作者二' }] } }) };
        }
        if (fn === 'log' || fn === 'toast') return { ok: true };
        return { ok: true, value: '' };
      }
    });
    const r = await w3.win.eval("window.__qrInvoke('explore', " + JSON.stringify({
      source: src, kindUrl: 'https://fake.example.com/list', page: 1
    }) + ")");
    const books = (r && r.books) || [];
    console.log('  出书 =', books.length, '| 书名 =', books.map(b => b.name).join(','));
    ok(books.length === 2, '**复合规则的列表出书了**（以前 0 本）', '实际 ' + books.length);
    ok(books[0] && books[0].name === '书名一', '尾部 $.data.books 选中的项取到了字段',
       books[0] && books[0].name);
  }

  console.log('\n=== 8. 活体（离线）：规则产出的 URL 带 `,{json}` 请求选项 ===');
  {
    // 站方常把「本次请求的 method/body/headers」写在 URL 后面（创世中文网）：
    //     ruleBookInfo.tocUrl = 'https://x/chapter/123,{"headers":{"X-Test":"1"}}'
    // ⇒ Legado 语义：逗号后那段 JSON = **请求选项**，不是 URL 的一部分
    // ⚠️ 轻阅以前**详情/目录/正文三个 op 都没走 analyzeUrl**（只有 explore/search 走了）
    //   ⇒ 后缀原样发出去 ⇒ 服务端 404 ⇒ **目录 0 章** ⭐
    let seen = null;
    const src = {
      bookSourceUrl: 'https://fake.example.com/', bookSourceName: '假源', enabled: true,
      ruleBookInfo: {
        init: '@js: JSON.parse(String(result)).data',
        name: '$.book_name',
        // 目录 URL 带请求选项
        tocUrl: 'https://fake.example.com/chapter/1,{"method":"POST","headers":{"X-Test":"yes"},"body":"a=1"}'
      },
      ruleToc: { chapterList: '$.list[*]', chapterName: '$.title', chapterUrl: '$.url' }
    };
    const w4 = createSandbox({
      nativeMock: async (fn, args) => {
        if (fn === 'request') {
          seen = { url: String(args.url || ''), method: args.method || 'GET',
                   headers: args.headers || {}, body: args.body || '' };
          return { ok: true, code: 200, url: seen.url, headers: {},
                   body: JSON.stringify({ data: { book_name: '书名一' },
                                         list: [{ title: '第1章', url: 'https://fake.example.com/c/1' }] }) };
        }
        if (fn === 'log' || fn === 'toast') return { ok: true };
        return { ok: true, value: '' };
      }
    });
    const r = await w4.win.eval("window.__qrInvoke('toc', " + JSON.stringify({
      source: src, bookUrl: 'https://fake.example.com/book/1',
      tocUrl: 'https://fake.example.com/chapter/1,{"method":"POST","headers":{"X-Test":"yes"},"body":"a=1"}',
      book: { bookUrl: 'https://fake.example.com/book/1', name: '书名一' }, maxPages: 1
    }) + ")");
    console.log('  章节数 =', (r.chapters || []).length, '| 实际请求 =', JSON.stringify(seen));
    ok(seen && seen.url === 'https://fake.example.com/chapter/1',
       '**`,{json}` 后缀被剥掉了**（以前原样发出去 ⇒ 404）', seen && seen.url);
    ok(seen && seen.method === 'POST', '**method 也生效了**', seen && seen.method);
    ok(seen && seen.headers && seen.headers['X-Test'] === 'yes',
       '**headers 也生效了**', JSON.stringify(seen && seen.headers));
    ok((r.chapters || []).length === 1, '目录出章了', '实际 ' + (r.chapters || []).length);
  }

  console.log('\n=== 9. 活体（离线）：`text.` 前缀是【文本完全相等】 ===');
  {
    // 站方拿 `text.` 挑**某一个确定的链接**：
    //   'text.查看目录@tag.a@href'（啃书阁）/ 'text.点击阅读@href'（去读书）/ 'text.目录@href'（QQ阅读）
    // ⇒ 以前是「包含」⇒ 连 `<title>`（标题里也含这四个字）都匹配上 ⇒ 11 个
    //    ⇒ `@tag.a` 挑到「首页」⇒ 目录页抓错 ⇒ **目录只有 1 章** ⭐
    const HTML = '<html><head><title>某书最新章节_查看目录_txt下载</title></head><body>'
      + '<a href="/">首页</a>'
      + '<a href="/x/1/" class="catalogbtn"><i class="ui-icon"></i>查看目录</a>'
      + '<a href="/x/2/">开始阅读</a></body></html>';
    const w5 = createSandbox({
      nativeMock: async (fn) => {
        if (fn === 'request') return { ok: true, code: 200, url: '', headers: {}, body: HTML };
        if (fn === 'log' || fn === 'toast') return { ok: true };
        return { ok: true, value: '' };
      }
    });
    const sel = await w5.win.eval(`(function(){
      var doc = QR.dom.parseHTML(${JSON.stringify(HTML)}, 'https://x');
      var n = QR.dom.selectAll(doc, 'text.查看目录@tag.a@href');
      return JSON.stringify({ n: n.length, href: n.length ? n[0].getAttribute('href') : '' });
    })()`);
    const s = JSON.parse(sel);
    console.log('  选择器结果 =', sel);
    ok(s.n === 1, '**只匹配 1 个**（以前 11 个：连 <title> 都匹配上）', '实际 ' + s.n);
    ok(s.href === '/x/1/', '取到的正是「查看目录」那个链接', s.href);
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
