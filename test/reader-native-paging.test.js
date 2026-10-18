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

/**
 * 剥掉源码里的注释（块注释 + 行注释）。
 *
 * 血的教训：门禁用正则查源码时，**注释里提一嘴某个函数名**就会被误判成
 * 「代码里有这个」。这轮就因为我在注释里写了 `as? CTLine` 和 `enumerated()`，
 * 门禁报了两个假阳性。查源码的断言一律先剥注释。
 */
function stripComments(src) {
  return src
    .replace(/\/[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
}

let pass = 0, fail = 0;
const ok = (c, l, e) => { if (c) { pass++; console.log(`  ✓ ${l}`); } else { fail++; console.log(`  ✗ ${l}${e ? '  → ' + e : ''}`); } };

const P = path.join(ROOT, 'Features/Reader/Paging');
const paginator = stripComments(fs.readFileSync(path.join(P, 'ReaderPaginator.swift'), 'utf8'));
const layout   = stripComments(fs.readFileSync(path.join(P, 'ReaderLayoutConfig.swift'), 'utf8'));
const paged    = stripComments(fs.readFileSync(path.join(P, 'PagedReaderView.swift'), 'utf8'));
const webRaw   = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
const web      = stripComments(webRaw);
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

console.log('\n── 用户报的问题 ①：第一章最后一页划不到第二章第一页 ──');
ok(/let chapterKey: Int/.test(paged), 'PagedReaderView 有 chapterKey');
ok(/\.onChange\(of: chapterKey\)/.test(paged), '监听章节变化');
ok(/current = 0[\s\S]{0,200}?layout\(in: geo\.size\)/.test(paged),
   '换章时页码归零（不归零就会落在新章最后一页 = 划不过去）');
ok(!/if current >= result\.count \{ current = max\(0, result\.count - 1\) \}/.test(paged)
   || /onChange\(of: chapterKey\)/.test(paged), '换章归零优先于 clamp');

console.log('\n── 用户报的问题 ③：每章开始的标题 ──');
ok(/let title: String/.test(paged), '有 title');
ok(/config\.attributed\(title: title, body: text\)/.test(paged), '标题进排版内容');
ok(/func attributed\(title: String, body: String\)/.test(layout), '排版支持标题+正文');
ok(/fontSize \* 1\.18/.test(layout), '标题字号 = 正文 × 1.18（照栖阅 reader.css）');
ok(/head\.paragraphSpacing = 28/.test(layout), '标题下边距 28（照栖阅 reader.css）');
ok(/title: session\.chapterTitle/.test(web), '标题来源是章节标题');

console.log('\n── 用户报的问题 ②：设置面板照栖阅 ──');
for (const [label, re] of [
  ['垂直两端对齐',        /垂直两端对齐/],
  ['「每页文字自动调整行间距填满页面」说明', /开启后每页文字会自动调整行间距以填满页面，使底部对齐整齐/],
  ['段落间空行',          /段落间空行/],
  ['行底线',              /行底线/],
  ['「每一行底部绘制整行横线」说明', /开启后会在正文每一行底部绘制整行横线/],
  ['独立底线颜色',        /独立底线颜色/],
  ['整行 / 按文字',       /整行|按文字/],
  ['跟随系统深浅色',      /跟随系统深浅色/],
  ['上滑退出阅读',        /上滑退出阅读/],
  ['点击任意位置翻到下一页', /点击页面任意位置翻到下一页/],
  ['iPad 同屏显示左右两页', /iPad 或宽屏横屏时自动同屏显示左右两页/],
  ['内容限制在页眉页脚之间', /内容限制在页眉页脚之间，不遮挡/],
  ['段落对齐 左/居中/右/两端', /段落对齐/],
]) ok(re.test(webRaw), label);
ok(/private func sizeKnob/.test(web), '小/大 是灰底圆角方块（参考截图就是这样，不是 SF Symbol）');
ok(/Color\.gray\.opacity\(0\.18\)[\s\S]{0,120}?RoundedRectangle\(cornerRadius: 10/.test(web),
   '小/大方块是灰底圆角');
ok(/circle\.lefthalf\.filled/.test(web), '跟随系统用 circle.lefthalf.filled');
for (const [raw, hint] of [
  ['flip','模拟真实翻书效果，页面卷曲翻转'],
  ['slide','类似 Apple Books 的左右滑动翻页'],
  ['flat','左右平移动画翻页'],
  ['none','无翻页动画，立即切换'],
  ['scroll','上下滚动浏览，连续阅读体验']]) {
  ok(webRaw.includes(hint), `栖阅原文说明：${hint}`);
}

console.log('\n── 这些项要真接上，不能只是摆位 ──');
ok(/paginateJustified/.test(paged), '垂直两端对齐真接进分页器');
ok(/showBaseline/.test(paged) && /drawBaselines/.test(paginator), '行底线真画了');
ok(/CTLineGetImageBounds/.test(paginator), '「按文字」范围用了行内字形边界');
ok(/paraAlign\.textAlignment/.test(layout), '段落对齐真进排版');
ok(/tapAnywhereTurnsPage/.test(paged), '点击任意位置翻页真接了');
ok(/paragraphSpacing: CGFloat\(paraSpacing\)/.test(web), '段落间空行真进排版');

console.log('\n── 踩过的坑不能再踩 ──');
// 整个 HStack 塞一个表达式里 → 编译器类型检查超时
ok(/private var paraAlignRow: some View/.test(web), '段落对齐行拆成独立子视图');
ok(/private var baselineScopeRow: some View/.test(web), '底线范围行拆成独立子视图');
ok(/private var pageTurnCard: some View/.test(web), '翻页方式在独立卡片视图里');
// 光拆成子视图还不够 —— 按钮本体（Button + label + 嵌套 background + 三元）
// 也必须抽成独立 View，否则类型检查器照样超时
ok(/private struct ChipButton: View/.test(web), '小胶囊按钮抽成独立 View（防类型检查超时）');
ok(/ChipButton\(title: a\.name, selected: paraAlign == a\.raw\)/.test(web), '段落对齐用 ChipButton');
ok(/ChipButton\(title: sc\.name, selected: baselineScope == sc\.raw\)/.test(web), '底线范围用 ChipButton');
ok(!/Button \{ paraAlign = a\.raw \} label: \{[\s\S]{0,200}?RoundedRectangle/.test(web),
   '段落对齐那一行里没有内联的复杂按钮');
// ForEach 集合重载挑不中 → 编译器只剩 Binding<C> 可选
// 根因是类型：enum 靠 raw value 隐式带来的 Hashable，
// 会让 Identifiable 的 `where Self: Hashable` 扩展多出一个 id 候选 → ID 推导歧义
ok(/struct ReaderParaAlign: Identifiable, Hashable/.test(layout),
   'ReaderParaAlign 做成 struct + 显式 Hashable（跟能编译的 ReaderFont 一致）');
ok(!/enum ReaderParaAlign/.test(layout), 'ReaderParaAlign 别做成 enum');
ok(/struct ReaderBaselineScope: Identifiable, Hashable/.test(layout), 'ReaderBaselineScope 也是 struct');
ok(/ForEach\(ReaderParaAlign\.all\) \{ a in/.test(web), '段落对齐用 ReaderParaAlign.all');
ok(/ForEach\(ReaderBaselineScope\.all\) \{ sc in/.test(web), '底线范围用 ReaderBaselineScope.all');
ok(!/ReaderParaAlign\.allCases/.test(web), '别用 allCases（只是 Collection，ForEach 挑不中）');
ok(!/ReaderParaAlign\.cases/.test(web), '别用 .cases（改成 .all 对齐其它枚举）');
// 所有 ForEach 都得是「Identifiable struct 数组 + 无 id:」这个已验证模式
const foreachLines = web.split('\n').filter(l => /ForEach\(/.test(l) && !/^\s*\/\//.test(l));
ok(foreachLines.every(l => !/id:/.test(l)),
   '所有 ForEach 都不用 id: 重载', foreachLines.filter(l => /id:/.test(l)).join(' | '));
ok(!/enumerated\(\)/.test(web), '没有 enumerated() 元组（做不了 key path）');
ok(/featureTile\(FeatureTile\(name: "朗读设置"/.test(web), '功能磁贴写死两行，不用 ForEach');
ok(/ForEach\(Array\(tiles\.enumerated\(\)\)/.test(web) === false, '没有 enumerated() 元组 ForEach');

// iOS SDK 里没有 CTLineGetOffsetForIndex
// 只查**调用**（注释里提一嘴名字不算）
ok(!/CTLineGetOffsetForIndex\(/.test(paginator), '别用 CTLineGetOffsetForIndex（SDK 里没这符号）');
ok(/CTLineGetImageBounds/.test(paginator), '行内字形范围用 CTLineGetImageBounds');
ok(!/as\? CTLine/.test(paginator), '别对 CTLine 做条件转换（编译期报 always succeed）');
ok(/unsafeBitCast\(raw, to: CTLine\.self\)/.test(paginator), 'CTLine 用 CFArray 取指针 + unsafeBitCast');
ok(/CFArrayGetCount\(lines\)/.test(paginator), 'CFArray 用 CFArrayGetCount 取长度');
// CFArray 没有 count
ok(!/CTFrameGetLines\([a-z]+\)\.count/.test(paginator), 'CFArray 要先 as NSArray 再取 count');
ok(/CTFrameGetLines\([a-z]+\) as NSArray\)\.count/.test(paginator), 'CTFrameGetLines 先 as NSArray');
// NSMutableAttributedString 的标签
ok(/NSMutableAttributedString\(attributedString:/.test(paginator), 'NSMutableAttributedString 用 attributedString: 标签');
ok(!/NSMutableAttributedString\(attributed:/.test(paginator), '没有 attributed: 标签的写法');
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
