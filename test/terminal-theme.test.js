#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：「星澜终端」皮肤的约定**（2026-11-24 用户给 HTML 原型后换肤）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁** ⭐⭐⭐：
 *   ① **换肤必须「一处改色、全 App 生效」** ⇒ 页面里**不许硬编码颜色**
 *     ⇒ 否则下次换肤要翻几十个文件 ⇒ 必然漂、必然漏 ⭐⭐⭐
 *   ② ⭐⭐⭐⭐⭐ **「发现页筛选键」必须保留**（用户明确要求）⭐⭐⭐⭐⭐
 *     ⇒ 用户原话：「UI 能不能换成这个，**然后发现页筛选键保留**」⭐⭐⭐
 *     ⇒ 筛选键是站方 `exploreUrl` 出来的 `type:"select"` 项 ⇒ 宿主执行**站方 action** ⇒
 *        它是「切平台 / 切性别 / 切模式」的唯一入口 ⭐⭐⭐
 *     ⇒ **一旦重构把它弄没了 ⇒ 用户又会遇到「切了没反应」** ⇒ 必须有门禁拦住 ⭐⭐⭐
 *   ③ ⭐⭐⭐ **玻璃白纱不能是「乳白」**：深色底上 38% 白纱 ⇒ 玻璃糊成一片白 ⇒ 不是玻璃 ⭐⭐⭐
 *
 * ⭐⭐⭐ 每条断言都要问「把它改坏，它会不会红」⇒ 改坏 ⇒ 必须红 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const read = (rel) => fs.readFileSync(path.join(APP, rel), 'utf8');

function swiftFiles(dir, out = []) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) swiftFiles(p, out);
    else if (name.endsWith('.swift')) out.push(p);
  }
  return out;
}

// ── ① 终端主题文件必须在，且配色常量集中在那儿 ──────────────────────
const themePath = path.join(APP, 'App/TerminalTheme.swift');
ok(fs.existsSync(themePath), '① App/TerminalTheme.swift 在（终端配色集中地）');
const theme = fs.existsSync(themePath) ? fs.readFileSync(themePath, 'utf8') : '';

for (const key of ['static let bg', 'static let ink', 'static let cyan', 'static let violet',
                   'static let gradient', 'struct TerminalBackdrop', 'struct TerminalTitle']) {
  ok(theme.includes(key), `① Terminal 里定义了 ${key}`);
}

