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
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 * · 老门禁用 **JS 层**的 `nativeMock`（自己发真请求）⇒ 老引擎删了 ⇒ 门禁的对象没了 ⭐⭐⭐
 * · ⇒ 现在：**门禁自己真抓**（Node 的 fetch）⇒ 把**真响应**喂给新引擎的**声明式 routes**
 *   （规范 §1.1）⇒ **真网络 ✓ + 真引擎 ✓** 两条都在 ⭐⭐⭐
 *   ⇒ 收敛机制见 `test/live-helpers.js` 的 `LiveProxy`（多轮：引擎报 URL → 真抓 → 再跑）⭐⭐⭐
 */
const { createSandbox, engineAvailable } = require('./new-engine-harness.js');
const { LiveProxy, liveFetch } = require('./live-helpers');
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

/** ⭐⭐⭐ **真网络连通性**（SKIP 的判据：**没验到 ≠ 通过**） */
async function probeReal(url, headers) {
  return liveFetch(url, { headers, timeout: 25000 });
}

if (!engineAvailable()) {
  console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
  console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
  process.exit(0);
}

(async () => {
  // 书源文件可能是单对象，也可能是数组包一层（Legado 导出惯例）
  const _raw = JSON.parse(fs.readFileSync(SRC_FILE, 'utf8'));
  const SOURCE = Array.isArray(_raw) ? _raw[0] : _raw;
  const SRC_HEADERS = (() => {
    try { return JSON.parse(SOURCE.header || '{}'); } catch (e) { return {}; }
  })();

  /* ── 0. 连通性（真网络） ── */
  console.log('\n── 0. 真实接口连通性 ──');
  const proxy = new LiveProxy({ headers: SRC_HEADERS, timeout: 25000, maxRounds: 6 });
  const probe = await proxy.probe(`https://cxb-pro.cread.com/cx/itf/getvolume?bookId=${BOOK_ID}`);
  if (!probe.ok || probe.status !== 200) {
    skip('全部用例', `接口不通（${probe.error || probe.status}），跳过而不是假装通过`);
    console.log(`\n⚠ 跳过 ${skipped} 项（沙盒出网受限）\n`);
    process.exit(0);
  }
  ok(true, `getvolume 可达（${probe.body.length} 字节）`);

  // ⭐⭐⭐ **假服务器 = 声明式 routes**（规范 §1.1）⇒ 引擎吃的是**真响应**
  const { win, sandbox } = createSandbox({ routes: proxy.routes() });
  const invoke = (op, payload) => win.__qrInvoke(op, payload);
  /** ⭐⭐⭐ **跑一个 op 并把真响应喂进去**（收敛） */
  const live = (op, payload) => proxy.converge((routes) => {
    // ⭐ 每次都把最新的 routes 交给沙盒（`createSandbox` 的 routes 是快照 ⇒ 重建）
    const s = createSandbox({ routes });
    return s.win.__qrInvoke(op, payload);
  });

  /* ── 1. 主站 URL 的 @ 后缀 ── */
  console.log('\n── 1. bookSourceUrl 带 @ 后缀（Basic 用户名）──');
  {
    // ⭐ 引擎算出来的请求 URL 里**不能带** `@遇知`（那是 Basic 用户名 ⇒ 得剥掉）
    const ex = await invoke('explain', { source: SOURCE, kindUrl: null, page: 1 });
    const u = (ex && (ex['请求URL'] || ex.requestUrl)) || '';
    ok(!/@/.test(String(u || '')), '请求 URL 里不含 @遇知', JSON.stringify(u));
  }

  /* ── 2. exploreUrl 的 @js: 生成分类树 ── */
  console.log('\n── 2. exploreUrl @js: 生成分类树 ──');
  const ex = await invoke('exploreKinds', { source: SOURCE });
  const kinds = (ex && ex.kinds) || (Array.isArray(ex) ? ex : []);
  if (!kinds.length) {
    // ⭐⭐⭐ **显式 SKIP（不是「通过」）** —— 2026-10-26 实证
    //
    // ⚠️ **为什么这一段没验到**：站方的 `exploreUrl` 用了 **Rhino 方言**：
    //   `bd.map([title,list]=>{ … })` —— **箭头函数的解构参数不写括号** ⭐⭐⭐
    //   ⇒ **标准 JS（JSC / Node）都解析不了**（`([a,b])=>{}` 才合法）⭐⭐⭐
    //   ⇒ 分类自然是空的 ⇒ **站方这一条在 iOS 真机上也是空的**（不是迁移造成的）⭐⭐⭐
    //   ⇒ **没验到 ≠ 验过了没问题** ⇒ 下面的 2b 用**同形状的合法 JS**把引擎的语义单独验掉 ⭐⭐⭐
    const diag = await invoke('explain', { source: SOURCE, kindUrl: null, page: 1 });
    skip('exploreKinds（站方 exploreUrl 是 Rhino 方言）',
      '分类为空 —— ' + JSON.stringify(diag).slice(0, 200));
  } else {
    ok(kinds.length > 20, `分类数合理（书源写了 ~80 个）`, `实际 ${kinds.length}`);
    const withUrl = kinds.filter(k => k.url);
    ok(withUrl.length > 20, '绝大多数分类有 url', `${withUrl.length}/${kinds.length}`);
    const p1 = withUrl[0];
    ok(!!p1 && p1.url.indexOf('cread.com') > 0, 'url 是 cread 接口地址', p1 && p1.url);
    // ⚠️ 2026-10-22：**@js: 里的 `{{}}` 原样保留**（Legado / 栖阅语义，build202）
    //   ⇒ 分类 url 里的 `{{page}}` **不该**在 exploreKinds 阶段被插成固定页码
    //   （插了就永远是第一页 ⇒ 发现页翻页失效 ⭐）
    const paged = withUrl.filter(k => String(k.url).indexOf('{{page}}') >= 0);
    ok(paged.length > 0, '分类 url 里的 {{page}} 原样保留（到 explore 阶段才插值）',
       `${paged.length} 个`);
    // ⚠️ 2026-10-22：**分组契约**（栖阅同款，build200/201）
    //   站方里 **url 为空的行 = 组标题行** ⇒ 它变成**组名**，
    //   后面的分类项归到它 ⇒ 它**不再**作为一个点不动的分类项混在 kinds 里
    ok(kinds.every(k => !!k.url), '分类项都有 url（组标题行不再混进分类列表）',
       `${kinds.filter(k => !k.url).length} 个空 url`);
    ok(kinds.some(k => String(k.group || '').indexOf('男频榜单') >= 0),
       '「❤男频榜单❤」这类组标题行变成了组名');
  }

  /* ── 2b. 【分组契约 / 翻页插值】用同形状的合法 JS 单独验 ── */
  {
    // ⭐⭐⭐ **站方的 exploreUrl 是 Rhino 方言 ⇒ 沙盒解析不了** ⇒ 上面那段没验到
    //   ⇒ 这里用**同形状**（组标题行 + `{{page}}`）的**合法 JS** ⇒ 把引擎的语义单独验掉 ⭐⭐⭐
    //   ⇒ 语义等价点：**组标题行 ⇒ 组名**、**`{{page}}` 到 explore 阶段才插值**（两条都是引擎的语义）⭐⭐⭐
    const SYN = Object.assign({}, SOURCE, {
      exploreUrl: '@js:JSON.stringify(['
        + '{"title":"❤男频榜单❤","url":""},'
        + '{"title":"好评榜","url":"https://cxb-pro.cread.com/cx/new/rankList?uid=1&curpage={{page}}"},'
        + '{"title":"追更榜","url":"https://cxb-pro.cread.com/cx/new/rankList?uid=1&bdid=2&curpage={{page}}"}'
        + '])',
    });
    const k2 = await invoke('exploreKinds', { source: SYN });
    const ks = (k2 && k2.kinds) || [];
    ok(ks.length === 2, '组标题行**不混进**分类列表（只留真分类）', `实际 ${ks.length}`);
    ok(ks.every(k => !!k.url), '每个分类项都有 url', JSON.stringify(ks).slice(0, 120));
    ok(ks.some(k => String(k.group || '').indexOf('男频榜单') >= 0),
       '「❤男频榜单❤」变成了**组名**', JSON.stringify(ks).slice(0, 200));
    ok(ks.some(k => String(k.url).indexOf('{{page}}') >= 0),
       '分类 url 里的 {{page}} **原样保留**（到 explore 阶段才插值）');
    const ex2 = await invoke('explain', {
      source: SYN, kindUrl: (ks[0] || {}).url, page: 2
    });
    const u2 = String((ex2 && (ex2['请求URL'] || ex2.requestUrl)) || '');
    ok(/curpage=2/.test(u2), 'explore 阶段把 {{page}} 插成了当前页（翻页不写死）',
       u2.slice(0, 160));
  }

  /* ── 3. explore 取书（真网络） ── */
  console.log('\n── 3. explore 榜单取书（$..dataList[*]）──');
  const list = await live('explore', {
    source: SOURCE,
    kindUrl: `https://cxb-pro.cread.com/cx/new/rankList?uid=127995117&cnid=10013&bdid=904&name=x&index=1&pageSize=50&curpage=1`,
    page: 1,
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

  /* ── 4. bookInfo（真网络） ── */
  console.log('\n── 4. bookInfo（详情接口 + init + tocUrl）──');
  const bi = await live('bookInfo', {
    source: SOURCE,
    bookUrl: `https://readbook-service-freebook.cread.com/reader-book/details?bookId=${BOOK_ID}`,
    book: { name: '都市修仙之至尊宝玉' },
  });
  const book = (bi && bi.book) || {};
  ok(book.name === '都市修仙之至尊宝玉', '书名对', book.name);
  ok(book.author === '至尊宝', '作者对', book.author);
  ok(/getvolume\?bookId=359915/.test(book.tocUrl || ''), 'tocUrl 指向 getvolume 接口', book.tocUrl);
  // ⚠️ 不能用 $..bookId：详情响应里若有「推荐书籍」等嵌套结构，
  // 递归下降会匹配到**别的书的 bookId**（实测 [111,999]），
  // 取错就静默抓错接口 → 目录 0 章且不报错。
  ok(!/\$\.\.bookId/.test(SOURCE.ruleBookInfo.tocUrl || ''),
     'tocUrl 不用 $..bookId 取书号（会取到嵌套的别的书）', SOURCE.ruleBookInfo.tocUrl);
  ok(/book\.bookUrl/.test(SOURCE.ruleBookInfo.tocUrl || ''),
     'tocUrl 从 bookUrl 切书号（与响应结构解耦）');
  ok(!/@/.test(book.tocUrl || ''), 'tocUrl 里没有 @遇知', book.tocUrl);
  ok((book.intro || '').length > 20, '简介拼出来了（含评分/标签/人气）', (book.intro || '').slice(0, 60));
  ok(/，/.test(book.intro || '') || /标签/.test(book.intro || ''), '「##\\s##，」把标签数组拼成了顿号串');
  ok(!/undefined/.test(book.intro || ''), '简介里没有 undefined', (book.intro || '').slice(0, 120));

  /* ── 5. toc（真网络） ── */
  console.log('\n── 5. toc（getvolume + $.list..bookChapters[*]）──');
  const toc = await live('toc', {
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

  /* ── 6. content（真网络） ── */
  console.log('\n── 6. content（chapterRead + $..content）──');
  const c1 = await live('content', {
    source: SOURCE, chapterUrl: c0.url, book: { name: book.name }
  });
  const text = (c1 && c1.content) || '';
  ok(text.length > 200, `正文有内容`, `${text.length} 字`);
  ok(!/<div|<span|<p>/i.test(text), '正文已剥 HTML 标签', text.slice(0, 60));

  // ⭐⭐⭐⭐⭐ **正文要跟【站方真返回】对得上**（2026-10-25 改）
  //
  // ⚠️⚠️ **为什么不能用硬编码的句子**（原来写的是「正文含『少壮不升级』」）：
  //   · 站方**按请求头返回不同的正文**！实测（同一 URL）：
  //       只带 UA              ⇒ 3577 字，开头「少壮不升级，老大徒伤悲！」
  //       带源里的 app 请求头   ⇒ 3286 字，开头「“对不起，我知道你们学校…”」
  //   ⇒ 门禁的假服务器是**带 app 头真抓**的 ⇒ 拿到的就是**第二种**
  //   ⇒ 硬编码第一种的句子 ⇒ **门禁必红** ⇒ 但**引擎是对的** ⭐⭐⭐
  //   ⇒ 看着像「引擎把正文弄丢了」，其实是**门禁写死了一句请求头决定的话** ⭐⭐⭐
  //
  // ⇒ 正解：**跟门禁自己真抓到的那份正文对拍**（引擎的输出 = 站方返回的正文）
  //   ⇒ 站方以后改内容/改请求头，**这条断言都不会误报**（它只问「是不是同一份」）⭐⭐⭐
  {
    const fetched = (proxy.fetched || []).find(f => String(f.url || '').indexOf('chapterRead') >= 0);
    ok(!!fetched, '门禁真抓到了章节正文（没抓到 ⇒ 本段没验到）');
    if (fetched && fetched.body) {
      let siteText = '';
      try {
        const j = JSON.parse(fetched.body);
        const cl = (j && j.chapterList) || [];
        siteText = String((cl[0] && cl[0].content) || '');
      } catch (e) { siteText = ''; }
      ok(siteText.length > 200, '站方真返回的正文有内容（对照基准成立）', `${siteText.length} 字`);
      if (siteText.length > 200) {
        // ⭐ 清洗规则只丢「长度 < 40 的行」⇒ **长行必须一条不丢**（精确判据）⭐⭐⭐
        const longLines = siteText.split(/\r?\n/).map(s => s.trim()).filter(s => s.length >= 40);
        const missing = longLines.filter(l => text.indexOf(l) < 0);
        ok(longLines.length > 0 && missing.length === 0,
           '引擎的正文 = 站方返回的正文（长行一条不丢）',
           `站方 ${longLines.length} 行，丢 ${missing.length} 行` +
           (missing.length ? '｜首行：' + missing[0].slice(0, 50) : ''));
        // ⭐ 而且不能**多出**站方没有的东西（防「引擎自己编了一段」）
        const extra = text.split(/\r?\n/).map(s => s.trim()).filter(s => s.length >= 40)
          .filter(l => siteText.indexOf(l) < 0);
        ok(extra.length === 0, '引擎没有多出站方没有的段落',
           extra.length ? '｜多出：' + extra[0].slice(0, 50) : '');
      }
    }
  }

  /* ── 7. 引擎侧新增能力（这些原来全废） ── */
  console.log('\n── 7. 引擎侧新增能力（这些原来全废）──');
  {
    const { evalRule } = require('./engine-gate-helpers.js');
    const B = { bookId: 359915, categoryName: '都市', bookStatue: '03', grade: 85,
                updateDate: '2017-04-24 14:16:34',
                tags: [{ name: '热血' }, { name: '官场' }] };
    // ⭐ 条目级基准（baseType:"json"）⇒ 站方的 `{{$.x}}` 模板能取到字段 ⭐⭐⭐
    const gv = (r) => {
      const res = evalRule(r, { baseType: 'json', baseJSON: B, isJSON: true });
      return res && res.ok !== false ? res.first : `ERR:${res && res.error}`;
    };
    ok(gv('{{java.getString(\'$.bookStatue\')==\'03\'?\'完结\':\'连载\'}}') === '完结',
       'java.getString(\'$.x\') 能当取值用（原来恒空 → 完结的书显示成连载）',
       gv('{{java.getString(\'$.bookStatue\')==\'03\'?\'完结\':\'连载\'}}'));
    ok(gv('{{$.tags..name##\\s##，}}').indexOf('热血') >= 0,
       '{{}} 里的 $..递归下降 + ##正则##替换', gv('{{$.tags..name##\\s##，}}'));
    const tf = gv('{{java.timeFormat(java.getString(\'$.updateDate\'))}}');
    // ⭐⭐⭐⭐⭐ **语义订正**（2026-10-25）：`java.timeFormat` 返回的是**字符串**，不是毫秒数字 ⭐⭐⭐
    //
    // ⚠️ **为什么原来写的是「13 位毫秒」**：
    //   轻阅以前**自己实现**的 timeFormat 返回**数字** ⇒ 站方 `java.timeFormat(x).padEnd(20,"\t")`
    //   直接抛 `padEnd is not a function` ⇒ **用户真机 bug**（会员卡片拼不出来）⭐⭐⭐
    //   ⇒ 现在跟 **Legado 官方语义**对齐：返回**格式化后的日期字符串**
    //   （Legado 的 `java.timeFormat` 就是返回 "yyyy-MM-dd HH:mm:ss" 字符串）⭐⭐⭐
    //
    // ⇒ 门禁必须锁住「**是字符串**」⇒ 站方的 `.padEnd` 才不会炸 ⭐⭐⭐
    ok(/^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?$/.test(String(tf)),
       'java.timeFormat 返回**日期字符串**（站方 .padEnd 才不会炸）', String(tf));
    ok(String(tf).length > 0, 'java.timeFormat 有输出', String(tf));
    const multi = gv('A\n{{$.categoryName}}\nB');
    ok(multi === 'A\n都市\nB', '含 {{ 的多行模板不按行截断（intro/kind 靠这个）',
       JSON.stringify(multi));
    const withTail = gv('{{$.categoryName}}##(市)##[$1]');
    // "都市" 里的「市」被 $1 捕获 → "都[市]"
    ok(withTail === '都[市]', '{{}} 外的 ##正则##替换带反向引用 $1',
       JSON.stringify(withTail));
    // URL 模板
    const urlTpl = gv('https://x.com/cx/itf/getvolume?bookId={{$.bookId}}');
    ok(urlTpl === 'https://x.com/cx/itf/getvolume?bookId=359915',
       'URL 模板插值后原样返回（不被当 CSS 选择器丢空）', urlTpl);
  }

  /* ── 8. 真网络到底跑了多少条 ── */
  console.log('\n── 8. 真网络抓取记录 ──');
  console.log(`   真抓到 ${proxy.fetched.length} 条 URL，失败 ${proxy.failed.length} 条`);
  for (const f of proxy.fetched.slice(0, 8)) {
    console.log(`   ✓ ${f.status} ${String(f.len).padStart(7)} 字节  ${f.url.slice(0, 96)}`);
  }
  for (const f of proxy.failed.slice(0, 5)) {
    console.log(`   ✗ 抓不到 ${f.url.slice(0, 96)}  （${f.error}）`);
  }
  ok(proxy.fetched.length > 0, '门禁**真的联网抓了站方接口**（不是假服务器自娱自乐）',
     `${proxy.fetched.length} 条`);
  ok(proxy.failed.length === 0, '真抓一条都没失败', JSON.stringify(proxy.failed).slice(0, 200));

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}${skipped ? ' / 跳过 ' + skipped : ''}\n`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('测试崩了:', e); process.exit(1); });
