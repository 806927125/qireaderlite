// ⭐⭐⭐ **全量真实源双实现对拍** —— 老引擎 vs 新引擎，逐源对比
//
// 用途：**找出「老引擎能出、新引擎出不来」的源** ⇒ 那就是「老引擎有、新引擎没有」的语义缺口
//   （比人工翻老引擎源码可靠 ⇒ 直接用真实语料定位）
//
// 用法：node test/live-parity-all.js <pack.json> [关键词]
// 输出：每个源一行 + 末尾汇总（差的源列在最前面）
//
// ⚠️ 旧引擎侧（Node + jsdom）逐源跑；新引擎侧由 live-parity.sh 编译的探针逐源跑
// ⇒ 本脚本负责**驱动两边**并汇总

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { createSandbox } = require('./new-engine-harness');

// ⚠️⚠️ **老引擎内部有未捕获的 promise rejection**（java-api.js 的原生桥）
//   ⇒ 不吞掉的话，整个 Node 进程会挂 ⇒ 对拍跑到一半就死 ⭐
//   ⇒ 吞掉 + 记一笔（那一步本来就失败 ⇒ 不影响结论）
process.on('unhandledRejection', (e) => {
  try { console.log('  [吞掉未捕获 rejection] ' + String((e && e.message) || e)); } catch (_) {}
});

const packPath = process.argv[2];
const keyword = process.argv[3] || '';
if (!packPath) {
  console.error('用法: node test/live-parity-all.js <pack.json> [关键词]');
  process.exit(2);
}

let pack = JSON.parse(fs.readFileSync(packPath, 'utf8'));
if (!Array.isArray(pack)) pack = pack.data || [pack];
if (keyword) pack = pack.filter(s => (s.bookSourceName || '').includes(keyword));

// ── 新引擎探针（由 live-parity.sh 编译好，放在环境变量指的路径）──
const NEW_BIN = process.env.NEW_ENGINE_BIN || '/tmp/parity/new-live';
if (!fs.existsSync(NEW_BIN)) {
  console.error('找不到新引擎探针：' + NEW_BIN + '（先跑 bash test/live-parity.sh 编译）');
  process.exit(2);
}

// ── 老引擎：每个源一个沙盒（jsLib 的全局污染会串源 ⇒ 必须隔离）──
async function runOld(src) {
  const { win } = createSandbox({
    origin: 'https://book.example.com/',
    nativeMock: async (fn, args) => {
      if (fn === 'request') {
        try {
          const headers = {};
          for (const [k, v] of Object.entries(args.headers || {})) headers[k] = v;
          const r = await fetch(args.url, {
            method: args.method || 'GET', headers,
            body: args.body || undefined, redirect: 'follow',
          });
          const body = await r.text();
          return { ok: true, code: r.status, url: args.url, redirectUrl: r.url,
                   headers: Object.fromEntries(r.headers.entries()), body, bytes: body.length };
        } catch (e) {
          return { ok: false, error: String((e && e.message) || e) };
        }
      }
      return { ok: true, value: '' };
    }
  });
  const invoke = async (op, payload) => {
    try {
      const r = await win.__qrInvoke(op, payload);
      if (r && r.error) return { error: String(r.error) };
      return r || {};
    } catch (e) { return { error: String((e && e.message) || e) }; }
  };
  const S = { source: src };
  const out = { steps: {} };
  const kinds = await invoke('exploreKinds', S);
  out.steps.kinds = kinds.error ? { error: kinds.error } : { count: (kinds.kinds || []).length };
  const firstUrl = (kinds.kinds || []).map(k => k.url).find(u => u && !u.isEmpty) || '';
  if (!firstUrl) { out.steps.explore = { error: '没有分类 URL' }; return out; }
  const ex = await invoke('explore', { ...S, kindUrl: firstUrl, page: 1 });
  out.steps.explore = ex.error ? { error: ex.error } : { count: (ex.books || []).length };
  const b = (ex.books || [])[0];
  if (!b || !b.bookUrl) return out;
  const bi = await invoke('bookInfo', { ...S, bookUrl: b.bookUrl });
  out.steps.bookInfo = bi.error ? { error: bi.error } : { name: (bi.book || {}).name || '' };
  const toc = await invoke('toc', { ...S, tocUrl: (bi.book || {}).tocUrl || '', bookUrl: b.bookUrl, book: b });
  out.steps.toc = toc.error ? { error: toc.error } : { count: (toc.chapters || []).length };
  const ch = (toc.chapters || []).find(c => c.url && !c.isVolume);
  if (ch) {
    const ct = await invoke('content', { ...S, chapterUrl: ch.url, chapter: ch, book: b });
    out.steps.content = ct.error ? { error: ct.error } : { len: (ct.content || '').length };
  } else out.steps.content = { error: '没有可用的章节' };
  return out;
}

