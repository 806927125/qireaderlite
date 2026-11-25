/**
 * ⭐⭐⭐⭐⭐ **阅读器翻页模式门禁（逻辑部分，纯离线）** ⭐⭐⭐⭐⭐
 *
 * 背景（2026-10-19 用户反馈）：「想看第二章必须进目录点第二章才出正文」。
 * ⇒ 点正文左 32% = 上一章 / 点右 32% = 下一章 / 点中间 = 出菜单；
 *   左右滑动 = 翻章；翻到头/尾要弹一句提示，不能装没听见。
 *
 * ⚠️⚠️⚠️ **2026-11-25 柴阅化改写** ⭐⭐⭐：
 *   原来的门禁有三块断言是**栖阅那套 WebView 阅读器**的（`Core/ReaderHost.swift`
 *   的 `onTapZone` / `__qrTapPos` / 手写 `UISwipeGestureRecognizer`）⇒
 *   **那套阅读器已经删掉了** ⇒ 断言必须按**新意图**重写，不是放宽 ⭐⭐⭐：
 *     · 滑动翻页 ⇒ 现在由 **UIPageViewController 的系统手势**负责（`PagedReaderUI`）
 *     · 点击分区 ⇒ 现在由 `handleReaderTap(zone:)`（原生分页）+ `session.onTapZone`（滚动）
 *     · 翻页方式的选择 ⇒ 从**栖阅的 overlay 面板**挪到了**柴阅式 sheet 面板**
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

const web = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
const sess = fs.readFileSync(path.join(ROOT, 'Core/ReaderSession.swift'), 'utf8');
const panel = fs.existsSync(path.join(ROOT, 'Features/Reader/ReaderStylePanel.swift'))
  ? fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderStylePanel.swift'), 'utf8') : '';
const pagerUI = fs.existsSync(path.join(ROOT, 'Features/Reader/Paging/PagedReaderUI.swift'))
  ? fs.readFileSync(path.join(ROOT, 'Features/Reader/Paging/PagedReaderUI.swift'), 'utf8') : '';
const webCode = stripComments(web);

console.log('\n── ⭐⭐⭐ 栖阅那套 WebView 阅读器已经拆掉（老代码不许留）⭐⭐⭐');
ok(!fs.existsSync(path.join(ROOT, 'Core/ReaderHost.swift')),
   'Core/ReaderHost.swift（栖阅 WebView 阅读器）已删');
ok(!fs.existsSync(path.join(ROOT, 'Resources/reader')),
   'Resources/reader/（reader.html/js/css/scroll-core.js 共 48KB）已删');
ok(!/host\.setSettings|host\.apply|host\.update|host\.fail/.test(webCode),
   'ReaderWebView 不再往 WebView 下发 settings / 喂章节');
ok(!/let host = ReaderHost\(\)/.test(sess),
   'ReaderSession 不再持有 ReaderHost');

console.log('\n── 分区判定 ──');
ok(/x < 0\.32/.test(web), '左 32% → 上一章');
ok(/x > 0\.68/.test(web), '右 32% → 下一章');
ok(web.indexOf('0.32') < web.indexOf('0.68'), '左右阈值有序（0.32 < 0.68）');
ok(/private func handleReaderTap\(zone: CGFloat\)/.test(web),
   '原生分页的点击分发在 handleReaderTap(zone:)');

console.log('\n── ⭐⭐⭐ 滑动翻页 = 系统手势（不再是手写 UISwipeGestureRecognizer）⭐⭐⭐');
const pager = fs.existsSync(path.join(ROOT, 'Features/Reader/Paging/PagedChapterPager.swift'))
  ? fs.readFileSync(path.join(ROOT, 'Features/Reader/Paging/PagedChapterPager.swift'), 'utf8') : '';
ok(/UIPageViewController/.test(pager) || /UIPageViewController/.test(pagerUI),
   '分页容器用 UIPageViewController ⇒ 左右滑动由系统负责');
ok(!/UISwipeGestureRecognizer/.test(webCode),
   'ReaderWebView 不再手写滑动识别器（那套随 WebView 一起删了）');

console.log('\n── 边界必须提示，不能装没听见 ──');
ok(/func step\(_ delta: Int\)/.test(sess), 'ReaderSession 有 step(delta)');
ok(/已经是第一章/.test(sess) && /已经是最后一章/.test(sess), '两头都有提示文案');
ok(/onPageEdge\?/.test(sess), '到头会回调 onPageEdge');
ok(/next < 0/.test(sess) && /next >= flat\.count/.test(sess), '两个边界都判了');

console.log('\n── ⭐⭐⭐ 坐标来源：原生分页的点击位置（不再是 web view 的消息）⭐⭐⭐');
ok(/onTapZone/.test(pagerUI), 'PagedReaderUI 有 onTapZone 回调');
ok(/onTapZone\?\(max\(0, min\(1, p\.x \/ view\.bounds\.width\)\)\)/.test(pagerUI),
   '点击位置按视图宽度归一化到 0~1');
ok(/pageCtl\.onTapZone = \{ zone in/.test(web),
   'ReaderWebView 接上分页器的 onTapZone');

console.log('\n── 开关与默认值 ──');
ok(/@AppStorage\("reader\.pageTurn"\) private var pageTurn: Bool = true/.test(web),
   '翻页模式默认开（用户明确要的）');
ok(/private var useNativePaging: Bool/.test(web), '有「原生分页 vs 滚动」的分流');
ok(/pageTurnMode != "scroll"/.test(web), '选「上下滚动」就走滚动模式，其余走原生分页');

console.log('\n── ⭐⭐⭐ 翻页方式的选择在柴阅式面板里（不是栖阅的 overlay 面板）⭐⭐⭐');
ok(/private var modeRow: some View/.test(panel), '柴阅面板有「翻页方式」那一行');
ok(/PageTurnMode\.all/.test(panel), '翻页方式列全部 5 种');
ok(/pageTurnMode = m\.raw/.test(panel), '点一下就切翻页方式');
ok(!/private var pageTurnRow/.test(webCode),
   '栖阅面板里的 pageTurnRow 已经删掉了（挪进柴阅面板）');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