// ── ② ⭐⭐⭐ 页面里不许硬编码颜色（换肤必须一处改色）⭐⭐⭐ ──────────
//   例外：① 终端主题自身 ② 阅读器的「纸色配色表」（那是阅读设置，不是壳）③ 玻璃实现内部
const EXEMPT = [
  'App/TerminalTheme.swift',
  'App/LiquidGlass.swift',
  'App/GlassTint.swift',
];
// ⚠️⚠️⚠️ **阅读器整体豁免**（2026-11-24）⭐⭐⭐
//   ⇒ 阅读器有**自己的一套「纸色配色」用户设置**（8 浅 + 8 深 + 跟随系统）⭐⭐⭐
//   ⇒ 那是**阅读场景**，不是 App 外壳 ⇒ 强行套深空皮肤会覆盖用户的阅读偏好 ⭐⭐⭐
//   ⇒ ⇒ 这里只管「外壳」（书架/发现/搜索/设置/书源/详情）⭐⭐⭐
const offenders = [];
for (const f of swiftFiles(APP)) {
  const rel = path.relative(APP, f);
  // ⭐⭐⭐ 阅读器**整体**豁免（它有自己的一套「纸色配色」用户设置）⭐⭐⭐
  if (EXEMPT.includes(rel) || rel.startsWith('Features' + path.sep + 'Reader' + path.sep)) continue;
  const code = fs.readFileSync(f, 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ');
  // ⭐ 只抓「页面里写死的实色」⇒ 不抓 Theme./Terminal. 引用，也不抓 .opacity(...) 的半透明修饰
  const lines = code.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/Color\(\s*red:/.test(line) || /UIColor\(\s*red:/.test(line)
        || /Color\.white\b/.test(line) || /Color\.black\b/.test(line)) {
      // 白/黑只在「明确的背景/描边」里算硬编码；文字用 .white 是允许的（深色底）
      if (/Color\.white/.test(line) && !/background|fill|stroke|border|overlay/i.test(line)) continue;
      if (/Color\.black/.test(line) && !/background|fill|stroke|border|overlay|shadow/i.test(line)) continue;
      offenders.push(`${rel}:${i + 1}  ${line.trim().slice(0, 90)}`);
    }
  }
}
ok(offenders.length === 0,
   '⭐⭐⭐ 页面里没有硬编码颜色（换肤只改 Theme/Terminal 一处 ⇒ 不会漂）',
   offenders.slice(0, 4).join(' | '));

// ── ③ ⭐⭐⭐ 玻璃白纱默认必须是「通透」而不是「乳白」⭐⭐��─
const tint = read('App/GlassTint.swift');
const dm = tint.match(/defaultValue:\s*Double\s*=\s*([0-9.]+)/);
ok(!!dm && parseFloat(dm[1]) <= 0.12,
   '⭐⭐⭐ 玻璃白纱默认值 ≤ 0.12（深色底上不能是乳白玻璃）',
   dm ? dm[1] : '没找到 defaultValue');
ok(/object\(forKey: key\) != nil else \{ return 8 \}/.test(tint),
   '⭐⭐⭐ 新装的玻璃浓度默认 8%（≈ 原型的 rgba(255,255,255,.06)）');
const app = read('App/QiReaderLiteApp.swift');
ok(/GlassTintStore\.percent == 45/.test(app) && /GlassTintStore\.percent = 8/.test(app),
   '⭐⭐⭐ 旧默认 45 会被一次性对齐到 8（用户自己调过的不动）');

// ── ③b ⭐⭐⭐⭐⭐ **必须强制深色外观**（2026-11-24 真机：「这些按钮太白了」）⭐⭐⭐⭐⭐
//   ⇒ 下拉菜单 / 筛选胶囊 / 标签栏 / 分类筛选页的按钮 / 阅读页底部面板
//     **全是系统玻璃**（iOS 26 的 `.glassEffect`）⇒ **系统按「当前外观」渲染** ⭐⭐⭐
//   ⇒ App 以前**从来没强制过外观** ⇒ 跟系统走（浅色）⇒ 深空底上变成**一排乳白板** ⭐⭐⭐
//   ⇒ 正解：**根部 `.preferredColorScheme(.dark)`** ⇒ 一处 ⇒ 系统玻璃全切深色 ⭐⭐⭐
const appRoot = app;
ok(/preferredColorScheme\(\.dark\)/.test(appRoot),
   '⭐⭐⭐⭐⭐ App 根部强制了深色外观（系统玻璃不再渲染成乳白）');
ok(!/preferredColorScheme\(\.light\)/.test(appRoot),
   '⭐⭐⭐⭐⭐ 没有任何地方把外观改回浅色');

// ── ④ ⭐⭐⭐⭐⭐ **发现页的筛选键必须还在**（用户明确要求）⭐⭐⭐⭐⭐ ──
const explore = read('Features/Explore/ExploreView.swift');
for (const sym of ['filterBar', 'filterChip', 'applySourceFilter', 'infoMap']) {
  ok(explore.includes(sym), `⭐⭐⭐⭐⭐ 发现页仍有 ${sym}（筛选键链路没被换肤弄丢）`);
}
ok(/private var filterBar: some View/.test(explore), '⭐⭐⭐⭐⭐ 筛选键行仍在内容区顶部（不是被删了）');
ok(/func applyFilter/.test(explore), '⭐⭐⭐⭐⭐ 筛选动作仍在（切平台/性别/模式的入口）');
// 筛选键必须仍然走「执行站方 action」这条路（通用做法）
ok(/applySourceFilter/.test(explore) && /infoMap/.test(explore),
   '⭐⭐⭐⭐⭐ 筛选仍执行站方 action（不猜变量键名 ⇒ 通用）');
// ⭐ 而且筛选芯片不能被换肤改成「不可点」
ok(/\.glassCapsule\(\)/.test(explore), '⭐⭐⭐ 筛选键仍是液态玻璃胶囊（可点）');

// ── ④b ⭐⭐⭐⭐⭐ **阅读页 UI = 柴阅原版**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
//   以前这一段钉的是「我们自己重写版的阅读页」（混色背景 + 皮肤底 + 柴阅式 sheet 面板）
//   ⇒ 现在**阅读正文界面整体换成柴阅的** ⇒ 这一段的判据也跟着换 ⭐⭐⭐
//   · 皮肤 / 配色 / 页眉页脚 / 章节号装饰 / 外观面板 ⇒ **全是柴阅的**（我们不再自己画）⭐⭐⭐
//   · 轻阅这边只剩**宿主适配**（模型转换 + 会话接线）⇒ 不许再有我们自己的皮肤/面板 ⭐⭐⭐
const readerDir = path.join(APP, 'Features/Reader');
const chaiyueDir = path.join(readerDir, 'Chaiyue');
ok(fs.existsSync(chaiyueDir), '⭐⭐⭐⭐⭐ 宿主适配目录在（Features/Reader/Chaiyue/）');
for (const gone of ['ReaderSkin.swift', 'ReaderSkinBackground.swift', 'ReaderStylePanel.swift',
                    'ReaderTheme.swift', 'ReaderWebView.swift']) {
  ok(!fs.existsSync(path.join(readerDir, gone)),
     `⭐⭐⭐⭐⭐ 我们重写版的 ${gone} 已删（阅读页不再由我们自己画）`);
}
ok(!fs.existsSync(path.join(readerDir, 'Paging')),
   '⭐⭐⭐⭐⭐ 我们自研的原生分页目录已删（分页交给柴阅的 ReaderKit）');

const chaiyueScreen = fs.existsSync(path.join(chaiyueDir, 'ChaiyueReaderScreen.swift'))
  ? fs.readFileSync(path.join(chaiyueDir, 'ChaiyueReaderScreen.swift'), 'utf8') : '';
ok(/ReaderContainer\(launch:/.test(chaiyueScreen),
   '⭐⭐⭐⭐⭐ 阅读正文界面用的是柴阅的 `ReaderContainer`');
ok(/\.environment\(/.test(chaiyueScreen),
   '⭐⭐⭐⭐⭐ 给柴阅的阅读界面注入了 `AppModel`（宿主侧接线）');

// ⭐⭐⭐ 阅读页是**全屏页**（柴阅自带 chrome）⇒ 不能再叠一层系统导航栏 ⭐⭐⭐
const detailCode = read('Features/BookDetail/BookDetailView.swift');
ok(/fullScreenCover\(item: \$readerChapter\)/.test(detailCode),
   '⭐⭐⭐⭐⭐ 阅读页用 fullScreenCover 打开（自带 chrome 的全屏页，不叠系统导航栏）');
ok(/ChaiyueReaderScreen\(book:/.test(detailCode),
   '⭐⭐⭐⭐⭐ 详情页打开的是柴阅阅读界面');

// ⭐⭐⭐ **写死的灰阶文字**（`Color(white: 0x…`）⇒ 深色主题上不可读 ⇒ 一律不许 ⭐⭐⭐
const greyHits = [];
for (const f of swiftFiles(readerDir)) {
  const code = fs.readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
  code.split('\n').forEach((line, i) => {
    if (!/Color\(white:\s*0x/.test(line)) return;
    // ⭐⭐⭐ **主题定义里的「浅色分支」是合法的**（写死灰阶 = 浅色主题的值）
    //   ⇒ 但它必须**成对**：同一行里必须有 `isDark ?`（深色分支）⇒ 否则就是「只写了一边」⭐⭐⭐
    if (/isDark\w*\s*\?/.test(line)) return;   // `isDarkTheme ?` / `isDark ?` 都算「成对」
    greyHits.push(`${path.relative(APP, f)}:${i + 1}`);
  });
}
ok(greyHits.length === 0,
   '⭐⭐⭐⭐⭐ 阅读页没有写死的灰阶文字（Color(white: 0x…）—— 深色主题上会看不见',
   greyHits.slice(0, 4).join(', '));
// ── ⑤ 终端首页的结构件都在（原型 v-terminal 的标志性元素）──────────
const shelf = read('Features/Bookshelf/BookshelfView.swift');
for (const sym of ['TerminalTitle', 'ProgressRing', 'QuickBubble', 'RecentSpine', '继续阅读']) {
  ok(shelf.includes(sym), `⑤ 终端首页含 ${sym}（原型 v-terminal 的标志性元素）`);
}
const root = read('App/RootView.swift');
ok(/Label\("终端"/.test(root), '⑤ 第一个 tab 叫「终端」（原型同名）');
ok(/Label\("发现"/.test(root), '⑤ 「发现」tab 保留（筛选键所在页）');

console.log(fail === 0 ? `通过 ${pass} / 失败 ${fail}` : `通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
