/* 规则解释器回归测试 —— 跑法：node test/rules.test.js
 *
 * ⭐⭐⭐⭐⭐ **2026-10-26：老 JS 引擎物理删除 ⇒ 本门禁改跑【新引擎】**
 *   · 老门禁在 jsdom 里跑老引擎的 `QR.rule.getValue` / `QR.rule.getElements` /
 *     `QR.dom.parseHTML` / `QR.jsoup.Jsoup` / `QR.java.md5Encode` / `QR.sha1` ⭐⭐⭐
 *   · 老引擎（`QiReaderLite/Resources/engine/*.js`）已删 ⇒ 那些对象没了 ⇒ 覆盖会丢 ⭐⭐⭐
 *   · ⇒ 现在**直接调新引擎**（`legado-engine` 的 `conformance --eval`）⇒ 覆盖不丢，
 *     而且验的是**真正在跑的那份代码**（不是参考实现）⭐⭐⭐
 *
 * ⭐ **语义映射（老 API ⇒ 新引擎入口）**：
 * | 老 API | 新引擎 | 语义 |
 * |---|---|---|
 * | `QR.rule.getValue(rule, base, ctx)` | `--eval {rule,base}` ⇒ **`first`** | 字段出口：**第一个非空命中**（Legado 语义） |
 * | `QR.rule.getElements(rule, base, ctx).values` | `--eval {rule,base,all:true}` ⇒ **`values`** | 列表出口：**全部命中** |
 * | `QR.dom.parseHTML(html, base)` + `QR.dom.selectOne(doc, sel)` + `QR.dom.value(node, …)` | `--eval {baseType:"node",selector,base}` ⇒ **`first`** | 条目级基准（相对某个节点求值） |
 * | `QR.java.md5Encode(s)` / `QR.sha1(bytes)` | `--eval {rule:"@js:java.md5Encode(s)"}` | 宿主 API（纯计算） |
 *
 * ⚠️ **`result` 的语义变了**（新引擎按 §S-RES 分层）：
 *   页面级规则的 `result` = **页原文（HTML 源码）**，不是纯文本 ⭐⭐⭐
 *   ⇒ 站方 `@js:` 里 `String(result).match(/<div class="book-like">…/)` 才有意义
 *   ⇒ 老门禁那条「`<js>result.length</js>` = 文本长度」改成「= 页原文长度」（语义更准）⭐⭐⭐
 */
const { evalRule, engineAvailable } = require('./engine-gate-helpers.js');

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

const JSON_BASE = { code: 200, data: { list: [{ name: '甲', id: 1 }, { name: '乙', id: 2 }] } };

/** ⭐⭐⭐ **没编译引擎 ⇒ 显式 SKIP**（不许假绿：没验到 ≠ 验过了没问题） */
if (!engineAvailable()) {
  console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁**没验到**（**不等于通过**）');
  console.log('\n✅ 通过 0 / 失败 0（引擎不可用 ⇒ 显式跳过）');
  process.exit(0);
}

/** ⭐ **字段出口**（= 老引擎的 `QR.rule.getValue` ⇒ 第一个非空命中） */
function first(rule, opts = {}) {
  const r = evalRule(rule, Object.assign({ base: LIST, baseUrl: B }, opts));
  return r && r.ok !== false ? r.first : `ERR:${r && r.error}`;
}
/** ⭐ **列表出口**（= 老引擎的 `QR.rule.getElements(…).values` ⇒ 全部命中） */
function values(rule, opts = {}) {
  const r = evalRule(rule, Object.assign({ base: LIST, baseUrl: B, all: true }, opts));
  return r && r.ok !== false ? (r.values || []) : [`ERR:${r && r.error}`];
}
/** ⭐ **条目级基准**（= 老引擎的 `QR.dom.selectOne` + `QR.dom.value`） */
function atNode(rule, selector, opts = {}) {
  const r = evalRule(rule, Object.assign({
    baseType: 'node', selector, base: LIST, baseUrl: B,
  }, opts));
  return r && r.ok !== false ? r.first : `ERR:${r && r.error}`;
}
/** ⭐ **JSON 基准** */
function jsonFirst(rule) {
  const r = evalRule(rule, { baseType: 'json', baseJSON: JSON_BASE, isJSON: true });
  return r && r.ok !== false ? r.first : `ERR:${r && r.error}`;
}
function jsonValues(rule) {
  const r = evalRule(rule, { baseType: 'json', baseJSON: JSON_BASE, isJSON: true, all: true });
  return r && r.ok !== false ? (r.values || []) : [`ERR:${r && r.error}`];
}

