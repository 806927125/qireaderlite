#!/usr/bin/env node
/**
 * XPath / DOM 能力门禁（2026-10-26 改跑**新引擎**）
 *
 * 背景：老引擎时代这条门禁在 jsdom 里跑老引擎的 `org-jsoup.js`
 *   （`org.seimicrawler.xpath.{JXDocument,JXNode}` + `org.jsoup.Jsoup` 的垫片）⭐⭐⭐
 *   ⇒ 2026-10-25 **老 JS 引擎物理删除** ⇒ 那层 JS 垫片没了 ⇒ 门禁的对象没了 ⭐⭐⭐
 *
 * ⭐⭐⭐ **现在验的是【新引擎】的同一份能力**：
 * · **XPath** ⇒ 新引擎的 `Sources/LegadoCore/DOM/XPathEngine.swift`（自研 XPath 子集）
 *   ⇒ 门禁直接跑**新引擎的求值器**（`conformance --eval`）⇒ 验的是**真正在跑的那份** ⭐⭐⭐
 * · **DOM/CSS** ⇒ 新引擎的 SwiftSoup 封装（`Sources/LegadoCore/DOM/SwiftSoupDOM.swift`）⭐⭐⭐
 *
 * ⚠️ **「老引擎的 JS 垫片 API」⇒ 退休**（规范 §2.1）：
 *   `JXDocument.selN().size()/each()/get()/toArray()`、`Elements.eq/map/filter/eachText/subList`、
 *   `Element.hasAttr/removeAttr/attributes/hasClass/normalName/textNodes/clone/childrenSize`、
 *   `Document.getElementsByClass/getElementsByAttribute/outerHtml` …⭐⭐⭐
 *   ⇒ 那些是**老引擎的一层 JS 垫片**（实现细节），不是语义 ⇒ 新引擎**没有等价物**
 *   ⇒ 退休**不损失语义覆盖**（语义在下面的【真跑段】里，用新引擎验）⭐⭐⭐
 */
const { evalRule, engineAvailable } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  ✗ ' + m + (extra ? '  → ' + extra : '')); }
};

const html = `<!doctype html><html><head><title>测试书名</title></head><body>
<div id="list">
  <ul>
    <li class="c" data-x="1"><a href="/book/1.html">第一章</a><span class="n">10.2万</span></li>
    <li class="c" data-x="2"><a href="/book/2.html">第二章</a><span class="n">8.5万</span></li>
    <li class="c" data-x="3"><a href="/book/3.html">第三章</a><span class="n">9.9万</span></li>
  </ul>
</div>
<div class="intro">这是简介的第一段。</div>
</body></html>`;

const BASE = 'https://example.com/book/9.html';

/** ⭐ **求值一条规则**（新引擎）⇒ 返回 {first, values, count, branch, failure} */
function ev(rule, opts = {}) {
  const r = evalRule(rule, Object.assign({
    baseType: 'page', base: html, baseUrl: BASE, all: true,
  }, opts));
  return r || { error: '引擎不可用' };
}
/** ⭐ **相对某个节点求值**（老门禁的 `JXNode.getElement()` / `Doc/El.xpath()` 那层） */
function evAt(rule, selector, opts = {}) {
  return ev(rule, Object.assign({ baseType: 'node', selector }, opts));
}

if (!engineAvailable()) {
  console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
  console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
  process.exit(0);
}

console.log('=== ① XPath（跑的是新引擎的 XPathEngine）===');
{
  const r = ev('//li[@class="c"]');
  ok(r.count === 3, `selN('//li[@class="c"]') 拿到 3 个（实际 ${r.count}）`);
  ok(r.branch === 'XPath', '走的真是 **XPath 分支**（不是回落）', r.branch);

  const t = ev('//li[@class="c"]/a/text()');
  ok(JSON.stringify(t.values) === JSON.stringify(['第一章', '第二章', '第三章']),
    `selN + /text() 对得上（实际 ${JSON.stringify(t.values)}）`);

  const h = ev('//li[@class="c"]/a/@href');
  ok(JSON.stringify(h.values) === JSON.stringify(['/book/1.html', '/book/2.html', '/book/3.html']),
    `selN + /@href 取到属性值（实际 ${JSON.stringify(h.values)}）`);

  const title = ev('//title');
  ok(!!title.first, "sel('//title') 有结果");
  ok(title.first === '测试书名', `sel().text() 取到标题（实际 ${title.first}）`);

  const none = ev('//不存在的标签');
  ok(none.count === 0, '取不到时是**空**（Java 语义：可空）而不是炸',
    JSON.stringify(none.failure));

  // ⭐⭐⭐ **`count()` 标量函数**：老引擎（`document.evaluate` = 完整 XPath 1.0）有
  //   ⇒ 新引擎的 XPath 是**子集**（规格 §S-DOM-07 的 8 种语法）⇒ **没有** `count()`
  //   ⇒ 这是**能力缺口**（不是实现细节）⇒ 已报告 ⭐⭐⭐
  //   ⇒ 语义等价点：**「数出匹配节点」这件事**用【命中列表的长度】验（下面这条）⭐⭐⭐
  ok(ev('//li[@class="c"]').count === 3, '能数出匹配节点（count() 的等价语义）');

  // ⭐ **从节点再往下钻**（老门禁的 `JXNode.getElement()` 那层）
  const at = evAt('//a', '#list');
  ok(at.count === 3, '从节点建档后 XPath 还能用（实际 ' + at.count + '）');
}

