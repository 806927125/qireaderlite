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
// ⚠️ 必须在 `private func hairLine` **之前**切断 ——
//    否则第二个 hairLine 会匹配到函数定义而不是调用，顺序断言必挂。
// 用「函数定义 + {」定位，避开注释里同名的字样
const _hairDef = web.indexOf('private func hairLine: some View {');
const pc = web.slice(web.indexOf('private var panelContent'),
                      _hairDef > 0 ? _hairDef : web.length);
const featureGrid = web.slice(web.indexOf('private var featureGrid'),
                               web.indexOf('private func featureTileLabel'));
const ft = web.slice(web.indexOf('private func featureTileLabel'),
                         web.indexOf('private var displaySettingsPage'));
const fontMenu = web.slice(web.indexOf('private var fontMenu'),
                              web.indexOf('private var paletteGrid'));   // paletteGrid 紧跟 fontMenu
const slider = fs.readFileSync(path.join(ROOT, 'Features/Reader/Paging/QRSlider.swift'), 'utf8');
const sizeRow = web.slice(web.indexOf('private var sizeRow'),
                          web.indexOf('private func sizeKnob'));
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
// 主面板**没有** NavigationStack 了（它会吃满全屏 → 面板变全屏、内容居中），
// 三个子页各自用系统 .sheet，各带一个 ClearNavigationBackground。
ok((web.match(/ClearNavigationBackground\(\)/g) || []).length === 3,
   'ClearNavigationBackground 出现 3 次：三个子页各一个');
ok(!/private var settingsContent[\s\S]{0,400}NavigationStack/.test(web),
   '主面板不含 NavigationStack（它会吃满全屏，面板变全屏、内容居中）');
ok(/\.sheet\(isPresented: \$showDisplaySettings\)/.test(web) &&
   /\.sheet\(isPresented: \$showLayoutSettings\)/.test(web) &&
   /\.sheet\(isPresented: \$showMoreSettings\)/.test(web),
   '三个子页各自用系统 .sheet');