(async () => {
  /* ---- 基础选择器 ---- */
  check('书名第一条', first('class.list@tag.li@tag.a@text'), '斗破苍穹');
  check('书名全部', first('class.item@tag.a@text'), '斗破苍穹');
  check('href 绝对化', values('class.item@tag.a@href'),
    ['https://novel.example.com/b/1', 'https://novel.example.com/b/2', 'https://novel.example.com/b/3']);
  check('作者全部', values('class.au@text'),
    ['天蚕土豆', '辰东', '爱潜水的乌贼']);
  check('标签', values('class.tag@text'), ['玄幻', '玄幻 仙侠', '奇幻']);
  check('状态', values('class.st@text'), ['连载中', '已完结', '连载中']);

  /* ---- 根元素自身也算命中（Jsoup 语义） ---- */
  // ⭐ 等价语义：老门禁用 `QR.dom.selectOne(doc,'class.item')` 取出**一个节点**，
  //   再在这个节点里查 `class.item@tag.a@text` ⇒ 命中的是**根节点自己**
  //   ⇒ 新引擎的等价入口 = **条目级基准**（`baseType:"node"` + `selector`）⭐⭐⭐
  check('在 li 内查 li 自身', atNode('class.item@tag.a@text', 'li.item'), '斗破苍穹');

  /* ---- Jsoup 专有伪类 ---- */
  check(':contains 过滤', values('li:contains(遮天)').length, 1);
  check(':contains 文本', first('li:contains(遮天)@tag.a@text'), '遮天');
  check(':matches 正则', values('li:matches(辰东|乌贼)').length, 2);
  check('属性 [href^=]', values('a[href^=/b/]').length, 3);
  check('属性 [href$]', values('a[href$=/2]').length, 1);

  /* ---- 文本前缀简写 + 中文类名 ---- */
  check('text. 前缀', values('text.辰东').length > 0, true);
  check('中文类名链', first('class.书名@tag.a@text',
    { base: '<div class="书名"><a>斗破</a></div>' }), '斗破');

  /* ---- 回退链 ---- */
  check('|| 前空走后', first('class.没有@text || class.au@text'), '天蚕土豆');
  check('|| 前中有后', first('class.au@text || class.没有@text'), '天蚕土豆');
  // ⭐⭐⭐ **「&&」的语义：新引擎按 Legado 规格 = 【依次求值并拼接】**（§S-EVAL-05 / §S-FBK-02）
  //   老引擎是「依次尝试，前一个有结果就停」（轻阅自己的取舍，**不是** Legado 语义）
  //   ⇒ 语义等价点：**两段都命中时，结果里两段都在**（拼接）⇒ 这里断言拼接后的结果 ⭐⭐⭐
  check('&& 前空（后段拼上）', first('class.没有@text && class.item@tag.a@text'),
    '斗破苍穹\n遮天\n诡秘之主');
  check('&& 两段都命中（拼接）', first('class.item@tag.a@text && class.au@text'),
    '斗破苍穹\n遮天\n诡秘之主天蚕土豆\n辰东\n爱潜水的乌贼');
  // ⭐ 数组规则（Legado 的「多行规则」写法）⇒ 新引擎用**换行**分隔（§S-EVAL-01）
  //   ⇒ 语义等价点：**逐行取第一个非空的** ⭐⭐⭐
  check('多行数组规则', first('class.没有@text\nclass.item@tag.a@text'), '斗破苍穹');

  /* ---- 正则 ---- */
  check('正则纯提取', first('##(斗破苍穹)##'), '斗破苍穹');
  // ⭐ 用**只有一本书**的页面 ⇒ 「尾部正则作用在整条结果文本上」= 「作用在那本书的书名上」
  //   ⇒ 与老引擎「逐值替换后取第一个」**语义等价**（老门禁就是拿第一本书验的）⭐⭐⭐
  check('正则替换后缀', first('class.item@tag.a@text##(斗破)苍穹##$1天穹',
    { base: '<html><body><ul><li class="item"><a href="/b/1">斗破苍穹</a></li></ul></body></html>' }),
    '斗破天穹');
  check('正则全量', values('##(遮天|奇幻)##'), ['遮天', '奇幻']);

  /* ---- JSONPath / XPath ---- */
  check('JSONPath 取值', jsonFirst('$.data.list[*].name'), '甲');
  check('JSONPath 下标', jsonFirst('$.data.list[1].name'), '乙');
  check('JSONPath 全量', jsonValues('$.data.list[*].id'), ['1', '2']);
  check('XPath 取属性', first('//span[@class="au"]'), '天蚕土豆');
  check('XPath 全量', values('//a[contains(@href,"/b/")]').length, 3);

  /* ---- @js: ---- */
  check('@js: 字符串', first('@js:result.length > 0 ? "有" : "无"'), '有');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这两条断言验的是**老引擎的 JS 上下文里有 `document`**（老引擎跑在 WebView 里）
  //   ⇒ 那是**老引擎的实现机制**，不是语义 ⇒ 新引擎（JS 在 JSC/Node 里跑，DOM 在 Swift 侧）
  //   ⇒ **没有等价物**（新引擎的 `@js:` 上下文里**没有 `document`**）⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 「从页面里取作者列表」这个语义，由上面的 CSS 规则断言（`class.au@text`）覆盖 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（270 项）与真机上 ⭐⭐⭐
  check('@js: java.md5Encode', first('@js:java.md5Encode("abc")'), '900150983cd24fb0d6963f7d28e17f72');
  // ⭐⭐⭐ **`result` = 页原文（HTML 源码）**（新引擎 §S-RES：页面级 ⇒ 原始内容）
  //   ⇒ 语义等价点：**站方 `@js:` 能正则匹配 HTML 标签**（`String(result).match(/<div …/)`）
  //   ⇒ 老门禁断言的是「文本长度」；新引擎给的是**页原文长度**（更准 ⇒ 站方才正则得到）⭐⭐⭐
  check('<js> 包裹（result = 页原文）', first('<js>result.length</js>'), String(LIST.length));
  check('<js> 后处理', first('class.item@tag.a@text<js>result.length</js>'), '3');

  /* ---- org.jsoup 兼容（老引擎的 JS 侧 org.jsoup 垫片） ---- */
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这四条断言验的是**老引擎 JS 侧 `org.jsoup.Jsoup` 垫片的 API 形状**
  //   （`Elements.size()` / `Elements.text()` / `Element.attr('abs:href')` / `Element.html()`）
  //   ⇒ 那是**实现细节**（一套 JS 垫片），不是语义 ⇒ 老引擎退役后**没有等价物**
  //   ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价语义（新引擎的 DOM 出口）就在本文件里：
  //      · `select('class.item').size()` ⇒ **CSS 规则命中数**（`values('class.item')`）
  //      · `Elements.text()` ⇒ **命中文本**（`values('class.au@text')`）
  //      · `attr('abs:href')` ⇒ **绝对化后的 href**（`values('class.item@tag.a@href')`）
  //      · `Element.html()` ⇒ **元素的 HTML**（`@html` 取值模式）⭐⭐⭐
  check('DOM 出口：CSS 命中数（= 老 Elements.size()）', values('class.item').length, 3);
  // ⭐ `@html` 取的是**元素内部 HTML**（与 Jsoup 的 `Element.html()` 同语义 ⇒ 老门禁那条
  //   `html().includes('斗破苍穹')` 的等价断言就在这里）⭐⭐⭐
  check('DOM 出口：元素 HTML（= 老 Element.html()）',
    first('class.item@html').indexOf('斗破苍穹') >= 0, true);

  /* ---- 哈希 ---- */
  check('md5 空串', first('@js:java.md5Encode("")'), 'd41d8cd98f00b204e9800998ecf8427e');
  // ⭐⭐⭐ **sha1**：老引擎的 `QR.sha1(bytes)`（`Resources/engine/sha1.js`）已随老引擎删除
  //   ⇒ 新引擎原来**也没有** sha1（宿主 API 清单写着 `java.sha1Encode` 却没人实现 ⇒ 静默失效）⭐⭐⭐
  //   ⇒ 2026-10-26 **给新引擎补上了**（`Crypto.sha1Hex` + `engineJava("sha1Encode")`）⭐⭐⭐
  //   ⇒ 语义等价点：**同一个输入 ⇒ 同一个 SHA-1 摘要**（"abc" ⇒ a9993e36…）⭐⭐⭐
  check('sha1 abc', first('@js:java.sha1Encode("abc")'), 'a9993e364706816aba3e25717850c26c9cd0d89d');

  /* ---- 报告 ---- */
  console.log(`\n规则引擎: ${pass} 通过 / ${fail} 失败`);
  if (failures.length) {
    console.log('\n失败明细:');
    failures.forEach(f => console.log('  ✗ ' + f));
    process.exit(1);
  }
})().catch(e => { console.error('测试崩溃:', e); process.exit(1); });
