#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：正文阅读界面必须【只有柴阅那套】**（2026-11-25）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁**（用户原话）⭐⭐⭐：
 *   「**阅读正文界面的，老的代码全部删掉，全部用柴阅的**」
 *   ⇒ 老阅读器（我们自己手写的原生分页 + 滚动 + WebView 那套）**必须真的没了**
 *   ⇒ 留着 = 下次有人又去改那个改错的东西 ⇒ 白烧 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **这条门禁是「双向」的** ⭐⭐⭐⭐⭐：
 *   ① **老阅读器符号 = 0 命中**（不是「不生效」，是**源码里一个都不许有**）⭐⭐⭐
 *   ② **柴阅阅读器必须在**（宿主真的打开了柴阅的 `ReaderContainer`）⭐⭐⭐
 *   ⇒ 只做① ⇒ 可能把阅读器整删了还不自知；只做② ⇒ 老代码可能还留着当"备用方案"⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据：源码文本命中（含注释）** ⭐⭐⭐⭐⭐
 *   这条门禁**故意不剥注释** ⇒ 连「注释里提一嘴」都不许 ⭐⭐⭐
 *   ⇒ 理由：老阅读器的名字一旦还出现在源码里，下一个人 grep 一下就会以为它还在 ⭐⭐⭐
 *   ⇒ （别的门禁剥注释是因为它们要查**行为**；这条查的是**「这个东西还在不在」**）⭐⭐⭐
 *
 * ⭐⭐⭐ **变异对照（门禁能红）** ⭐⭐⭐：
 *   门禁末尾会**往一份临时副本里注入老符号** ⇒ 同一个扫描器必须报出来
 *   ⇒ 报不出来 = 这条门禁是摆设（假绿）⇒ 直接判失败 ⭐⭐⭐
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

// ── 老阅读器的符号清单（我们手写的那套的全部类型名）────────────────
const OLD_SYMBOLS = [
  'ReaderWebView',        // 老阅读页外壳（WebView）
  'PagedReaderUI',        // 原生分页的 SwiftUI 壳
  'ReaderPageVC',         // 原生分页的一页一个 VC
  'SwiftScrollReaderView',// 原生滚动阅读视图
  'ReaderPaginator',      // 自研分页器
  'PagedChapterPager',    // 自研章界数据源
  'ReaderLayoutConfig',   // 自研排版配置
  'ReaderScrollCore',     // 自研滚动核心
  'QRSlider',             // 自研滑块
  'ReaderSkinBackground', // 我们重写版的皮肤底
  'ReaderStylePanel',     // 我们重写版的外观面板
  'ReaderBaselineScope',  // 我们重写版的底线范围
  'ReaderParaAlign',      // 我们重写版的段落对齐
  'ReaderFontPicker',     // 我们重写版的字体分段
];

// ── 老阅读器的文件（必须真的没了）──────────────────────────────
const OLD_FILES = [
  'Features/Reader/Paging',
  'Features/Reader/ReaderWebView.swift',
  'Features/Reader/ReaderSkin.swift',
  'Features/Reader/ReaderSkinBackground.swift',
  'Features/Reader/ReaderStylePanel.swift',
  'Features/Reader/ReaderTheme.swift',
  'Core/ReaderSession.swift',
];

// ── 老阅读器独占的设置键（不再被任何 `@AppStorage` 消费）──────────
// ⚠️ 注意：这些键名**允许**出现在「清理名单」里（`removeObject(forKey:)`）⇒
//   判据是**不被消费**（`@AppStorage("...")` / `AppStorage(...)`）⭐⭐⭐
const OLD_SETTING_KEYS = [
  'reader.lineSpacing', 'reader.paraSpacing', 'reader.paraAlign',
  'reader.fontKey', 'reader.theme', 'reader.pageTurn',
  'reader.showBaseline', 'reader.baselineScope', 'reader.baselineColor',
  'reader.verticalJustify', 'reader.tapAnywhere', 'reader.swipeUpExit',
  'reader.twoPageSpread', 'reader.contentInHeaderFooter', 'reader.followSystem',
];

/** 扫一个目录里的所有 .swift，返回 [符号, 文件] 命中列表 */
function scanOldSymbols(dir) {
  const hits = [];
  const walk = (d) => {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (_) { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!e.name.endsWith('.swift')) continue;
      let src;
      try { src = fs.readFileSync(p, 'utf8'); } catch (_) { continue; }
      for (const sym of OLD_SYMBOLS) {
        if (src.includes(sym)) hits.push([sym, path.relative(ROOT, p)]);
      }
    }
  };
  walk(dir);
  return hits;
}

/** 扫「被消费的旧设置键」 */
function scanOldSettingKeys(dir) {
  const hits = [];
  const walk = (d) => {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (_) { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!e.name.endsWith('.swift')) continue;
      let src;
      try { src = fs.readFileSync(p, 'utf8'); } catch (_) { continue; }
      for (const key of OLD_SETTING_KEYS) {
        // 只认「消费」：@AppStorage("key") / AppStorage("key")
        const re = new RegExp('AppStorage\\(\\s*"' + key.replace('.', '\\.') + '"');
        if (re.test(src)) hits.push([key, path.relative(ROOT, p)]);
      }
    }
  };
  walk(dir);
  return hits;
}

