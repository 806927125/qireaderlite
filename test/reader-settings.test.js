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
  ['翻页方式在灰底圆角卡片里',        /private var pageTurnCard/],
  ['功能磁贴 4+4（照栖阅）',          /private var featureGrid/],
  ['子页：显示设置',                  /private var displaySettingsPage/],
  ['子页：间距设置',                  /private var layoutSettingsPage/],
]) ok(re.test(web), label);

console.log('\n── 液态玻璃：用系统层级的，不是自己糊一层 ──');
// Apple 规则（WWDC25 session 323）：
//   · iOS 26 的 partial-height sheet **默认就是液态玻璃**
//   · .large 全屏 detent 是不透明的
//   · 自定义 presentationBackground 会**覆盖掉**系统的玻璃 → 要去掉
const fit = web.slice(web.indexOf('private struct FitSheetHeight'));
ok(/private struct FitSheetHeight: ViewModifier/.test(web), '有 FitSheetHeight 修饰符');
ok(!/Spacer\(minLength: 0\)/.test(web.slice(web.indexOf('var settingsContent'), web.indexOf('var displayCard'))),
   '主面板没有 Spacer（会把 sheet 撑满）');

// ★ iOS 26 的系统玻璃必须是 partial-height sheet。
//   只给 presentationSizing(.fitted) 而不给 detent → sheet 走默认全屏
//   → 全屏不透明 → 玻璃出不来、面板还撑满整屏（build 43 实机就是这么翻车的）。
const fitBody = web.slice(web.indexOf('private struct FitSheetHeight'));
const iOS26 = fitBody.slice(fitBody.indexOf('#available(iOS 26.0'), fitBody.indexOf('#available(iOS 18.0'));
ok(/presentationDetents\(\[\.height\(/.test(iOS26), 'iOS 26 给了 partial detent（.height 是 partial）');
ok(!/presentationSizing/.test(iOS26), 'iOS 26 分支不再单靠 presentationSizing(.fitted)');
ok(!/presentationBackground/.test(iOS26), 'iOS 26 分支不覆盖系统玻璃背景');
ok(/presentationDetents\(\[\.height\([^)]*\)\]\)/.test(fitBody), 'detent 高度可动态传入');
ok(/private struct SheetContentHeightKey: PreferenceKey/.test(web), '有测高 preference');
ok(/preference\(key: SheetContentHeightKey\.self, value: geo\.size\.height\)/.test(web), '背景 GeometryReader 量内容高度');
ok(/fixedSize\(horizontal: false, vertical: true\)/.test(web), '内容固定成自然高度（否则量到的是 detent 高度，成死循环）');
ok(/if #available\(iOS 26\.0, \*\)/.test(fit), 'iOS 26 单独一条分支');
// iOS 26 分支里不能有 presentationBackground
const ios26Branch = fit.slice(fit.indexOf('if #available(iOS 26.0, *)'), fit.indexOf('} else if #available(iOS 18.0'));
ok(!/presentationBackground/.test(ios26Branch),
   'iOS 26 分支**不设** presentationBackground（会覆盖掉系统的玻璃）');
ok(!/presentationCornerRadius/.test(fit), '不用 presentationCornerRadius 覆盖系统圆角');
// 旧系统才自己糊
ok(/presentationBackground\(\.ultraThinMaterial\)/.test(fit), 'iOS 17~25 用 ultraThinMaterial 兜底');
// 全屏 detent 会让玻璃消失
ok(!/presentationDetents\(\[\.large\]\)/.test(web), '不能用 .large（全屏不透明，玻璃就没了）');
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
const mainSheet = web.slice(web.indexOf('private var settingsContent'), web.indexOf('private var displayCard'));
ok(!/ScrollView/.test(mainSheet), '主面板不用 ScrollView（否则 fitted 撑不满）');
ok(/VStack/.test(mainSheet), '主面板用 VStack（内容行数固定，高度确定）');

console.log('\n── 关键布局细节 ──');
// 字体下拉必须跟滑块同一行（不是单独一行）
const sizeRow = web.slice(web.indexOf('private var sizeRow'), web.indexOf('private func sizeKnob'));
ok(/fontMenu/.test(sizeRow), '字体下拉在字号行里（同一行）');
ok(!/private var fontRow/.test(web), '没有单独的字体行');
// 翻页方式卡片：灰底圆角 + 左侧图标
// 圆角按栖阅 designer.css 的 token 阶梯：--r-sm 8 / --r-md 12 / --r-lg 16
ok(/Color\.white\.opacity\(0\.34\)[\s\S]{0,80}?RoundedRectangle\(cornerRadius: 16/.test(web),
   '翻页方式卡片是半透明白圆角，cornerRadius 16 = 栖阅 --r-lg');
ok(/cornerRadius: 12/.test(web), '磁贴 cornerRadius 12 = 栖阅 --r-md');
ok(/RoundedRectangle\(cornerRadius: 8, style: \.continuous\)/.test(web),
   '小方块/配色格 cornerRadius 8 = 栖阅 --r-sm');
// ⭐ 填充色必须**带蓝调**（栖阅 --fill: rgba(120,120,128,0.12)），
//    不是纯灰 —— 纯灰叠在暖色纸背景上显脏。
ok(/Color\(red: 120\/255, green: 120\/255, blue: 128\/255\)\.opacity\(0\.12\)/.test(web),
   '控件底色用栖阅 --fill（120,120,128 偏冷的灰）');
ok(!/\.background\(Color\.gray\.opacity/.test(web),
   '**没有**用 Color.gray.opacity 当填充 —— 那是纯灰，不是栖阅的冷灰');
ok(/Color\(red: 60\/255, green: 60\/255, blue: 67\/255\)\.opacity\(0\.12\)/.test(web),
   '细分隔线用栖阅 --line (60,60,67,0.12)');
ok(/Image\(systemName: "doc\.text"\)/.test(web), '翻页方式卡片左边有图标');
// 磁贴：图标 + 粗体标题 + 副标题
ok(/Image\(systemName: icon\)/.test(web), '磁贴有图标');
ok(/font\(\.subheadline\.weight\(\.semibold\)\)/.test(web), '磁贴标题是粗体');
ok(/Text\(subtitle \?\? ""\)\.font\(\.caption2\)/.test(web), '磁贴有副标题');
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
ok(/Image\(systemName: icon\)\.font\(\.system\(size: 15\)\)/.test(web),
   '磁贴图标 15pt（原来 19，是磁贴撑到 190px 的主因）');
ok(/VStack\(spacing: 3\)/.test(web), '磁贴内间距 3（原来 6）');
{
  const ft = web.slice(web.indexOf('private func featureTileLabel'));
  ok(/\.padding\(\.vertical, 8\)/.test(ft), '磁贴上下留白 8（原来 14）');
  ok(/VStack\(spacing: 3\)/.test(ft), '磁贴内间距 3（原来 6）');
}
ok(/frame\(height: 28\)/.test(web), '配色格高 28（原来 36）');
ok(/frame\(width: 32, height: 28\)/.test(web), '小/大方块 32x28（原来 36x32）');
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
