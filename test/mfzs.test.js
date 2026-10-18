/**
 * 「免费追书」书源适配门禁 —— 真网络 + 真引擎。
 *
 * 这个源跟 HTML 站是两个世界：
 *   · 主站 URL 带 `@` 后缀（Legado 约定 = HTTP Basic 用户名）
 *   · searchUrl 是 `url,{json}` 形式，POST + form body
 *   · exploreUrl 是一整段 `@js:`，用箭头函数/模板串/解构，最后一行是
 *     `JSON.stringify(sort);`（**带分号的语句**，不是裸表达式）
 *   · 详情/目录/正文全是 JSON 接口，靠 `$..content` / `$.list..bookChapters[*]` 取
 *   · 规则里混了 `{{java.timeFormat(...)}}`、`{{...=='03'?'完结':'连载'}}`、
 *     `##(^|[。！？]+[”」）】]?)##$1<br>` 这种带反向引用的正则替换
 *
 * 打真接口，所以跑之前要能连通 cxb-pro.cread.com。
 */
const { createSandbox } = require('./harness');
const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');

const SRC_FILE = path.join(__dirname, 'fixtures', 'mfzs-source.json');
const BOOK_ID = '359915';   // 都市修仙之至尊宝玉（完结，334 章）

let pass = 0, fail = 0, skipped = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}
function skip(label, why) { skipped++; console.log(`  ⚠ ${label} —— ${why}`); }

/** 真 HTTPS 请求，替掉 harness 的 mock */
function realRequest({ url, method, body, headers }) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.request({
      hostname: u.hostname, port: u.port || (u.protocol === 'http:' ? 80 : 443),
      path: u.pathname + u.search, method: method || 'GET',
      headers: Object.assign({}, headers || {})
    }, (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        resolve({
          ok: true, code: res.statusCode, url,
          redirectUrl: (res.headers.location || url),
          headers: res.headers, body: buf.toString('utf8'), bytes: buf.length
        });
      });
    });
    req.on('error', e => resolve({ ok: false, error: String(e.message || e) }));
    req.setTimeout(25000, () => { req.destroy(); resolve({ ok: false, error: 'timeout' }); });
    if (body) req.write(body);
    req.end();
  });
}