// 磁贴：一层统一淡底 + 两行文字
{
  // 规格：按钮背景 rgba(0,0,0,.05)（不是 --fill 的冷灰 12%）
  ok(/background\(Color\.black\.opacity\(0\.05\)/.test(ft),
     '8 格磁贴底色 rgba(0,0,0,.05)（规格表）');
  ok(!/Color\.white\.opacity\(ready \?/.test(ft), '磁贴不叠第二层白底');
}
// 「小 / 大」的圆用 ZStack + Circle().fill() **直接画出来** ——
// 圆在 ZStack 里是 flexible view，会填满 34×34，保证完整正圆，
// 不用跟背景裁剪 / 布局挤压较劲。
ok(/ZStack \{\s*Circle\(\)\.fill\(/s.test(web), '「小/大」的圆是直接画出来的（ZStack + Circle.fill）');
ok(/Circle\(\)\.fill\(Color\.black\.opacity\(0\.05\)\)/.test(web),
   '「小 / 大」是圆形底 rgba(0,0,0,.05)（规格表）');
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
ok(/Circle\(\)\.fill\(Color\.black\.opacity\(0\.05\)\)/.test(web),
   '「小 / 大」是圆形底 rgba(0,0,0,.05)（规格表）');
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
// ⚠️⚠️ build93 真机炸过：外层 ZStack 的 alignment 写成了 **.top**，
//    外层把整个内容块（含内层 ZStack）当成一个子视图顶到屏幕上方 ——
//    真机表现：面板跑到顶部、内容被裁掉一半。
//    门禁必须盯死**所有** ZStack 都是 .bottom。
{
  // 根 ZStack 必须 .bottom（面板贴底）；开关那个 .leading 是局部的，允许。
  const zs = web.match(/ZStack\(alignment: \.[a-z]+\)/g) || [];
  ok(zs.filter(z => /\.top/.test(z)).length === 0,
     '没有 ZStack(alignment: .top)（会把面板顶到屏幕上方）');
  ok(zs.filter(z => /\.bottom/.test(z)).length >= 1, '根容器是 .bottom 对齐');
}
// ⚠️⚠️ 另一个坑：`.fixedSize` 和测高 GeometryReader 挂在**平级子元素**上时，
//    只作用于紧挨着的那一个（featureGrid），量到的不是整个面板高度。
//    必须用 VStack 把 panelContent + featureGrid 包起来再挂。
{
  const sc = web.slice(web.indexOf('private var settingsContent'),
                        web.indexOf('private var panelContent'));
  // ⚠️ VStack 和 .fixedSize 之间可能隔着 .frame(maxWidth:)，
  //    所以这里只要求 VStack 之后**不远处**出现 fixedSize。
  // settingsContent 里现在是「VStack { panelContent }」——
  // featureGrid 已经在 panelContent 内部了（build113 加 top-card 时挪进去的）。
  ok(/VStack\(spacing: 0\) \{[\s\S]{0,120}panelContent[\s\S]{0,200}\.fixedSize/.test(sc),
     'fixedSize 挂在**包住全部内容**的 VStack 上（不是只挂 featureGrid）');
  ok(/VStack\(spacing: 0\) \{[\s\S]{0,120}panelContent[\s\S]{0,700}SheetContentHeightKey/.test(sc),
     '测高 GeometryReader 同样挂在包住全部内容的 VStack 上');
}
ok(/settingsSheet/.test(web.slice(web.indexOf('ZStack(alignment: .bottom)'))),
   '面板挂在 ZStack 里（等价于 Positioned(bottom:0)）');
// 「上下滚动」被截 → 我绕了**四轮**弯路，每轮都改错了地方：
//   ① fillsWidth 强制平分装不下 → 缩字号 13→12        ← 治字号，错
//   ② 改 Wrap / LazyVGrid 换行   → 真机断成「无动\n画」 ← 治换行，仍错
//   ③ 死磕等分（fillsWidth）      → build86，还是装不下
//   ④ **正解：不等分 + 横向滚动**（.pill flex-shrink:0 + overflow-x:auto）
//      没人跟它抢宽度，「上下滚动」字号 14 也完整
ok(!/fillsWidth: true/.test(pageTurn), 'pills 不等分（第 5 版正解）');
ok(/ScrollView\(\.horizontal, showsIndicators: false\)/.test(pageTurn),
   '翻页方式横向滚动（放不下就滚，不截字）');
ok(/fixedSize\(\)/.test(chip), 'pill 按内容宽度 fixedSize');

// ★ iOS 26 的系统玻璃必须是 partial-height sheet。
//   只给 presentationSizing(.fitted) 而不给 detent → sheet 走默认全屏
//   → 全屏不透明 → 玻璃出不来、面板还撑满整屏（build 43 实机就是这么翻车的）。
// 面板背景 = **液态玻璃**（用户明确要：栖阅风格液态玻璃）。
// build102 我拿「折射会扭掉边缘控件」把它换成磨砂白，那是**误解**诉求 ——
// 折射不是成因，成因是**内容区高度不够、控件被裁**。
// 面板背景 = **液态玻璃** .glassEffect(.regular) + 白 tint。
//
// ⚠️ 之前在「结构还没对」时来回换过这个背景（.82 磨砂白 ↔ .glassEffect），
//    两边都不对 —— 那是**结构问题**不是材质问题。结构对了（build120）才比得了材质。
ok(/\.glassEffect\(\.regular\.tint\(Color\.white\.opacity\(0\.35\)\)/.test(panel),
   '面板是**液态玻璃** .glassEffect(.regular) + 白 tint（保白度，白块要能分层）');
ok(/\.background\(\s*Color\.clear\s*\n?\s*\.glassEffect/.test(panel),
   '面板玻璃用 background(_:in:) 重载（.background { Shape } 会撑成全屏）');
// 判定要看**代码**，不能看注释（注释里会写这些名字做说明）
// 目录 sheet 本来就该有 detent（.medium/.large）；
// 只判定**设置面板**那一段没有 detent。
ok(!/presentationDetents/.test(panel),
   '设置面板不使用 presentationDetents（走 overlay，不是 sheet）');
// 推入的子页要透明，否则玻璃被盖
ok((web.match(/modifier\(ClearNavigationBackground\(\)\)/g) || []).length >= 3,
   '三个子页都用了 ClearNavigationBackground');
ok(/private struct ClearNavigationBackground: ViewModifier/.test(web), '有 ClearNavigationBackground 修饰符');
// 部署目标已经是 iOS 26（用户要求「给我走 26」），
// .navigation placement（iOS 18 引入）不需要 #available 分派了。
ok(/containerBackground\(\.clear, for: \.navigation\)/.test(web),
   '用 containerBackground(.clear, for: .navigation) 清导航背景');
ok(!/private struct ClearNavigationBackground[\s\S]{0,200}#available\(iOS 18/.test(web),
   'iOS 26 目标下不再需要 #available(iOS 18) 分派');
// containerBackground(.clear, for: .navigation) 只能活在 #available(iOS 18) 分支里
const navMod = web.slice(web.indexOf('private struct ClearNavigationBackground'));
ok(navMod.indexOf('containerBackground(.clear, for: .navigation)') >= 0,
   'ClearNavigationBackground 里用了 containerBackground(.clear)');

console.log('\n── 高度贴合内容 ──');
const mainSheet = web.slice(web.indexOf('private var settingsContent'),
                            web.indexOf('private var hairLine'));
ok(/VStack/.test(mainSheet), '主面板用 VStack（内容行数固定，高度确定）');
ok(/panelContent/.test(mainSheet), '主面板用 panelContent（内含 top-card 白块 + 8 个宫格）');
ok(!/private var (displayCard|pageTurnCard|upperPanelCard)/.test(web),
   '旧卡片视图名全部退役（displayCard / pageTurnCard / upperPanelCard）');
ok(!/\.background\(\s*Color\.white/.test(featureGrid),
   '磁贴区不垫独立白底（只有一层统一淡底）');

console.log('\n── 第 5 版面板结构 ──');

// ⚠️⚠️ 「中间有一块阴影」= **面板玻璃容器自己投的 box-shadow**，
//    不是容器里再套一层白色块。
//    我 build82~89 一直加着那层白卡（white@.35 / radius 22）—— 从一开始就错了。
ok(!/upperPanelCard/.test(web), '不再有内层白卡（那层是我误加的）');
ok(/upperPanelCard/.test(web) === false, '没有额外的内层白卡（top-card 那层是规格要的）');
ok(/panelContent/.test(web), '内容装在 panelContent 里');
ok(/sizeRow[\s\S]{0,40}hairLine[\s\S]{0,40}paletteGrid/.test(pc),
   '分割线有**两条**：字号下面 + 跟随系统下面（我之前错删成一条）');
{
  // ⚠️ 两个 hairLine 用 indexOf 找会拿到**同一个位置**（都是第一次出现），
  //    所以必须带着游标递增地找，不能各算各的 indexOf。
  let cur = -1;
  const seq = ['sizeRow','hairLine','paletteGrid','followSystemRow','hairLine','pageTurnRow'];
  const found = seq.map(k => { cur = pc.indexOf(k, cur + 1); return cur; });
  ok(found.every((v,i) => v >= 0 && (i === 0 || v > found[i-1])),
     '顺序 = 字号/线/配色/跟随/线/翻页（两条分割线都在）');
}

// 面板容器按 ui.txt 一比一：left/right/bottom 14、radius 22、padding 12/14/16
// ⚠️⚠️ ui.txt 的 .panel 有**两个层级**的留白：
//     left/right/bottom 14  = ① 定位（玻璃**外面**）
//     padding 12/14/16      = ② 内部（玻璃**里面**）
// 写成重复的 .padding(.horizontal, 14) 会累加成左右各 28
// → 玻璃撑宽 → 内容溢出屏幕被裁（真机：色块第8个、宫格「高亮」被切）。
{
  // 玻璃层 = 第一个 `.background(... in: RoundedRectangle(cornerRadius: 22)`
  const glassAt = panel.indexOf('in: RoundedRectangle(cornerRadius: 22');
  const innerPad = panel.indexOf('.padding(.horizontal, 14)');
  const innerTop = panel.indexOf('.padding(.top, 12)');
  const innerBot = panel.indexOf('.padding(.bottom, 16)');
  const outerPad = panel.lastIndexOf('.padding(.horizontal, 14)');
  const outerBot = panel.lastIndexOf('.padding(.bottom, Self.bottomSafeInset + 14)');
  // 顶部 12 → 30（用户要「内容整体往下挪」；栖阅真机约 40pt）
  // 顶部 12 → 30 → 42 → 50：用户连续要「按钮整体下移一点」。
  ok(innerTop >= 0 && innerBot >= 0, '有内部 padding（top 12 / bottom 16，规格表）');
  // 顶部 12 → 30 → 42：用户连续要「里面整体往下挪」，
  // 栖阅真机面板顶到「小」那行的距离约 42pt（截图量）。
  // 顶部 12 → 30 → 42 → 56：栖阅那块是**磨砂白**（没有玻璃边缘折射），
// 面板顶到「小」那行约 42pt；我们用**真液态玻璃**，边缘有折射区，
// 控件离边缘太近会被"啃"掉一块（用户：「那缺口在上面啊」）。
// 顶部总留白 = 面板内 34 + 字号行 8 = 42，对齐栖阅真机。
ok(/\.padding\(\.top, 12\)/.test(panel), '面板内部顶部留白 12（规格表：上12/左右14/下16）');
  ok(innerPad >= 0 && innerPad < glassAt,
     '内部 padding 在 玻璃**之前**（玻璃里面）');
  ok(innerBot < glassAt, '内部底 padding 在玻璃之前');
  ok(outerPad > glassAt && outerPad !== innerPad,
     '定位 padding 在玻璃**之后**（玻璃外面），且不与内部那个重复');
  ok(outerBot > glassAt, '定位底 padding 在玻璃之后');
  // ⚠️ 面板底部必须**让开 home indicator**（栖阅是收在指示条上方的）。
  //    写死 14 会让面板压在指示条上、整体显得往上偏。
  ok(/\.padding\(\.bottom, Self\.bottomSafeInset \+ 14\)/.test(panel),
     '面板底部让开 home indicator（bottomSafeInset + 14）');
  ok(/private static var bottomSafeInset/.test(web), '有底部安全区取值');
  // 左右 padding 在玻璃前后各出现一次，且**不能**都在玻璃前
  const hP = [...panel.matchAll(/\.padding\(\.horizontal, 14\)/g)].map(m => m.index);
  ok(hP.length === 2 && hP[0] < glassAt && hP[1] > glassAt,
     '左右 padding 恰好两次：一次在玻璃前、一次在玻璃后');
}
ok(/cornerRadius: 22/.test(panel), '面板圆角 22');
// 面板 = 磨砂玻璃 white@0.82 + .ultraThinMaterial（规格表）。
// 之前用 .glassEffect(.regular)：面板太通透，**内层白块 white@.55 叠上去
// 几乎看不出层次**，而参考实现里那块白卡是明显比面板亮的。
ok(/\.glassEffect\(\.regular/.test(panel), '面板是液态玻璃');
ok(/\.glassEffect\(\.regular\.tint\(/.test(panel), '液态玻璃带白 tint（内层白块要能分层）');
ok(!/\.background\(\s*Color\.white\.opacity\(0\.82\)/.test(panel), '不再用纯磨砂白（换成真液态玻璃）');
ok(!/\.background\(\s*Color\.white\.opacity\(0\.82\)/.test(panel), '不再用纯磨砂白（换成真液态玻璃）');
ok(/cornerRadius: 22/.test(panel), '面板圆角 22');
//    build103 我把 fixedSize 放在 **NavigationStack 外面** ——
//    NavigationStack 的 ideal height 算出来接近 **0**，面板只剩 padding 撑起来
//    的 86pt，真机表现：**面板卡在屏幕底，只露薄薄一条**。
// 内容高度由 **NavigationStack 内部**的 .fixedSize 自然撑开（外面用会塌成 0）。
ok(/VStack\(spacing: 0\) \{\s*panelContent[\s\S]{0,200}\.fixedSize\(horizontal: false, vertical: true\)/.test(web),
   '内容用 fixedSize 自然撑开（在 NavigationStack **内部**，外面会塌成 0）');
ok(!/\.frame\(height: max\(sheetHeight/.test(panel), '不用 frame(height:) 硬压内容区');
ok(/hardCap = screenH \* 0\.80/.test(web), '高度有屏幕 80% 硬上限');

// 字号行
ok(/frame\(width: 34, height: 34\)/.test(web), '小/大 圆形 34×34');
// ⚠️ 必须 fixedSize —— QRSlider 内部是 GeometryReader（贪婪），
//    在 HStack 里会抢宽度，把这两个圆压成缺角的椭圆
//    （用户：「把大、小字体的圆圈补全」）。
{
  const knob = web.slice(web.indexOf('private func sizeKnob'));
  ok(/frame\(width: 34, height: 34\)/.test(knob), '「小/大」圆形 34×34（规格表）');
  ok(/font\(\.system\(size: 14\)/.test(knob), '「小/大」字号 14（规格表）');
  ok(/ZStack \{\s*Circle\(\)\.fill\(/s.test(knob),
     '「小/大」用 ZStack + Circle.fill 直接画圆（保证完整正圆）');
  // ⭐ 必须 `.aspectRatio(1, .fit)` —— **锁死宽高比**。
  //    `.frame(width:34,height:34)` + `.fixedSize()` 只锁"理想尺寸"，
  //    锁不住"实际分配比例"：HStack 里被压时圆照样会变成椭圆。
  //    `.aspectRatio(1,.fit)` 保证宽高永远相等 → 圆不可能变形。

}
ok(/14\.\.\.28/.test(web), '字号滑块 14...28（ui.txt min:14 max:28）');
// ⚠️ SwiftUI 的 Slider 在 iOS 26 新样式下**滑轨会画到自己 frame 之外**。
//    HStack 的 spacing 只管视图框、管不住绘制外延 →
//    「小」按钮的圆形底会盖住滑轨左端一小截（用户反馈「滑块被挡了一点」）。
//    所以 Slider 必须有水平 padding 给绘制外延留位置。
// ⚠️ 用**自绘**的 QRSlider，不用系统 Slider。
//    连续两次真机反馈「滑块被挡了一点」「上面被挡」：
//    iOS 26 的系统 Slider frame 高度比 thumb 直径小（thumb 上下溢出自己
//    frame 画的），跟相邻控件打架、还会被裁。
// ⚠️ 「小」按钮和滑轨之间必须有间距 —— 我为了塞 thumb 把 spacing 收到 2，
//    结果两者只差 2pt，视觉上就是「滑块被小按钮压住」（用户连续三次反馈）。
//    自绘 QRSlider 之后 thumb 两端正位，**不需要收窄 spacing**。
ok(/HStack\(spacing: 10\)/.test(sizeRow), '字号行 spacing 10（规格表）');
ok(!/HStack\(spacing: 2\)/.test(sizeRow), '不用 spacing 2（会让滑块看着被小按钮压住）');
ok(/QRSlider\(value: \$fontSize, range: 14\.\.\.28, step: 1\)/.test(web),
   '字号滑块用自绘 QRSlider（不用系统 Slider）');
ok(!/(?<![A-Za-z])Slider\(value: \$fontSize/.test(web), '不用系统 Slider');
ok(/private let thumb: CGFloat = 26/.test(slider) && /private let track: CGFloat = 6/.test(slider),
   '自绘滑块：thumb 26 / 轨道 6（照 ui.txt 的 input[type=range]）');
ok(/\.shadow\(color: Color\.black\.opacity\(0\.25\), radius: 8, y: 2\)/.test(slider),
   'thumb 带阴影（ui.txt box-shadow:0 2px 8px rgba(0,0,0,.25)）');
ok(/thumb \/ 2 \+ usable \* ratio/.test(slider), 'thumb 位置两端各留半个 thumb，不会出 frame');
ok(/Capsule\(\)\.fill\(Color\.black\.opacity\(0\.12\)\)/.test(slider) &&
   /Capsule\(\)\.fill\(accent\)/.test(slider), '轨道：未填充灰 + 已填充蓝');
// ⚠️⚠️ 垂直方向也必须留！SwiftUI 的 Slider **frame 高度比 thumb 直径小**，
//    thumb 是**上下都溢出**自己 frame 画的。
//    内容区高度 = 内容自然高（sheetHeight - 4）时，thumb 溢出那几 pt
//    直接被裁掉 → 真机「滑块上面被挡」（用户反馈）。
ok(/\.frame\(height: thumb\)/.test(slider), '自绘滑块高度 = thumb 直径（上下不裁）');
ok(/padding\(\.horizontal, 13\)/.test(fontMenu), '字体下拉 水平内边距 13（ui.txt .font-select）');
ok(/padding\(\.vertical, 7\)/.test(fontMenu), '字体下拉 垂直内边距 7');
ok(/cornerRadius: 18/.test(chip) && /font\(\.system\(size: 14\)/.test(chip),
   'chip 圆角 18 / 字号 14（规格表 .pill）');

// pills：**不等分** + 横向滚动（正解，不是等分也不是换行）
ok(/ScrollView\(\.horizontal, showsIndicators: false\)/.test(pageTurn),
   '翻页方式横向滚动（放不下就滚，不截字）');
ok(!/fillsWidth: true/.test(pageTurn), 'pills 不等分 —— 等分是我 build86~88 走的三轮弯路');
ok(/fixedSize\(\)/.test(chip), 'pill 按内容宽度 fixedSize');

// 色块
// ⚠️ 色块**不能**用固定 width —— 8×42 + 间距 + 图标槽 = 428pt，
//    超出可用宽 412pt → 整个内容被撑宽、两边溢出被裁（真机验证过）。
//    改成自适应均分（栖阅真机就是 8 个均分贴边），高度仍固定 42。
ok(/frame\(maxWidth: \.infinity\)[\s\S]{0,80}frame\(height: 42\)/.test(web),
   '色块宽度自适应均分（固定 42 会撑爆行宽导致内容溢出）');
ok(!/frame\(width: 42, height: 42\)/.test(web), '不用固定 width 42 的色块');
ok(/cornerRadius: 9/.test(web), '色块圆角 9');
ok(/font\(\.system\(size: 13\)\)/.test(web), '色块文字 13');
ok(/frame\(width: 28\)/.test(web), '色块行图标槽 28（参考实现 .mode-icon width:28）');

// 宫格：**两行文字、没有图标行、不需要固定高度**
ok(/Text\(name\)\.font\(\.system\(size: 18, weight: \.semibold\)\)/.test(ft),
   '宫格第一行 18pt（参考实现 .ic 18）');
ok(/Text\(subtitle \?\? ""\)\.font\(\.system\(size: 13\)\)/.test(ft),
   '宫格第二行 13pt（参考实现 .t1 13）');
// ui.txt 的 .cell 只有**两行**：.ic(占图标位,放大字18) + .t1(13)。
// 之前多画了一行 SF Symbol 图标 → 三行 81pt（规格是 52pt），
// 8 个按钮因此显得太大。
ok(!/Image\(systemName: icon\)/.test(ft), '宫格**没有** SF Symbol 图标行（ui.txt .ic 位放大字）');
ok(/Text\(name\)\.font\(\.system\(size: 18, weight: \.semibold\)\)[\s\S]{0,120}Text\(subtitle \?\? ""\)\.font\(\.system\(size: 13\)\)/.test(ft),
   '宫格两行：.ic 位放大字 18 + .t1 副标题 13');
ok(!/frame\(height: 76\)/.test(ft), '宫格不设固定高度（两行文字自然等高）');
ok(/\.padding\(\.top, 9\)[\s\S]{0,60}padding\(\.horizontal, 4\)[\s\S]{0,60}padding\(\.bottom, 8\)/.test(ft),
   '宫格内边距 9/4/8（规格表 .cell padding:9px 4px 8px）');
ok(/cornerRadius: 12/.test(ft), '宫格圆角 12（参考实现 .cell）');
ok(/VStack\(spacing: 8\) \{\s*tileRow\(0\)/.test(web), '宫格间距 8（参考实现 gap:8px）');
// ⚠️ 用户要的「下移」是**这 8 个宫格按钮**，不是整个面板内容。
//    之前我理解成「整体下移」，把面板内部 top padding 一路加到 56 —— 方向错了。
ok(web.slice(web.indexOf('private var panelContent: some View {'),
             web.indexOf('private var hairLine')).includes('.padding(.bottom, 12)'),
   '白块和宫格之间有 12 间距（ui.txt margin-bottom:12，在 top-card 之后）');
ok(/padding\(\.top, 12\)/.test(panel),
   '面板内部顶留白 12（规格表）');
// ⚠️ 字号行是面板内容的第一行，它上面就是玻璃边缘 —— 三个控件
//    （小/大/楷体）同处这一行，所以一起被"啃"掉上沿。
ok(!/private var sizeRow[\s\S]{0,900}padding\(\.top, 8\)/.test(web),
   '字号行不再自己下移（top-card 白块已隔开玻璃边缘）');
ok(/padding\(\.top, 12\)/.test(panel),
   '面板内部顶留白 12（规格表）');

// ⚠️ 参考实现建议「去掉置灰（enabled:false）」让它看着正常 —— **不采纳**。
//    未实现的功能（朗读 / 高亮 / 气泡 / 格式 / 页眉页脚）置灰是用户明确要的：
//    宁可看起来淡，也不能让用户以为点得动。撤置灰 = 伪装成已完成。
ok(/foregroundStyle\(ready \? Color\(white: 0x22 \/ 0xff\) : Theme\.sub\.opacity\(0\.45\)\)/.test(web),
   '未实现功能仍置灰（不采纳参考实现「去掉置灰」的建议）');
ok(/\.disabled\(!ready\)/.test(web), '未实现功能仍 disabled，不弹虚假完成提示');

// ── 版本号可见 ──
// 这一轮最大的坑是「用户装的到底是哪一版」：build 107 之后又出了 108/109，
// 拿旧版截图对栖阅会白改好几轮。设置页显示 build 号，一眼可确认。
{
  const fs2 = require('fs');
  const sv = fs2.readFileSync(path.join(ROOT, 'Features/Settings/SettingsView.swift'), 'utf8');
  ok(sv.includes('build \\(AppBuildInfo.number)'), '设置页显示 build 号');
  ok(/CFBundleVersion/.test(sv), 'build 号从 Info.plist 读');
}

// ── 上半白块（top-card）──
// 照 ui.txt 的 .top-card：
//     background: rgba(255,255,255,.55); border-radius: 16px;
//     padding: 14px 12px 2px;  margin-bottom: 12px;
//     box-shadow: 0 1px 6px rgba(0,0,0,.04);
//
// ⚠️ CSS 的 padding 在 background **之内**（背景盖住 padding 区），
//    所以 SwiftUI 必须是 `.padding(...)` **在** `.background(...)` **之前**。
//    写反了会把白块推远（内容离白块边没有内边距）。
{
  const pc2 = web.slice(web.indexOf('private var panelContent: some View {'),
                         web.indexOf('private var hairLine'));
  ok(/padding\(EdgeInsets\(top: 14, leading: 12, bottom: 2, trailing: 12\)\)[\s\S]{0,140}background\(\s*Color\.white\.opacity\(0\.55\)/.test(pc2),
     'top-card：padding 在 background 之前（CSS 的 padding 在 background 之内）');
  ok(/Color\.white\.opacity\(0\.55\)/.test(pc2), 'top-card 底色 white@0.55（ui.txt 原值）');
  ok(/cornerRadius: 16/.test(pc2), 'top-card 圆角 16');
  ok(/shadow\(color: Color\.black\.opacity\(0\.04\), radius: 6, x: 0, y: 1\)/.test(pc2),
     'top-card 阴影 0 1px 6px rgba(0,0,0,.04)');
  ok(/\.padding\(\.bottom, 12\)/.test(pc2), 'top-card margin-bottom 12');
  ok(/sizeRow[\s\S]{0,200}hairLine[\s\S]{0,200}paletteGrid[\s\S]{0,200}followSystemRow[\s\S]{0,200}hairLine[\s\S]{0,200}pageTurnRow/.test(pc2),
     '白块里含：字号/线/色块/跟随/线/翻页（不含 8 个宫格）');
}

// ── featureGrid 只能出现一次 ──
// build113 我把 featureGrid 挪进 panelContent（加 top-card 白块），
// 外层那个忘了删 → 真机 **8 个宫格渲染成 16 个**（重复两遍）。
{
  const sc2 = web.slice(web.indexOf('private var settingsContent: some View {'),
                         web.indexOf('private var panelContent: some View {'));
  const calls = (sc2.match(/^\s*featureGrid\s*$/gm) || []).length;
  ok(calls === 0, 'settingsContent 里不再单独挂 featureGrid（它已在 panelContent 内）');
  const pc3 = web.slice(web.indexOf('private var panelContent: some View {'),
                         web.indexOf('private var hairLine'));
  ok((pc3.match(/^\s*featureGrid\s*$/gm) || []).length === 1,
     'featureGrid 在 panelContent 里只出现一次');
}

// ── 发丝线 ──
// @3x 下 1pt = 3 物理像素，系统分隔线是 1 物理像素 = 1/scale pt。
ok(/frame\(height: 1\.0 \/ UIScreen\.main\.scale\)/.test(web),
   '分隔线是发丝线 1/scale pt（@3x 下 1 物理像素）');

// ── 引擎 JS 桥接（真机报过 code 5）──
{
  const fs2 = require('fs');
  const sb = fs2.readFileSync(path.join(ROOT, 'Core/RuleSandbox.swift'), 'utf8');
  // ⚠️ JSON.stringify 对 **函数 / Symbol** 返回 undefined（不是字符串），
  //    脚本返回 undefined → WebKit 抛 code 5「返回结果的类型不受支持」。
  //    之前只处理了 v === undefined，函数/Symbol 漏了。
  ok(/typeof s !== 'string'/.test(sb),
     'JS 桥接：JSON.stringify 结果必须再判一次 typeof（函数/Symbol 会返回 undefined）');
  ok(/JSON 序列化失败/.test(sb), 'JSON.stringify 抛异常（循环引用）时有兜底错误信息');
  ok(/JSON 序列化失败/.test(sb) && /typeof s !== 'string'/.test(sb),
     '脚本无论如何都返回字符串');
  // 并发：同一个 WKWebView 上并发 callAsyncJavaScript 会让结果类型不受支持。
  ok(/invokeTail/.test(sb) && /let prev = invokeTail/.test(sb),
     'invoke 走串行链（并发会触发 code 5）');
  // ⚠️ 这个类整体是 @MainActor —— 同文件里再声明独立 actor 会被继承全局 actor，
  //    编译报 "actor ... cannot have a global actor"。所以串行用 Task 链实现。
  ok(!/private actor InvokeSerializer/.test(sb),
     '不声明独立 actor（会被 @MainActor 继承 → 编译错）');
}

// ── 换阅读背景要**立刻**生效 ──
// 真机症状：「换背景只有状态栏生效，要重进正文才变过来」。
// 根因：layoutConfig 是 computed（主题色在里面），但只有 syncPager 重新求值
// 才会赋给 pager.config —— 而 syncPager 之前**只在尺寸变化时**被调用；
// WebView 滚动模式的 settingsPayload 也只在 session.start() 时发一次。
{
  const fs3 = require('fs');
  const rv = fs3.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
  // ⚠️ 统一成一个签名监听（覆盖 themeKey / followSystemAppearance / darkScheme
  //    以及字号/行距/段距/字体/对齐/基线）—— 分开挂会漏项，
  //    漏掉的那些就是「改了不生效」的来源。
  ok(/onChange\(of: readerLayoutSig\)[\s\S]{0,60}applyThemeChange\(\)/.test(rv),
     '统一签名变化 → applyThemeChange（所有设置都要立刻生效）');
  ok(/private func applyThemeChange\(\)[\s\S]{0,600}syncPager\(size: pagerViewport\)/.test(rv),
     'applyThemeChange 走 syncPager（原生分页：config 重新求值 + 重排）');
  ok(/applyThemeChange\(\)[\s\S]{0,900}host\.setSettings\(settingsPayload/.test(rv),
     'applyThemeChange 重新下发 settings（WebView 滚动模式）');
}

// ── 阅读渲染层迁到 Swift ──
// reader.html + ReaderHost 那套 WebView 渲染**不再使用**（换背景要重进正文才生效）。
// 注意：engine.js（书源规则引擎）**仍在 WebView 里跑** —— 站方规则要求 JS，
// 那个跟阅读渲染是两回事。
{
  const fs4 = require('fs');
  const rv = fs4.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
  ok(/SwiftScrollReaderView\(/.test(rv), '滚动模式用 SwiftScrollReaderView');
  ok(!/ReaderWebContainer\(\s*\n?\s*host: session\.host/.test(rv),
     '滚动模式不再用 ReaderWebContainer（WebView 渲染）');
  ok(/private var scrollLoadedTexts/.test(rv), '有已加载正文集合（当前章 + 预取邻章）');
  ok(/onRequestChapter: \{ idx in[\s\S]{0,120}session\.prefetch/.test(rv),
     '窗口里缺的章 → 后台预取');
  ok(/onVisibleChapter: \{ ch in[\s\S]{0,160}session\.followIndex/.test(rv),
     '滚到别的章 → followIndex 跟着走');

  const core = fs4.readFileSync(path.join(ROOT, 'Features/Reader/Paging/ReaderScrollCore.swift'), 'utf8');
  ok(/enum ReaderScrollCore/.test(core), '有 ReaderScrollCore（scroll-core.js 的 Swift 翻译）');
  ok(/func trimChapterWindow/.test(core) && /func shouldReportProgress/.test(core)
     && /func viewportAnchorAdjustment/.test(core) && /func chooseTrimRemovalSide/.test(core)
     && /func normalizedTitleHeight/.test(core),
     'ReaderScrollCore 覆盖 JS 版导出的 5 个函数');
  const sv = fs4.readFileSync(path.join(ROOT, 'Features/Reader/Paging/SwiftScrollReaderView.swift'), 'utf8');
  ok(/ReaderScrollCore\.shouldReportProgress/.test(sv), '进度上报用 ReaderScrollCore 节流');
  ok(/normalizedParagraphs/.test(sv), '段落拆分对齐 reader.js 的 normalizedParagraphs');
  // CI 必须跑 Swift↔JS 对拍
  const wf = fs4.readFileSync(path.join(ROOT, '../.github/workflows/build-ipa.yml'), 'utf8');
  ok(/scroll-core-parity/.test(wf), 'CI 跑 Swift↔JS 对拍');
}

// ── 顶栏 / 底栏对齐栖阅 ──
{
  const fs5 = require('fs');
  const rv = fs5.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
  const top = rv.slice(rv.indexOf('private var topBar'),
                       rv.indexOf('private var bottomBar'));
  const bot = rv.slice(rv.indexOf('private var bottomBar'));
  // ① 顶栏中间：书名 + 副标题要装在一个圆角胶囊里
  ok(/Text\(book\.name\)[\s\S]{0,220}Text\(book\.sourceName\)[\s\S]{0,200}liquidGlass\(cornerRadius: 20/.test(top),
     '顶栏书名+副标题装在圆角胶囊里（栖阅那样）');
  // ② 底栏：‹ 在最左、› 在最右，滑块夹中间
  const arrowRow = bot.slice(bot.indexOf('HStack(spacing: 10) {'),
                             bot.indexOf('HStack(spacing: 0) {'));
  ok(arrowRow.indexOf('chevron.left') < arrowRow.indexOf('Slider(')
     && arrowRow.indexOf('Slider(') < arrowRow.indexOf('chevron.right'),
     '底栏 ‹ 在最左、› 在最右，滑块在中间（栖阅那样）');
  ok(arrowRow.indexOf('chevron.right') < arrowRow.indexOf('chevron.left') + 100
     || arrowRow.indexOf('chevron.left') < arrowRow.indexOf('chevron.right'),
     '两个箭头不堆在同一边');
}

// ── 用户一次提的 5 个问题 ──
{
  const fs6 = require('fs');
  const rv = fs6.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
  const sv = fs6.readFileSync(path.join(ROOT, 'Features/Reader/Paging/SwiftScrollReaderView.swift'), 'utf8');

  // ① 滚动模式章节高度自算（之前 Auto Layout 算错 → 下面留一大片空白）
  ok(/func updateHeights\(width: CGFloat\)/.test(sv), '章节高度自己算');
  ok(/bodyHeight = bodyView\.heightAnchor\.constraint/.test(sv),
     'bodyView 高度用可更新约束（不靠 bottom 约束撑）');
  ok(!/bodyView\.bottomAnchor\.constraint\(equalTo: bottomAnchor/.test(sv),
     'bodyView 不约束到底（会跟自算高度打架）');

  // ②③ 排版/主题任何一项变了都要立刻重排 → 统一签名
  ok(/private var readerLayoutSig: String/.test(rv), '有排版统一签名');
  ok(/onChange\(of: readerLayoutSig\)/.test(rv), '监听统一签名（一次覆盖全部设置项）');
  for (const k of ['fontSize','lineSpacing','paraSpacing','themeKey','fontKey',
                   'paraAlign','verticalJustify','showBaseline','baselineScope',
                   'baselineColorHex']) {
    ok(rv.includes(k), '排版签名含 ' + k);
  }
  // ⚠️ 签名里只能列**真实存在**的 @AppStorage。
  //    之前写了 horizontalMargin（它是 layoutConfig 里写死的 20，不是 @AppStorage）
  //    → 编译报 "cannot find 'horizontalMargin' in scope"。
  ok(!/readerLayoutSig[\s\S]{0,400}horizontalMargin/.test(rv),
     '排版签名里不引用不存在的 horizontalMargin（它是写死的 20，不是 @AppStorage）');

  // ④ 设置面板按住下拖关闭（跟目录一样）
  ok(/panelDragOffset/.test(rv), '设置面板有拖拽位移状态');
  ok(/DragGesture\(minimumDistance: 6\)[\s\S]{0,400}panelDragOffset = min/.test(rv),
     '设置面板可按住往下拖（面板跟着手指走）');
  ok(/value: panelDragOffset/.test(rv), '拖拽有回弹动画');

  // ⑤ 上滑退出阅读
  ok(/onSwipeUp/.test(sv) && /swipeUpExitEnabled/.test(sv), '滚动层支持上滑退出');
  ok(/handleSwipeUp/.test(sv) && /v\.y < -90/.test(sv), '上滑判定：明显向上才退出');
  // ⚠️ 只有**从底部起手**才算上滑退出（正文中间往上滑 = 正常滚动）
  ok(/swipeStartY = g\.location\(in: self\)\.y/.test(sv), '记录上滑手势起点');
  ok(/swipeStartY > bounds\.height \* 0\.70/.test(sv), '只有底部 30% 起手才触发退出');
  // ③ 设置面板整块都能往下拖 → 必须 simultaneousGesture（gesture 会被子视图吃掉）
  ok(/\.simultaneousGesture\(\s*DragGesture\(minimumDistance: 6\)/.test(rv),
     '设置面板用 simultaneousGesture（gesture 会让上半拖不动）');
  // ④ 顶栏书名胶囊要居中
  ok(/Spacer\(minLength: 8\)[\s\S]{0,120}Text\(book\.name\)[\s\S]{0,400}Spacer\(minLength: 8\)/.test(top),
     '顶栏书名胶囊前后各有 Spacer（居中）');
  ok(/frame\(maxWidth: 340\)/.test(top), '书名胶囊限宽 340');
  ok(/if swipeUpExit \{ dismiss\(\) \}/.test(rv), '上滑退出接 dismiss');
  ok(!/上滑退出阅读[\s\S]{0,200}\.disabled\(true\)/.test(rv), '「上滑退出阅读」开关不再置灰');
}
