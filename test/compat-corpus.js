/* 兼容性体检：把 9060 个真实书源的 15 万条规则全跑一遍引擎，看哪些不支持
   跑法：node test/compat-corpus.js */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');
const { QR } = createSandbox();

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';

let srcs = [];
for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
  try {
    const d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8'));
    srcs.push(...(Array.isArray(d) ? d : [d]));
  } catch (e) { /* 跳过坏文件 */ }
}

const RULES = [];
const add = (v, field, src) => { if (typeof v === 'string' && v.trim()) RULES.push({ field, text: v, src }); };

for (const s of srcs) {
  const n = s.bookSourceName || s.bookSourceUrl;
  for (const g of ['ruleSearch', 'ruleExplore']) {
    for (const k of ['searchUrl', 'bookList', 'name', 'author', 'intro', 'kind',
      'lastChapter', 'coverUrl', 'bookUrl', 'wordCount']) add(s[g] && s[g][k], g + '.' + k, n);
  }
  for (const k of ['name', 'author', 'intro', 'kind', 'lastChapter', 'coverUrl', 'tocUrl', 'wordCount'])
    add(s.ruleBookInfo && s.ruleBookInfo[k], 'ruleBookInfo.' + k, n);
  for (const k of ['chapterList', 'chapterName', 'chapterUrl', 'nextTocUrl', 'prefetchTocUrl',
    'formatJs', 'isVolume', 'isVip', 'isPay', 'updateTime'])
    add(s.ruleToc && s.ruleToc[k], 'ruleToc.' + k, n);
  for (const k of ['content', 'title', 'nextContentUrl', 'webJs', 'sourceRegex',
    'replaceRegex', 'imageStyle', 'imageDecode'])
    add(s.ruleContent && s.ruleContent[k], 'ruleContent.' + k, n);
  add(s.exploreUrl, 'exploreUrl', n);
  add(s.jsLib, 'jsLib', n);
}

const fail = {};
const bad = (kind, r, detail) => {
  (fail[kind] = fail[kind] || []).push({ field: r.field, src: r.src, text: r.text, detail });
};

const DEMO = `<html><body>
<div class="book"><a href="/b/1" class="nm">斗破苍穹</a><span class="au">天蚕土豆</span></div>
<ul class="chapter-list"><li><a href="/c/1">第1章 天炎</a></li></ul>
<table><tr><td><a href="/b/1">斗破苍穹</a></td><td>连载中</td><td>天蚕土豆</td></tr></table>
<div id="content"><p>正文第一段。</p><p>正文第二段。</p></div>
</body></html>`;
const demoDoc = QR.dom.parseHTML(DEMO, 'https://x.com/');
const DEMO_JSON = JSON.stringify({
  code: 0, data: { list: [{ name: '甲', id: 1 }, { name: '乙', id: 2 }] },
  list: [{ bookName: 'A' }, { bookName: 'B' }]
});

const RE_PLACEHOLDER_OK = /^(keyword|key|page|pageIndex|source|book|chapter|result|java|encodeURI|encodeURIComponent|decodeURI|String|Math|Date|\$|ho|ha|hb|js)$/i;

