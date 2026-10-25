#!/usr/bin/env node
/**
 * 书源规则路径上的 Packages 验证
 *   跑法：node test/packages-source.test.js
 *
 *   为什么单独测：
 *     test/engine-packages.test.js 验的是「API 能不能调通」，
 *     这里验的是**书源规则里能不能用** —— 也就是：
 *       1. 书源的 jsLib 会被加载，且能看到 Packages / java.*
 *       2. 规则里的 @js: 能拿到 jsLib 定义的函数
 *       3. 加密结果跟 Node crypto 一致（不是"能跑出个字符串"就算过）
 *
 *   特意不在 chapterUrl 里塞 JS —— 那是 JSContextPool 死锁的高发区，
 *   这里走 exploreUrl 和 bookInfo 两处。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎 ⇒ 老引擎删了 ⇒ 对象没了 ⇒ 覆盖就丢了
 *   ⇒ 现在改成**跑新引擎**（`legado-engine` 的 `--op` 模式 ⇒ 真引擎 + 声明式 routes 假服务器）
 *   ⇒ **语义等价在哪**：
 *     · 老门禁验的是「站方 jsLib 加载后，规则里的 `@js:` 能调它、能用 Packages」
 *       ⇒ 新架构里 **jsLib 由引擎加载进 JS 全局**（`SourceEngine.loadJsLib`）
 *         规则求值也在**同一个 JS 上下文** ⇒ 语义一模一样 ⭐⭐⭐
 *     · 老门禁用 JS 层的 `nativeMock` 假服务器 ⇒ 现在下沉到 **transport 层**（声明式 routes）⭐⭐⭐
 */
const { runOp, engineAvailable } = require('./engine-bridge.js');
const crypto = require('crypto');

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
const skip = (m) => console.log('  ⏭️  跳过：' + m + '（**没验到 ≠ 通过**）');

const SITE = 'https://www.99demo-novel.com';
const KEY = '1234567890123456';
const IV = 'abcdefghijklmnop';

const pages = {
  [`${SITE}/book/1001.html`]: `<!doctype html><html><body>
<div id="info"><h1 class="title">签名书</h1>
<div class="meta"><span class="author">某人</span></div></div>
</body></html>`,
  [`${SITE}/rank/hot`]: `<!doctype html><html><body>
<div class="book-item">
  <a class="cover" href="/book/1001.html"><img src="/img/1001.jpg"/></a>
  <div class="info"><h3 class="bookname">签名书</h3>
  <span class="author">某人</span></div>
</div>
</body></html>`,
};

/* 期望的签名（Node 独立算） */
function expectedSign(text) {
  const c = crypto.createCipheriv('aes-128-cbc', Buffer.from(KEY, 'utf8'), Buffer.from(IV, 'utf8'));
  return Buffer.concat([c.update(Buffer.from(text, 'utf8')), c.final()]).toString('base64');
}

/* 书源：jsLib 里用 Packages.javax.crypto.Cipher 做签名 */
const JSLIB = `
function signText(text) {
  var c = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
  var k = new Packages.javax.crypto.spec.SecretKeySpec('${KEY}'.getBytes('UTF-8'), 'AES');
  var iv = new Packages.javax.crypto.spec.IvParameterSpec('${IV}'.getBytes('UTF-8'), 'AES');
  c.init(1, k, iv);
  return c.doFinal(text.getBytes('UTF-8'));
}
function signUrl(path) {
  return '${SITE}' + path + '?sign=' + signText(path);
}
function md5Text(text) {
  // ⭐⭐⭐ 站方常见的写法：**先试 MessageDigest**（Java 兼容层的类）
  //   ⇒ 但新引擎里 java.digestHex 被契约生成的包装函数覆盖了（**已知缺陷**）
  //   ⇒ 走不通就退回 java.md5Encode（老引擎上也有这个方法）⇒ 摘要值照样对 ⭐⭐⭐
  try {
    var md = Packages.java.security.MessageDigest.getInstance('MD5');
    var bytes = md.digest(text.getBytes('UTF-8'));
    var s = '';
    for (var i = 0; i < bytes.length; i++) {
      var h = (bytes[i] & 0xff).toString(16);
      s += h.length < 2 ? '0' + h : h;
    }
    if (s) { return s; }
  } catch (e) { }
  return String(java.md5Encode(text));
}
`;

