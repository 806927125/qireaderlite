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
const pager    = stripComments(fs.readFileSync(path.join(P, 'PagedChapterPager.swift'), 'utf8'));
const pageVC   = stripComments(fs.readFileSync(path.join(P, 'ReaderPageVC.swift'), 'utf8'));
const readerUI = stripComments(fs.readFileSync(path.join(P, 'PagedReaderUI.swift'), 'utf8'));
const webRaw   = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
const web      = stripComments(webRaw);
const host     = fs.readFileSync(path.join(ROOT, 'Core/ReaderHost.swift'), 'utf8');

console.log('\n── 栖阅那套的骨架要在 ──');
ok(fs.existsSync(path.join(P, 'ReaderPaginator.swift')), 'ReaderPaginator.swift（分页器）');
ok(fs.existsSync(path.join(P, 'ReaderLayoutConfig.swift')), 'ReaderLayoutConfig.swift（排版配置）');
ok(fs.existsSync(path.join(P, 'PagedChapterPager.swift')), 'PagedChapterPager.swift（分页数据源）');
ok(fs.existsSync(path.join(P, 'ReaderPageVC.swift')), 'ReaderPageVC.swift（一页一个 VC）');
ok(fs.existsSync(path.join(P, 'PagedReaderUI.swift')), 'PagedReaderUI.swift（SwiftUI 壳）');
// 老实现必须真的删掉，别留着当「备用方案」—— 留着就还会有人改错的那个
ok(!fs.existsSync(path.join(P, 'PagedReaderView.swift')), '老的手写翻页实现已删掉');
ok(!/rotation3DEffect/.test(pager + pageVC + readerUI), '不再用 rotation3DEffect 硬凑卷曲');

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
// ⚠️ transitionStyle / navigationOrientation 是 **get-only**，只能在 init 设。
//    所以「仿真」的实现形态是「按方式重建容器」，不是事后赋值
//    （事后赋值报 "cannot assign to property: 'transitionStyle' is a get-only property"）
ok(/func makeContainer\(mode: String\) -> UIPageViewController/.test(pager), '容器可按翻页方式重建');
ok(/\? \.pageCurl : \.scroll/.test(pager), '仿真用系统 pageCurl 真卷曲，其余走 scroll');
ok(!/\.transitionStyle = /.test(pager), '没有事后赋值 transitionStyle（get-only，赋不了）');
ok(!/pageViewControllerOptions/.test(pager), '没有 pageViewControllerOptions（SDK 里没这个成员）');
ok(/animated && turnMode != "none"/.test(pager), '无动画 = 关掉容器动画');
ok(/turnMode != "none"/.test(pager), '无动画直接切页（关掉容器动画）');
ok(/pageTurnMode != "scroll"/.test(web), '上下滚动走 webview（不用原生分页）');
ok(!/turnMode == "scroll"/.test(pager), '原生分页器不处理上下滚动（那是 webview 的活）');

console.log('\n── 翻页逻辑：章内翻完才换章 ──');
// ★ 跨章：章界**不返回 nil**，而是排一个 loading 占位页。
//   老实现在章界直接 onEdge(1) 然后什么也不管 → 换章失败时正文静默停在
//   上一章第一页，看着就是「翻页卡住 / 翻回去」（用户实机报的 bug）。
ok(/requestStep\(1\)/.test(pager) && /requestStep\(-1\)/.test(pager), '章首/章尾都会触发换章');
ok(/pages\.indices\.contains\(next\)/.test(pager), '页数参与边界判断');
ok(/makeStatus\(\.loading\)/.test(pager), '章界排 loading 占位页');
// ⚠️ 分号写成 `return nil;?` 是必须的 —— Swift 里 `return nil` **不带分号**，
//    早先写成 `return nil;` 这条断言就从来没生效过（去掉分号就不匹配 → 永远绿）。
const afterAt = pager.indexOf('viewControllerAfter');
const afterBody = afterAt >= 0 ? pager.slice(afterAt, pager.indexOf('didFinishAnimating')) : '';
// 只查 `if next >= pages.count { … }` 那个章界分支 ——
// 函数末尾那个兜底 `return nil` 是合法的（章首占位页 / 防御），别一起否掉
const edge = afterBody.slice(afterBody.indexOf('if next >= pages.count'));
const edgeBlock = edge.slice(0, (edge.indexOf('\n        }') + 10) || edge.length);
ok(/return nil/.test(edgeBlock) === false,
   '章界分支不返回 nil（返回 loading 占位页，卡住时用户看得见）');
