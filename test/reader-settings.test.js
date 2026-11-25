#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：阅读设置面板必须是「柴阅式」**（2026-11-25 重写）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么整条重写**（不是放宽）⭐⭐⭐：
 *   用户原话：「**阅读界面是不是有老代码保留，全给替换成柴阅的，设置那些也要替换**」⭐⭐⭐
 *   ⇒ 旧的这条门禁整条是**冲栖阅那版面板**去的（照参考截图 1:1 复刻）：
 *       底部 overlay 磨砂大卡 + 字号方块滑杆 + 配色格子 + **8 个功能磁贴**
 *   ⇒ 那版面板本轮**删掉了** ⇒ 门禁必须**按新意图重写**：
 *       柴阅的「外观」= **sheet**（高 548）+ 细轨滑块 + 字号步进 + 行距三档
 *                    + 字体分段 + 主题小页纸条 + 翻页方式 ⭐⭐⭐
 *       排版**细项**挪到 **App 设置的「阅读设置」子页**（柴阅的位置）⭐⭐⭐
 *
 * ⭐⭐⭐ 每条断言都要问「把它改坏，它会不会红」⇒ 都能被变异对照证伪 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}
let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const readIf = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? stripComments(fs.readFileSync(p, 'utf8')) : '';
};
const web = readIf('Features/Reader/ReaderWebView.swift');
const panel = readIf('Features/Reader/ReaderStylePanel.swift');
const screens = readIf('Features/Settings/SettingsScreens.swift');

// ── ① ⭐⭐⭐ 柴阅面板的 6 个组件都在 ──
{
  ok(fs.existsSync(path.join(ROOT, 'Features/Reader/ReaderStylePanel.swift')),
     '① 柴阅面板文件在（ReaderStylePanel.swift）');
  ok(/struct ReaderStylePanel: View/.test(panel), '① 有 ReaderStylePanel');
  for (const [label, re] of [
    ['亮度行',        /private var brightnessRow: some View/],
    ['字号步进',      /private var sizeStepper: some View/],
    ['行距三档',      /private var spacingPicker: some View/],
    ['字体分段',      /private var fontPicker: some View/],
    ['主题条',        /private var themeRow: some View/],
    ['翻页方式',      /private var modeRow: some View/],
  ]) ok(re.test(panel), `① 面板有${label}`);
  for (const [label, re] of [
    ['细轨滑块',      /struct ReaderGlassSlider: View/],
    ['字号步进器',    /struct ReaderFontSizeStepper: View/],
    ['行距三档选择器', /struct ReaderSpacingPicker: View/],
    ['行距图标',      /struct ReaderSpacingGlyph: Shape/],
    ['字体分段',      /struct ReaderFontPicker: View/],
    ['主题条',        /struct ReaderThemeStrip: View/],
    ['主题小页纸',    /struct ReaderThemeSwatch: View/],
  ]) ok(re.test(panel), `① 有${label}组件`);
}

// ── ② ⭐⭐⭐ 面板是 sheet（不是栖阅的底部 overlay），且强制外观跟主题走 ──
{
  ok(/presentationDetents\(\[\.height\(548\)\]\)/.test(panel),
     '② 面板是 sheet，高 548（柴阅规格）');
  ok(/presentationDragIndicator\(\.visible\)/.test(panel), '② 有拖拽指示条（柴阅）');
  ok(/preferredColorScheme\(theme\.isDarkTheme \? \.dark : \.light\)/.test(panel),
     '②⭐⭐⭐ 面板强制外观跟阅读主题走（深色阅读 ⇒ 深色 sheet，不许乳白板）');
  ok(/UIScreen\.main\.brightness = CGFloat\(v\)/.test(panel),
     '② 亮度滑块真接到屏幕亮度（柴阅 brightnessRow）');
  ok(/Image\(systemName: "sun\.min"\)/.test(panel) && /Image\(systemName: "sun\.max"\)/.test(panel),
     '② 亮度行两头是 sun.min / sun.max（柴阅）');
}

