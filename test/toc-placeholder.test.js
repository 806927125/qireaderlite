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
 * ⇒ 现在：按「title == 书名 && url 是 data: 载荷」判掉，
 *         并把「原始条数 / 是否占位」回报给宿主（让提示说人话）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

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
//    解出来是：{"book_id":"NzQxNDMwODg4MTQ5NDQ1ODkwNA","sources":"番茄","tab":"小说","url":""}
const TOC_URL = 'data:;base64,eyJib29rX2lkIjoiTnpReU5ETXdPRGc0TVRRNU5EUTFPRGt3TkEiLCJzb3VyY2VzIjoi55Wq6IyEIiwidGFiIjoi5bCP6K+0IiwidXJsIjoiIn0=';

function src() {
  return Object.assign({}, bookSource, { __variables: VARS, __loginInfo: {} });
}

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 造一个「服务器只回了书自己那条占位」的引擎环境 */
function makeSandbox(catalogBody) {
  const nativeMock = async (fn, args) => {
    if (fn === 'request') {
      const url = String(args.url || '');
      if (url.indexOf('/catalog') >= 0) {
        return { ok: true, code: 200, url, headers: {}, body: catalogBody };
      }
      return { ok: true, code: 200, url, headers: {}, body: '{"code":0,"data":[]}' };
    }
    if (fn === 'log') return { ok: true };
    return { ok: true, value: '' };
  };
  return createSandbox({ nativeMock });
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

(async () => {
  console.log('=== ① 服务器只回「书自己」那条占位 ⇒ 0 章 + 标记占位 ===');
  {
    const { win } = makeSandbox(PLACEHOLDER);
    const r = await win.eval(`window.__qrInvoke('toc', ${JSON.stringify({
      source: src(),
      tocUrl: TOC_URL,
      bookUrl: TOC_URL,
      book: { name: '放开那个女巫' },
      maxPages: 1,
    })})`);
    console.log('  章节数:', (r.chapters || []).length,
      '| rawCount:', r.rawCount, '| placeholder:', r.placeholderFiltered);
    ok((r.chapters || []).length === 0, '占位不该被当成章节（实际 ' + (r.chapters || []).length + '）');
    ok(r.rawCount === 1, `原始条数应该是 1（实际 ${r.rawCount}）`);
    ok(r.placeholderFiltered === true, '标记为「过滤掉了占位」');
  }

  console.log('\n=== ② 正常章节列表 ⇒ 原样保留，不误伤 ===');
  {
    const { win } = makeSandbox(NORMAL);
    const r = await win.eval(`window.__qrInvoke('toc', ${JSON.stringify({
      source: src(),
      tocUrl: TOC_URL,
      bookUrl: TOC_URL,
      book: { name: '放开那个女巫' },
      maxPages: 1,
    })})`);
    console.log('  章节数:', (r.chapters || []).length,
      '| rawCount:', r.rawCount, '| placeholder:', r.placeholderFiltered);
    ok((r.chapters || []).length === 2, '正常的两章都留着（实际 ' + (r.chapters || []).length + '）');
    ok(r.placeholderFiltered !== true, '不该标成占位');
    ok(r.rawCount === 2, `原始条数 2（实际 ${r.rawCount}）`);
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
    const r = await win.eval(`window.__qrInvoke('toc', ${JSON.stringify({
      source: src(),
      tocUrl: TOC_URL,
      bookUrl: TOC_URL,
      book: { name: '放开那个女巫' },
      maxPages: 1,
    })})`);
    console.log('  章节数:', (r.chapters || []).length, '| placeholder:', r.placeholderFiltered);
    ok((r.chapters || []).length === 2,
       '第一章标题 == 书名时**不能**被误判成占位（实际 ' + (r.chapters || []).length + '）');
    ok(r.placeholderFiltered !== true, '不该标成占位');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
