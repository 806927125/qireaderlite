#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：正文阅读页的「柴阅皮肤」必须完整**（2026-11-25）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁** ⭐⭐⭐：
 *   用户原话：「**正文阅读页 ui 我要全搬柴阅的啊**」⭐⭐⭐
 *   ⇒ 柴阅（github.com/Lincb522/Chaiyue）的阅读页 = 一整套：
 *     · **四套皮肤**（宣纸 / 晴窗 / 星夜 / 烛灯）= 字体 + 强调色 + **章节号装饰** + **进度装饰** ⭐⭐⭐
 *     · **一页 = 页眉 + 正文 + 页脚**（页眉=书名/章名，页脚=页码+全书进度%）⭐⭐⭐
 *     · **排版默认值**（字号 20 / 行距 0.55× / 段距 0.7× / 首行缩进 2 字 / 两端对齐）⭐⭐⭐
 *   ⇒ **GPL-3.0 ⇒ 只读当规格、不抄代码** ⇒ 观感重写 ⇒ **必须有门禁钉住，否则下次重构就没了** ⭐⭐⭐
 *
 * ⭐⭐⭐ 每条断言都要问「把它改坏，它会不会红」⇒ 都能被变异对照证伪 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'QiReaderLite');
let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

// ── ① ⭐⭐⭐ 四套皮肤（柴阅的宣纸/晴窗/星夜/烛灯）⭐⭐⭐
{
  const p = path.join(ROOT, 'Features/Reader/ReaderSkin.swift');
  ok(fs.existsSync(p), '① 阅读皮肤文件在（ReaderSkin.swift）');
  if (fs.existsSync(p)) {
    const s = read('Features/Reader/ReaderSkin.swift');
    for (const k of ['case xuan', 'case qing', 'case xing', 'case zhu']) {
      ok(s.includes(k), `① 皮肤有 ${k}`);
    }
    for (const k of ['宣纸', '晴窗', '星夜', '烛灯']) {
      ok(s.includes(k), `① 皮肤名有「${k}」`);
    }
    // 柴阅的四个强调色（十六进制）
    for (const hex of ['0xB23A2C', '0x1F2430', '0xE9D9A6', '0xE8A35C']) {
      ok(s.includes(hex), `① 强调色含柴阅原值 ${hex}`);
    }
    // 章节号装饰的四种样式（柴阅：宣纸=朱印 / 晴窗=描边大号 / 星夜=居中小字 / 烛灯=标题下纹样）
    for (const k of ['case seal', 'case outlineBig', 'case centeredSmall', 'case ornament']) {
      ok(s.includes(k), `① 章节号装饰有 ${k}`);
    }
    // 进度装饰
    for (const k of ['case brush', 'case dots', 'case starlight', 'case pageNumber']) {
      ok(s.includes(k), `① 进度装饰有 ${k}`);
    }
    ok(/struct ReaderPageChrome/.test(s), '① 有「一页的 chrome」结构（页眉/页脚/章节号装饰）');
  }
}

