/**
 * 阅读设置面板门禁（照栖阅那一版布局）。
 *
 * 用户给了参考截图：字号滑杆 + 字体 → 浅色/深色两排配色格子
 * → 跟随系统深浅色 → 翻页方式（仿真/滑动/平移/无动画/上下滚动）
 * → 功能宫格（大小/间距/朗读/高亮/气泡/格式/标题样式/页眉页脚/更多）。
 *
 * 硬要求：**没接上的功能只摆位不点**（灰掉、disabled）。
 * 给用户一个点下去只会挨骂的按钮，比没有更糟。
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
  // ⚠️ 旧写法 /\/[\s\S]*?\*\//g **漏了一个 \***，实际含义变成
  //    「/ … * … /」，从文件开头的 /// 一路吃到中间的 */，把半个文件删掉。
  //    正确：\/\* 要两个字符紧邻，且先删块注释再删行注释。
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
}

/** stripComments 自检 —— 门禁工具自己出错，下面所有断言都是随机结果 */
function selfTestStripComments() {
  const src = ['/// 文档', 'let a = 1 /* 块 */', '// 行 @State x', 'let b = 2'].join('\n');
  const out = stripComments(src);
  return out.includes('let a = 1') && out.includes('let b = 2')
      && !out.includes('文档') && !out.includes('块') && !out.includes('行 @State');
}

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

