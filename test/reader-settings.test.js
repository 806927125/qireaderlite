#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：阅读设置必须是「柴阅式」的**（2026-11-25 改写）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么整条改写**（不是放宽）⭐⭐⭐：
 *   旧版这条门禁钉的是「**我们自己重写版的**阅读设置面板 + App 设置页里的排版细项」
 *   （行底线 / 垂直两端对齐 / 宽屏双页 / 内容限制在页眉页脚之间 / 点击任意位置翻页 / 上滑退出…）
 *   ⇒ 那些细项是**我们自己那套阅读器**的功能 ⇒ 阅读器换成柴阅的 ⇒ **柴阅没有这些能力** ⭐⭐⭐
 *   ⇒ 留在设置页里就是「摆着不点」的死设置 ⇒ **清掉** ⭐⭐⭐
 *   ⇒ 新的判据：**设置页列的每一项，柴阅的阅读器真的认** ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **接法：键名对齐，零桥接** ⭐⭐⭐⭐⭐
 *   柴阅的 `ReaderSettings` 直接读写 `UserDefaults.standard`
 *   （包内 `ChaiyueReader/ReaderSettings.swift`）
 *   ⇒ 轻阅这边用 `@AppStorage` 写**同样的键** ⇒ 两边天然同步 ⇒ 改完立刻生效 ⭐⭐⭐
 *
 * ⭐⭐⭐ 每条断言都要问「把它改坏，它会不会红」⇒ 都能被变异对照证伪 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'QiReaderLite');
const PKG_SETTINGS = path.join(__dirname, '..',
  'LegadoEngine/Sources/ChaiyueReader/ReaderSettings.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const read = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
};

// ── ① ⭐⭐⭐⭐⭐ **阅读设置页列的每一项，柴阅的 `ReaderSettings` 都得认** ⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  const chaiyue = fs.existsSync(PKG_SETTINGS)
    ? fs.readFileSync(PKG_SETTINGS, 'utf8') : '';

  // 轻阅设置页用的键（@AppStorage 写的就是柴阅读的那几个）
  const OUR_KEYS = [
    'reader.fontSize', 'reader.spacing', 'reader.pageStyle',
    'reader.brightness', 'reader.keepScreenOn', 'reader.tapNext',
    'reader.paragraphComments', 'reader.autoAddToShelf',
    'reader.conversion', 'reader.preload',
  ];
  for (const key of OUR_KEYS) {
    ok(screens.includes(`"${key}"`), `① 阅读设置页有柴阅的键 ${key}`);
    // ⭐⭐⭐ **键必须在柴阅那边真的存在**（否则就是「写了个没人读的设置」）⭐⭐⭐
    ok(chaiyue.includes(`"${key}"`), `① 柴阅的 ReaderSettings 真的读 ${key}`);
  }
}

// ── ② ⭐⭐⭐⭐⭐ **老阅读器独占的细项必须清干净**（别留死设置）⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  const DEAD = [
    'reader.lineSpacing', 'reader.paraSpacing', 'reader.paraAlign',
    'reader.showBaseline', 'reader.baselineScope', 'reader.baselineColor',
    'reader.verticalJustify', 'reader.tapAnywhere', 'reader.swipeUpExit',
    'reader.twoPageSpread', 'reader.contentInHeaderFooter',
    'reader.pageTurn', 'reader.followSystem', 'reader.fontKey', 'reader.theme',
  ];
  for (const key of DEAD) {
    ok(!screens.includes(`@AppStorage("${key}")`), `② 老死键不再被消费：${key}`);
  }
  // 老阅读器那套 UI 组件也不许残留
  for (const sym of ['ReaderBaselineScope', 'ReaderParaAlign', 'ReaderFontPicker']) {
    ok(!screens.includes(sym), `② 老组件已清：${sym}`);
  }
}

// ── ③ ⭐⭐⭐⭐⭐ **字体页用柴阅的字体枚举** ⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  ok(/ReaderFontChoice\.allCases/.test(screens), '③ 字体页列的是柴阅的 `ReaderFontChoice`');
  ok(screens.includes('"reader.font"'), '③ 字体页写柴阅的键 `reader.font`');
  ok(!screens.includes('ReaderFont.all'), '③ 不再用我们重写版的 `ReaderFont.all`');
}

// ── ④ ⭐⭐⭐⭐⭐ **柴阅的设置项一个都不能漏接**（反向钉：柴阅有的，我们也得有）⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  const chaiyue = fs.existsSync(PKG_SETTINGS)
    ? fs.readFileSync(PKG_SETTINGS, 'utf8') : '';
  // 柴阅 `ReaderSettings` 里落盘用的键（`defaults.set(…, forKey: "…")` / `defaults.string(forKey: "…")`）
  const chaiyueKeys = [...chaiyue.matchAll(/forKey:\s*"([^"]+)"/g)].map(m => m[1]);
  const unique = [...new Set(chaiyueKeys)].filter(k => k.startsWith('reader.'));
  // ⭐⭐⭐ 这些键柴阅自己用，但**轻阅不在设置页暴露**（它们要么是浅色槽、要么由别处管）⭐⭐⭐
  //   · `reader.lightTheme` / `reader.darkTheme` / `reader.customTheme` = 主题槽（在「阅读主题」页管）⭐⭐⭐
  //   · `reader.font` = 字体枚举（在「字体」页管）⭐⭐⭐
  //   · `reader.customFont` = **导入字体**的 PostScript 名 ⇒ 由柴阅自己的「外观」面板管
  //     （`StylePanel` → 字体 → 导入字体；轻阅的「字体」页只列三套内置字体）⭐⭐⭐
  const NOT_ON_PAGE = new Set(['reader.lightTheme', 'reader.darkTheme', 'reader.customTheme',
                               'reader.font', 'reader.customFont']);
  for (const key of unique) {
    if (NOT_ON_PAGE.has(key)) continue;
    ok(screens.includes(`"${key}"`), `④ 柴阅的设置项 ${key} 我们也接了`);
  }
}

// ── ⑤ ⭐⭐⭐⭐⭐ **App 的「阅读设置」入口还在**（别把整个入口删了）⭐⭐⭐⭐⭐
{
  const settings = read('Features/Settings/SettingsView.swift');
  ok(/ReadingSettingsScreen\(\)/.test(settings), '⑤ 设置页还有「阅读设置」入口');
  ok(/ReaderThemesScreen\(\)/.test(settings), '⑤ 设置页还有「阅读主题」入口');
  ok(/FontsScreen\(\)/.test(settings), '⑤ 设置页还有「字体」入口');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
