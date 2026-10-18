#!/usr/bin/env node
/**
 * org-jsoup.js 的 XPath 层 + Jsoup API 补齐的实测门禁
 *
 * 背景：栖阅的引擎能力分散在两个文件里——
 *   packages_stub.js  → 我整份搬了（125 个 Packages.* 全在）
 *   jsoup_bridge.js   → 没搬，理由是「依赖 Swift/Kanna live DOM 句柄」
 * 结果 org.seimicrawler.xpath.{JXDocument,JXNode} 和 Doc/El.xpath() 全是 undefined，
 * 书源里凡是走 XPath 的规则全哑火。
 *
 * 那个判断是错的：XPath 不用桥，WebView 的 document.evaluate() 就是完整 XPath 1.0。
 *
 * ⚠️ 这里必须在 jsdom 里真跑，不能只 grep 源码。
 *    jsdom 自带 XPathResult + document.evaluate，跟 WebKit 同规格。
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { createSandbox, ENGINE_DIR } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// 用跟真机同一套 harness：runScripts + vm.runInContext + 完整注入顺序，
// 别自己造沙盒（之前就是漏了 runScripts:'outside-only' 导致 window.eval 没真跑）
const { win: w } = createSandbox({ origin: 'https://example.com/book/9.html' });

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

const jd = new w.org.seimicrawler.xpath.JXDocument(html);

const nodes = jd.selN('//li[@class="c"]');
ok(nodes.length === 3, `selN('//li[@class="c"]') 拿到 3 个（实际 ${nodes.length}）`);
ok(nodes.size() === 3, 'selN 返回的 List 有 size()');
ok(typeof nodes.each === 'function', 'selN 返回的 List 有 each()（书源常用）');
ok(typeof nodes.get === 'function', 'selN 返回的 List 有 get()');
ok(typeof nodes.toArray === 'function', 'selN 返回的 List 有 toArray()');

const titles = jd.selN('//li[@class="c"]/a/text()').map(n => n.asString());
ok(JSON.stringify(titles) === JSON.stringify(['第一章', '第二章', '第三章']),
   `selN + /text() + asString() 对得上（实际 ${JSON.stringify(titles)}）`);

const hrefs = jd.selN('//li[@class="c"]/a/@href').map(n => n.getTextValue());
ok(JSON.stringify(hrefs) === JSON.stringify(['/book/1.html', '/book/2.html', '/book/3.html']),
   `selN + /@href 取到属性值（实际 ${JSON.stringify(hrefs)}）`);

const one = jd.sel('//title');
ok(one !== null, "sel('//title') 有结果");
ok(one.text() === '测试书名', `sel().text() 取到标题（实际 ${one && one.text()}）`);
ok(jd.sel('//不存在的标签') === null, 'sel() 取不到返回 null（Java 是可空）');
ok(jd.selString('count(//li[@class="c"])') === '3', 'selString 取标量 count()');
ok(jd.selText('//title') === '测试书名', 'selText 直接取首个文本');

ok(JXNodeHasProto(), 'JXNode 继承链正常');
function JXNodeHasProto() {
  return w.org.seimicrawler.xpath.JXNode.prototype.getTextValue !== undefined;
}

// 从字符串建档 + 复用已有 Doc
const jd2 = w.org.seimicrawler.xpath.JXDocument.create(html);
ok(jd2.selN('//li').length === 3, 'JXDocument.create() 静态工厂可用');

// 从 JXNode 再往下钻
const ul = jd.sel('//ul');
const ulDoc = ul.getElement();
ok(ulDoc !== null, 'JXNode.getElement() 返回 Jsoup Element');
ok(ulDoc.selN('//li').length === 3, '从 Element 建档后 XPath 还能用');

/* ---------------- Doc/El 上的 xpath（之前直接是 undefined） ---------------- */

const doc = w.org.jsoup.Jsoup.parse(html, 'https://example.com');
ok(typeof doc.xpath === 'function', 'Jsoup.parse().xpath 存在（之前 undefined）');
ok(doc.xpath('//a').length === 3, 'Jsoup.parse().xpath 能选到');
ok(typeof doc.selN === 'function', 'Jsoup.parse().selN 存在');
ok(doc.sel('//title').text() === '测试书名', 'Jsoup.parse().sel().text() 可用');