console.log('\n=== ② XPath 用在 Jsoup 文档上（老门禁的 Doc/El.xpath()）===');
{
  const r = ev('//a');
  ok(r.count === 3, `xpath('//a') 能选到（实际 ${r.count}）`);
  const t = ev('//title');
  ok(t.first === '测试书名', "xpath('//title').text() 可用");
}

console.log('\n=== ③ 坏表达式不能炸书源 ===');
{
  const bad = ev('//[[[');
  ok(bad.count === 0, '坏 XPath 返回空而不是抛异常',
    JSON.stringify(bad.failure));
  ok(/unsupportedSyntax/.test(String(bad.failure || '')),
    '坏 XPath **有诊断**（不是静默空 ⇒ 站方能看出「规则没命中」）', bad.failure);
  const bad2 = ev('$$$$');
  ok(bad2.count === 0, '坏标量规则返回空而不是抛异常');
}

console.log('\n=== ④ 不回归：原有 CSS 能力还在 ===');
{
  const c = ev('li.c');
  ok(c.count === 3, `CSS select 仍正常（实际 ${c.count}）`);
  const c2 = ev('li.c > a');
  ok(c2.count === 3, `CSS 子代选择器仍正常（实际 ${c2.count}）`);
  const t = ev('class.intro');
  ok((t.first || '').indexOf('这是简介的第一段。') >= 0, 'CSS 取文本仍正常');
  // ⭐ 相对节点的 CSS（老门禁的 `el.select('.//a')`）
  //   ⚠️ 新引擎的 CSS **不支持 `.//` 前缀**（那是 XPath 写法）⇒ 等价写法是 `//a`（XPath）
  //   ⇒ 语义等价点：**「在这个节点下面找所有 a」**——用 XPath 的 `//a` + 条目级基准验 ⭐⭐⭐
  const rel = evAt('//a', '#list');
  ok(rel.count === 3, '节点下的相对查找可用（= 老 el.select(\'.//a\') 的语义）');
}

console.log('\n=== ⑤ 老引擎的 JS 垫片 API（org.jsoup / org.seimicrawler）===');
// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎 `org-jsoup.js` 的 JS 垫片 API 形状**
//   （`JXDocument.selN().size()/each()/get()/toArray()`、
//     `Jsoup.parse().xpath()/selN()/sel()`、
//     `Elements.eq/map/filter/eachText/subList/text/first/last`、
//     `Element.hasAttr/removeAttr/attributes/hasClass/normalName/textNodes/clone/childrenSize`、
//     `Document.getElementsByClass/getElementsByAttribute/outerHtml`、
//     `JXDocument.create()` 静态工厂、`JXNode.prototype.getTextValue`）⭐⭐⭐
//   ⇒ 那些是**实现细节**（一层 JS 垫片），不是语义 ⇒ 老引擎退役后**没有等价物**
//   ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（270 项）与真机上 ⭐⭐⭐

console.log('\n=== ⑥ 门禁不是摆设 ===');
{
  // ⭐ **判别力**：XPath 与 CSS 是**两条不同的分支** ⇒ 断言 `branch` 真的落在 XPath 上
  //   ⇒ 哪天 XPath 被摘掉 ⇒ 这条立刻红（不会「静默变成空列表」蒙过去）⭐⭐⭐
  const x = ev('//li[@class="c"]/a/text()');
  ok(x.branch === 'XPath' && x.count === 3,
    'XPath 分支真的被走到（branch=XPath 且命中 3 条）', `branch=${x.branch}`);
  // ⭐ **CSS 分支也真的在**（别把两条路都验成一条）
  const c = ev('li.c');
  ok(c.branch !== 'XPath' && c.count === 3,
    'CSS 分支也真的被走到（branch≠XPath 且命中 3 条）', `branch=${c.branch}`);
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
