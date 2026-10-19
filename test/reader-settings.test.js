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
const ft = web.slice(web.indexOf('private func featureTileLabel'));
const fontMenu = web.slice(web.indexOf('private var fontMenu'),
                              web.indexOf('private var paletteGrid'));   // paletteGrid 紧跟 fontMenu
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
ok((web.match(/ClearNavigationBackground\(\)/g) || []).length === 4,
   'ClearNavigationBackground 出现 4 次：根页 + 3 个子页（根页以前漏了）');
ok(/\.toolbar\(\.hidden, for: \.navigationBar\)[\s\S]{0,200}ClearNavigationBackground\(\)/.test(web),
   '根页藏导航栏的同时**必须**清 containerBackground');
// 磁贴：一层统一淡底 + 两行文字
{
  ok(/background\(Self\.qrFill,[\s\S]{0,60}RoundedRectangle\(cornerRadius: 12/.test(ft),
     '8 格磁贴底色统一一层（栖阅那样，不是「亮/暗」两档）');
  ok(!/Color\.white\.opacity\(ready \?/.test(ft), '磁贴不叠第二层白底');
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
// ⚠️⚠️ build93 真机炸过：外层 ZStack 的 alignment 写成了 **.top**，
//    外层把整个内容块（含内层 ZStack）当成一个子视图顶到屏幕上方 ——
//    真机表现：面板跑到顶部、内容被裁掉一半。
//    门禁必须盯死**所有** ZStack 都是 .bottom。
{
  const zs = web.match(/ZStack\(alignment: \.[a-z]+\)/g) || [];
  ok(zs.length > 0 && zs.every(z => /\.bottom/.test(z)),
     '所有 ZStack(alignment:) 都是 .bottom（写 .top 会把面板顶到屏幕上方）');
  ok(!/ZStack\(alignment: \.top\)/.test(web), '不许出现 ZStack(alignment: .top)');
}
// ⚠️⚠️ 另一个坑：`.fixedSize` 和测高 GeometryReader 挂在**平级子元素**上时，
//    只作用于紧挨着的那一个（featureGrid），量到的不是整个面板高度。
//    必须用 VStack 把 panelContent + featureGrid 包起来再挂。
{
  const sc = web.slice(web.indexOf('private var settingsContent'),
                        web.indexOf('private var panelContent'));
  ok(/VStack\(spacing: 0\) \{\s*panelContent\s*featureGrid\s*\}\s*\n?\s*\.fixedSize/.test(sc),
     'fixedSize 挂在**包住全部内容**的 VStack 上（不是只挂 featureGrid）');
  ok(/VStack\(spacing: 0\) \{[\s\S]{0,120}panelContent[\s\S]{0,60}featureGrid[\s\S]{0,600}SheetContentHeightKey/.test(sc),
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
// 玻璃：iOS 26 用 .glassEffect(.regular, in: shape) 是真液态玻璃
// 比 .ultraThinMaterial 层次更深（折射背后的内容，不是模糊）
ok(/glassEffect\(\.regular/.test(web), '面板用 .glassEffect(.regular) 真液态玻璃');
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
                            web.indexOf('private func hairLine'));
ok(/VStack/.test(mainSheet), '主面板用 VStack（内容行数固定，高度确定）');
ok(/panelContent[\s\S]{0,40}featureGrid/.test(mainSheet),
   '主面板 = panelContent + featureGrid（没有内层白卡了）');
ok(!/private var (displayCard|pageTurnCard|upperPanelCard)/.test(web),
   '旧卡片视图名全部退役（displayCard / pageTurnCard / upperPanelCard）');
ok(!/\.background\(\s*Color\.white/.test(featureGrid),
   '磁贴区不垫独立白底（只有一层统一淡底）');

console.log('\n── 第 5 版面板结构 ──');

// ⚠️⚠️ 「中间有一块阴影」= **面板玻璃容器自己投的 box-shadow**，
//    不是容器里再套一层白色块。
//    我 build82~89 一直加着那层白卡（white@.35 / radius 22）—— 从一开始就错了。
ok(!/upperPanelCard/.test(web), '不再有内层白卡（那层是我误加的）');
ok(!/Color\.white\.opacity\(0\.35\)/.test(web), '没有那层 white@0.35 内嵌白块');
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
  const glassAt = panel.indexOf('glassEffect');
  const innerPad = panel.indexOf('.padding(.horizontal, 14)');
  const innerTop = panel.indexOf('.padding(.top, 12)');
  const innerBot = panel.indexOf('.padding(.bottom, 16)');
  const outerPad = panel.lastIndexOf('.padding(.horizontal, 14)');
  const outerBot = panel.lastIndexOf('.padding(.bottom, 14)');
  ok(innerTop >= 0 && innerBot >= 0, '有内部 padding 12/16');
  ok(innerPad >= 0 && innerPad < glassAt,
     '内部 padding 在 glassEffect **之前**（玻璃里面）');
  ok(innerBot < glassAt, '内部底 padding 在 glassEffect 之前');
  ok(outerPad > glassAt && outerPad !== innerPad,
     '定位 padding 在 glassEffect **之后**（玻璃外面），且不与内部那个重复');
  ok(outerBot > glassAt, '定位底 padding 在 glassEffect 之后');
  // 左右 padding 在玻璃前后各出现一次，且**不能**都在玻璃前
  const hP = [...panel.matchAll(/\.padding\(\.horizontal, 14\)/g)].map(m => m.index);
  ok(hP.length === 2 && hP[0] < glassAt && hP[1] > glassAt,
     '左右 padding 恰好两次：一次在玻璃前、一次在玻璃后');
}
ok(/cornerRadius: 22/.test(panel), '面板圆角 22');
ok(!/\.background\(Color\.white\.opacity\(0\.82\)/.test(panel),
   '**不**留 white@.82（那是普通毛玻璃，不是液态玻璃）');
// ⚠️⚠️ 面板背景**必须是液态玻璃**（.glassEffect(.regular, in:shape)），
// 不是 ui.txt 的 white @ 0.82。用户一开始就要求栖阅风格液态玻璃，
// ui.txt 那份不是栖阅源码，那 .82 是普通毛玻璃，迁就它会失去玻璃的深度。
ok(/glassEffect\(\.regular, in: RoundedRectangle\(cornerRadius: 22/.test(panel),
   '面板用 .glassEffect(.regular) 液态玻璃（不是 ui.txt 的 white@.82）');
// ⚠️ 不照搬 ui.txt 的 box-shadow 0 4px 30px rgba(0,0,0,.12)：
// glassEffect 在 iOS 26 自带 ambient shadow，再叠 .shadow() 会出双影。
ok(!/\.shadow\(color: Color\.black\.opacity\(0\.12\), radius: 15/.test(panel),
   '不叠 .shadow（glassEffect 自带 ambient shadow，再叠会双影）');
ok(!/\.background \{[\s\S]{0,200}RoundedRectangle\(cornerRadius: 22/.test(web),
   '不写 .background { RoundedRectangle(...) }（flexible Shape 会铺满）');
ok(/\.frame\(height: sheetHeight\)/.test(panel), '面板显式高度（overlay 没 detent 撑）');
ok(/hardCap = screenH \* 0\.70/.test(web), '高度有屏幕 70% 硬上限');

// 字号行
ok(/frame\(width: 34, height: 34\)/.test(web), '小/大 圆形 34×34');
ok(/14\.\.\.28/.test(web), '字号滑块 14...28（ui.txt min:14 max:28）');
ok(/padding\(\.horizontal, 13\)/.test(fontMenu), '字体下拉 水平内边距 13（ui.txt .font-select）');
ok(/padding\(\.vertical, 7\)/.test(fontMenu), '字体下拉 垂直内边距 7');
ok(/cornerRadius: CGFloat = 18/.test(chip) && /fontSize: CGFloat = 14/.test(chip),
   'chip 圆角 18 / 字号 14（参考实现 .pill）');

// pills：**不等分** + 横向滚动（正解，不是等分也不是换行）
ok(/ScrollView\(\.horizontal, showsIndicators: false\)/.test(pageTurn),
   '翻页方式横向滚动（放不下就滚，不截字）');
ok(!/fillsWidth: true/.test(pageTurn), 'pills 不等分 —— 等分是我 build86~88 走的三轮弯路');
ok(/fixedSize\(\)/.test(chip), 'pill 按内容宽度 fixedSize');

// 色块
ok(/frame\(width: 42, height: 42\)/.test(web), '色块 42×42（参考实现 .swatch）');
ok(/cornerRadius: 9/.test(web), '色块圆角 9');
ok(/font\(\.system\(size: 13, weight: \.regular\)\)/.test(web), '色块文字 13');
ok(/frame\(width: 28\)/.test(web), '色块行图标槽 28（参考实现 .mode-icon width:28）');

// 宫格：**两行文字、没有图标行、不需要固定高度**
ok(/Text\(name\)\.font\(\.system\(size: 18, weight: \.semibold\)\)/.test(ft),
   '宫格第一行 18pt（参考实现 .ic 18）');
ok(/Text\(subtitle \?\? ""\)\.font\(\.system\(size: 13\)\)/.test(ft),
   '宫格第二行 13pt（参考实现 .t1 13）');
ok(!/Color\.clear\.frame\(width: 18, height: 18\)/.test(ft),
   '不再有空图标占位（没有图标行，这个 hack 没用了）');
ok(!/frame\(height: 76\)/.test(ft), '宫格不设固定高度（两行文字自然等高）');
ok(/padding\(\.vertical, 9\)[\s\S]{0,40}padding\(\.horizontal, 4\)/.test(ft),
   '宫格内边距 9/4（参考实现 .cell padding:9px 4px 8px）');
ok(/cornerRadius: 12/.test(ft), '宫格圆角 12（参考实现 .cell）');
ok(/VStack\(spacing: 8\) \{\s*tileRow\(0\)/.test(web), '宫格间距 8（参考实现 gap:8px）');

// ⚠️ 参考实现建议「去掉置灰（enabled:false）」让它看着正常 —— **不采纳**。
//    未实现的功能（朗读 / 高亮 / 气泡 / 格式 / 页眉页脚）置灰是用户明确要的：
//    宁可看起来淡，也不能让用户以为点得动。撤置灰 = 伪装成已完成。
ok(/foregroundStyle\(ready \? Theme\.ink : Theme\.sub\.opacity\(0\.45\)\)/.test(web),
   '未实现功能仍置灰（不采纳参考实现「去掉置灰」的建议）');
ok(/\.disabled\(!ready\)/.test(web), '未实现功能仍 disabled，不弹虚假完成提示');
