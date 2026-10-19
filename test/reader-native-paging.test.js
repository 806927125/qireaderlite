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
  // ⚠️⚠️ 这里以前写的是 /\/[\s\S]*?\*\//g —— **漏了一个 \***，
  //    实际含义变成「一个 / … 一个 * … 一个 /」，于是从文件开头的 `///`
  //    一路吃到文件中间的某个 `*/`，把**半个文件**当注释删掉。
  //    之前没暴露是因为 ReaderWebView.swift 里从来没出现过 /* */ 块注释，
  //    我这轮写了 `/* … */` 才引爆 —— 半个文件的断言全变随机结果。
  //
  //    正确写法：\/\* 必须**两个字符紧邻**；而且要先删块注释再删行注释，
  //    否则行注释里的 /* 会误开一个块注释。
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
}

// 剥注释函数自己的自检：门禁工具出错会让下面所有断言变成随机结果
function selfTestStripComments() {
  const src = [
    '/// 文档注释',
    'let a = 1 /* 块注释 */',
    'let b = 2',
    '// 行注释 @State private var pageCtl',
    'let c = 3',
  ].join('\n');
  const out = stripComments(src);
  const keep = ['let a = 1', 'let b = 2', 'let c = 3'];
  return keep.every(k => out.includes(k)) && !out.includes('文档注释')
      && !out.includes('块注释') && !out.includes('行注释');
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
const sess     = fs.readFileSync(path.join(ROOT, 'Core/ReaderSession.swift'), 'utf8');

ok(selfTestStripComments(), 'stripComments 自检通过（门禁工具自己出错的话下面全是随机结果）');

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
ok(!/import CoreText|CTFramesetter|CTFrameGetVisibleStringRange|CTFrameDraw/.test(paginator),
   '分页器**不再用 CoreText**（栖阅二进制里 CTFramesetter 0 处，用的是 NSLayoutManager）');
ok(/NSTextStorage\(attributedString:/.test(paginator), '用 NSTextStorage 装文本');
ok(/NSLayoutManager\(\)/.test(paginator), '用 NSLayoutManager 排版');
ok(/lm\.glyphRange\(for: c\)/.test(paginator), '页边界取自 glyphRange(for: container)');
ok(/lm\.drawGlyphs\(forGlyphRange: g, at: origin\)/.test(paginator),
   '绘制用**同一个** layoutManager 的 drawGlyphs（边界与内容同源，不可能对不齐）');
ok(/lm\.characterRange\(forGlyphRange: g, actualGlyphRange: nil\)/.test(paginator),
   '同时记录 glyph 范围（绘制直接用，不做换算）');
ok(!/translateBy|scaleBy/.test(paginator) || /不要翻转|不翻转/.test(paginator),
   '绘制不翻坐标系（NSLayoutManager 用 UIKit 坐标，翻了会上下颠倒）');
ok(/g\.length > 0\] else \{ break \}|guard g\.length > 0/.test(paginator),
   '页数按实际排版算：循环次数 = 排版出的 container 数，不是估的');
ok(/guard g\.length > 0 else \{ break \}/.test(paginator),
   '装不下字必须 break（否则死循环）');
ok(/result\.count > 20000/.test(paginator), '页数上限兜底（异常文本不吃穿内存）');
ok(/if NSMaxRange\(g\) >= lm\.numberOfGlyphs \{ break \}/.test(paginator),
   '排到末尾即停（终止条件用 numberOfGlyphs，不是估算）');

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

ok(/private var useNativePaging: Bool/.test(web), '有 useNativePaging 判断');
ok(/if useNativePaging/.test(web), '只有「上下滚动」才走 webview');


console.log('\n── 翻页逻辑：章内翻完才换章 ──');
// ★ 跨章：章界**不返回 nil**，而是排一个 loading 占位页。
//   老实现在章界直接 onEdge(1) 然后什么也不管 → 换章失败时正文静默停在
//   上一章第一页，看着就是「翻页卡住 / 翻回去」（用户实机报的 bug）。

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


console.log('\n── 绝不留白正文 ──');
ok(/func pageCount\(of c: Int\)/.test(pager), '按章算页数（重建 spine 用）');
ok(/private var renders: \[Int: ChapterRender\]/.test(pager), '各章排版结果有缓存');
ok(/private func pageCount\(of c: Int\) -> Int \{ renders\[c\]\?\.pageCount \?\? 1 \}/.test(pager),
   '没文本的章按 1 页占位');
ok(/@discardableResult[\s\S]{0,80}private func render\(_ c: Int\)/.test(pager), '有 render() 统一排版');

// ★ 标题 / 页数必须**同一基准**：之前 pageCount 不带标题、makePage 带标题，
//   两边不一致 → 页边界和渲染对不上，标题页错位（用户报的「标题去哪了」）
ok(/config\.attributed\(title: t\.title, body: t\.body\)/.test(pager),
   '页数按「带标题」的基准算');
ok(/paginateJustified\(attr, pageSize: pageSize, config: config\)/.test(pager),
   '页数用 paginateJustified 的返回值算（垂直两端对齐会改行距重排，不能自己数）');
ok(/let attr = config\.attributed\(title: t\.title, body: t\.body\)/.test(pager),
   '标题只排一次进章首页');
ok(/v\.setPage\(paginator: r\.paginator, page: gp\.page/.test(pager),
   '绘制直接用该章排好的 paginator + 页号（不再重新造 attr / 重算页边界）');
ok(!/config\.attributed\(title: gp\.page/.test(pager),
   '**不要**在 makePage 里按页号重新造 attributed（算页带标题、取页不带标题 → 差一整个标题高度）');
ok(/func setPageSize\(_ size: CGSize\)/.test(pager), '视口变化要能重算页数');
ok(/func diagnose\(sessionIndex: Int = -1/.test(pager), 'pager 有自检输出');
ok(/chapterChangeSent/.test(pager) && /followReceived/.test(pager),
   '自检并排显示 pager 和 session 两边（断在哪一眼看到）');
ok(/chapterChangeSent \+= 1/.test(pager), 'pager 记录章变化通知发出次数');
ok(/followReceived \+= 1/.test(sess), 'session 记录 followIndex 收到次数');
ok(/barItem\("自检"/.test(web), '阅读页底栏有自检入口（真机只能靠它拿状态）');
ok(/guard size\.width > 1, size\.height > 1 else \{ return \}/.test(pager),
   'setPageSize 同样不让 .zero 进来（那会算出 80×80 迷你页）');
ok(!/chapterTextProvider/.test(pager), 'pager 不再回头问上层要文本（provider 只会给当前章）');
ok(/private var texts: \[Int: ChapterText\]/.test(pager), 'pager 自己缓存各章正文');
ok(/func chapterTextArrived\(_ c: Int, _ text: ChapterText\)/.test(pager),
   '上层 push 文本给 pager（唯一入口）');
ok(/guard let t = texts\[c\], !t\.body\.isEmpty/.test(pager),
   '排版只读自己的缓存 → 邻章也能排出来');
ok(/func prefetchedText\(index i: Int\)/.test(sess), '预取结果能取出来喂 pager');
ok(/rebuildSpine\(around:/.test(pager), 'spine 会重建');

console.log('\n── 接线：webview 只在上下滚动模式用 ──');
ok(/useNativePaging/.test(web), '有 useNativePaging 判断');
ok(/if useNativePaging/.test(web), '只有「上下滚动」才用 webview');
ok(/PagedReaderUI\(controller: pageCtl\)/.test(web), '新分页器接进阅读页');
ok(/UIPageViewController\(transitionStyle/.test(pager), '容器是 UIPageViewController');
ok(/func setMode\(/.test(readerUI), 'SwiftUI 侧能换翻页方式');
ok(/pager\.makeContainer\(mode: newMode\)/.test(readerUI), '换方式时重建容器');
ok(/v\.dataSource = self/.test(pager) && /v\.delegate = self/.test(pager),
   '数据源和代理都接上了（在 makeContainer 里）');
ok(/UIPageViewControllerDataSource, UIPageViewControllerDelegate/.test(pager),
   'pager 真的是 UIPageViewController 的数据源+代理');
ok(/session\.chapterText/.test(web), '正文来源是 session.chapterText');

console.log('\n── CSS 多列那套要彻底没了 ──');
ok(!fs.existsSync(path.join(ROOT, 'Resources/reader/reader-paginate.js')), 'reader-paginate.js 已删');
ok(!/paginateReady|onPaginatePage|onPaginateEdge|onPaginateFail/.test(host), 'ReaderHost 不再有 CSS 分页的桥');
ok(!/paginateReady|repaginate/.test(web), 'ReaderWebView 不再有 CSS 分页的接线');
ok(!/installPaginate|callPaginateJS/.test(host), '没有残留的注入/调用');

console.log('\n── 用户报的问题 ①：第一章最后一页划不到第二章第一页 ──');
ok(/func show\(cursor idx: Int/.test(pager), '能切到全书序列的任意位置');
ok(/func turn\(_ delta: Int\)/.test(pager), '能翻页');
// SwiftUI ↔ pager 的类型边界：闭包参数不标类型会推不出来
ok(/\{ \(p: Int, total: Int\) in/.test(web), 'onPageChange 闭包参数标了类型');
ok(/\{ \(c: Int\) in/.test(web), 'onNeedChapter / onChapterChange 闭包参数标了类型');
// ReaderLayoutConfig 是全默认值的 struct，没有 static default
ok(!/ReaderLayoutConfig\.default/.test(pager), '没有用不存在的 ReaderLayoutConfig.default');
ok(/ReaderLayoutConfig\(\)/.test(pager), '用 ReaderLayoutConfig() 初始化');
// ReaderBaselineScope 是 struct（不是 enum），成员是 .word 不是 .text
ok(!/\.baselineScope\.rawValue/.test(web), 'ReaderBaselineScope 用 .raw 不是 .rawValue');
ok(/scope != \.full/.test(pageVC),
   '底线范围用 == 比较（ReaderBaselineScope 是 struct，对它 switch 报 must be exhaustive）');
ok(/p\.lineRects\(at: pageIndex\)/.test(pageVC), '行底线用 paginator 的行矩形（不手动算基线偏移）');
ok(/func lineRects\(at index: Int\) -> \[CGRect\]/.test(paginator), 'paginator 有统一的行矩形方法');
ok(!/lm\.numberOfLineFragments|lm\.numberOfLineFragments|\.numberOfLineFragments\(/.
   test(paginator.replace(/\/\/[^\n]*/g, '')) && !/\.numberOfLineFragments\(/.test(pageVC.replace(/\/\/[^\n]*/g, '')),
   '**没调用 numberOfLineFragments(forGlyphRange:)** —— iOS 的 NSLayoutManager 没这个方法（只有 macOS 有），编译器会直接报 has no member');
ok(/lineFragmentRect\(forGlyphAt: glyphIdx, effectiveRange: &eff\)/.test(paginator),
   '逐行靠 lineFragmentRect + effectiveRange 推进（iOS 上量行的唯一姿势）');
ok(/if next <= glyphIdx \{ break \}/.test(paginator), '行推进有防死循环检查');
ok(!/CTLineGetImageBounds|unsafeBitCast|CFArray/.test(pageVC),
   '页画布里没有 CoreText 调用');
ok(/lm.lineFragmentRect\(forGlyphAt: glyphIdx/.test(paginator),
   '行范围用 lineFragmentRect（CoreText 那套 CTLineGetImageBounds 换成了 UIKit API）');
ok(!/CTLineGetImageBounds/.test(pageVC), '页画布里不再有 CTLine 调用');
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
ok(/pager\.chapterTextArrived\(session\.index, text\)/.test(web), '上层 push 章节文本');
// ★ chapterTextArrived 绝不能跳页 —— 文本是异步到的，一到就跳首页
//   就是用户报的「下面控件上的目录显示乱跳」
ok(/func chapterTextArrived\(_ c: Int, _ text: ChapterText\)/.test(pager), '有 chapterTextArrived');
// ⚠️ 这条以前写成 `show(cursor: firstIndexOf` —— **正则里少了个 `(`**，
//    `firstIndexOf` 跟源码里的 `firstIndex(ofChapter:` 压根不匹配，
//    于是这条断言**永远绿**。正则写错比没有更危险：它假装在守，实际没守。
const arrivedBody = pager.slice(pager.indexOf('func chapterTextArrived'),
                                pager.indexOf('private func refresh'));
ok(!/show\(cursor: firstIndex/.test(arrivedBody),
   '文本到齐不跳该章首页（跳了就是底部控件乱跳的来源）');
ok(/refresh\(at: at\)/.test(arrivedBody), '文本到齐走原地重画，保持当前页');
ok(/func refresh\(at idx: Int\)/.test(pager), '原地重画当前页');
ok(/let at = cursor/.test(pager), '重排时记着当前位置');
ok(/loadChapter[\s\S]{0,300}?show\(cursor: firstIndex\(ofChapter: c\)/.test(pager),
   '只有真正换章才落该章第一页');

// ★ 串章防护：章号先变、文本后到（异步），provider 必须三重校验
// ⚠️ 之前用 provider 回调 + 三重校验，**把邻章也堵死了**：
//    回调只给当前章，邻章永远拿不到文本 → pageCount=1 → 翻过去卡在加载页。
ok(!/chapterTextProvider/.test(web), '不用 provider 回调拿文本');
ok(/session\.prefetchedText\(index: c\)/.test(web), '邻章文本从 session 预取缓存拿');
ok(/func followIndex\(_ i: Int\)/.test(sess), '有 followIndex（只跟章号不跳页）');
ok(/pager\.onChapterChange[\s\S]{0,200}?session\.followIndex\(c\)/.test(web),
   'onChapterChange 只跟不跳');
// ⚠️ session.index 现在会跟着 pager 走了（点击翻页也通知），
//    所以 syncPager 里**绝不能**按 switchedChapter 调 loadChapter ——
//    那会把用户刚点着翻到「第4章第2页」打回第1页。
ok(!/pager\.loadChapter\(session\.index\)/.test(web),
   'syncPager 里不调 loadChapter（会跳章首页，把用户的页打回去）');
ok(/func jumpToChapter\(_ c: Int\)/.test(pager), '目录跳章有独立入口 jumpToChapter');
ok(/pager\.jumpToChapter\(i\)/.test(web), '从目录选章才调 jumpToChapter');

// ★ 点击翻页跨章必须通知上层 —— 之前只有 didFinishAnimating 有，
//   点着翻页走 show() 那条路完全不通知 → session.index 停在 0
//   → 底栏永远「第一章 上岸被斩 · 第1章」（用户实机报的）
ok(/private func syncChapterIfNeeded\(_ gp: GlobalPage\)/.test(pager), '章变化同步抽成一处');
{
  const showBody = pager.slice(pager.indexOf('func show(cursor idx: Int'),
                                  pager.indexOf('func turn(_ delta: Int)'));
  ok(/syncChapterIfNeeded\(target\)/.test(showBody),
     'show(cursor:) 也通知（点击翻页跨章靠这条）');
  const refreshBody = pager.slice(pager.indexOf('private func refresh(at idx: Int)'),
                                  pager.indexOf('// MARK: - 页面构造'));
  ok(/syncChapterIfNeeded\(spine\[idx\]\)/.test(refreshBody), 'refresh 也通知');
  const didFin = pager.slice(pager.indexOf('didFinishAnimating'));
  ok(/syncChapterIfNeeded\(gp\)/.test(didFin), 'didFinishAnimating 也通知');
}
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
ok(/lineFragmentRect\(forGlyphAt:/.test(paginator), '「按文字」范围用了行 fragment 边界');
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
ok(/lineFragmentRect/.test(paginator), '行范围用 lineFragmentRect');
ok(!/as\? CTLine/.test(paginator), '别对 CTLine 做条件转换（编译期报 always succeed）');
ok(!/unsafeBitCast/.test(paginator), '没有 unsafeBitCast 取 CoreFoundation 类型');
// CFArray 没有 count
ok(/func lineCount\(at index: Int\)/.test(paginator), '有量行数的方法（垂直两端对齐要用）');
ok(/lineRects\(at: index\)\.count/.test(paginator), '行数由行矩形数量得出，不调不存在的 API');
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
ok(/addTextContainer/.test(paginator), '分页靠连续 addTextContainer（UIKit 自动接着往下排）');
ok(/lineFragmentPadding = 0/.test(paginator),
   '清掉 lineFragmentPadding（默认左右各 5pt，不清每页都会少排几个字）');
ok(!/ctx\.translateBy|ctx\.scaleBy/.test(paginator),
   '绘制不翻转坐标系（NSLayoutManager 用 UIKit 坐标）');

// ── 跨章翻页：加载竞态 + 失败必须可见 ────────────────────────────
// 症状：翻到第二章末尾再往下翻，回到第二章开始且内容不变。
// 根因两条：
//   ① load(index:) 没有竞态防护 —— load(2)/load(3) 同时在飞，
//      旧结果后到就把 chapterText 覆盖回上一章
//   ② load 失败时 errorText 写了但**没有任何 UI 显示**，
//      正文静默停在上一章第一页，看着就是「翻页卡住」
{
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
  ok(/func chapterFailed\(/.test(pager), '换章失败时把占位页换成失败页');
  ok(/showFailure\(/.test(pager + pageVC), '占位页能改成失败页');
  ok(/stepBack: \{ \[weak self\] in self\?\.turn\(-1\)/.test(pager), '失败页给出回上一章的退路');
  ok(/func reloadCurrent\(\)/.test(sess), '有重新加载当前章的入口');
  ok(/retry: \{ \[weak self\] in/.test(pager), '失败页的重试真的接上了');
  ok(/case \.loading/.test(pageVC) && /case \.failure/.test(pageVC), '页有加载态和失败态两种');
}

// ── 全书页平铺：跨章在数据源层不存在 ──────────────────────────
// 用户实机报：① 翻到下一张一直「正在加载中」② 翻到最后一页再翻回到第一章。
// 根因同一个：**我把 viewControllerBefore/After 当命令方法，在里面换章。**
// 它们是 UIKit 的**查询**方法 —— 预取/布局/用户取消手势都会调，一次翻页触发好几次，
// loading 标志位卡在 true 永远复位不了。
// 现在：全书页平铺成连续序列，章界就是 idx+1，数据源里没有跨章分支、没有 loading 标志。
{
  ok(/private\(set\) var spine: \[GlobalPage\]/.test(pager), '有全书页序列 spine');
  ok(/struct GlobalPage[\s\S]{0,80}let chapter: Int[\s\S]{0,60}let page: Int/.test(pager),
     '每页记录「哪一章第几页」');

  const before = pager.slice(pager.indexOf('viewControllerBefore'), pager.indexOf('viewControllerAfter'));
  const after  = pager.slice(pager.indexOf('viewControllerAfter'), pager.indexOf('didFinishAnimating'));
  ok(!/requestStep|onStep|step\(/.test(before), 'viewControllerBefore 里不换章（那是查询不是命令）');
  ok(!/requestStep|onStep|step\(/.test(after),  'viewControllerAfter 里不换章');
  ok(!/private var loading: Bool/.test(pager),  '没有跨章 loading 标志位（卡死的来源）');
  ok(!/var onStep:/.test(pager),                 '没有 onStep 回调');
  ok(/var onNeedChapter:/.test(pager),           '改成「需要某章正文」的回调');
  ok(/ensureNeighbor/.test(pager),                '接近章尾就预取邻章');
  ok(/func prefetch\(index i: Int\) async -> Bool/.test(sess), 'ReaderSession 有 prefetch');
  ok(/@discardableResult/.test(sess),            '预取结果不用也不报警告');

  // 章界在数据源里就是普通的一页接一页
  ok(/spine\.indices\.contains\(v\.slot \+ 1\)/.test(after), 'after 就是 spine[idx+1]');
  ok(/spine\.indices\.contains\(v\.slot - 1\)/.test(before), 'before 就是 spine[idx-1]');
  ok(!/pages\.indices\.contains\(next\)/.test(pager), '不再有「章内页数」边界判断');

  // 上层接线
  ok(/pager\.onNeedChapter = /.test(web), '接了 onNeedChapter');
  ok(/pager\.onChapterChange = /.test(web), '接了 onChapterChange');
  ok(!/pager\.onStep = /.test(web), '不再接 onStep');
  ok(/pager\.chapterCount = session\.flat\.count/.test(web), '告诉 pager 一共几章');
ok(/pager\.chapterTextArrived\(session\.index, text\)/.test(web), '把当前章正文 push 给 pager');
  ok(/pager\.chapterTextArrived\(session\.index, text\)/.test(web),
     '上层 push 章节文本给 pager（不再用 provider 回调）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
