/**
 * 真·分页门禁：在 jsdom 里搭出 reader.js 的真实 DOM 结构，
 * 注入 reader-paginate.js，验证分页**真的能算页数、能翻页**。
 *
 * 背景（2026-10-19 用户反馈）：「你说的是左右滑动翻页」。
 * 我上一版做的是"滑动换章"，不是翻页 —— 参考 App 的
 * 「仿真 / 滑动 / 平移 / 无动画 / 上下滚动」是**分页方式**，
 * 正文要切成一页页、左右滑动翻页，章内翻完才接下一章。
 *
 * jsdom 不做布局，column 算不出列宽，所以这里给 body 注入一个
 * 可控的 scrollWidth 桩，用它验证「页数计算 / 翻页位移 / 边界抛边」
 * 这几件事，CSS 那一层交给真机。
 */
const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'reader', 'reader-paginate.js');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

const html = `<!doctype html><html><body>
<main id="reader-root" style="padding:20px">
  <section class="chapter" data-chapter-index="0">
    <h1>第一章</h1>
    <div class="chapter-body"><p>一</p></div>
  </section>
  <section class="chapter" data-chapter-index="1">
    <h1>第二章</h1>
    <div class="chapter-body"><p>二</p></div>
  </section>
</main></body></html>`;

const dom = new JSDOM(html, { pretendToBeVisual: true, runScripts: 'outside-only' });
const win = dom.window;
// jsdom 不排版：给 root 和 body 补上确定的几何
Object.defineProperty(win.document.getElementById('reader-root'), 'clientWidth', { value: 400 });

win.innerHeight = 800;

win.eval(fs.readFileSync(SRC, 'utf8'));
const P = win.QiReaderPaginate;

(async () => {
  console.log('\n── 挂载与模式 ──');
  ok(!!P, 'QiReaderPaginate 已挂到 window');
  ok(P.enable(0, 'slide') === true, 'enable 能给第 0 章装上分页');

  const body = win.document.querySelector('section.chapter[data-chapter-index="0"] .chapter-body');
  console.log('\n── 分页样式真的加上了吗 ──');
  ok(/px/.test(body.style.height), '固定了高度（一屏）', body.style.height);
  ok(body.style.columnWidth !== '', '设了 column-width（这是分页的关键）', body.style.columnWidth);
  ok(body.style.columnFill === 'auto', 'column-fill=auto，文字横向流出成一页页');

  console.log('\n── 只显示当前章 ──');
  const c1 = win.document.querySelector('section.chapter[data-chapter-index="1"]');
  ok(c1.style.display === 'none', '其他章被藏起来了（不然会看到下一章标题）');

  console.log('\n── 页数 / 翻页 / 边界 ──');
  // jsdom 不排版，scrollWidth 是 0 → 页数会是 1。这里打桩成 5 页。
  const pages = [];
  const edges = [];
  P.onPage((p, c) => pages.push([p, c]));
  P.onEdge(d => edges.push(d));
  // 实际页宽 = root.clientWidth(400) - 左右 padding(20+20) = 360
  Object.defineProperty(body, 'scrollWidth', { value: 360 * 5, configurable: true });
  P.refresh(0);
  const cur = P.current();
  ok(cur.count === 5, '按 scrollWidth 算出了 5 页', JSON.stringify(cur));

  // 合成事件没有 touches，**不能抛异常**（这是真 bug，2026-10-19 门禁抓出来的）
  let threw = null;
  try { win.document.dispatchEvent(new win.Event('touchstart')); } catch (e) { threw = e; }
  ok(!threw, 'touchstart 没有 touches 时不抛异常', threw && threw.message);

  // 点右侧 = 翻到下一页，transform 要真的动
  const before = body.style.transform;
  const ev = new win.MouseEvent('click', { clientX: 395, bubbles: true });
  win.document.dispatchEvent(ev);
  ok(body.style.transform !== before, '点右侧正文，transform 真的翻了',
     String(before) + ' → ' + String(body.style.transform));
  ok(P.current().page === 1, '页码走到第 2 页', JSON.stringify(P.current()));

  console.log('\n── 5 种翻页方式（对应参考 App 那一排）──');
  for (const m of ['flip', 'slide', 'flat', 'none', 'scroll']) {
    P.setMode(m);
    ok(P.current().mode === m, `setMode("${m}") 生效`);
  }

  console.log('\n── 失败要能退回，不能把正文搞没 ──');
  ok(P.enable(99, 'slide') === false, '章节不存在时返回 false 而不是抛异常');

  console.log('\n── 关掉要还原 ──');
  P.disable();
  ok(body.style.columnWidth === '', 'disable 清掉 column-width');
  ok(win.document.querySelector('section.chapter[data-chapter-index="1"]').style.display === '',
     'disable 把藏起来的章放回来');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('崩了:', e); process.exit(1); });