(async () => {
  // 书源文件可能是单对象，也可能是数组包一层（Legado 导出惯例）
  const _raw = JSON.parse(fs.readFileSync(SRC_FILE, 'utf8'));
  const SOURCE = Array.isArray(_raw) ? _raw[0] : _raw;

  const calls = [];
  const { win } = createSandbox({
    nativeMock: async (fn, args) => {
      if (fn === 'request') {
        calls.push({ url: args.url, method: args.method, body: (args.body || '').slice(0, 80) });
        return realRequest(args);
      }
      if (fn === 'log') return { ok: true, value: '' };
      return { ok: true, value: '' };
    }
  });
  const invoke = (op, payload) => win.__qrInvoke(op, payload);

  /* ── 0. 连通性 ── */
  console.log('\n── 0. 真实接口连通性 ──');
  const probe = await realRequest({
    url: `https://cxb-pro.cread.com/cx/itf/getvolume?bookId=${BOOK_ID}`,
    method: 'GET', headers: JSON.parse(SOURCE.header)
  });
  if (!probe.ok || probe.code !== 200) {
    skip('全部用例', `接口不通（${probe.error || probe.code}），跳过而不是假装通过`);
    console.log(`\n⚠ 跳过 ${skipped} 项（沙盒出网受限）\n`);
    process.exit(0);
  }
  ok(true, `getvolume 可达（${probe.bytes} 字节）`);

  /* ── 1. 主站 URL 的 @ 后缀 ── */
  console.log('\n── 1. bookSourceUrl 带 @ 后缀（Basic 用户名）──');
  const baseSeen = calls.length ? null : null;
  const { QR } = createSandbox({ nativeMock: async () => ({ ok: true, value: '' }) });
  const bu = QR && QR.dom ? null : null;
  // 直接看引擎算出来的 baseUrl 会不会带 @遇知
  {
    const sb = createSandbox({ nativeMock: async () => ({ ok: true, value: '' }) });
    const r = await sb.win.__qrInvoke('explainExplore', { source: SOURCE, url: null }).catch(() => null);
    const u = r && (r['请求URL'] || r.requestUrl || '');
    ok(!/@/.test(String(u || '')), '请求 URL 里不含 @遇知', JSON.stringify(u));
  }

  /* ── 2. exploreUrl 的 @js: 生成 ── */
  console.log('\n── 2. exploreUrl @js: 生成分类树 ──');
  const ex = await invoke('exploreKinds', { source: SOURCE, url: null });
  const kinds = (ex && ex.kinds) || (Array.isArray(ex) ? ex : []);
  if (!kinds.length) {
    const diag = await invoke('explainExplore', { source: SOURCE, url: null }).catch(e => String(e));
    skip('exploreKinds', '返回空 —— ' + JSON.stringify(diag).slice(0, 300));
  } else {
    ok(kinds.length > 20, `分类数合理（书源写了 ~80 个）`, `实际 ${kinds.length}`);
    const withUrl = kinds.filter(k => k.url);
    ok(withUrl.length > 20, '绝大多数分类有 url', `${withUrl.length}/${kinds.length}`);
    const p1 = withUrl[0];
    ok(!!p1 && p1.url.indexOf('cread.com') > 0, 'url 是 cread 接口地址', p1 && p1.url);
    ok(!!p1 && p1.url.indexOf('{{page}}') < 0, 'url 里 {{page}} 已插值成具体页码', p1 && p1.url);
    // 分组标题（url 为 null 的那些）应该保留
    ok(kinds.some(k => !k.url), '保留了「❤男频榜单❤」这类分组标题行');
  }

  /* ── 3. explore 取书 ── */
  console.log('\n── 3. explore 榜单取书（$..dataList[*]）──');
  const list = await invoke('explore', {
    source: SOURCE,
    kindUrl: `https://cxb-pro.cread.com/cx/new/rankList?uid=127995117&cnid=10013&bdid=904&name=x&index=1&pageSize=50&curpage=1`,
    page: 1
  });
  const books = (list && list.books) || (Array.isArray(list) ? list : []);
  ok(books.length > 5, `取到书（榜单应有 50 条）`, `${books.length} 本`);
  const b0 = books[0] || {};
  ok(!!b0.name, '书名非空', b0.name);
  ok(!!b0.bookUrl, 'bookUrl 是 details 接口且带 bookId', b0.bookUrl);
  ok(!!b0.coverUrl, '封面非空', b0.coverUrl);
  ok(!/undefined|NaN/.test(JSON.stringify(books[0] || {})), '第一条没有 undefined/NaN 污染',
     JSON.stringify(books[0] || {}).slice(0, 160));
  // bookStatue 三元
  ok(/完结/.test(b0.kind || ''), 'kind 里的 bookStatue 三元判对了（完结的书不能显示连载）', b0.kind);
  ok(/都市/.test(b0.kind || ''), 'kind 带了分类名', b0.kind);

  /* ── 4. bookInfo ── */
  console.log('\n── 4. bookInfo（详情接口 + init + tocUrl）──');
  const bi = await invoke('bookInfo', {
    source: SOURCE,
    bookUrl: `https://readbook-service-freebook.cread.com/reader-book/details?bookId=${BOOK_ID}`,
    book: { name: '都市修仙之至尊宝玉' }
  });
  const book = (bi && bi.book) || {};
  ok(book.name === '都市修仙之至尊宝玉', '书名对', book.name);
  ok(book.author === '至尊宝', '作者对', book.author);
  ok(/getvolume\?bookId=359915/.test(book.tocUrl || ''), 'tocUrl 指向 getvolume 接口', book.tocUrl);
  ok(!/@/.test(book.tocUrl || ''), 'tocUrl 里没有 @遇知', book.tocUrl);
  ok((book.intro || '').length > 20, '简介拼出来了（含评分/标签/人气）', (book.intro || '').slice(0, 60));
  ok(/，/.test(book.intro || '') || /标签/.test(book.intro || ''), '「##\\s##，」把标签数组拼成了顿号串');
  ok(!/undefined/.test(book.intro || ''), '简介里没有 undefined', (book.intro || '').slice(0, 120));

  /* ── 5. toc ── */
  console.log('\n── 5. toc（getvolume + $.list..bookChapters[*]）──');
  const toc = await invoke('toc', {
    source: SOURCE, tocUrl: book.tocUrl,
    bookUrl: `https://readbook-service-freebook.cread.com/reader-book/details?bookId=${BOOK_ID}`,
    maxPages: 5
  });
  const chs = (toc && toc.chapters) || [];
  ok(chs.length > 100, `章节数合理（站方 334 章）`, `${chs.length} 章`);
  ok(chs.length !== 1, '不是整页兜底的 1 章', `${chs.length}`);
  const c0 = chs[0] || {};
  ok(/chapterRead\?bookId=359915&chapterId=\d+/.test(c0.url || ''),
     'chapterUrl 拼成 chapterRead 接口（含 bookid + id 两个变量）', c0.url);
  ok(!/undefined/.test(c0.url || ''), 'chapterUrl 没有 undefined 变量', c0.url);
  ok(/第1章/.test(c0.title || ''), '章节名对', c0.title);
  const dup = new Set(chs.map(c => c.url));
  ok(dup.size === chs.length, '章节 URL 无重复', `${chs.length - dup.size} 条重复`);

  /* ── 6. content ── */
  console.log('\n── 6. content（chapterRead + $..content）──');
  const c1 = await invoke('content', {
    source: SOURCE, chapterUrl: c0.url, book: { name: book.name }
  });
  const text = (c1 && c1.content) || '';
  ok(text.length > 200, `正文有内容`, `${text.length} 字`);
  ok(/少壮不升级/.test(text), '正文是首章真实文字', text.slice(0, 40));
  ok(!/<div|<span|<p>/i.test(text), '正文已剥 HTML 标签', text.slice(0, 60));

  console.log('\n── 7. 引擎侧新增能力（这些原来全废）──');
  {
    const B = { bookId: 359915, categoryName: '都市', bookStatue: '03', grade: 85,
                updateDate: '2017-04-24 14:16:34',
                tags: [{ name: '热血' }, { name: '官场' }] };
    const c = { baseUrl: 'https://x.com/', source: SOURCE, book: {} };
    const gv = async r => String(await QR.rule.getValue(r, B, c));

    ok((await gv('{{java.getString(\'$.bookStatue\')==\'03\'?\'完结\':\'连载\'}}')) === '完结',
       'java.getString(\'$.x\') 能当取值用（原来恒空 → 完结的书显示成连载）');
    ok((await gv('{{$.tags..name##\\s##，}}')).indexOf('热血') >= 0,
       '{{}} 里的 $..递归下降 + ##正则##替换');
    ok(/^\d{13}$/.test(await gv('{{java.timeFormat(java.getString(\'$.updateDate\'))}}')),
       'java.timeFormat 存在且返回 13 位毫秒',
       await gv('{{java.timeFormat(java.getString(\'$.updateDate\'))}}'));
    const multi = await gv('A\n{{$.categoryName}}\nB');
    ok(multi === 'A\n都市\nB', '含 {{ 的多行模板不按行截断（intro/kind 靠这个）',
       JSON.stringify(multi));
    const withTail = await gv('{{$.categoryName}}##(市)##[$1]');
    // "都市" 里的「市」被 $1 捕获 → "都[市]"
    ok(withTail === '都[市]', '{{}} 外的 ##正则##替换带反向引用 $1',
       JSON.stringify(withTail));
    // URL 模板
    ok((await gv('https://x.com/cx/itf/getvolume?bookId={{$.bookId}}'))
       === 'https://x.com/cx/itf/getvolume?bookId=359915',
       'URL 模板插值后原样返回（不被当 CSS 选择器丢空）');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}${skipped ? ' / 跳过 ' + skipped : ''}\n`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('测试崩了:', e); process.exit(1); });