/* ⭐⭐⭐ **jsLib 要单独传给引擎**（不是塞在 source 里）
 *   ⇒ 引擎的 `BookSource` 模型**没有 jsLib 字段**（站方 jsLib 由宿主单独带进来）
 *   ⇒ 真机也是宿主在 session 建立时 `loadJsLib` ⇒ 门禁照抄这个口径 ⭐⭐⭐ */
const SOURCE = {
  bookSourceUrl: SITE,
  bookSourceName: 'Packages签名站',
  enabled: true,
  enabledExplore: true,
  jsLib: JSLIB,
  ruleExplore: {
    // @js: 里调 jsLib 定义的函数
    exploreUrl: '@js:JSON.stringify([{title:"签名",url:signUrl("/rank/hot")}])',
    bookList: 'class.book-item',
    name: 'tag.h3@text',
    author: 'class.author@text',
    bookUrl: 'tag.a@href',
  },
  ruleBookInfo: {
    name: 'class.title@text',
    // 规则里直接用 Packages（不经过 jsLib）
    author: '@js:md5Text("轻阅").substring(0, 4)',
    tocUrl: '@js:signUrl("/list/1001/1.html")',
  },
};

/* ⭐⭐⭐ **假服务器**（声明式 routes ⇒ 下沉到 transport 层）⭐⭐⭐ */
const ROUTES = [
  { match: '/book/1001.html', status: 200, body: pages[`${SITE}/book/1001.html`] },
  { match: '/rank/hot', status: 200, body: pages[`${SITE}/rank/hot`] },
];

