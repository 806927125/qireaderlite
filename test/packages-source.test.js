/* 书源规则路径上的 Packages 验证
   跑法：node test/packages-source.test.js

   为什么单独测：
     test/engine-packages.test.js 验的是「API 能不能调通」，
     这里验的是**书源规则里能不能用** —— 也就是：
       1. 书源的 jsLib 会被加载，且能看到 Packages / java.*
       2. 规则里的 @js: 能拿到 jsLib 定义的函数
       3. 加密结果跟 Node crypto 一致（不是"能跑出个字符串"就算过）

   特意不在 chapterUrl 里塞 JS —— 那是 JSContextPool 死锁的高发区，
   这里走 exploreUrl 和 bookInfo 两处。 */
const { createSandbox } = require('./harness');
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
const SOURCE = {
  bookSourceUrl: SITE,
  bookSourceName: 'Packages签名站',
  enabled: true,
  enabledExplore: true,
  // jsLib：书源自定义的 JS 环境。栖阅/轻阅都会在规则执行前把它 eval 到全局。
  jsLib: `
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
  var md = Packages.java.security.MessageDigest.getInstance('MD5');
  var bytes = md.digest(text.getBytes('UTF-8'));
  var s = '';
  for (var i = 0; i < bytes.length; i++) {
    var h = (bytes[i] & 0xff).toString(16);
    s += h.length < 2 ? '0' + h : h;
  }
  return s;
}
`,
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

(async () => {
  const requests = [];
  const { win } = createSandbox({
    nativeMock: async (fn, args) => {
      if (fn === 'request') {
        requests.push(args.url);
        // 签名 URL 带 query，按 path 匹配 mock
        const path = String(args.url).split('?')[0];
        const body = pages[args.url] !== undefined ? pages[args.url] : pages[path];
        if (body === undefined) return { ok: false, error: '404 mock: ' + args.url };
        return {
          ok: true, code: 200, url: args.url, redirectUrl: args.url,
          headers: { 'Content-Type': 'text/html; charset=utf-8' }, body, bytes: body.length
        };
      }
      return { ok: true, value: '' };
    }
  });

  const invoke = async (op, payload) => {
    const r = await win.__qrInvoke(op, payload);
    if (r && r.error) console.log(`  [${op}] 错误: ${r.error}`);
    return r;
  };

  /* ---- 1. exploreKinds：@js: 调 jsLib 函数，拿到带签名的分类 URL ----
     （jsLib 是引擎在执行规则时加载的，所以必须先跑一次规则再检查可见性） */
  const kinds = await invoke('exploreKinds', { source: SOURCE });
  truthy('发现页分类没报错', kinds && !kinds.error, kinds && kinds.error);
  truthy('分类列表非空', kinds && kinds.kinds && kinds.kinds.length === 1, JSON.stringify(kinds && kinds.kinds));

  /* ---- 1b. explore：拿分类 URL 真的去请求 ---- */
  const ex = await invoke('explore', { source: SOURCE, kindUrl: kinds.kinds[0].url, page: 1 });
  truthy('发现页没报错', ex && !ex.error, ex && ex.error);

  /* ---- 2. jsLib 是否被加载、Packages 是否可见 ---- */
  const inLib = win.eval("typeof signText === 'function'");
  truthy('jsLib 里的 signText 已进全局', inLib === true, String(inLib));

  const pkgVisible = win.eval("typeof Packages !== 'undefined' && typeof Packages.javax.crypto.Cipher.getInstance === 'function'");
  truthy('jsLib 作用域里 Packages 可见', pkgVisible === true, String(pkgVisible));

  /* ---- 3. jsLib 里的加密结果跟 Node 一致 ---- */
  const sign = win.eval("typeof signText === 'function' ? signText('轻阅') : null");
  check('jsLib 里 Packages AES 加密结果与 Node 一致', sign, expectedSign('轻阅'));

  const md5 = win.eval("typeof md5Text === 'function' ? md5Text('轻阅') : null");
  check('jsLib 里 MessageDigest MD5 与 Node 一致', md5, crypto.createHash('md5').update('轻阅', 'utf8').digest('hex'));

  const exploreUrl = requests.find(u => u.indexOf('/rank/hot') >= 0);
  truthy('发现页真的用签名 URL 发了请求', !!exploreUrl, JSON.stringify(requests));
  if (exploreUrl) {
    const expectSign = expectedSign('/rank/hot');
    truthy('签名参数正确', exploreUrl.indexOf('sign=' + encodeURIComponent(expectSign)) >= 0
      || exploreUrl.indexOf('sign=' + expectSign) >= 0, exploreUrl);
  }
  truthy('发现页解析出书', ex && ex.books && ex.books.length === 1, JSON.stringify(ex && ex.books));

  /* ---- 4. bookInfo：规则里直接用 Packages，@js: 出 author / tocUrl ---- */
  const info = await invoke('bookInfo', { source: SOURCE, bookUrl: `${SITE}/book/1001.html` });
  truthy('详情页没报错', info && !info.error, info && info.error);
  const md5Prefix = crypto.createHash('md5').update('轻阅', 'utf8').digest('hex').substring(0, 4);
  check('规则里 @js: 用 MessageDigest 算出的 author', info && info.book && info.book.author, md5Prefix);

  // tocUrl 也是 @js: 算出来的签名 URL
  const expectToc = expectedSign('/list/1001/1.html');
  truthy('规则里 @js: 算出的 tocUrl 带正确签名',
    !!(info && info.book && info.book.tocUrl &&
       (info.book.tocUrl.indexOf('sign=' + encodeURIComponent(expectToc)) >= 0 ||
        info.book.tocUrl.indexOf('sign=' + expectToc) >= 0)),
    info && info.book && info.book.tocUrl);

  console.log('');
  console.log('═'.repeat(52));
  console.log(`  通过 ${pass}  失败 ${fail}`);
  if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
  console.log('═'.repeat(52));
  process.exit(fail === 0 ? 0 : 1);
})();