// ── ② ⭐⭐⭐ 16 套配色**每套都要有皮肤**（两层分开：颜色 vs 版式）⭐⭐⭐
{
  // ⚠️ 2026-11-25：`ReaderView.swift`（没人用的旧阅读器）已删 ⇒ 配色搬到 ReaderTheme.swift
  const s = read('Features/Reader/ReaderTheme.swift');
  const themes = s.match(/static let \w+ = ReaderTheme\(/g) || [];
  ok(themes.length >= 16, `② 共 ${themes.length} 套配色`);
  const skins = s.match(/skin: \.\w+/g) || [];
  ok(skins.length >= 16, `② ${skins.length} 套配色都指定了皮肤`);
  // 四种皮肤都要有人用
  for (const k of ['.xuan', '.qing', '.xing', '.zhu']) {
    ok(skins.includes('skin: ' + k), `② 有配色用皮肤 ${k}`);
  }
}

// ── ③ ⭐⭐⭐ 一页 = 页眉 + 正文 + 页脚（页眉页脚要占位）⭐⭐⭐
{
  const cfg = read('Features/Reader/Paging/ReaderLayoutConfig.swift');
  ok(/var headerHeight: CGFloat = \d+/.test(cfg), '③ 排版配置有页眉高度');
  ok(/var footerHeight: CGFloat = \d+/.test(cfg), '③ 排版配置有页脚高度');
  // ⭐⭐⭐ **按「函数体切片」判**（别用跨函数的正则 ⇒ 极易误判）⭐⭐⭐
  const pageSizeBody = cfg.slice(cfg.indexOf('func pageSize(in viewport'),
                                 cfg.indexOf('func pageSize(in viewport') + 400);
  ok(pageSizeBody.includes('headerHeight') && pageSizeBody.includes('footerHeight'),
     '③ 页尺寸把页眉页脚两条带**扣掉**（不然文字会压上去）');
  // 页眉页脚高度要进「排版指纹」⇒ 改了必须重排
  const fpBody = cfg.slice(cfg.indexOf('var layoutFingerprint'),
                          cfg.indexOf('var layoutFingerprint') + 700);
  ok(fpBody.includes('headerHeight') && fpBody.includes('footerHeight'),
     '③ 页眉页脚高度进了排版指纹（改了会重排）');

  const vc = read('Features/Reader/Paging/ReaderPageVC.swift');
  ok(/drawPageChrome/.test(vc), '③ 画布会画页眉/页脚');
  ok(/chrome\.header/.test(vc) && /chrome\.footerLeft/.test(vc) && /chrome\.footerRight/.test(vc),
     '③ 页眉 + 页脚左右两段都画');
  ok(/drawChapterNumber/.test(vc), '③ 画布会画章节号装饰');
  ok(/textOrigin = CGPoint\(x: chrome\.horizontalMargin, y: chrome\.headerHeight\)/.test(vc),
     '③ 正文整体下移一条页眉带（给页眉让位）');
  ok(/chrome\.horizontalMargin/.test(vc),
     '③⭐⭐⭐ 正文**左边距生效**（以前 x=0 ⇒ 文字顶到屏幕左边缘、整块偏左 22pt）');
}

// ── ④ ⭐⭐⭐ 排版默认值对齐柴阅 ⭐⭐⭐
{
  const w = read('Features/Reader/ReaderWebView.swift');
  ok(w.includes('@AppStorage("reader.fontSize") private var fontSize: Double = 20'),
     '④ 默认字号 20（柴阅）');
  ok(w.includes('@AppStorage("reader.lineSpacing") private var lineSpacing: Double = 11'),
     '④ 默认行距 11（柴阅 0.55×20）');
  ok(w.includes('@AppStorage("reader.paraSpacing") private var paraSpacing: Double = 14'),
     '④ 默认段距 14（柴阅 0.7×20）');
  ok(w.includes('@AppStorage("reader.paraAlign") private var paraAlign: String = "justify"'),
     '④ 默认**两端对齐**（柴阅 justified=true）');
  ok(/firstLineIndent: CGFloat\(fontSize\) \* 2/.test(w),
     '④ 首行缩进 = 2 个字（随字号，柴阅同款）');
  // 旧默认要一次性对齐（否则老用户永远拿不到新默认值）⭐⭐⭐
  const app = read('App/QiReaderLiteApp.swift');
  ok(/reader\.fontSize[\s\S]{0,200}== 18/.test(app),
     '④ 旧默认 18 会被一次性对齐到新默认（用户自己调过的不动）');
  ok(/reader\.paraAlign[\s\S]{0,200}== "left"/.test(app),
     '④ 旧默认「左对齐」也会一次性对齐成两端对齐');
}

// ── ⑤ ⭐⭐⭐ 分页器要把「书名 / 皮肤 / 进度」交给画布 ⭐⭐⭐
{
  const pager = read('Features/Reader/Paging/PagedChapterPager.swift');
  ok(/var bookTitle: String/.test(pager), '⑤ 分页器知道书名（页眉首屏显示它）');
  ok(/var skin: ReaderSkin/.test(pager), '⑤ 分页器知道皮肤');
  ok(/ReaderPageChrome\(/.test(pager), '⑤ 分页器给每一页构造 chrome');
  // ⭐⭐⭐ **用字符串查找，不用正则**（转义层数很容易写错 ⇒ 这门禁自己崩了就没牙齿）⭐⭐⭐
  ok(pager.includes('footerLeft: "\\(gp.page + 1) / \\(pageCount)"'),
     '⑤ 页脚左 = 页码 / 总页（柴阅同款）');
  ok(pager.includes('String(format: "%.1f%%"'), '⑤ 页脚右 = 全书进度 %（柴阅同款）');
  ok(/isChapterFirstPage: gp\.page == 0/.test(pager), '⑤ 章首页判定（装饰只画在章首页）');
}

console.log(fail === 0 ? `通过 ${pass} / 失败 ${fail}` : `通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
