// ⭐⭐⭐ **老引擎（Node）跑真实源** —— 用来跟新引擎做「真实源双实现对拍」
//
// ⚠️ 为什么要有它：
//   132 条 fixture 对拍验的是「零件」⇒ 而「老引擎有的、新引擎没有的语义」
//   往往藏在**真实源的整体链路**里（分类 → 书 → 目录 → 正文 的某一步）
//   ⇒ 同一个源、同一套规则，两边各跑一遍 ⇒ **数字不一样的地方就是差异**⭐
//
// 用法：node test/old-engine-live.js <书源包.json> [源名关键字]
// 输出：一行 JSON（分类数 / 书数 / 首本名 / 章节数 / 正文字数 / 每步错误）
//
// ⚠️ 原生请求走**真网络**（node fetch）⇒ 跟真机同条件

const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const packPath = process.argv[2];
const keyword = process.argv[3] || '';
if (!packPath) {
  console.error('用法: node test/old-engine-live.js <pack.json> [源名关键字]');
  process.exit(2);
}
let pack = JSON.parse(fs.readFileSync(packPath, 'utf8'));
if (!Array.isArray(pack)) pack = pack.data || [pack];
const src = pack.find(s => (s.bookSourceName || '').includes(keyword)) || pack[0];
if (!src) { console.error('没找到源'); process.exit(2); }

const requests = [];
const { win: window } = createSandbox({
  origin: 'https://book.example.com/',
  nativeMock: async (fn, args) => {
    if (fn === 'request') {
      requests.push(args.url);
      try {
        const headers = {};
        for (const [k, v] of Object.entries(args.headers || {})) headers[k] = v;
        const r = await fetch(args.url, {
          method: args.method || 'GET',
          headers,
          body: args.body || undefined,
          redirect: 'follow',
        });
        const body = await r.text();
        return {
          ok: true, code: r.status, url: args.url, redirectUrl: r.url,
          headers: Object.fromEntries(r.headers.entries()),
          body, bytes: body.length,
        };
      } catch (e) {
        return { ok: false, error: String((e && e.message) || e) };
      }
    }
    return { ok: true, value: '' };
  }
});

const invoke = async (op, payload) => {
  try {
    const r = await window.__qrInvoke(op, payload);
    if (r && r.error) return { error: String(r.error) };
    return r || {};
  } catch (e) {
    return { error: String((e && e.message) || e) };
  }
};

(async () => {
  const out = { source: src.bookSourceName, steps: {} };
  const S = { source: src };

  // ① 分类
  const kinds = await invoke('exploreKinds', S);
  out.steps.kinds = kinds.error ? { error: kinds.error }
    : { count: (kinds.kinds || []).length, filters: (kinds.filters || []).length };
  const firstUrl = (kinds.kinds || []).map(k => k.url).find(u => u && !u.isEmpty) || '';

  // ② 发现
  if (firstUrl) {
    const ex = await invoke('explore', { ...S, kindUrl: firstUrl, page: 1 });
    out.steps.explore = ex.error ? { error: ex.error }
      : { count: (ex.books || []).length, first: (ex.books || [])[0] ? (ex.books[0].name || '') : '' };
    const b = (ex.books || [])[0];
    if (b && b.bookUrl) {
      // ③ 详情
      const bi = await invoke('bookInfo', { ...S, bookUrl: b.bookUrl });
      out.steps.bookInfo = bi.error ? { error: bi.error }
        : { name: (bi.book || {}).name || '', author: (bi.book || {}).author || '' };
      // ④ 目录
      const toc = await invoke('toc', { ...S, tocUrl: (bi.book || {}).tocUrl || '', bookUrl: b.bookUrl, book: b });
      out.steps.toc = toc.error ? { error: toc.error }
        : { count: (toc.chapters || []).length, first: (toc.chapters || [])[0] ? (toc.chapters[0].title || '') : '' };
      const ch = (toc.chapters || []).find(c => c.url && !c.isVolume);
      // ⑤ 正文
      if (ch) {
        const ct = await invoke('content', { ...S, chapterUrl: ch.url, chapter: ch, book: b });
        out.steps.content = ct.error ? { error: ct.error }
          : { len: (ct.content || '').length };
      } else {
        out.steps.content = { error: '没有可用的章节' };
      }
    }
  } else {
    out.steps.explore = { error: '没有分类 URL' };
  }
  out.requests = requests.length;
  console.log(JSON.stringify(out));
})().catch(e => {
  console.log(JSON.stringify({ source: src.bookSourceName, steps: {}, fatal: String((e && e.message) || e) }));
});
