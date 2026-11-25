#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：阅读会话的公开 API 清单不许缺**（2026-11-25）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁**（血坑实录）⭐⭐⭐：
 *   这轮拆栖阅 WebView 阅读器时，我是**用字符串标记去切代码**的
 *   （`s[s.index("private func wire() {"):s.index("/// 界面 ready 之后…")]`）
 *   ⇒ ⇒ **`wire()` 连带把后面的 `attach()` 一起切掉了** ⭐⭐⭐
 *   ⇒ ⇒ 语法门禁查不出来（切完还是合法 Swift）⇒ **只有 Xcode 编译才炸** ⇒ 白烧一轮 CI ⭐⭐⭐
 *
 * ⭐⭐⭐ ⇒ 所以：**每个「按标记切代码」的改动，都要配一条 API 清单门禁** ⭐⭐⭐
 *   ⇒ 切完立刻在沙盒红 ⇒ 不用等 CI。
 *
 * ⭐⭐⭐ 判据原则：**只钉「对外承诺的成员」**（谁在调它），
 *   内部实现随便改；但**少一个就红**（这正是切代码最容易犯的错）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

const sess = stripComments(fs.readFileSync(path.join(ROOT, 'Core/ReaderSession.swift'), 'utf8'));

// ── ① ReaderSession 的公开成员（谁在调它，谁就钉死）──
const API = [
  // 生命周期
  ['func attach(sources: SourceStore, library: LibraryStore)', 'attach(store)'],
  ['func start()', 'start()'],
  ['func reloadCurrent()', 'reloadCurrent()'],
  // 翻页 / 换章
  ['func step(_ delta: Int)', 'step(delta)'],
  ['func jump(to i: Int)', 'jump(to:)'],
  ['func followIndex(_ i: Int)', 'followIndex(_:)'],
  ['func replaceChapters(_ newFlat: [Chapter]) -> Bool', 'replaceChapters(_:)'],
  // 正文
  ['func load(index i: Int) async', 'load(index:)'],
  ['func prefetch(index i: Int) async -> Bool', 'prefetch(index:)'],
  ['func prefetchedText(index i: Int)', 'prefetchedText(index:)'],
  ['func coverDataURL(_ urlString: String) async -> String?', 'coverDataURL(_:)'],
  // 状态
  ['@Published var index: Int', 'index（当前章号）'],
  ['@Published var chapterText: String', 'chapterText（当前章正文）'],
  ['@Published var chapterTitle: String', 'chapterTitle（当前章标题）'],
  ['@Published var loadingChapter: Bool', 'loadingChapter（换章中）'],
  ['@Published var errorText: String', 'errorText（换章失败）'],
  ['var onTap: (() -> Void)?', 'onTap（点正文）'],
  ['var onTapZone: ((Double) -> Void)?', 'onTapZone（点两侧）'],
  ['var onPageEdge: ((String) -> Void)?', 'onPageEdge（到头提示）'],
  ['var pagingOwnsIndex: Bool', 'pagingOwnsIndex（章号归属）'],
  ['private(set) var flat: [Chapter]', 'flat（章节表）'],
];
for (const [needle, label] of API) {
  ok(sess.includes(needle), `① ReaderSession 公开成员还在：${label}`,
     needle);
}

// ── ② 被拆掉的东西**不许复活**（栖阅 WebView 阅读器）──
ok(!/let host = ReaderHost\(\)/.test(sess), '② 不再有 ReaderHost（栖阅 WebView 阅读器）');
ok(!/func wire\(\)/.test(sess), '② 不再有 wire()（它只服务 WebView 回声）');
ok(!/host\.onProgress|host\.onVisibleChapter|host\.onRequestChapter/.test(sess),
   '② 不再有 WebView 回声回调');
ok(!/host\.apply|host\.update|host\.fail|host\.setSettings/.test(sess),
   '② 不再往 WebView 喂章节 / 报错 / 下发设置');
ok(!/for _ in 0\.\.<60 where !hostReady/.test(sess), '② 不再等 hostReady（那会白等 6 秒）');

// ── ③ 阅读页外壳的公开成员（ReaderWebView 同样被大改过）──
const web = stripComments(fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8'));
const WEB_API = [
  ['private var topBar: some View', 'topBar（顶栏）'],
  ['private var bottomBar: some View', 'bottomBar（底栏）'],
  ['private func syncPager(size: CGSize)', 'syncPager（把排版推进分页器）'],
  ['private func applyThemeChange()', 'applyThemeChange（换主题立即生效）'],
  ['private func handleReaderTap(zone: CGFloat)', 'handleReaderTap（点击分发）'],
  ['private func toggleDayNight()', 'toggleDayNight（日夜一键）'],
  ['private func refreshCatalog()', 'refreshCatalog（刷新目录）'],
  ['private func jumpToLastChapter()', 'jumpToLastChapter（跳到最后一章）'],
  ['private var layoutConfig: ReaderLayoutConfig', 'layoutConfig（排版参数）'],
  ['private func applySpacingLevel(_ level: Int, fontSize: Double)', 'applySpacingLevel（行距档位）'],
];
for (const [needle, label] of WEB_API) {
  ok(web.includes(needle), `③ ReaderWebView 成员还在：${label}`);
}

// ── ④ 分页器的公开成员（PagedChapterPager 也动过）──
const pager = stripComments(fs.readFileSync(path.join(ROOT, 'Features/Reader/Paging/PagedChapterPager.swift'), 'utf8'));
for (const [needle, label] of [
  ['var bookTitle: String', 'bookTitle（页眉首屏显示书名）'],
  ['var skin: ReaderSkin', 'skin（皮肤决定装饰）'],
  ['func setPageSize(_ size: CGSize)', 'setPageSize'],
  ['func jumpToChapter(_ c: Int)', 'jumpToChapter'],
  ['func adoptFreshChapterList(', 'adoptFreshChapterList（刷新目录）'],
  ['func preloadedChapters()', 'preloadedChapters'],
]) {
  ok(pager.includes(needle), `④ PagedChapterPager 成员还在：${label}`);
}

// ── ⑤ 画布的公开成员（ReaderPageVC：装饰/边距都改过）──
const vc = stripComments(fs.readFileSync(path.join(ROOT, 'Features/Reader/Paging/ReaderPageVC.swift'), 'utf8'));
for (const [needle, label] of [
  ['func drawPageChrome(', 'drawPageChrome（页眉页脚）'],
  ['func drawChapterNumber(', 'drawChapterNumber（章节号装饰）'],
  ['func drawBaselines(', 'drawBaselines（行底线）'],
  ['func setPage(paginator:', 'setPage'],
  ['func showFailure(', 'showFailure（换章失败页）'],
]) {
  ok(vc.includes(needle), `⑤ ReaderPageCanvasView 成员还在：${label}`);
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