// ── ③ ⭐⭐⭐ 组件规格照柴阅 ──
{
  ok(/range: ClosedRange<Double> = 14\.\.\.30/.test(panel), '③ 字号范围 14…30（柴阅）');
  ok(/\.system\(size: 14, weight: \.medium\)/.test(panel), '③ 小号 A 是 14pt（柴阅）');
  ok(/\.system\(size: 21, weight: \.medium\)/.test(panel), '③ 大号 A 是 21pt（柴阅）');
  ok(/\.frame\(width: 36\)/.test(panel), '③ 数字宽 36（柴阅）');
  ok(/\.frame\(height: 46\)/.test(panel), '③ 控件高 46（柴阅）');
  ok(/cornerRadius: 16, style: \.continuous/.test(panel), '③ 圆角 16（柴阅）');
  ok(/matchedGeometryEffect\(id: "reader-spacing"/.test(panel), '③ 行距选中态有形变动画（柴阅）');
  ok(/let gaps: \[CGFloat\] = \[3\.2, 4\.6, 6\.2\]/.test(panel), '③ 行距图标三档间距照柴阅');
  ok(/frame\(width: 62, height: 80\)/.test(panel), '③ 主题小页纸 62×80（柴阅）');
  ok(/proxy\.scrollTo\(current, anchor: \.center\)/.test(panel), '③ 主题条滚到当前项（居中，柴阅）');
  ok(/proxy\.scrollTo\(selection, anchor: \.center\)/.test(panel), '③ 字体分段滚到当前项（柴阅）');
}

// ── ④ ⭐⭐⭐ 行距 = 档位（柴阅），不是绝对值 ──
{
  ok(/enum ReaderSpacingLevel: Int, CaseIterable, Identifiable/.test(panel),
     '④ 行距是三档枚举（柴阅 spacing）');
  ok(/case compact = 0/.test(panel) && /case normal  = 1/.test(panel) && /case relaxed = 2/.test(panel),
     '④ 三档 = 紧凑/标准/宽松');
  ok(/return 0\.55/.test(panel), '④ 标准档行距系数 0.55（柴阅）');
  ok(/return 0\.70/.test(panel), '④ 标准档段距系数 0.70（柴阅）');
  ok(/static func nearest\(lineSpacing: Double, fontSize: Double\)/.test(panel),
     '④ 能从旧的绝对行距反推档位（一次性迁移用）');
  ok(/@AppStorage\("reader\.spacingLevel"\)/.test(web), '④ 档位有独立存储键');
  ok(/@AppStorage\("reader\.spacingLevelMigrated"\)/.test(web), '④ 有一次性迁移标记');
  ok(/if !spacingLevelMigrated \{/.test(web), '④ 迁移只做一次');
  ok(/private func applySpacingLevel\(_ level: Int, fontSize: Double\)/.test(web),
     '④ 档位会写回行距/段距');
  ok(/applySpacingLevel\(spacingLevel, fontSize: newSize\)/.test(web),
     '④⭐⭐⭐ 改字号时行距按新字号重算（柴阅行为）');
}

// ── ⑤ ⭐⭐⭐ 栖阅那版面板**彻底没了** ──
{
  for (const [label, re] of [
    ['底部 overlay 面板', /private var settingsSheet: some View/],
    ['字号方块行',       /private var sizeRow: some View/],
    ['灰底方块',         /private func sizeKnob/],
    ['字体下拉',         /private var fontMenu: some View/],
    ['配色格子网格',     /private var paletteGrid: some View/],
    ['配色格子行',       /private func paletteRow/],
    ['功能磁贴',         /private var featureGrid: some View/],
    ['磁贴数据表',       /private static let tiles/],
    ['小胶囊按钮',       /private struct ChipButton: View/],
    ['显示设置子页',     /private var displaySettingsPage: some View/],
    ['间距设置子页',     /private var layoutSettingsPage: some View/],
    ['更多设置子页',     /private var moreSettingsPage: some View/],
  ]) ok(!re.test(web), `⑤ 栖阅那版的${label}已经删掉`);
  ok(!/严格按 ui\.txt/.test(web), '⑤ 栖阅 ui.txt 规格的注释也没了');
}

// ── ⑥ ⭐⭐⭐ 排版细项迁到 App 设置的独立子页（柴阅的位置）──
{
  ok(/struct ReadingSettingsScreen: View/.test(screens), '⑥ 有「阅读设置」独立子页');
  ok(/struct ReaderThemesScreen: View/.test(screens), '⑥ 有「阅读主题」独立子页');
  ok(/struct FontsScreen: View/.test(screens), '⑥ 有「字体」独立子页');
  ok(/struct CacheScreen: View/.test(screens), '⑥ 有「缓存」独立子页');
  ok(/struct AboutScreen: View/.test(screens), '⑥ 有「关于」独立子页');
  ok(/struct BackupScreen: View/.test(screens), '⑥ 有「备份」独立子页（灰态）');
  for (const [label, re] of [
    ['垂直两端对齐',   /垂直两端对齐/],
    ['行底线',         /行底线/],
    ['底线颜色',       /底线颜色/],
    ['段落对齐',       /段落对齐/],
    ['点击翻页',       /点击页面任意位置翻页/],
    ['上滑退出',       /上滑退出阅读/],
    ['跟随系统深浅色', /跟随系统深浅色/],
  ]) ok(re.test(screens), `⑥ 「阅读设置」页有${label}`);
  // 入口页要把这些子页都列出来
  const settings = readIf('Features/Settings/SettingsView.swift');
  for (const s of ['ReadingSettingsScreen', 'ReaderThemesScreen', 'FontsScreen',
                   'CacheScreen', 'BackupScreen', 'AboutScreen']) {
    ok(settings.includes(s), `⑥ 设置入口页有「${s}」入口`);
  }
}

// ── ⑦ ⭐⭐⭐ 栖阅那套 WebView 阅读器彻底没了 ──
{
  ok(!fs.existsSync(path.join(ROOT, 'Core/ReaderHost.swift')),
     '⑦ Core/ReaderHost.swift（栖阅 WebView 阅读器）已删');
  ok(!fs.existsSync(path.join(ROOT, 'Resources/reader')),
     '⑦ Resources/reader/（48KB 的 reader.html/js/css）已删');
  ok(!/host\.setSettings|host\.apply|host\.update|host\.fail/.test(web),
     '⑦ 阅读页不再往 WebView 下发 settings / 喂章节');
  ok(!/WKWebView/.test(web), '⑦ 阅读页不再引用 WKWebView');
}

// ── ⑧ ⭐⭐⭐ 左右边距：正文不许顶到屏幕左边缘 ──
{
  ok(/var horizontalMargin: CGFloat = 22/.test(readIf('Features/Reader/ReaderSkin.swift')),
     '⑧ chrome 带左右边距（柴阅左右各 26，轻阅 22）');
  ok(/textOrigin = CGPoint\(x: chrome\.horizontalMargin, y: chrome\.headerHeight\)/.test(
       readIf('Features/Reader/Paging/ReaderPageVC.swift')),
     '⑧⭐⭐⭐ 正文绘制原点的 x = 左右边距（以前 x=0 ⇒ 文字顶到屏幕左边缘）');
  const vc = readIf('Features/Reader/Paging/ReaderPageVC.swift');
  ok(/drawChapterNumber\(number, in: CGRect\(x: m,/.test(vc),
     '⑧ 章节号装饰也缩进到文字区（跟正文对齐）');
  ok(/at: CGPoint\(x: max\(0, w - m - size\.width\), y: footerY\)/.test(vc),
     '⑧ 页脚右侧值也缩进（左右对称）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