const web = stripComments(fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8'));
const chip = web.slice(web.indexOf('private struct ChipButton'));
const panel = web.slice(web.indexOf('private var settingsSheet'),
                         web.indexOf('private var settingsContent'));
const pageTurn = web.slice(web.indexOf('private var pageTurnRow'),
                            web.indexOf('private var featureGrid'));
const view = stripComments(fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderView.swift'), 'utf8'));

console.log('\n── 面板结构（照参考截图 1:1）──');
for (const [label, re] of [
  ['字号行：小方块+滑块+大方块+字体下拉', /private var sizeRow/],
  ['小/大 是灰底圆角方块',            /private func sizeKnob/],
  ['字体下拉是胶囊',                  /private var fontMenu/],
  ['分隔线',                          /private var hairLine/],
  ['配色格子（浅色一排）',            /paletteRow\(ReaderTheme\.light/],
  ['配色格子（深色一排）',            /paletteRow\(ReaderTheme\.darkRow/],
  ['跟随系统深浅色',                  /跟随系统深浅色/],
  ['翻页方式那一行（底并进上半卡片）',  /private var pageTurnRow/],
  ['功能磁贴 4+4（照栖阅）',          /private var featureGrid/],
  // v2 参考实现：color white @ 0.35、borderRadius 22、padding fromLTRB(12,14,12,14)
  ['上半一整块亮底（控件坐在里面）',  /upperPanelCard[\s\S]{0,900}Color\.white\.opacity\(0\.35\)[\s\S]{0,140}cornerRadius: 22/],
  ['亮底含字号/配色/跟随/翻页四块',  /upperPanelCard[\s\S]{0,700}sizeRow[\s\S]{0,80}paletteGrid[\s\S]{0,80}followSystemRow[\s\S]{0,80}pageTurnRow/],
  ['子页：显示设置',                  /private var displaySettingsPage/],
  ['子页：间距设置',                  /private var layoutSettingsPage/],
]) ok(re.test(web), label);

console.log('\n── 液态玻璃：用系统层级的，不是自己糊一层 ──');
// Apple 规则（WWDC25 session 323）：
//   · iOS 26 的 partial-height sheet **默认就是液态玻璃**
//   · .large 全屏 detent 是不透明的
//   · 自定义 presentationBackground 会**覆盖掉**系统的玻璃 → 要去掉
ok(!/FitSheetHeight/.test(web.replace(/\/\/[^\n]*/g,'')), '不再有 FitSheetHeight（面板改 overlay）');
// ⚭� 结构差异：栖阅那块面板是**一整块玻璃**，内部只有细分隔线，
//    配色格 / 磁贴 / 翻页行都直接坐在玻璃上，**没有各自的半透明卡片底**。
//    我原来给每张卡片都垫了 Color.white.opacity(0.34)，
//    结果后面透不出插画，看着像「一堆卡片」而不是「一块面板」。
ok((web.match(/Color\.white\.opacity\(0\.34\)/g) || []).length === 0,
   '面板内部**没有任何独立的半透明白卡片底**（栖阅是一整块玻璃）');
// ⚠️⚠️ build79 之后用户还是说「不像」，这才是真凶：
//    NavigationStack 的 containerBackground 默认是**不透明** systemBackground，
//    我只给三个**子页**写了 ClearNavigationBackground，**根页漏了** →
//    系统玻璃被这层不透明底整个遮死，后面插画透不出来，面板是块米黄色板子。
//    对照证据：目录面板没有 NavigationStack，所以它是透明的。
ok((web.match(/ClearNavigationBackground\(\)/g) || []).length === 4,
   'ClearNavigationBackground 出现 4 次：根页 + 3 个子页（根页以前漏了）');
ok(/\.toolbar\(\.hidden, for: \.navigationBar\)[\s\S]{0,200}ClearNavigationBackground\(\)/.test(web),
   '根页藏导航栏的同时**必须**清 containerBackground');
// 磁贴：8 格统一淡色底，靠文字深浅区分状态（不是两档底色）
{
  const ft = web.slice(web.indexOf('private func featureTileLabel'));
  // 参考实现只有**一层**底色（Colors.grey @ 0.12）。
  // 我原来叠了 qrFill + 一层白（ready 0.34 / 未实现 0.16）= 两档，
  // 结果 4 亮 4 暗，看着像两套东西。
  ok(/background\(Self\.qrFill,[\s\S]{0,60}RoundedRectangle\(cornerRadius: 16/.test(ft),
     '8 格磁贴底色**统一**一层（栖阅那样，不是「亮/暗」两档）');
  ok(!/Color\.white\.opacity\(ready \?/.test(ft), '磁贴不再叠第二层白底');
  ok(/cornerRadius: 16/.test(ft), '磁贴圆角 16（第 4 版）');
  // ⚠️ frame 必须在 background **之前**，否则缺图标的「格式」格
  //    背景比别格矮一截，八格对不齐。
  ok(/frame\(height: 76\)[\s\S]{0,120}\.background\(Self\.qrFill/.test(ft),
     '磁贴等高 76，且 frame 在 background 之前（八格才能对齐）');
  ok(/else \{\s*Color\.clear\.frame\(width: 18, height: 18\)/.test(ft),
     '空图标用 18×18 占位（「格式」格内容基线一致）');
}
// 面板内边距照参考实现 EdgeInsets.fromLTRB(16, 16, 16, 28)：
// 底部 28 是给 home indicator 让的，面板贴到屏边但最后一行磁贴不压指示条。
ok(/padding\(\.horizontal, 12\)[\s\S]{0,80}padding\(\.top, 0\)[\s\S]{0,60}padding\(\.bottom, 12/.test(web),
   '面板内边距左右12/顶0/底12（贴边后内容整体下坐）');
{
  const ub = web.slice(web.indexOf('private var upperPanelCard'),
                       web.indexOf('private func hairLine'));
  ok(/sizeRow[\s\S]{0,40}paletteGrid[\s\S]{0,40}followSystemRow[\s\S]{0,40}hairLine[\s\S]{0,40}pageTurnRow/.test(ub),
     '分割线在「跟随系统」下面（分隔 chips 段），不在字号下面');
  // ⚠️ 内层白卡的 padding **上下左右要对称**。
  //    面板 top padding 是 0（面板本身贴边），
  //    所以白卡上面的间距要靠自己补：top 24 配 left/right 12，
  //    合计和下面 12(面板)+12(本块)=24 一样宽。
  ok(/padding\(EdgeInsets\(top: 24, leading: 12, bottom: 12, trailing: 12\)\)/.test(ub),
     '内层白卡 padding 上下对称（top24 / l12 / b12 / r12）');
}
ok(/in: Circle\(\)/.test(web), '「小 / 大」是圆形灰底（栖阅那样，不是圆角方形）');
// 幕布（scrim）：面板弹出时后面内容要压暗。
// iOS 26 对 `.height()` detent 的自带 scrim 很淡/不显示，真机上完全看不到 ——
// 所以手动加一层，放在 ZStack 最底层、正文之下。
ok(/Color\.black\.opacity\(0\.20\)[\s\S]{0,200}allowsHitTesting\(false\)/.test(web),
   '有幕布（黑色 20%）');
ok(/opacity\(showSettings \? 1 : 0\)/.test(web), '幕布跟着面板显隐淡入淡出');
ok(/Color\.black\.opacity\(0\.20\)[\s\S]{0,120}allowsHitTesting\(false\)/.test(web),
   '幕布不可命中（不能吃掉面板的下拉关闭手势）');
// 面板必须是 overlay 不是 .sheet —— sheet 在独立窗口里贴不了边，
// 而且 BackdropFilter 模糊不到后面的正文，那不是玻璃。
ok(!/\.sheet\(isPresented: \$showSettings\)/.test(web),
   '面板**不用 .sheet**（sheet 贴不了边、也模糊不到后面正文）');
ok(/ZStack\(alignment: \.bottom\)/.test(web), '根容器是 bottom 对齐的 ZStack');
ok(/settingsSheet/.test(web.slice(web.indexOf('ZStack(alignment: .bottom)'))),
   '面板挂在 ZStack 里（等价于 Positioned(bottom:0)）');
ok(/\.background\(\.ultraThinMaterial\)/.test(web),
   '面板用 .ultraThinMaterial（overlay 里才真的能模糊到下面）');
ok(/cornerRadius: 26/.test(web), '面板圆角 26');
ok(/DragGesture\(minimumDistance: 8\)[\s\S]{0,400}showSettings = false/.test(web),
   '自己实现了下拉关闭（overlay 没有系统 sheet 手势可依赖）');
// ⚠️ 「上下滚动」被截成「上下...」的**根因**不是字号，是 `fillsWidth` 强制
//    5 个 chip 平分宽度。v2 参考实现用的是 Wrap（可换行）。
//    我当时的修法是缩字号 —— 治错了地方。
//    现在：字号回 14 / 圆角 22 / 改可换行网格，挤不下就换行，不截字。
// 「上下滚动」被截成「上下...」→ 三轮弯路，根因是**排布**不是字号：
//   ① HStack + fillsWidth 平分放不下 → 我缩字号到 12  ← 治错了
//   ② 改 Wrap / LazyVGrid 可换行 → 真机换行成「无动\n画」，更难看
//   ③ 正解：**等分一行**，13pt 本就放得下（4字≈52pt vs 每格≈65pt）
ok(/fontSize: CGFloat = 13/.test(web) && /cornerRadius: CGFloat = 19/.test(web),
   'chip 字号 13 / 圆角 19（第 4 版）');
ok(/fillsWidth: true/.test(web), 'chip 等分铺满');
ok(!/LazyVGrid/.test(pageTurn), '翻页 chip 不用 LazyVGrid（真机换行成「无动/画」）');
ok(/HStack\(spacing: 6\)[\s\S]{0,240}ForEach\(PageTurnMode\.all\)/.test(pageTurn),
   'chips = HStack(spacing:6) + ForEach，一行五个等分');
ok(/frame\(height: 38\)/.test(chip), 'chip 高 38（第 4 版）');
ok(/minimumScaleFactor\(0\.85\)/.test(chip), '极端情况缩字兜底，常态不触发');
ok(!/Spacer\(minLength: 0\)/.test(web.slice(web.indexOf('var settingsContent'), web.indexOf('var displayCard'))),
   '主面板没有 Spacer（会把 sheet 撑满）');

// ★ iOS 26 的系统玻璃必须是 partial-height sheet。
//   只给 presentationSizing(.fitted) 而不给 detent → sheet 走默认全屏
//   → 全屏不透明 → 玻璃出不来、面板还撑满整屏（build 43 实机就是这么翻车的）。
// 玻璃：overlay 里 .ultraThinMaterial 真的能模糊到下面的正文
ok(/\.background\(\.ultraThinMaterial\)/.test(web), '面板用 .ultraThinMaterial');
// 判定要看**代码**，不能看注释（注释里会写这些名字做说明）
// 目录 sheet 本来就该有 detent（.medium/.large）；
// 只判定**设置面板**那一段没有 detent。
ok(!/presentationDetents/.test(panel),
   '设置面板不使用 presentationDetents（走 overlay，不是 sheet）');
// 推入的子页要透明，否则玻璃被盖
ok((web.match(/modifier\(ClearNavigationBackground\(\)\)/g) || []).length >= 3,
   '三个子页都用了 ClearNavigationBackground');
ok(/private struct ClearNavigationBackground: ViewModifier/.test(web), '有 ClearNavigationBackground 修饰符');
ok(/#available\(iOS 18\.0, \*\)[\s\S]{0,120}?containerBackground\(\.clear, for: \.navigation\)/.test(web),
   '.navigation 那个 placement 是 iOS 18+，必须用 #available 包起来');
// containerBackground(.clear, for: .navigation) 只能活在 #available(iOS 18) 分支里
const navMod = web.slice(web.indexOf('private struct ClearNavigationBackground'));
const avail = navMod.indexOf('#available(iOS 18.0, *)');
const cb = navMod.indexOf('containerBackground(.clear, for: .navigation)');
ok(avail >= 0 && cb > avail, 'containerBackground 在 #available(iOS 18) 之后');
ok(cb < navMod.indexOf('else'),
   'containerBackground 在 if 分支里，else 分支（iOS 17）走另一条路');

console.log('\n── 高度贴合内容 ──');
const mainSheet = web.slice(web.indexOf('private var settingsContent'), web.indexOf('private var upperPanelCard'));
ok(!/ScrollView/.test(mainSheet), '主面板不用 ScrollView（否则 fitted 撑不满）');
ok(/VStack/.test(mainSheet), '主面板用 VStack（内容行数固定，高度确定）');
// 上半是一整块，磁贴是裸的 —— 别退回 build76 那种「每块各垫一层」
// 也不要退回 build79 那种「全删」（上半会不够亮，和下半糊成一片）
ok(/upperPanelCard\s*\n\s*featureGrid/.test(mainSheet),
   '主面板 = 上半一整块 + 磁贴两块（不是每块各垫一层）');
const gridBody = mainSheet.slice(mainSheet.indexOf('featureGrid'));
ok(!/\.background\(\s*Color\.white/.test(gridBody),
   '磁贴区不垫独立白底（裸的面板玻璃，能透出插画）');
const upperBody = web.slice(web.indexOf('private var upperPanelCard'),
                            web.indexOf('private var hairLine'));
ok(!/private var (displayCard|pageTurnCard)/.test(web),
   '旧的 displayCard / pageTurnCard 已并成 upperPanelCard');

console.log('\n── 关键布局细节 ──');
// 字体下拉必须跟滑块同一行（不是单独一行）
const sizeRow = web.slice(web.indexOf('private var sizeRow'), web.indexOf('private func sizeKnob'));
ok(/fontMenu/.test(sizeRow), '字体下拉在字号行里（同一行）');
ok(!/private var fontRow/.test(web), '没有单独的字体行');
// 翻页方式卡片：灰底圆角 + 左侧图标
// 圆角按栖阅 designer.css 的 token 阶梯：--r-sm 8 / --r-md 12 / --r-lg 16
// （翻页方式**不再有卡片底**了 —— 栖阅那行是直接坐在面板玻璃上的）
ok(/cornerRadius: 16/.test(web), '磁贴圆角 16（第 4 版）');
ok(/font\(\.system\(size: 15, weight: \.bold\)\)/.test(web), '磁贴主标题 15/w700（第 4 版）');
ok(/Slider\(value: \$fontSize, in: 14\.\.\.34/.test(web),
   '字号滑块 14...34（v2 参考实现 min:14 max:34）');
// ⭐ 填充色必须**带蓝调**（栖阅 --fill: rgba(120,120,128,0.12)），
//    不是纯灰 —— 纯灰叠在暖色纸背景上显脏。
ok(/Color\(red: 120\/255, green: 120\/255, blue: 128\/255\)\.opacity\(0\.12\)/.test(web),
   '控件底色用栖阅 --fill（120,120,128 偏冷的灰）');
ok(!/\.background\(Color\.gray\.opacity/.test(web),
   '**没有**用 Color.gray.opacity 当填充 —— 那是纯灰，不是栖阅的冷灰');
ok(/Color\(red: 60\/255, green: 60\/255, blue: 67\/255\)\.opacity\(0\.12\)/.test(web),
   '细分隔线用栖阅 --line (60,60,67,0.12)');
ok(/Image\(systemName: "description"\)/.test(web), '翻页方式左边有图标（v2 用 description_outlined，18pt）');
// 磁贴：图标 + 粗体标题 + 副标题
ok(/Image\(systemName: icon\)/.test(web), '磁贴有图标');
ok(/Text\(name\)\.font\(\.system\(size: 15, weight: \.bold\)\)/.test(web),
   '磁贴主标题 15 / w700（第 4 版）');
ok(/Text\(subtitle \?\? ""\)\.font\(\.system\(size: 11\)\)/.test(web),
   '磁贴副标题 11pt（第 4 版 size:11）');
// ⭐ 文案逐格照抄栖阅截图，不是我自己起的名
const TILES = [
  ['大小', '显示设置', 'doc.text'],
  ['间隔', '间隔设置', 'line.3.horizontal.decrease'],
  ['朗读', '朗读设置', 'speaker.wave.2'],
  ['高亮', '高亮设置', 'highlighter'],
  ['气泡', '设置', 'bubble.left.and.bubble.right'],
  ['格式', '标题样式', ''],          // ← 栖阅这格没有图标
  ['页眉', '页脚', 'doc.text'],
  ['更多', '设置', 'ellipsis.circle'],
];
for (const [n, sub] of TILES) {
  ok(web.includes(`("${n}", "${sub}"`), `磁贴「${n} / ${sub}」在（栖阅原文案）`);
}
ok(TILES.length === 8, '一共 8 格');
ok(/private func tileRow\(_ from: Int\)/.test(web) &&
   /Self\.tiles\[from\.\.<min\(from \+ 4/.test(web),
   '按 4 + 4 两行排（不是 4 + 5 —— 那样第二行长一截，就是用户说的「怪」）');
ok(!/name: "标题样式"/.test(web) && !/name: "页眉页脚"/.test(web),
   '「格式/标题样式」是**一格**、「页眉/页脚」也是一格 —— 不拆成 9 格');
{
  const fmt = web.slice(web.indexOf('("格式", "标题样式"'),
                         web.indexOf('("格式", "标题样式"') + 60);
  ok(/"", false\)/.test(fmt),
     '「格式」那格图标是空串 —— 栖阅截图里它**没有图标**，图标为空时还不占位');
}
// 色板 8 + 8
ok(/static let light: \[ReaderTheme\] = \[[^\]]*\]/.test(view), '浅色色板在');
const lightCount = (view.match(/static let light: \[ReaderTheme\] = \[(.*?)\]/s) || ['',''])[1].split(',').filter(x=>x.trim()).length;
ok(lightCount === 8, `浅色色板 8 个`, `实际 ${lightCount}`);
const darkCount = (view.match(/static let darkRow: \[ReaderTheme\] = \[(.*?)\]/s) || ['',''])[1].split(',').filter(x=>x.trim()).length;
ok(darkCount === 8, `深色色板 8 个`, `实际 ${darkCount}`);

console.log('\n── 5 种翻页方式（跟参考 App 一致）──');
// 空白宽度不该被门禁卡住；直接按 raw 名找，不去截区间
for (const [raw, name] of [['flip','仿真'],['slide','滑动'],['flat','平移'],['none','无动画'],['scroll','上下滚动']]) {
  const re = new RegExp('raw:\\s*"' + raw + '",\\s*\\n?\\s*name:\\s*"' + name + '"');
  ok(re.test(web), `${name}（${raw}）在列表里`);
}

// ⭐ 尺寸是被真机并排截图量出来改的，不是从栖阅包里查的
//    （SwiftUI 的 .frame 编译成 ARM64 内联立即数，扫不出来）
//    build76 对照：磁贴 190px vs 栖阅 120px / 配色格 70 vs 60 / 面板占屏 70% vs 46%
// 图标 20 / spacing 4 —— build77「整体收小」改成 15 / 3 是收过头了，
// 栖阅参考实现是 Icons 的 size: 20 + SizedBox(height: 4)。
ok(/Image\(systemName: icon\)\.font\(\.system\(size: 18\)\)/.test(web),
   '磁贴图标 18pt');
ok(/VStack\(spacing: 4\)/.test(web), '磁贴内间距 4（照参考实现 SizedBox(4)）');
{
  const ft = web.slice(web.indexOf('private func featureTileLabel'));
  ok(/\.padding\(\.vertical, 8\)/.test(ft), '磁贴上下留白 8（原来 14）');
  ok(/VStack\(spacing: 4\)/.test(ft), '磁贴内间距 4');
}
ok(/frame\(height: 44\)/.test(web), '配色格高 44（第 4 版 height:44）');
ok(/font\(\.system\(size: 15, weight: \.medium\)\)[\s\S]{0,240}frame\(height: 44\)[\s\S]{0,140}cornerRadius: 12/.test(web),
   '配色格：字号 15 / 高 44 / 圆角 12');
ok(/private var featureGrid[\s\S]{0,120}VStack\(spacing: 10\)/.test(web),
   '宫格行间距 10（照参考实现 mainAxisSpacing:10）');
ok(/frame\(width: 36, height: 36\)/.test(web), '小/大圆形 36x36（第 4 版 _circle）');
// 栖阅那个面板**顶部就是内容**，没有标题栏也没有右上角按钮
ok(!/navigationTitle\("阅读设置"\)/.test(web), '没有「阅读设置」大标题');
ok(!/Button\("完成"\)/.test(web), '没有「完成」按钮');
ok(/\.toolbar\(\.hidden, for: \.navigationBar\)/.test(web),
   '根页整个导航栏藏掉（栖阅那个面板压根没有导航栏）');
// ⚠️ 但子页**必须**显式恢复 —— .toolbar(.hidden) 对整个 NavigationStack 生效，
//    不恢复的话 push 进去连返回按钮都没有，用户出不来。
ok((web.match(/\.toolbar\(\.visible, for: \.navigationBar\)/g) || []).length === 3,
   '三个子页（显示/间距/更多）都显式恢复导航栏 + 返回按钮');
ok(/min\(max\(h \+ 4, 260\), 840\)/.test(web),
   'detent 不再给导航栏留高度（原 +56 / +46 都去掉了）');
console.log('\n── 没接的功能：摆位但不点 ──');
const tiles = web.slice(web.indexOf('private static let tiles:'),
                        web.indexOf('private func tileRow'));
const notReady = (tiles.match(/,\s*false\)/g) || []).length;
ok(notReady === 5, `5 个功能标了 false（还没接的）`, `实际 ${notReady}`);
ok(/,\s*true\)/.test(tiles), '有接上的磁贴（大小 / 间隔 / 更多）');
ok(/\.disabled\(!ready\)/.test(web), 'ready:false 的宫格是 disabled');
ok(/guard ready else \{ return \}/.test(web), '点击前先挡一道（不只靠 disabled）');
ok(/foregroundStyle\(ready \? Theme\.ink : Theme\.sub\.opacity\(0\.45\)\)/.test(web),
   '未接的格子画成灰的，一眼看得出还没做');

console.log('\n── 真接上的功能 ──');
// 栖阅的排版项是**真实控件行**，不是宫格：
// 字号滑杆、字体、配色、跟随系统、段落对齐、段落间空行、行底线、垂直两端对齐
ok(/private var sizeRow/.test(web), '字号/字体是真实控件');
ok(/private var layoutSettingsPage/.test(web), '间距设置子页是真实控件');
ok(/Slider\(value: \$fontSize/.test(web), '字号滑杆真接了');
ok(/paragraphSpacing: CGFloat\(paraSpacing\)/.test(web), '段落间空行真进排版');
ok(/lineSpacing: CGFloat\(lineSpacing\)/.test(web), '行间距真进排版');
ok(/fontFamily: ReaderFont\.family\(for: fontKey\)/.test(web), '字体真进排版');

console.log('\n── 配色色板 ──');
ok(/static let light: \[ReaderTheme\]/.test(view) && /static let darkRow: \[ReaderTheme\]/.test(view),
   '色板分了浅色一排 / 深色一排');
ok((view.match(/static let \w+ = ReaderTheme\(key:/g) || []).length >= 12,
   '色板够铺满两排', String((view.match(/static let \w+ = ReaderTheme\(key:/g) || []).length));
ok(/static func isDark/.test(view), '有 isDark 判定（给 isNightMode 用）');

console.log('\n── 踩过的坑不能再踩 ──');
ok(/static func isDark\(_ t: ReaderTheme\) -> Bool \{ darkRow\.contains\(where:/.test(view),
   'isDark 用 contains(where:) —— contains(t) 在 Swift 5.9 编译不过');
ok(!/darkRow\.contains\(t\)/.test(view), '没有残留的 contains(t)');
const envDecl = web.split('@Environment(\\.colorScheme)').length - 1;
ok(!/ForEach\(0\.\.<[^)]*\)/.test(web),
   '没有 ForEach(Range) —— Range 会被推成 Binding<C>，泛型 C 推不出来');
ok(!/ForEach\(0\.\.\</.test(web), 'ForEach 别直接吃 Range');
ok(/darkScheme == \.dark/.test(web),
   'ColorScheme 要跟 .dark 比 —— 不能直接当 Bool 用');
ok(!/rows\[\.\.<0\]/.test(web), '没有那个恒等于 0 的 id 计算残留');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);

// ⚠️ 参考实现建议「去掉置灰（enabled:false）」让它看着正常 —— **不采纳**。
//    未实现的功能（朗读 / 高亮 / 气泡 / 格式 / 页眉页脚）置灰是用户明确要的：
//    宁可看起来淡，也不能让用户以为点得动。撤置灰 = 伪装成已完成。
ok(/foregroundStyle\(ready \? Theme\.ink : Theme\.sub\.opacity\(0\.45\)\)/.test(web),
   '未实现功能仍置灰（不采纳参考实现「去掉置灰」的建议）');
ok(/\.disabled\(!ready\)/.test(web), '未实现功能仍 disabled，不弹虚假完成提示');