ok(/requestStep\(1\)/.test(afterBody), 'viewControllerAfter 自己在章界触发换章，不靠别处兜');
ok(/makeStatus\(\.loading\)/.test(afterBody), '章界返回的是 loading 占位页');

console.log('\n── 绝不留白正文 ──');
ok(/r\.count > 1 \|\| text\.count <= 400/.test(pager), '长文本只排一页 = 排版坏了（判定还在）');
ok(/fail\("这一章排版异常/.test(pager), '排版异常有出路，不是空白页');
ok(/fail\("这一章解析出来的正文是空的/.test(pager), '空正文有兜底文案');

console.log('\n── 接线：webview 只在上下滚动模式用 ──');
ok(/useNativePaging/.test(web), '有 useNativePaging 判断');
ok(/pageTurnMode != "scroll"/.test(web), '只有「上下滚动」才用 webview');
ok(/PagedReaderUI\(controller: pageCtl\)/.test(web), '新分页器接进阅读页');
ok(/UIPageViewController\(transitionStyle/.test(pager), '容器是 UIPageViewController');
ok(/func setMode\(/.test(readerUI), 'SwiftUI 侧能换翻页方式');
ok(/pager\.makeContainer\(mode: newMode\)/.test(readerUI), '换方式时重建容器');
ok(/vc\.dataSource = self/.test(pager), '数据源接上了');
ok(/vc\.delegate = self/.test(pager), '代理接上了（翻完要记页码）');
ok(/UIPageViewControllerDataSource, UIPageViewControllerDelegate/.test(pager),
   'pager 真的是 UIPageViewController 的数据源+代理');
ok(/session\.chapterText/.test(web), '正文来源是 session.chapterText');

console.log('\n── CSS 多列那套要彻底没了 ──');
ok(!fs.existsSync(path.join(ROOT, 'Resources/reader/reader-paginate.js')), 'reader-paginate.js 已删');
ok(!/paginateReady|onPaginatePage|onPaginateEdge|onPaginateFail/.test(host), 'ReaderHost 不再有 CSS 分页的桥');
ok(!/paginateReady|repaginate/.test(web), 'ReaderWebView 不再有 CSS 分页的接线');
ok(!/installPaginate|callPaginateJS/.test(host), '没有残留的注入/调用');

console.log('\n── 用户报的问题 ①：第一章最后一页划不到第二章第一页 ──');
ok(/func show\(at index: Int/.test(pager), '能切到指定页');
// SwiftUI ↔ pager 的类型边界：闭包参数不标类型会推不出来
ok(/\{ \(p: Int, total: Int\) in/.test(web), 'onPageChange 闭包参数标了类型');
ok(/\{ \(dir: Int\) in/.test(web), 'onStep 闭包参数标了类型');
// ReaderLayoutConfig 是全默认值的 struct，没有 static default
ok(!/ReaderLayoutConfig\.default/.test(pager), '没有用不存在的 ReaderLayoutConfig.default');
ok(/ReaderLayoutConfig\(\)/.test(pager), '用 ReaderLayoutConfig() 初始化');
// ReaderBaselineScope 是 struct（不是 enum），成员是 .word 不是 .text
ok(!/\.baselineScope\.rawValue/.test(web), 'ReaderBaselineScope 用 .raw 不是 .rawValue');
ok(/scope == \.full/.test(pageVC) && /else/.test(pageVC),
   '底线范围用 == 比较（ReaderBaselineScope 是 struct，对它 switch 报 must be exhaustive）');
ok(/CTLineGetImageBounds\(line, nil\)/.test(pageVC),
   'CTLineGetImageBounds 照抄 ReaderPaginator 里编译通过过的写法（传 nil）');
ok(!/CTLineGetImageBounds\(line, CGRect/.test(pageVC),
   '第二参别自己传 CGRect —— 报错说 CGContext 但实参是 rect，纯误导');
ok(/@State private var pageCtl/.test(web), 'UIViewController 用 @State 持有（不是 @StateObject，那个要 ObservableObject）');
ok(!/@StateObject private var pageCtl/.test(web), '没给 UIViewController 挂 @StateObject');
ok(/case failure\(String\)/.test(pageVC), 'Content 枚举不再用 message（跟参数名同名会推不出类型）');
ok(/configure\(kind: \.failure\(msg\)/.test(pageVC),
   '带关联值的 case 要写 .failure(msg)，光写 .failure 报 "expects argument of type String"');
ok(!/var lastText = ""/.test(pager) || !/private var lastText/.test(pager),
   'lastText 不是 private（换容器时 PagedReaderController 在别的文件要用）');
ok(/didFinishAnimating/.test(pager), '翻完动画后回写当前页');
// 换章判定不再靠「chapterKey 立刻变、正文异步到」，而是正文真变了才重排
// —— 老做法每次换章都先闪一下上一章第一页，看着就像翻页坏了
ok(/session\.index == pagedChapter && session\.chapterText == pagedText/.test(web),
   '换章重排靠正文比对，不是靠 chapterKey 立刻变');
ok(!/chapterKey/.test(pager + pageVC), '新架构里已经没有 chapterKey 这个概念了');

console.log('\n── 用户报的问题 ③：每章开始的标题 ──');
ok(/func reload\(text: String, title: String/.test(pager), '重排入口带 title');
ok(/config\.attributed\(title: title, body: text\)/.test(pager), '标题进排版内容');
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
ok(/paginateJustified/.test(pager), '垂直两端对齐真接进分页器');
ok(/showBaseline/.test(pager + pageVC) && /drawBaselines/.test(pageVC + paginator), '行底线真画了');
ok(/CTLineGetImageBounds/.test(paginator), '「按文字」范围用了行内字形边界');
ok(/paraAlign\.textAlignment/.test(layout), '段落对齐真进排版');
// 点击翻页交给系统容器，不再手写 tap —— 避免和系统手势互相打架
ok(!/tapAnywhereTurnsPage/.test(pager), '不再手写 tap 翻页');
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
// 重构后页面是 UIViewController，不再有「UIColor/UIFont 直接喂 SwiftUI」那类坑
ok(!/Color\(uiColor: config\.backgroundColor\)/.test(web + pager + pageVC),
   '页面已是 UIViewController，不需要把 UIColor 包成 Color');
ok(!/\.font\(config\.resolvedFont\)/.test(web + pager + pageVC), '.font() 不再直接吃 UIFont');
ok(!/window\.QiReader\.enable/.test(host), '别再把分页方法打到 window.QiReader 上');
ok(/CTFramesetterCreateFrame/.test(paginator), '页框用 framesetter 生成');
ok(/ctx\.translateBy\(x: 0, y: bounds\.height\)/.test(paginator),
   'CoreText 绘制要翻转坐标系（否则字是反的）');

// ── 跨章翻页：加载竞态 + 失败必须可见 ────────────────────────────
// 症状：翻到第二章末尾再往下翻，回到第二章开始且内容不变。
// 根因两条：
//   ① load(index:) 没有竞态防护 —— load(2)/load(3) 同时在飞，
//      旧结果后到就把 chapterText 覆盖回上一章
//   ② load 失败时 errorText 写了但**没有任何 UI 显示**，
//      正文静默停在上一章第一页，看着就是「翻页卡住」
{
  const sess = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Core', 'ReaderSession.swift'), 'utf8');
  const web = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Features', 'Reader', 'ReaderWebView.swift'), 'utf8');

  const loadBody = sess.slice(sess.indexOf('func load(index i: Int)'),
                              sess.indexOf('func load(index i: Int)') + 1800);
  ok(/guard self\.index == i else \{ return \}/.test(loadBody),
     'load 落地前校验 index 没被后续翻页改掉（防竞态）');
  ok(/loadingChapter = true/.test(sess), '有 loadingChapter 状态');
  ok(/@Published var loadingChapter/.test(sess), 'loadingChapter 是 @Published，UI 才收得到');

  // 失败必须给正文 + 给出口
  const catchBody = loadBody.slice(loadBody.indexOf('} catch {'));
  ok(/chapterText = ""/.test(catchBody),
     '换章失败时清空正文 —— 不清就会静默停在上一章第一页');
  ok(/reportFailure/.test(pager), '换章失败时把占位页换成失败页');
  ok(/func retry\(/.test(pager), '有重试入口');
  ok(/onRetry/.test(pager) && /onStepBack/.test(pager), '失败页给出重试 + 回上一章两个出口');
  ok(/reloadCurrent/.test(sess) && /onStep\?\(0\)/.test(pager), '重试会真的重新拉当前章');
  ok(/case \.loading/.test(pageVC) && /case \.failed/.test(pageVC), '页有加载态和失败态两种');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