function trySelector(t, demoDoc) {
  const head = t.split('@@')[0].split(/##/)[0];
  const pc = QR.dom.parseChain(head);
  // `@text` / `@href` 单独作规则是合法的（取当前元素），resolve 会兜住
  const allAttr = !pc.selector && pc.chain.length === 1 && pc.chain[0].kind === 'attr';
  if (!pc.selector && !allAttr) return '选择器为空';
  try { QR.dom.resolve(demoDoc, t); } catch (e) { return '选择器异常: ' + String(e.message).slice(0, 40); }
  return null;
}

for (const r of RULES) {
  const t = r.text.trim();
  let kind;
  try { kind = QR.rule.classify(t); }
  catch (e) { bad('classify 抛异常', r, String(e.message).slice(0, 60)); continue; }

  if (kind === 'selector') {
    const err = trySelector(t, demoDoc);
    if (err) bad(err, r);
  } else if (kind === 'jsonpath') {
    try {
      const out = QR.jsonpath.select(JSON.parse(DEMO_JSON), t);
      if (out === undefined) bad('JSONPath 返回 undefined', r);
    } catch (e) { bad('JSONPath 执行异常', r, String(e.message).slice(0, 60)); }
  } else if (kind === 'xpath') {
    if (/::/.test(t)) bad('XPath 命名空间 ::', r);
    if (/\(\)/.test(t) && !/\b(text|node|self|contains|starts-with|not|matches)\(\)/.test(t))
      bad('XPath 未知函数', r);
  }

  // 未支持的占位符
  const ph = t.match(/\{\{\s*([A-Za-z_$][\w.$]*)\s*\}\}/g) || [];
  for (const p of ph) {
    const expr = p.slice(2, -1).trim();
    const head2 = expr.split(/[.(]/)[0];
    if (RE_PLACEHOLDER_OK.test(head2)) continue;
    if (/^page/i.test(head2)) continue;   // URL 级占位符，buildUrl 会处理
    // 带括号的多半是函数调用（java.put / Math.round / Date.now），
    // 能不能求值交给引擎，这里只报「不是函数调用且名字不认识」的
    if (/[()]/.test(expr)) continue;
    bad('占位符 {{' + expr + '}}', r);
  }
  // @js: 里用到但没实现的 java.*
  if (/^@js:/i.test(t)) {
    const KNOWN = ['ajax', 'ajaxAll', 'ajaxAllAsync', 'ajaxAsync', 'ajaxPromise', 'get', 'getAsync',
      'getPromise', 'getStrResponse', 'post', 'postAsync', 'postPromise', 'put', 'delete', 'head',
      'headAsync', 'connect', 'connectAsync', 'connectPromise', 'base64Encode', 'base64Decode',
      'base64DecodeToByteArray', 'md5Encode', 'md5Encode16', 'sha1Encode', 'encodeURI',
      'encodeURIComponent', 'decodeURI', 'decodeURIComponent', 'escape', 'unescape', 'log',
      'toast', 'longToast', 'getString', 'getStringArray', 'getStringWrapper', 'getElements',
      'getStringMatch', 'getCookie', 'setCookie', 'cacheFile', 'cacheText', 'cacheFileRaw',
      'readFile', 'importScript', 'getWebViewUA', 'deviceID', 'androidId', 'getLang', 'lang',
      'isWhiteList', 'open', 'openUrl', 'getSource', 'regex', 'htmlFormat', 'webView',
      'startBrowser', 'copyText', 'timeFormat', 'getLastUpdateTime'];
    const used = new Set(t.match(/java\.([A-Za-z_]\w*)/g) || []);
    for (const u of used) {
      const m = u.replace('java.', '');
      if (!KNOWN.includes(m)) bad('java.' + m + ' 未实现', r);
    }
    if (/JavaImporter|importPackage|new Java/.test(t)) bad('@js: 用了 JavaImporter（JVM 专有）', r);
  }
}

console.log('书源 ' + srcs.length + ' 个，规则 ' + RULES.length + ' 条\n');
console.log('=== 不支持 / 失败（按出现次数） ===');
const keys = Object.keys(fail).sort((a, b) => fail[b].length - fail[a].length);
if (!keys.length) console.log('  （没有发现问题）');
for (const k of keys) {
  console.log(String(fail[k].length).padStart(6), k);
  const ex = fail[k][0];
  console.log('        例: [' + (ex.src || '?') + '] ' + ex.field + ' → ' +
    String(ex.text).replace(/\s+/g, ' ').slice(0, 64));
}
const total = keys.reduce((a, k) => a + fail[k].length, 0);
console.log('\n有问题的规则 ' + total + ' / ' + RULES.length +
  ' = ' + (total / RULES.length * 100).toFixed(2) + '%');
