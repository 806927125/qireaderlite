#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：翻页必须由柴阅提供**（2026-11-25 改写）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么整条改写**（不是放宽）⭐⭐⭐：
 *   旧版这条门禁钉的是「**我们自己写的**翻页器」
 *   （`PagedChapterPager` / `PagedReaderUI` / `ReaderPageVC` / `useNativePaging` / `onTapZone`）
 *   ⇒ 2026-11-25 那套**整套删掉** ⇒ 翻页由**柴阅的 `ReaderKit` + `PagerView`**负责 ⭐⭐⭐
 *   ⇒ 判据从「我们翻得对」变成「**翻页是柴阅的**」⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **柴阅的翻页方式**（`ChaiyueReaderKit/ReaderStyle.swift` 的 `PageTurnStyle`）⭐⭐⭐⭐⭐：
 *   仿真 curl / 平移 scroll / 滑动 slide / 无动画 none / 上下滚动 vertical ⭐⭐⭐
 *   ⇒ 与我们老的那五种**一一对应** ⇒ 用户的手感不变，但**实现换成柴阅的** ⭐⭐⭐
 *
 * ⭐⭐⭐ 每条断言都要问「把它改坏，它会不会红」⇒ 都能被变异对照证伪 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'QiReaderLite');
const PKG = path.join(__dirname, '..', 'LegadoEngine/Sources');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const read = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
};

// ── ① ⭐⭐⭐⭐⭐ **我们自研的翻页器必须整套删掉** ⭐⭐⭐⭐⭐
{
  ok(!fs.existsSync(path.join(ROOT, 'Features/Reader/Paging')),
     '① 我们自研的原生分页目录已删');
  ok(!fs.existsSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift')),
     '① 我们自研的 WebView 阅读页已删');
  // 全 App 不许再有「我们自己翻页」的痕迹
  const leftovers = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!e.name.endsWith('.swift')) continue;
      const src = fs.readFileSync(p, 'utf8');
      for (const sym of ['useNativePaging', 'onTapZone', 'chapterTextArrived',
                         'makeContainer(mode:', 'UIPageViewController']) {
        if (src.includes(sym)) leftovers.push(`${sym} @ ${path.relative(ROOT, p)}`);
      }
    }
  };
  walk(ROOT);
  ok(leftovers.length === 0, '① App 侧不再有自研翻页的痕迹',
     leftovers.slice(0, 6).join(' / '));
}

// ── ② ⭐⭐⭐⭐⭐ **柴阅的五种翻页方式都还在**（规格没被改坏）⭐⭐⭐⭐⭐
{
  const style = fs.readFileSync(path.join(PKG, 'ChaiyueReaderKit/ReaderStyle.swift'), 'utf8');
  for (const [raw, title] of [['curl', '仿真'], ['scroll', '平移'], ['slide', '滑动'],
                              ['none', '无动画'], ['vertical', '上下滚动']]) {
    ok(new RegExp(`case ${raw}\\b`).test(style), `② 柴阅有翻页方式 ${raw}（${title}）`);
    ok(style.includes(`"${title}"`), `② 翻页方式 ${raw} 的中文名「${title}」在`);
  }
  ok(/public enum PageTurnStyle/.test(style), '② `PageTurnStyle` 是 public（宿主能用）');
}

// ── ③ ⭐⭐⭐⭐⭐ **我们的设置页用柴阅的翻页方式**（不再是那个布尔开关）⭐⭐⭐⭐⭐
{
  const screens = read('Features/Settings/SettingsScreens.swift');
  ok(/PageTurnStyle\.allCases/.test(screens), '③ 设置页列的是柴阅的 `PageTurnStyle.allCases`');
  ok(screens.includes('"reader.pageStyle"'), '③ 设置页写柴阅的键 `reader.pageStyle`');
  ok(!screens.includes('@AppStorage("reader.pageTurn")'), '③ 老的布尔开关 `reader.pageTurn` 已清');
}

// ── ④ ⭐⭐⭐⭐⭐ **柴阅的翻页实现还在包侧**（我们只是接上，不是重写）⭐⭐⭐⭐⭐
{
  for (const f of ['ChaiyueReader/PagerController.swift', 'ChaiyueReader/PageView.swift',
                   'ChaiyueReader/VerticalController.swift']) {
    ok(fs.existsSync(path.join(PKG, f)), `④ 柴阅的 ${path.basename(f)} 在`);
  }
  const kit = fs.readFileSync(path.join(PKG, 'ChaiyueReaderKit/ChapterPaginator.swift'), 'utf8');
  ok(/public/.test(kit), '④ 柴阅的排版内核（ReaderKit）在且是 public');
}

// ── ⑤ ⭐⭐⭐⭐⭐ **阅读界面用的是柴阅的翻页视图** ⭐⭐⭐⭐⭐
{
  const screen = read('Features/Reader/Chaiyue/ChaiyueReaderScreen.swift');
  ok(/ReaderContainer\(launch:/.test(screen), '⑤ 宿主打开的是柴阅的 `ReaderContainer`');
  ok(!/UIPageViewController|PageViewController/.test(screen),
     '⑤ 宿主侧不再自己造翻页容器');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