const el = doc.selectFirst('#list');
ok(typeof el.xpath === 'function', 'Element.xpath 存在');
ok(el.xpath('.//a').length === 3, 'Element.xpath 相对选择能选到');
ok(el.select('.//a').length === 3, 'Element.select 相对选择没被我改坏');

/* ---------------- 补齐的 Jsoup 方法 ---------------- */

const els = doc.select('li.c');
ok(typeof els.eq === 'function' && els.eq(1).text().indexOf('第二章') === 0, 'Elements.eq(i)');
ok(typeof els.map === 'function' && els.map(x => x.attr('class')).length === 3, 'Elements.map');
ok(typeof els.filter === 'function' && els.filter(x => x.attr('class') === 'c').length === 3, 'Elements.filter');
ok(typeof els.eachText === 'function', 'Elements.eachText');
ok(typeof els.subList === 'function' && els.subList(0, 2).length === 2, 'Elements.subList');
ok(els.text().indexOf('第一章') >= 0, 'Elements.text 没被 patch 弄坏');
ok(els.size() === 3 && els.first() && els.last(), 'Elements.first/last 没被 patch 弄坏');

const a0 = doc.selectFirst('a');
ok(typeof a0.hasAttr === 'function' && a0.hasAttr('href') === true, 'Element.hasAttr');
ok(typeof a0.removeAttr === 'function', 'Element.removeAttr');
ok(typeof a0.attributes === 'function' && a0.attributes().href === '/book/1.html', 'Element.attributes');
ok(typeof a0.hasClass === 'function', 'Element.hasClass');
ok(typeof a0.normalName === 'function' && a0.normalName() === 'a', 'Element.normalName');
ok(typeof a0.textNodes === 'function', 'Element.textNodes');
ok(typeof a0.clone === 'function', 'Element.clone');
ok(typeof a0.childrenSize === 'function', 'Element.childrenSize');
ok(typeof doc.getElementsByClass === 'function' && doc.getElementsByClass('c').length === 3, 'Document.getElementsByClass');
// 注意：别拿 href 测 —— 引擎解析器会往 head 注入 <base href="">（相对 URL 要用），
// '[href]' 会合法地连它一起选中。用没有冲突的属性测。
ok(typeof doc.getElementsByAttribute === 'function' && doc.getElementsByAttribute('data-x').length === 3,
   'Document.getElementsByAttribute');
ok(typeof doc.outerHtml === 'function' && doc.outerHtml().indexOf('<title>') > 0, 'Document.outerHtml');

/* ---------------- 坏表达式不能炸书源 ---------------- */

ok(jd.selN('//[[[').length === 0, '坏 XPath 返回空而不是抛异常');
ok(jd.selString('$$$$') === '', '坏 XPath 标量返回空串');

/* ---------------- 不回归：原有 CSS 能力还在 ---------------- */

ok(doc.select('li.c').length === 3, 'CSS select 仍正常');
ok(doc.select('li.c > a').length === 3, 'CSS 子代选择器仍正常');
ok(doc.text().indexOf('第一章') >= 0, 'Document.text 仍正常');
ok(typeof w.org.jsoup.Jsoup.parse === 'function', 'Jsoup.parse 仍挂着');

/* ---------------- 门禁不是摆设 ---------------- */

{
  // 去掉 XPath 那段，selN 必须真的坏掉 —— 证明上面那些断言有判别力
  const src = fs.readFileSync(path.join(ENGINE_DIR, 'org-jsoup.js'), 'utf8');
  const s2 = createSandbox({ origin: 'https://example.com/book/9.html' });
  vm.runInContext(src.replace(/JXDocument\.prototype\.selN = function[\s\S]*?\n  \};/, ''), s2.ctx, { filename: 'org-jsoup.js' });
  const noX = s2.win;
  const gone = noX.window.org.seimicrawler.xpath.JXDocument;
  ok(typeof gone === 'function' && gone.prototype.selN === undefined,
     '去掉实现后 selN 确实没了（门禁有判别力）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