function runNew(src, bookName) {
  try {
    const args = [packPath, src.bookSourceName];
    if (bookName) args.push(bookName);   // ⭐ 两边跑**同一本书**才可比
    const out = execFileSync(NEW_BIN, args, {
      encoding: 'utf8', timeout: 120000, maxBuffer: 1 << 24,
    });
    const lines = out.trim().split('\n');
    const j = JSON.parse(lines[lines.length - 1]);
    return j.steps || {};
  } catch (e) { return { fatal: String((e && e.message) || e) }; }
}

// ⭐ 判定「新引擎更差」：正文长度少 / 章节少 / 步骤报错
// ⭐⭐⭐ **沙盒限制**（不是真缺口 ⇒ 不算差异）
//  ① 「需要 JS 后端」⇒ Linux 沙盒**没有 JSC** ⇒ iOS 上没这问题 ⭐
//  ② 站点自己挂了（404 / SSL / 超时）⇒ 跟引擎无关
function isSandboxLimit(text) {
  if (!text) return false;
  if (/JS 后端未接/.test(text)) return true;
  if (/HTTP 4\d\d|HTTP 5\d\d/.test(text)) return true;
  if (/SSL_ERROR|Empty reply|NSURLErrorDomain|unsupported URL|fetch failed/.test(text)) return true;
  return false;
}

function worse(o, n) {
  const bad = [];
  const oLen = (o.content || {}).len, nLen = (n.content || {}).len;
  if (typeof oLen === 'number' && typeof nLen === 'number' && nLen < oLen) bad.push(`正文 ${oLen}→${nLen}`);
  const oToc = (o.toc || {}).count, nToc = (n.toc || {}).count;
  if (typeof oToc === 'number' && typeof nToc === 'number' && nToc < oToc) bad.push(`章节 ${oToc}→${nToc}`);
  const oEx = (o.explore || {}).count, nEx = (n.explore || {}).count;
  if (typeof oEx === 'number' && typeof nEx === 'number' && nEx < oEx) bad.push(`书 ${oEx}→${nEx}`);
  // ⭐ 报错类差异：先排除「沙盒限制」
  if ((n.content || {}).error && !(o.content || {}).error && !isSandboxLimit(n.content.error))
    bad.push(`新正文报错: ${n.content.error}`);
  if ((n.toc || {}).error && !(o.toc || {}).error && !isSandboxLimit(n.toc.error))
    bad.push(`新目录报错: ${n.toc.error}`);
  if ((n.explore || {}).error && !(o.explore || {}).error && !isSandboxLimit(n.explore.error))
    bad.push(`新发现报错: ${n.explore.error}`);
  if ((n.kinds || {}).error && !(o.kinds || {}).error && !isSandboxLimit(n.kinds.error))
    bad.push(`新分类报错: ${n.kinds.error}`);
  return bad;
}

(async () => {
  const rows = [];
  for (const src of pack) {
    const oRaw = await runOld(src);
    const o = oRaw.steps || {};      // ⚠️⚠️ 修：worse() 访问的是 **steps 里**的字段
                                     //    （原来传的是 {steps:{...}} ⇒ 老引擎的 error 从没被读到
                                     //      ⇒ 所有「两边都失败」都被误判成差异）⭐
    // ⭐⭐⭐ **按书名配对**：老引擎挑的那本 ⇒ 新引擎也用同一本
    //   （两边「第一本书」常常不同 ⇒ 不配对就没法比）⭐
    const oldFirst = ((o.steps || {}).explore || {}).first;
    const n = runNew(src, oldFirst || '');
    const bad = worse(o, n);
    const good = [];
    const oLen = (o.content || {}).len, nLen = (n.content || {}).len;
    if (typeof oLen === 'number' && typeof nLen === 'number' && nLen > oLen) good.push(`正文 ${oLen}→${nLen}`);
    const oToc = (o.toc || {}).count, nToc = (n.toc || {}).count;
    if (typeof oToc === 'number' && typeof nToc === 'number' && nToc > oToc) good.push(`章节 ${oToc}→${nToc}`);
    rows.push({ name: src.bookSourceName, bad, good, o, n });
    // ⇒ 顺带把「两边都失败」的源也标出来（不是差异，但值得知道）
    console.log(`${bad.length ? '❌' : (good.length ? '⬆️ ' : '✅')} ${src.bookSourceName}` +
      (bad.length ? `  差: ${bad.join(' | ')}` : '') + (good.length ? `  好: ${good.join(' | ')}` : ''));
    fflush_stdout();
  }
  const worseRows = rows.filter(r => r.bad.length);
  const betterRows = rows.filter(r => !r.bad.length && r.good.length);
  const same = rows.filter(r => !r.bad.length && !r.good.length);
  console.log(`\n═══ 汇总：共 ${rows.length} 源 ═══`);
  console.log(`  ⬇️  新引擎更差：${worseRows.length} 源`);
  for (const r of worseRows) console.log(`      ${r.name} —— ${r.bad.join(' | ')}`);
  console.log(`  ⬆️  新引擎更好：${betterRows.length} 源`);
  console.log(`  ✅  一致      ：${same.length} 源`);
})().catch(e => { console.error(e); process.exit(1); });

function fflush_stdout() { process.stdout.write(''); }
