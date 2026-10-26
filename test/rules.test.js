/* 规则解释器回归测试 —— 跑法：node test/rules.test.js */
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const failures = [];

function check(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; return; }
  fail++; failures.push(`${name}\n    期望 ${e}\n    实际 ${a}`);
}
function ok(name, cond, detail) {
  if (cond) { pass++; return; }
  fail++; failures.push(`${name}\n    ${detail || '条件不成立'}`);
}

const B = 'https://novel.example.com/';
const LIST = `<!doctype html><html><body>
<div class="header"><h1>书库</h1></div>
<ul class="list">
  <li class="item"><a href="/b/1">斗破苍穹</a><span class="au">天蚕土豆</span><span class="st">连载中</span><em class="tag">玄幻</em></li>
  <li class="item"><a href="/b/2">遮天</a><span class="au">辰东</span><span class="st">已完结</span><em class="tag">玄幻 仙侠</em></li>
  <li class="item"><a href="/b/3">诡秘之主</a><span class="au">爱潜水的乌贼</span><span class="st">连载中</span><em class="tag">奇幻</em></li>
</ul>
<div class="page"><a class="prev" href="?page=1">上一页</a><a class="next" href="?page=2">下一页</a></div>
</body></html>`;

(async () => {
  const { QR } = createSandbox();
  const doc = QR.dom.parseHTML(LIST, B);
  const ctx = { baseUrl: B + '?key=x' };

  /* ---- 基础选择器 ---- */
  check('书名第一条', await QR.rule.getValue('class.list@tag.li@tag.a@text', doc, ctx), '斗破苍穹');
  check('书名全部', await QR.rule.getValue('class.item@tag.a@text', doc, ctx), '斗破苍穹');
  check('href 绝对化', (await QR.rule.getElements('class.item@tag.a@href', doc, ctx)).values,
    ['https://novel.example.com/b/1', 'https://novel.example.com/b/2', 'https://novel.example.com/b/3']);
  check('作者全部', (await QR.rule.getElements('class.au@text', doc, ctx)).values,
    ['天蚕土豆', '辰东', '爱潜水的乌贼']);
  check('标签', (await QR.rule.getElements('class.tag@text', doc, ctx)).values, ['玄幻', '玄幻 仙侠', '奇幻']);
  check('状态', (await QR.rule.getElements('class.st@text', doc, ctx)).values, ['连载中', '已完结', '连载中']);

  /* ---- 根元素自身也算命中（Jsoup 语义） ---- */
  const li = QR.dom.selectOne(doc, 'class.item');
  check('在 li 内查 li 自身', QR.dom.value(li, 'class.item@tag.a@text', B), '斗破苍穹');

  /* ---- Jsoup 专有伪类 ---- */
  check(':contains 过滤', (await QR.rule.getElements('li:contains(遮天)', doc, ctx)).values.length, 1);
  check(':contains 文本', await QR.rule.getValue('li:contains(遮天)@tag.a@text', doc, ctx), '遮天');
  check(':matches 正则', (await QR.rule.getElements('li:matches(辰东|乌贼)', doc, ctx)).values.length, 2);
  check('属性 [href^=]', (await QR.rule.getElements('a[href^=/b/]', doc, ctx)).values.length, 3);
  check('属性 [href$=2]', (await QR.rule.getElements('a[href$=/2]', doc, ctx)).values.length, 1);

  /* ---- 文本前缀简写 + 中文类名 ---- */
  check('text. 前缀', (await QR.rule.getElements('text.辰东', doc, ctx)).values.length > 0, true);
  check('中文类名链', await QR.rule.getValue('class.书名@tag.a@text',
    QR.dom.parseHTML('<div class="书名"><a>斗破</a></div>', B), ctx), '斗破');

  /* ---- 回退链 ---- */
  check('|| 前空走后', await QR.rule.getValue('class.没有@text || class.au@text', doc, ctx), '天蚕土豆');
  check('|| 前中有后无', await QR.rule.getValue('class.au@text || class.没有@text', doc, ctx), '天蚕土豆');
  check('&& 顺序回退', await QR.rule.getValue('class.没有@text && class.item@tag.a@text', doc, ctx), '斗破苍穹');
  check('&& 前中有后', await QR.rule.getValue('class.item@tag.a@text && class.au@text', doc, ctx), '斗破苍穹');
  check('多行数组规则', await QR.rule.getValue(['class.没有@text', 'class.item@tag.a@text'], doc, ctx), '斗破苍穹');

  /* ---- 正则 ---- */
  check('正则纯提取', await QR.rule.getValue('##(斗破苍穹)##', doc, ctx), '斗破苍穹');
  check('正则替换后缀', await QR.rule.getValue('class.item@tag.a@text##(斗破)苍穹##$1天穹', doc, ctx), '斗破天穹');
  check('正则全量', (await QR.rule.getElements('##(遮天|奇幻)##', doc, ctx)).values, ['遮天', '奇幻']);

  /* ---- JSONPath / XPath ---- */
  const json = JSON.stringify({ code: 200, data: { list: [{ name: '甲', id: 1 }, { name: '乙', id: 2 }] } });
  check('JSONPath 取值', await QR.rule.getValue('$.data.list[*].name', json, ctx), '甲');
  check('JSONPath 下标', await QR.rule.getValue('$.data.list[1].name', json, ctx), '乙');
  check('JSONPath 全量', (await QR.rule.getElements('$.data.list[*].id', json, ctx)).values, ['1', '2']);
  check('XPath 取属性', await QR.rule.getValue('//span[@class="au"]', doc, ctx), '天蚕土豆');
  check('XPath 全量', (await QR.rule.getElements('//a[contains(@href,"/b/")]', doc, ctx)).values.length, 3);

  /* ---- @js: ---- */
  check('@js: 字符串', await QR.rule.getValue('@js:result.length > 0 ? "有" : "无"', doc, ctx), '有');
  check('@js: document 作用域', await QR.rule.getValue(
    '@js:Array.from(document.querySelectorAll(".au")).map(function(e){return e.textContent}).join("|")', doc, ctx),
    '天蚕土豆|辰东|爱潜水的乌贼');
  check('@js: java.md5', await QR.rule.getValue('@js:java.md5Encode("abc")', doc, ctx), '900150983cd24fb0d6963f7d28e17f72');
  check('<js> 包裹', await QR.rule.getValue('<js>result.length</js>', doc, ctx), String(dom_len(LIST)));
  check('@js: 循环取链接', (await QR.rule.getElements(
    '@js:Array.from(document.querySelectorAll("a.item, .item a")).map(function(e){return e.href})', doc, ctx)).values.length, 3);
  check('<js> 后处理', await QR.rule.getValue('class.item@tag.a@text<js>result.length</js>', doc, ctx), '3');

  /* ---- org.jsoup 兼容 ---- */
  const J = QR.jsoup.Jsoup.parse(LIST, B);
  check('Jsoup.parse.select().size()', J.select('class.item').size(), 3);
  check('Jsoup Elements.text()', J.select('class.au').text(), '天蚕土豆');
  check('Jsoup absUrl', J.select('tag.a').attr('abs:href'), 'https://novel.example.com/b/1');
  check('Jsoup html()', J.select('class.item').get(0).html().includes('斗破苍穹'), true);

  /* ---- 哈希 ---- */
  check('md5 空串', QR.java.md5Encode(''), 'd41d8cd98f00b204e9800998ecf8427e');
  check('sha1 abc', QR.sha1(new Uint8Array([0x61, 0x62, 0x63])), 'a9993e364706816aba3e25717850c26c9cd0d89d');

  function dom_len(s) { return QR.dom.textOf(QR.dom.parseHTML(s, B)).length; }

  /* ---- 报告 ---- */
  console.log(`\n规则引擎: ${pass} 通过 / ${fail} 失败`);
  if (failures.length) {
    console.log('\n失败明细:');
    failures.forEach(f => console.log('  ✗ ' + f));
    process.exit(1);
  }
})().catch(e => { console.error('测试崩溃:', e); process.exit(1); });
