#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：正文阅读页的「柴阅皮肤」必须完整**（2026-11-25 改写）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么整条改写**（不是放宽）⭐⭐⭐：
 *   旧版这条门禁钉的是「**我们自己照着柴阅重画**的那套皮肤」（`ReaderSkin.swift` +
 *   `ReaderSkinBackground.swift` + 16 套配色 + `ReaderLayoutConfig` 的页眉页脚）。
 *   ⇒ 2026-11-25 用户要求：「**阅读正文界面的，老的代码全部删掉，全部用柴阅的**」
 *   ⇒ 那套重画版**整套删掉** ⇒ 皮肤/配色/页眉页脚/章节号装饰 **全部由柴阅提供** ⭐⭐⭐
 *   ⇒ 所以判据从「我们画得像柴阅」变成「**我们用的就是柴阅**」⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **柴阅那套皮肤长什么样**（规格来自柴阅源码，只读当规格）⭐⭐⭐⭐⭐：
 *   · **四套皮肤**：宣纸 / 晴窗 / 星夜 / 烛灯（字体 + 章节号装饰 + 进度装饰）⭐⭐⭐
 *   · **十套内置主题**（柴阅的 `ReaderThemeSpec.all`）：宣纸 / 晴窗 / 星夜 / 烛灯 /
 *     纸张 / 素白 / 豆绿 / 雾灰 / 暮色 / 夜间 ⭐⭐⭐
 *   · **一页 = 页眉 + 正文 + 页脚**（页眉=书名/章名，页脚=页码+全书进度%）⭐⭐⭐
 *   · **排版默认值**：字号 20 / 行距 0.55× / 段距 0.7× / 首行缩进 2 字 / 两端对齐 ⭐⭐⭐
 *
 * ⭐⭐⭐ 每条断言都要问「把它改坏，它会不会红」⇒ 都能被变异对照证伪 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'QiReaderLite');
const PKG = path.join(__dirname, '..', 'LegadoEngine/Sources/ChaiyueReader');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const read = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
};
const readPkg = (rel) => {
  const p = path.join(PKG, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
};

// ── ① ⭐⭐⭐⭐⭐ **我们重写版的那套必须整套删掉**（皮肤/配色/面板/排版配置）⭐⭐⭐⭐⭐
{
  for (const gone of ['Features/Reader/ReaderSkin.swift',
                      'Features/Reader/ReaderSkinBackground.swift',
                      'Features/Reader/ReaderStylePanel.swift',
                      'Features/Reader/ReaderTheme.swift',
                      'Features/Reader/ReaderWebView.swift']) {
    ok(!fs.existsSync(path.join(ROOT, gone)), `① 我们重写版的 ${gone} 已删`);
  }
  ok(!fs.existsSync(path.join(ROOT, 'Features/Reader/Paging')),
     '① 我们自研的原生分页目录已删');
}

// ── ② ⭐⭐⭐⭐⭐ **宿主用的是柴阅的阅读界面本体**⭐⭐⭐⭐⭐
{
  const screen = read('Features/Reader/Chaiyue/ChaiyueReaderScreen.swift');
  const host = read('Features/Reader/Chaiyue/ChaiyueReaderHost.swift');
  ok(/ReaderContainer\(launch:/.test(screen), '② 宿主打开的是柴阅的 `ReaderContainer`');
  ok(/\.environment\(/.test(screen), '② 给柴阅的阅读界面注入了 `AppModel`');
  ok(/class ChaiyueHostLibrary\s*:\s*ChaiyueReaderLibrary/.test(host),
     '② 宿主侧实现了柴阅的 `ChaiyueReaderLibrary` 门面');
}

// ── ③ ⭐⭐⭐⭐⭐ **四套皮肤 + 十套内置主题仍然在柴阅那边**（我们没动它，只是接上）⭐⭐⭐⭐⭐
{
  const settings = readPkg('ReaderSettings.swift');
  ok(settings.length > 0, '③ 柴阅的 `ReaderSettings.swift` 在');
  for (const id of ['xuan', 'qing', 'xing', 'zhu']) {
    ok(settings.includes(`id: "${id}"`), `③ 柴阅的皮肤/主题 ${id} 在`);
  }
  for (const name of ['宣纸', '晴窗', '星夜', '烛灯']) {
    ok(settings.includes(name), `③ 柴阅的皮肤名「${name}」在`);
  }
  // 十套内置主题：宣纸/晴窗/星夜/烛灯 + 纸张/素白/豆绿/雾灰/暮色/夜间
  // ⚠️ 柴阅写的是 `.init(id: "paper", …)` ⇒ 匹配 `id: "xxx"` 而不是 `ReaderThemeSpec(id: …`⭐⭐⭐
  const themeIds = (settings.match(/id:\s*"([a-z]+)"/g) || [])
    .map(s => (s.match(/"([a-z]+)"/) || [])[1])
    .filter(Boolean);
  // ⚠️ 柴阅的 `all` 共 **10** 条：4 条带皮肤（宣纸/晴窗/星夜/烛灯）+ 6 条纯配色（纸张/素白/豆绿/雾灰/暮色/夜间）⭐⭐⭐
  ok(themeIds.length >= 10, `③ 柴阅内置主题 ${themeIds.length} 套（4 皮肤 + 6 纯配色 = 10）`);
  for (const id of ['paper', 'white', 'green', 'mist', 'dusk', 'night']) {
    ok(themeIds.includes(id), `③ 柴阅的内置主题 ${id} 在`);
  }
}

// ── ④ ⭐⭐⭐⭐⭐ **我们的「阅读主题」页用柴阅的主题表**（不是我们那 16 套）⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  ok(/ReaderThemeSpec\.all/.test(screens), '④ 主题页列的是柴阅的 `ReaderThemeSpec.all`');
  ok(/reader\.darkTheme/.test(screens), '④ 主题页写的是柴阅的深色主题槽 `reader.darkTheme`');
  ok(/reader\.lightTheme/.test(screens), '④ 主题页也写柴阅的浅色主题槽 `reader.lightTheme`');
  ok(!/ReaderTheme\.all/.test(screens), '④ 不再用我们重写版的 `ReaderTheme.all`');
}

// ── ⑤ ⭐⭐⭐⭐⭐ **排版默认值归柴阅的 `ReaderSettings` 管**（键名一致 ⇒ 天然同步）⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  for (const key of ['reader.fontSize', 'reader.spacing', 'reader.pageStyle']) {
    ok(screens.includes(`"${key}"`), `⑤ 阅读设置页用柴阅的键 ${key}`);
  }
  // ⭐⭐⭐ **柴阅的排版默认值**（`ReaderKit/ReaderStyle.swift` 的 `ReaderTypography`）⭐⭐⭐
  const style = fs.readFileSync(path.join(__dirname, '..',
    'LegadoEngine/Sources/ChaiyueReaderKit/ReaderStyle.swift'), 'utf8');
  ok(/fontSize: Double = 20/.test(style), '⑤ 柴阅默认字号 20');
  ok(/lineSpacing: Double = 0\.55/.test(style), '⑤ 柴阅默认行距 0.55×');
  ok(/paragraphSpacing: Double = 0\.7/.test(style), '⑤ 柴阅默认段距 0.7×');
  ok(/indent: Double = 2/.test(style), '⑤ 柴阅默认首行缩进 2 字');
  ok(/justified: Bool = true/.test(style), '⑤ 柴阅默认两端对齐');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
