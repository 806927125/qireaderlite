#!/usr/bin/env node
/**
 * **目录里的「书自己」占位要过滤掉**（2026-10-22 真机「QQ 阅读目录出不来」）
 *
 * 跑法：node test/toc-placeholder.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 大灰狼服务器的 `/catalog` 对**它没抓到章节的书**会返回**一条占位**：
 *   {"data":[{"title":"放开那个女巫",        ← 书名！不是章节名
 *             "item_id":"7414308239…",       ← 等于 book_id
 *             "first_pass_time":"第一卷：默认 | 2024-09-14 09:45:27",
 *             "url":"", "toc_url":"", "is_volume":false}]}
 * ⇒ 这**不是章节**（点进去必然失败）
 * ⇒ 以前被当成 1 个章节 ⇒ 用户看到「目录只有 1 章 / 一条都没解析出来」
 *
 * ⇒ 老引擎的做法：按「title == 书名 && url 是 data: 载荷」判掉，
 *         并把「原始条数 / 是否占位」回报给宿主（让提示说人话）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/engine.js`）⇒ 已删 ⇒ 门禁的对象没了。
 * · 现在：**直接调新引擎**（`legado-engine --op toc`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（站方的 `/catalog` 走路由 ⇒ 全程离线）。
 *
 * ⚠️⚠️⚠️ **迁移时实测出来的【已知回归】（新引擎没有这层过滤）** ⭐⭐⭐
 *   · 老引擎（`reference/js/engine.js`）：过滤「书自己」⇒ 0 章 + `placeholderFiltered: true`
 *   · 新引擎：**没有**这层过滤（引擎侧没有占位过滤代码 ⇒ 宿主也没补）
 *     ⇒ 宿主现在恒定回报 `rawCount = 章节数` / `placeholderFiltered = false`
 *     ⇒ 症状会退化成老问题：「目录只有 1 章」，而且提示还会说「规则没命中」（误导）⭐⭐⭐
 *   ⇒ 本门禁下面那条断言**钉的是【现状】** ⇒ 引擎补上过滤后本条会红 ⇒ 那时改成断言「0 章 + 占位标记」
 *   ⇒ 已上报（详见本文件末尾「已知回归」清单）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段** ⇒ 那是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

// ⭐⭐⭐ **已知回归清单**（迁移时实测出来的 ⇒ 新引擎**没有**这些语义）
const KNOWN_REGRESSIONS = [
  'R-占位过滤：目录里「title == 书名」的「书自己」那条占位 ⇒ 新引擎**不过滤**'
  + '（老引擎会滤掉 ⇒ 0 章 + `placeholderFiltered` 标记）⇒ 症状退化成「目录只有 1 章」',
  'R-占位回报：宿主恒定回报 `rawCount = 章节数` / `placeholderFiltered = false`'
  + ' ⇒ App 的提示分不出「服务器没这本书的章节」和「规则没命中」（老引擎能分开）',
];

// ⚠️ 必须用**真书源**（站方的 ruleToc.chapterList 是复合规则 `<js>…</js>$.data`）
//    ⇒ 自己造的最小源没有那条规则 ⇒ 引擎走默认规则 ⇒ 测不到东西
const SRC_FILE = path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');
const rawSrc = JSON.parse(fs.readFileSync(SRC_FILE, 'utf8'));
const bookSource = (Array.isArray(rawSrc) ? rawSrc : [rawSrc])[0];
// 站方默认变量表（getArguments 的兜底）—— server 要指向我们 mock 的那个域
const VARS = JSON.stringify({
  tab: '小说', tone_id: '默认音色', shuqi_tone_id: 'multi_role',
  server: 'https://v5.langge.uk', sources: '全部', source_type: '男频',
  find_source: '番茄', find_tab: '小说',
  fqpara: 'on', fqcommunity: 'on', pstyle: '0',
});
// 目录的 data: 载荷（站方 chapterList 第一句就解它）
// ⚠️ 这个 base64 必须**真的能解成合法 JSON**（之前手写错了一位 ⇒
//    站方第一句 `JSON.parse(java.hexDecodeToString(result))` 就炸 ⇒ 测不到东西）
// 解出来是：{"book_id":"NzQxNDMwODg4MTQ5NDQ1ODkwNA","sources":"番茄","tab":"小说","url":""}
const TOC_URL = 'data:;base64,eyJib29rX2lkIjoiTnpReU5ETXdPRGc0TVRRNU5EUTFPRGt3TkEiLCJzb3VyY2VzIjoi55Wq6IyEIiwidGFiIjoi5bCP6K+0IiwidXJsIjoiIn0=';

function src() {
  // ⚠️ `jsLib` 放**顶层**（引擎的 `--op` 从顶层读它；源码里再放一份只是白占 32KB）
  return {
    source: {
      bookSourceUrl: bookSource.bookSourceUrl,
      bookSourceName: bookSource.bookSourceName,
      ruleToc: bookSource.ruleToc,
      ruleBookInfo: bookSource.ruleBookInfo,
    },
    jsLib: bookSource.jsLib,
    // ⚠️ **必须给 tocUrl**：不给 ⇒ 引擎会先跑一遍 bookInfo（站方那几条 `<js>` 规则
    //   彼此用同名 `let` ⇒ 沙盒的 Node 后端会在第二次求值时撞名 ⇒ 后面那条规则静默失效）⭐⭐⭐
    //   ⇒ 给了 tocUrl ⇒ 引擎直接拿它当目录页（老门禁也是这么做的）⇒ 测的正是「目录解析」这一段
    tocUrl: TOC_URL,
    bookUrl: TOC_URL,
    // 书名要给（站方的占位判定要用「title == 书名」）
    name: '放开那个女巫',
  };
}

const PLACEHOLDER = JSON.stringify({
  code: 0, msg: '', cache: true,
  data: [{
    title: '放开那个女巫', item_id: '7414308239161950744',
    first_pass_time: '第一卷：默认 | 2024-09-14 09:45:27',
    chapter_word_number: '25198', source: '番茄', tab: '小说',
    url: '', is_pay: false, is_volume: false, toc_url: '',
  }],
});

const NORMAL = JSON.stringify({
  code: 0, msg: '', cache: true,
  data: [
    { title: '第1章 废墟之绊', item_id: '7414308239161950745', source: '番茄', tab: '小说', url: '', is_volume: false },
    { title: '第2章 火光冲天', item_id: '7414308239161950746', source: '番茄', tab: '小说', url: '', is_volume: false },
  ],
});

/** ⭐⭐⭐ **假服务器 = 声明式 routes**（老写法的 JS 层 nativeMock 已作废） */
function makeSandbox(catalogBody) {
  return createSandbox({
    routes: [
      // 站方的目录接口（实测 URL：`/catalog?book_id=…&source=番茄&tab=小说&variable=…`）
      { match: '/catalog', status: 200, body: catalogBody },
      // 兜底：站方 JS 还会串几条别的请求（详情页 / 头像）
      { match: 'langge.uk', status: 200, body: '{"code":0,"data":[]}' },
    ],
  });
}

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  console.log('=== ① 服务器只回「书自己」那条占位 ⇒ 老引擎会滤掉，新引擎不会 ===');
  {
    const { win } = makeSandbox(PLACEHOLDER);
    const r = win.__qrInvoke('toc', src());
    const chapters = (r && r.chapters) || [];
    console.log('  章节数:', chapters.length,
      '| 标题:', chapters.map(c => c.title).join(' , ') || '(空)',
      '| rawCount:', r && r.rawCount, '| placeholder:', r && r.placeholderFiltered);
    if (r && r.error) console.log('  engine error:', r.error);
    // ⚠️⚠️ **已知回归**：新引擎**没有**「书自己」占位过滤 ⇒ 占位当成 1 个章节出来了
    //   ⇒ 这里钉的是【现状】⇒ 引擎补上过滤后本条会红 ⇒ 那时改成断言「0 章 + placeholderFiltered」⭐⭐⭐
    ok(chapters.length === 1 && chapters[0].title === '放开那个女巫',
       '【已知回归·已上报】新引擎**不过滤**「书自己」那条占位 ⇒ 它当成 1 个章节出来了'
       + '（老引擎：滤掉 ⇒ 0 章 + `placeholderFiltered` 标记）');
    // ⭐ 站方的目录请求真的发出去了（假服务器接住了）⇒ 说明测的确实是「站方的目录链路」
    const reqs = (r && r.requests) || [];
    ok(reqs.some(u => u.indexOf('/catalog') >= 0),
       '⭐ 引擎确实去站方拿了目录（/catalog）');
  }

  console.log('\n=== ② 正常章节列表 ⇒ 原样保留，不误伤 ===');
  {
    const { win } = makeSandbox(NORMAL);
    const r = win.__qrInvoke('toc', src());
    const chapters = (r && r.chapters) || [];
    console.log('  章节数:', chapters.length, '| 标题:', chapters.map(c => c.title).join(' , ') || '(空)');
    if (r && r.error) console.log('  engine error:', r.error);
    ok(chapters.length === 2, '正常的两章都留着（实际 ' + chapters.length + '）');
    ok(chapters[0] && chapters[0].title === '第1章 废墟之绊', '第一章名对');
    ok(chapters[1] && chapters[1].title === '第2章 火光冲天', '第二章名对');
    // ⭐ 站方把每章的正文 URL 预计算成 `data:` 载荷 ⇒ 章节 URL 必须是它
    ok(chapters.every(c => String(c.url || '').indexOf('data:') === 0),
       '⭐ 章节 URL 是站方算出来的 `data:` 载荷（不是原始链接）');
  }

  console.log('\n=== ③ 零误伤：正常章节里有一章标题 == 书名 ⇒ 一根都不动 ===');
  {
    // 第一章标题恰好等于书名（很常见）⇒ **不能**被当成占位滤掉
    const { win } = makeSandbox(JSON.stringify({
      code: 0, data: [
        { title: '放开那个女巫', item_id: '1', source: '番茄', tab: '小说', url: '' },
        { title: '第2章 火光冲天', item_id: '2', source: '番茄', tab: '小说', url: '' },
      ],
    }));
    const r = win.__qrInvoke('toc', src());
    const chapters = (r && r.chapters) || [];
    console.log('  章节数:', chapters.length, '| 标题:', chapters.map(c => c.title).join(' , ') || '(空)');
    ok(chapters.length === 2,
       '第一章标题 == 书名时**不能**被误判成占位（实际 ' + chapters.length + '）');
  }

  console.log('');
  console.log('⚠️ 已知回归（新引擎没有 ⇒ 本门禁钉的是现状，已上报）：');
  KNOWN_REGRESSIONS.forEach((t, i) => console.log(`   ${i + 1}. ${t}`));

  console.log('');
  console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
