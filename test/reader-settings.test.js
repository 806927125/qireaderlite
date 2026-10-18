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
  return src
    .replace(/\/[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
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
  ['功能磁贴 4+5',                    /private var featureGrid/],
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
ok(/if #available\(iOS 26\.0, \*\)/.test(fit), 'iOS 26 单独一条分支');
ok(/presentationSizing\(\.fitted\)/.test(fit), '用 presentationSizing(.fitted) 让高度贴合内容');
// iOS 26 分支里不能有 presentationBackground
const ios26Branch = fit.slice(fit.indexOf('if #available(iOS 26.0, *)'), fit.indexOf('} else if #available(iOS 18.0'));
ok(!/presentationBackground/.test(ios26Branch),
   'iOS 26 分支**不设** presentationBackground（会覆盖掉系统的玻璃）');
ok(!/presentationCornerRadius/.test(fit), '不用 presentationCornerRadius 覆盖系统圆角');
// 旧系统才自己糊
ok(/presentationBackground\(\.ultraThinMaterial\)/.test(fit), 'iOS 17~25 用 ultraThinMaterial 兜底');
ok(/presentationDetents\(\[\.height\(620\)\]\)/.test(fit), 'iOS 17 用固定高度 detent');
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
ok(/Color\.white\.opacity\(0\.34\)[\s\S]{0,80}?RoundedRectangle\(cornerRadius: 20/.test(web),
   '翻页方式卡片是半透明白圆角（玻璃感）');
ok(/Image\(systemName: "doc\.text"\)/.test(web), '翻页方式卡片左边有图标');
// 磁贴：图标 + 粗体标题 + 副标题
ok(/Image\(systemName: icon\)/.test(web), '磁贴有图标');
ok(/font\(\.subheadline\.weight\(\.semibold\)\)/.test(web), '磁贴标题是粗体');
ok(/Text\(subtitle\)\.font\(\.caption2\)/.test(web), '磁贴有副标题');
ok(/name: "大小", subtitle: "显示设置"/.test(web), '「大小/显示设置」磁贴');
for (const n of ['间距设置','朗读设置','高亮设置','气泡设置','格式','标题样式','页眉页脚','更多设置']) {
  ok(web.includes(`name: "${n}"`), `磁贴「${n}」在`);
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

console.log('\n── 没接的功能：摆位但不点 ──');
const tiles = web.slice(web.indexOf('private var featureGrid'), web.indexOf('private func featureTileLabel'));
const notReady = (tiles.match(/ready:\s*false/g) || []).length;
ok(notReady >= 6, `6 个功能标了 ready:false（还没接的）`, `实际 ${notReady}`);
ok(/ready:\s*true/.test(tiles), '有 ready:true 的磁贴（大小/间距/更多设置 是接上的）');
ok(/\.disabled\(!t\.ready\)/.test(web), 'ready:false 的宫格是 disabled');
ok(/guard t\.ready else \{ return \}/.test(web), '点击前先挡一道（不只靠 disabled）');
ok(/foregroundStyle\(ready \? Theme\.ink : Theme\.sub\.opacity\(0\.45\)\)/.test(web),
   '未接的格子画成灰的，一眼看得出还没做');
ok(/\.disabled\(!t\.ready\)/.test(web), 'ready:false 的磁贴是 disabled');

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
