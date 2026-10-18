/**
 * 原生分页门禁。
 *
 * 背景：用户骂「一点逻辑没抄，翻页那个就是摆设」——
 * 栖阅的翻页是**原生**的（ReaderPaginator / ReaderPageView / PageViewController，
 * 「仿真」还是 UIKit 的 pageCurl 真卷曲），
 * 而我之前自己拍脑袋造了一套 CSS 多列，还打错 JS 对象名，
 * 结果分页从头到尾没启用过。
 *
 * 现在只保留原生这套，门禁钉住它不退化。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, l, e) => { if (c) { pass++; console.log(`  ✓ ${l}`); } else { fail++; console.log(`  ✗ ${l}${e ? '  → ' + e : ''}`); } };

const P = path.join(ROOT, 'Features/Reader/Paging');
const paginator = fs.readFileSync(path.join(P, 'ReaderPaginator.swift'), 'utf8');
const layout   = fs.readFileSync(path.join(P, 'ReaderLayoutConfig.swift'), 'utf8');
const paged    = fs.readFileSync(path.join(P, 'PagedReaderView.swift'), 'utf8');
const web      = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
const host     = fs.readFileSync(path.join(ROOT, 'Core/ReaderHost.swift'), 'utf8');

console.log('\n── 栖阅那套的骨架要在 ──');
ok(fs.existsSync(path.join(P, 'ReaderPaginator.swift')), 'ReaderPaginator.swift（分页器）');
ok(fs.existsSync(path.join(P, 'ReaderLayoutConfig.swift')), 'ReaderLayoutConfig.swift（排版配置）');
ok(fs.existsSync(path.join(P, 'PagedReaderView.swift')), 'PagedReaderView.swift（分页阅读器）');

console.log('\n── 分页器：CoreText，页边界要精确 ──');
ok(/import CoreText/.test(paginator), '用了 CoreText');
ok(/CTFramesetterCreateWithAttributedString/.test(paginator), '用 CTFramesetter 排版');
ok(/CTFrameGetVisibleStringRange/.test(paginator), '用 visibleStringRange 取页边界');
ok(/CTFrameDraw/.test(paginator), '用 CTFrameDraw 画页');
ok(/Math\.ceil|visible\.length > 0/.test(paginator), '页数按实际排版算，不是猜的');
ok(/guard visible\.length > 0 else \{ break \}/.test(paginator),
   '装不下字必须 break（否则死循环）');
ok(/NSRange\(location: start, length: visible\.length\)/.test(paginator), '每页记精确字范围');

console.log('\n── 翻页方式：5 种齐全，且都真的实现 ──');
for (const [raw, name] of [['flip','仿真'],['slide','滑动'],['flat','平移'],['none','无动画'],['scroll','上下滚动']]) {
  ok(new RegExp(`raw: "${raw}",[\\s,]+name: "${name}"`).test(web), `${name}（${raw}）在设置里`);
}
ok(/mode == "flip"/.test(paged), '仿真有独立渲染分支');
ok(/flipStack/.test(paged) && /rotation3DEffect/.test(paged), '仿真用 3D 翻页（对应栖阅「卷曲翻转」）');
ok(/slideStack/.test(paged), '滑动/平移用平移栈');
ok(/mode == "none"/.test(paged), '无动画直接切页');
ok(/pageTurnMode != "scroll"/.test(web), '上下滚动走 webview（不用原生分页）');
ok(!/mode == "scroll"/.test(paged), '原生分页器不处理上下滚动（那是 webview 的活）');

console.log('\n── 翻页逻辑：章内翻完才换章 ──');
ok(/onEdge\(-1\)/.test(paged) && /onEdge\(1\)/.test(paged), '到章首/章尾会回调换章');
ok(/pages\.count/.test(paged), '页数参与边界判断');
ok(/incoming == nil/.test(paged), '拖到没有邻页时才算到边');
ok(/goPage\(-1\)|goPage\(1\)/.test(paged), '点左/右也能翻页');

console.log('\n── 绝不留白正文 ──');
ok(/layoutLooksBroken/.test(paged), '有分页异常检测');
ok(/pages\.count <= 1 && text\.count > 400/.test(paged), '长文本只排一页 = 排版坏了');
ok(/ScrollView \{[\s\S]{0,300}?Text\(text\)/.test(paged), '坏掉时退回连续滚动，不是空白页');
ok(/本章没有内容/.test(paged), '空正文有兜底文案');

console.log('\n── 接线：webview 只在上下滚动模式用 ──');
ok(/useNativePaging/.test(web), '有 useNativePaging 判断');
ok(/pageTurnMode != "scroll"/.test(web), '只有「上下滚动」才用 webview');
ok(/PagedReaderView\(/.test(web), '原生分页器接进阅读页');
ok(/session\.chapterText/.test(web), '正文来源是 session.chapterText');

console.log('\n── CSS 多列那套要彻底没了 ──');
ok(!fs.existsSync(path.join(ROOT, 'Resources/reader/reader-paginate.js')), 'reader-paginate.js 已删');
ok(!/paginateReady|onPaginatePage|onPaginateEdge|onPaginateFail/.test(host), 'ReaderHost 不再有 CSS 分页的桥');
ok(!/paginateReady|repaginate/.test(web), 'ReaderWebView 不再有 CSS 分页的接线');
ok(!/installPaginate|callPaginateJS/.test(host), '没有残留的注入/调用');

console.log('\n── 踩过的坑不能再踩 ──');
// 存一个叫 frame 的属性 → 成员查找先命中它 → SwiftUI 的 .frame(width:height:) 被遮住
ok(!/\n\s*let frame: CTFrame\?/.test(paginator), 'ReaderPageCanvas 别有 frame 属性（会遮住 .frame() 修饰符）');
ok(!/\n\s*let size: CGSize/.test(paginator), '别有 size 属性（会遮住 .size()）');
ok(!/\n\s*let background: UIColor/.test(paginator), '别有 background 属性（会遮住 .background()）');
ok(/import SwiftUI/.test(paginator), 'ReaderPaginator.swift 要 import SwiftUI（用了 UIViewRepresentable）');
ok(/Color\(uiColor: config\.backgroundColor\)/.test(paged),
   'UIColor 不能直接 .ignoresSafeArea()，要先包成 Color');
ok(!/config\.backgroundColor\.ignoresSafeArea/.test(paged), '没有 UIColor 直接当 View 用的残留');
// UIColor 不是 ShapeStyle，foregroundStyle 要 Color
ok(!/foregroundStyle\(config\.textColor\)/.test(paged), 'foregroundStyle 不能直接吃 UIColor');
ok(/foregroundStyle\(Color\(uiColor: config\.textColor\)\)/.test(paged), '文字颜色先包成 Color');
// .font() 要 SwiftUI Font，不是 UIFont
ok(!/\.font\(config\.resolvedFont\)/.test(paged), '.font() 不能直接吃 UIFont');
ok(/\.font\(Font\(config\.resolvedFont\)\)/.test(paged), 'UIFont 要包成 Font 再给 .font()');
ok(!/window\.QiReader\.enable/.test(host), '别再把分页方法打到 window.QiReader 上');
ok(/CTFramesetterCreateFrame/.test(paginator), '页框用 framesetter 生成');
ok(/ctx\.translateBy\(x: 0, y: bounds\.height\)/.test(paginator),
   'CoreText 绘制要翻转坐标系（否则字是反的）');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