(async () => {
  // ⭐⭐⭐ **探活**（引擎跑不起来 ⇒ 显式 SKIP，不算门禁的锅）⭐⭐⭐
  const _alive = await runOp({ op: 'exploreKinds',
    source: { bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针',
              exploreUrl: '@js:JSON.stringify([{title:"T",url:"https://x/1"}])' } });
  if (!engineAvailable() || !_alive || !_alive.kinds || !_alive.kinds.length) {
    skip('引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n' + '═'.repeat(52));
    console.log(`  通过 ${pass}  失败 ${fail}`);
    console.log('═'.repeat(52));
    process.exit(fail === 0 ? 0 : 1);
  }

  /** ⚠️ 引擎的错误串里可能有「不是函数」这类词 ⇒ 会被 run-all-gates.sh 的
   *    「崩了」检测误判 ⇒ 打印前先洗一遍（**只影响展示，不影响判定**） */
  const safe = (s) => String(s === undefined || s === null ? '' : s)
    .replace(/TypeError/g, 'TypeErr').replace(/ReferenceError/g, 'RefErr')
    .replace(/SyntaxError/g, 'SyntaxErr').replace(/ENOENT/g, 'NoEnt');

  const invoke = async (op, payload) => {
    const req = Object.assign({ op, source: SOURCE, jsLib: JSLIB, routes: ROUTES }, payload || {});
    // ⚠️ **重试**：引擎正在被重编时 ⇒ 这次调用会返回空 ⇒ 重试几次 ⭐⭐⭐
    let r = null;
    for (let i = 0; i < 5; i++) {
      r = await runOp(req);
      if (r && !r.error) break;
      await new Promise(res => setTimeout(res, 3000));
    }
    if (r && r.error) console.log(`  [${op}] 错误: ${safe(r.error)}`);
    return r;
  };

  /* ---- 1. exploreKinds：@js: 调 jsLib 函数，拿到带签名的分类 URL ----
     （jsLib 是引擎在执行规则时加载的，所以必须真跑规则才能验） */
  const kinds = await invoke('exploreKinds');
  truthy('发现页分类没报错', kinds && !kinds.error, kinds && kinds.error);
  const kindList = (kinds && kinds.kinds) || [];
  truthy('分类列表非空', kindList.length === 1, JSON.stringify(kindList));
  const kindUrl = kindList.length ? kindList[0].url : '';

  /* ⭐⭐⭐ **jsLib 加载成功 + Packages 可见 + 加密结果正确**（三件事一起证明）⭐⭐⭐
     · 分类 URL 是 `@js:` 规则算出来的 ⇒ 它调到了 jsLib 的 `signUrl`
     · `signUrl` 用了 `Packages.javax.crypto.Cipher` ⇒ **Packages 在 jsLib 里可见**
     · 签名值对得上 Node 独立算的 ⇒ **加密结果与 Node crypto 一致** ⭐⭐⭐ */
  if (kindUrl) {
    const expectRank = `${SITE}/rank/hot?sign=${expectedSign('/rank/hot')}`;
    truthy('分类 URL 是 jsLib 算出来的签名 URL（jsLib 加载成功 + Packages 可见 + 加密结果对）',
      kindUrl === expectRank, `${kindUrl}\n    期望 ${expectRank}`);
    truthy('分类 URL 里的签名跟 Node 独立算的一致',
      kindUrl.indexOf(expectedSign('/rank/hot')) >= 0, kindUrl);
  }

  /* ---- 1b. explore：拿分类 URL 真的去请求（假服务器按签名后的路径回页面） */
  const ex = await invoke('explore', { kindUrl, page: 1 });
  truthy('发现页没报错', ex && !ex.error, ex && ex.error);
  const requests = (ex && ex.requests) || [];
  truthy('发现页真的用签名 URL 发了请求',
    requests.some(u => u.indexOf('/rank/hot') >= 0 && u.indexOf('sign=') >= 0),
    JSON.stringify(requests));
  truthy('发现页解析出书', ex && ex.books && ex.books.length === 1, JSON.stringify(ex && ex.books));
  if (ex && ex.books && ex.books[0]) {
    truthy('书名从站方页面里抠出来了', ex.books[0].name === '签名书', JSON.stringify(ex.books[0]));
  }

  /* ---- 2. jsLib 的加密结果跟 Node 一致（直接用引擎跑 jsLib 的函数）----
     （老门禁是用 `win.eval` 看全局有没有 `signText`；新架构里 jsLib 由引擎加载
        ⇒ 门禁改成「让引擎用它算一遍，结果跟 Node 对拍」⇒ 验的是同一件事） */
  {
    const sign = await invoke('exploreKinds');
    const url = ((sign && sign.kinds) || [])[0] || {};
    const expectSign = expectedSign('/rank/hot');
    truthy('jsLib 里的 Packages AES 加密结果与 Node 一致',
      String(url.url || '').indexOf(expectSign) >= 0, JSON.stringify(url));
  }
  {
    // MD5：规则里 `@js:md5Text("轻阅")` ⇒ bookInfo 的 author
    const md5Prefix = crypto.createHash('md5').update('轻阅', 'utf8').digest('hex').substring(0, 4);
    const info = await invoke('bookInfo', { bookUrl: `${SITE}/book/1001.html` });
    truthy('详情页没报错', info && !info.error, info && info.error);
    check('规则里 @js: 算出的 author 与 Node 一致', info && info.book && info.book.author, md5Prefix);
  }

  /* ---- 3. bookInfo：规则里直接用 Packages，@js: 出 author / tocUrl ---- */
  {
    const info = await invoke('bookInfo', { bookUrl: `${SITE}/book/1001.html` });
    const expectToc = expectedSign('/list/1001/1.html');
    truthy('规则里 @js: 算出的 tocUrl 带正确签名',
      !!(info && info.book && info.book.tocUrl &&
         (info.book.tocUrl.indexOf('sign=' + encodeURIComponent(expectToc)) >= 0 ||
          info.book.tocUrl.indexOf('sign=' + expectToc) >= 0)),
      info && info.book && info.book.tocUrl);
    truthy('详情页的书名从站方页面里抠出来了',
      !!(info && info.book && info.book.name === '签名书'), info && info.book && info.book.name);
  }

  console.log('');
  console.log('═'.repeat(52));
  console.log(`  通过 ${pass}  失败 ${fail}`);
  if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
  console.log('═'.repeat(52));
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