console.log('\n── ① 老阅读器源码必须一个都不剩 ──');
{
  const hits = scanOldSymbols(ROOT);
  ok(hits.length === 0,
     `① 老阅读器符号 0 命中（扫了 ${OLD_SYMBOLS.length} 个符号）`,
     hits.slice(0, 8).map(h => `${h[0]} @ ${h[1]}`).join(' / '));

  for (const rel of OLD_FILES) {
    ok(!fs.existsSync(path.join(ROOT, rel)), `① 老文件已删：${rel}`);
  }
}

console.log('\n── ② 老阅读器独占的设置键不再被消费 ──');
{
  const hits = scanOldSettingKeys(ROOT);
  ok(hits.length === 0, '② 没有 `@AppStorage` 还在读老设置键',
     hits.map(h => `${h[0]} @ ${h[1]}`).join(' / '));
}

console.log('\n── ③ 柴阅阅读器必须在（而且是唯一的那套）──');
{
  const chaiyueDir = path.join(ROOT, 'Features/Reader/Chaiyue');
  ok(fs.existsSync(chaiyueDir), '③ 宿主适配目录在（Features/Reader/Chaiyue/）');

  const read = (rel) => {
    const p = path.join(ROOT, rel);
    return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
  };

  const adapter = read('Features/Reader/Chaiyue/ChaiyueReaderAdapter.swift');
  const host = read('Features/Reader/Chaiyue/ChaiyueReaderHost.swift');
  const screen = read('Features/Reader/Chaiyue/ChaiyueReaderScreen.swift');
  const detail = read('Features/BookDetail/BookDetailView.swift');

  // ③ 适配层：我们的模型 → 柴阅模型
  ok(/static func book\(/.test(adapter), '③ 适配层有「我们的书 → 柴阅的书」');
  ok(/static func chapter\(/.test(adapter), '③ 适配层有「我们的章 → 柴阅的章」');
  ok(/static func chapters\(/.test(adapter), '③ 适配层有「整张目录 → 柴阅的目录」');
  ok(/static func source\(/.test(adapter), '③ 适配层有「我们的书源 → 柴阅的书源」');

  // ③ 宿主侧的门面实现（shim 在 App 侧，不在包里）
  ok(/class ChaiyueHostLibrary\s*:\s*ChaiyueReaderLibrary/.test(host),
     '③ 宿主侧实现了柴阅的 `ChaiyueReaderLibrary` 门面（shim 在 App 侧）');
  ok(/func readerSession\(for book: /.test(host), '③ 门面造得出柴阅的 `ReaderSession`');
  ok(/func callBack\(/.test(host), '③ 门面实现了书源事件回调');

  // ③ 柴阅的权威链路全都在（BookContentService / ContentProcessor / BookshelfRepository / ReaderSession / ReaderModel）
  for (const [needle, label] of [
    ['BookContentService(', 'BookContentService（正文服务）'],
    ['ContentProcessor(', 'ContentProcessor（正文处理）'],
    ['BookshelfRepository(', 'BookshelfRepository（书架仓）'],
    ['ReaderSession(', 'ReaderSession（阅读会话）'],
    ['ChapterStore(', 'ChapterStore（章节缓存）'],
    ['SourceRepository(', 'SourceRepository（书源仓）'],
  ]) {
    ok(host.includes(needle), `③ 宿主侧接了柴阅的 ${label}`);
  }
  ok(/ReaderModel/.test(host) || /ReaderModel/.test(screen),
     '③ 宿主侧用柴阅的 `ReaderModel` 驱动阅读界面');

  // ③ 阅读界面本体 = 柴阅的 ReaderContainer
  ok(/ReaderContainer\(launch:/.test(screen), '③ 宿主打开的是柴阅的 `ReaderContainer`');
  ok(/\.environment\(/.test(screen), '③ 给柴阅的阅读界面注入了 `AppModel` 环境');

  // ③ 详情页确实换成柴阅了
  ok(/ChaiyueReaderScreen\(book:/.test(detail), '③ 详情页打开的是柴阅阅读界面');

  // ③ 目录不用重复请求站方（详情页已经取好）
  ok(/saveChapters\(/.test(host), '③ 目录预写进柴阅的章节缓存（不重复请求站方）');
}

console.log('\n── ④ 变异对照：门禁必须能红 ──');
{
  // ⚠️ 把一个老符号注入临时副本 ⇒ 同一个扫描器必须报出来
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'qr-reader-mutation-'));
  const seed = path.join(ROOT, 'Features/Reader/Chaiyue/ChaiyueReaderScreen.swift');
  const mutated = fs.readFileSync(seed, 'utf8')
    + '\n\n// 变异对照注入\nstruct ReaderWebView { let x = 1 }\n';
  fs.writeFileSync(path.join(tmp, 'Mutated.swift'), mutated, 'utf8');
  const hits = scanOldSymbols(tmp);
  ok(hits.length > 0, '④ 注入老符号后扫描器能报出来（门禁有牙齿）',
     hits.length ? '' : '扫描器没抓到注入的符号 ⇒ 这条门禁是假绿');
  ok(hits.some(h => h[0] === 'ReaderWebView'), '④ 报出来的正是被注入的那个符号');
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
