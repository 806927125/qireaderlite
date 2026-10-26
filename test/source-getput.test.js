#!/usr/bin/env node
/**
 * **`source.get(key)` / `source.put(key, value)` 要存在**（2026-10-22 真机「解锁了但发现页空白」）
 *
 * 跑法：node test/source-getput.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 现象（用户真机截图）
 *
 *   NovelHub 聚合小说 → 发现页 → **「这个书源没解析出分类」**
 *   用户：「这。。解锁了的」（⇒ 解锁动作**显示成功**了，但分类一个都没有）
 *
 * 根因
 *
 *   站方（🍒NovelHub）大量用 `source.get(key)` / `source.put(key, value)`
 *   （实测 jsLib + loginUrl 共 **71 处 get / 58 处 put**）：
 *     jsLib   ：source.get("nhAuthed") / source.put("nhAuthed", hash)
 *     loginUrl：source.get("mgck")      / source.put("mgck", ck)
 *
 *   轻阅以前**只实现了 `getVariable` / `setVariable`**（整份 JSON 串）
 *   ⇒ `source.get(...)` ⇒ **TypeError: not a function**
 *   ⇒ 站方把它包在 try/catch 里 ⇒ **静默失败**：
 *      ① `nhAuth()` 里 `source.get("nhAuthed")` 抛 ⇒ catch ⇒ return false
 *         ⇒ **所有规则字段都直接 return ""** ⇒ 发现页空白 ⭐
 *      ② `unlockAll()` 里 `source.put("nhAuthed", hash)` 抛 ⇒ 被吞
 *         ⇒ **解锁状态压根没存下来** ⇒ 但站方照样弹「🔓 已解锁」⇒ **假成功** ⭐
 *
 * 修法（source-api.js）
 *
 *   `source.get(key)`  → 读「书籍变量」里的某一项（没有 ⇒ 空串）
 *   `source.put(k, v)`  → 写某一项 ⇒ 标 dirty ⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘
 *
 *   ⚠️ **不能实现成「返回整份 vars」** —— 站方是
 *      `String(source.get("nhAuthed") || "")` 这样比对的，
 *      拿到整份 JSON 的话哈希对不上 ⇒ 还是不解锁。
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

const root = path.join(__dirname, '..');
const apiSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'source-api.js'), 'utf8');

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
const PWD = 'nhub2026';
const PWD_HASH = crypto.createHash('md5').update(PWD).digest('hex');

const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    const url = String(args.url || '');
    const method = (args.method || 'GET').toUpperCase();
    try {
      const res = await fetch(url, {
        method,
        headers: Object.assign({ 'User-Agent': UA }, args.headers || {}),
        body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
        redirect: 'follow',
      });
      return { ok: true, code: res.status, url, headers: {}, body: await res.text() };
    } catch (e) { return { ok: false, error: String(e.message) }; }
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  if (fn === 'deviceID') return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
  if (fn === 'getWebViewUA') return { ok: true, value: UA };
  if (fn === 'md5Encode') {
    return { ok: true, value: crypto.createHash('md5').update(String(args.text || args.str || '')).digest('hex') };
  }
  return { ok: true, value: '' };
};

(async () => {
console.log('=== 1. 源码：source.get / source.put 要存在 ===');
ok(/wrapped\.get\s*=\s*function/.test(apiSrc), 'source-api.js 里有 wrapped.get');
ok(/wrapped\.put\s*=\s*function/.test(apiSrc), 'source-api.js 里有 wrapped.put');
ok(/wrapped\.getVariable/.test(apiSrc) && /wrapped\.setVariable/.test(apiSrc),
   '原来的 getVariable/setVariable 还在（不能破）');

const { win } = createSandbox({ nativeMock });

console.log('\n=== 2. 语义：get 取单项、put 写单项、put 完能落盘 ===');
const sem = JSON.parse(await win.eval(`(function () {
  var s = window.QR.wrapSource({ __variables: JSON.stringify({ a: '1', b: '2' }) });
  var gotA = s.get('a');
  var gotMissing = s.get('zz');
  var whole = s.getVariable();
  s.put('c', '3');
  return JSON.stringify({
    gotA: gotA, gotMissing: gotMissing, whole: whole,
    afterPut: s.getVariable(), getC: s.get('c'),
    dirty: (window.QR.__qrDirtyVars || '')
  });
})()`));
ok(sem.gotA === '1', "get('a') 返回单项的值", '实际 ' + JSON.stringify(sem.gotA));
ok(sem.gotMissing === '', "get('zz')（没有的项）返回空串", '实际 ' + JSON.stringify(sem.gotMissing));
ok(sem.whole && sem.whole.indexOf('"a"') >= 0, 'getVariable() 仍返回整份 JSON');
ok(sem.afterPut && sem.afterPut.indexOf('"c":"3"') >= 0,
   "put('c','3') 写进了整份 JSON", '实际 ' + sem.afterPut);
ok(sem.getC === '3', "put 之后 get('c') 能读回来");
ok(sem.dirty && sem.dirty.indexOf('"c":"3"') >= 0,
   'put 标了 dirty（QR.__qrDirtyVars）⇒ 引擎会回传 __sourceVars', '实际 ' + sem.dirty);

console.log('\n=== 3. 活体端到端：解锁 → 落盘 → 分类出来 ===');
const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
if (!fs.existsSync(NH)) {
  console.log('  (跳过：本地没有 NovelHub 源文件)');
} else {
  const src = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];

  // ① 未解锁 ⇒ 站方 nhAuth() 恒 false ⇒ 分类 0（= 用户截图的现象）
  const before = await win.eval("window.__qrInvoke('exploreKinds', " + JSON.stringify({
    source: Object.assign({}, src, { __variables: '', __loginInfo: {} }),
    cookieSnapshot: {},
  }) + ")");
  const beforeKinds = (before && before.kinds) || [];
  console.log('  未解锁时 kinds =', beforeKinds.length);
  ok(beforeKinds.length === 0, '未解锁 ⇒ 分类 0（复现真机现象）');

  // ② 点「解锁整个源」⇒ 站方 unlockAll() 里 source.put("nhAuthed", hash)
  const lgin = await win.eval("window.__qrInvoke('login', " + JSON.stringify({
    source: Object.assign({}, src, { __variables: '', __loginInfo: {} }),
    action: 'unlockAll()',
    formValues: { '整源解锁密码': PWD },
    cookieSnapshot: {},
  }) + ")");
  const dirtyVars = (lgin && lgin.__sourceVars) || '';
  ok(lgin && lgin.ok, '解锁动作跑通了', lgin && lgin.error);
  ok(dirtyVars.indexOf('nhAuthed') >= 0,
     '**解锁状态真的落盘了**（__sourceVars 里有 nhAuthed）', '实际 ' + dirtyVars.slice(0, 160));
  ok(dirtyVars.indexOf(PWD_HASH) >= 0,
     '落盘的是 md5(密码)（站方比对的就是这个）', '实际 ' + dirtyVars.slice(0, 160));

  // ③ 把落盘的变量喂回去 ⇒ 分类应该出来（这才是用户要的效果）
  const after = await win.eval("window.__qrInvoke('exploreKinds', " + JSON.stringify({
    source: Object.assign({}, src, { __variables: dirtyVars, __loginInfo: {} }),
    cookieSnapshot: {},
  }) + ")");
  const afterKinds = (after && after.kinds) || [];
  const afterFilters = (after && after.filters) || [];
  console.log('  解锁后 kinds =', afterKinds.length, '| filters =', afterFilters.length,
              '| error:', (after && after.error) || '(无)');
  ok(afterKinds.length > 0,
     '**解锁后能解析出分类**（之前是 0 —— nhAuth 恒 false ⇒ 规则字段全 return ""）');
  ok(afterFilters.length > 0, '筛选栏项也能出来');

  // ④ ⭐⭐⭐ **发现页要能出书**（这条以前**完全没有断言** ⇒
  //      「分类有了但一个平台都出不了书」才能一路溜到真机才发现）
  //
  //   根因：站方的 `ruleExplore.bookList` 是 **83KB 的 `@js:`**，
  //   站方 JS 把十几个平台的列表统一成 `url|||name|||author|||cover|||intro…` 一行，
  //   再用 `name`/`bookUrl` 等 `##正则##` 子规则从每行里抠字段
  //   ⇒ 宿主必须有「bookList 是 @js: ⇒ 字符串列表 ⇒ 逐项套子规则」这条通路
  const firstKind = afterKinds.find(k => k.url);
  if (!firstKind) {
    ok(false, '有可请求的分类（才能测出书）');
  } else {
    const ex = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
      source: Object.assign({}, src, { __variables: dirtyVars, __loginInfo: {} }),
      kindUrl: firstKind.url, page: 1,
    }) + ")");
    const books = (ex && ex.books) || [];
    console.log('  explore 出书 =', books.length, '| error:', (ex && ex.error) || '(无)');
    ok(books.length > 0,
       '**发现页能出书**（分类有但书出不来 ⇒ bookList 是 @js: 的通路断了）',
       '分类「' + firstKind.title + '」出 0 本');
    ok(!!(books[0] && books[0].name), '书名非空');
    ok(!!(books[0] && books[0].author), '作者非空（子规则从 ||| 串里抠的）');
    ok(!!(books[0] && books[0].bookUrl), '详情 URL 非空');
    ok(!/undefined|NaN/.test(JSON.stringify(books[0] || {})), '第一条没有 undefined/NaN 污染',
       JSON.stringify(books[0] || {}).slice(0, 160));

    // ⑤ ⭐⭐ **站方多平台分支也要能出书**（真机用户点的是「都市」= www.aaccoo.com 那条线）
    //   这一条单独挑一个**别的平台**的分类 ⇒ 验「baseUrl 判断平台 + result 取当前页原文」都成立
    const acKind = afterKinds.find(k => /aaccoo/.test(k.url || ''));
    if (!acKind) {
      console.log('  (跳过：没有 aaccoo 分类)');
    } else {
      const ex2 = await win.eval("window.__qrInvoke('explore', " + JSON.stringify({
        source: Object.assign({}, src, { __variables: dirtyVars, __loginInfo: {} }),
        kindUrl: acKind.url, page: 1,
      }) + ")");
      const acBooks = (ex2 && ex2.books) || [];
      console.log('  aaccoo 分类「' + acKind.title + '」出书 =', acBooks.length);
      ok(acBooks.length > 0,
         '**别的平台分支也能出书**（站方靠 baseUrl 判断平台 + 从 result 取当前页原文）',
         '0 本 ⇒ 要么 baseUrl 不是当前页 URL，要么 result 不是原文');
      ok(!!(acBooks[0] && acBooks[0].name), 'aaccoo 那条线的书名非空');
    }
  }
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
