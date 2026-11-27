#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：浏览器/验证码必须浮在【阅读器】之上**（2026-11-27 真机反馈）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **真机症状** ⭐⭐⭐：
 *   「段评打开，**浏览器应该在阅读界面打开**，现在是**先回详情页**再打开的」⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **根因**（两层，都被这条门禁钉住）⭐⭐⭐：
 *   ① **浏览器**：轻阅用 `@Published item` + **App 根 View 上的 `.sheet(item:)`**
 *      ⇒ 而阅读器是 **`fullScreenCover`** ⇒ **它的呈现层级高于根上的 sheet**
 *      ⇒ ⇒ **浏览器被压在阅读器下面** ⇒ 用户看到的现象就是「浏览器不见了」⭐⭐⭐
 *      ⇒ 正解：**阅读器在场时，浏览器改由【阅读器那层】承载**（柴阅原版就是浮在阅读器之上）⭐⭐⭐
 *   ② **验证码弹窗**：`ChaiyueRuntime.topPresenter` 原来直接取 **rootViewController**
 *      ⇒ 同样被阅读器压住 ⇒ 改成**沿 `presentedViewController` 链找最顶层**（同柴阅 `topController()`）⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据（四条）**⭐⭐⭐⭐⭐：
 *   ① 根 View 的浏览器 sheet **必须过滤掉** `onReader == true` 的项（否则两层都 present）⭐⭐⭐
 *   ② **文字阅读器与漫画页都要挂**浏览器 sheet（且只接 `onReader == true`）⭐⭐⭐
 *   ③ `topPresenter` **必须沿 presented 链往上找**（不能只取 rootViewController）⭐⭐⭐
 *   ④ `BrowserPresenter` 必须有 `readerPresented` 标志 + `dismissIfReading()`（阅读器被关时收掉浏览器并回调）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
};

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

console.log('\n── ① 根 View 只承载「阅读器不在场」的浏览器 ──');
{
  const app = read('QiReaderLite/App/QiReaderLiteApp.swift');
  ok(/BrowserPresenter/.test(app), '① 根 View 仍挂着浏览器入口');
  ok(/item\?\.onReader == false/.test(app),
     '① 根 View 的 sheet 过滤掉 `onReader == true`（阅读器在场时不在根上 present）');
  ok(!/\.sheet\(item: \$browserPresenter\.item\)/.test(app),
     '① 根 View 不再直接监听全部浏览器项（那会与阅读器那层重复 present）');
}

console.log('\n── ② 文字阅读器与漫画页都要承载浏览器 ──');
{
  for (const [file, label] of [
    ['QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderScreen.swift', '文字阅读器'],
    ['QiReaderLite/Features/Reader/Chaiyue/ChaiyueComicScreen.swift', '漫画页'],
  ]) {
    const src = read(file);
    ok(src.length > 0, `② ${label} 在`);
    ok(/item\?\.onReader == true/.test(src),
       `② ${label} 挂了浏览器 sheet（且只接 onReader == true）`);
    ok(/readerPresented = true/.test(src), `② ${label} 出现时置位 readerPresented`);
    ok(/readerPresented = false/.test(src), `② ${label} 消失时复位 readerPresented`);
    ok(/dismissIfReading\(\)/.test(src), `② ${label} 消失时收掉还开着的浏览器`);
  }
}

console.log('\n── ③ 验证码弹窗要弹在最顶层（不能被阅读器压住）──');
{
  const rt = read('QiReaderLite/Core/ChaiyueRuntime.swift');
  ok(/static var topPresenter/.test(rt), '③ topPresenter 在');
  ok(/presentedViewController/.test(rt),
     '③ topPresenter 沿 presentedViewController 链往上找（阅读器是 presented ⇒ 找到它）');
  ok(!/\.rootViewController\s*$/.test(rt.split('static var topPresenter')[1].split('}')[0].trim() + '}'),
     '③ topPresenter 不再直接返回 rootViewController（那会被 fullScreenCover 压住）');
}

console.log('\n── ④ BrowserPresenter 要知道阅读器在场 ──');
{
  const ui = read('QiReaderLite/Core/ChaiyueSourceUI.swift');
  ok(/var readerPresented = false/.test(ui), '④ 有 readerPresented 标志');
  ok(/onReader: Bool/.test(ui), '④ BrowserItem 带 onReader（这次由谁承载）');
  ok(/func dismissIfReading\(\)/.test(ui), '④ 有 dismissIfReading()（阅读器被关 ⇒ 收浏览器 + 回调）');
}

console.log('\n── ⑤ 段评等【浮层】必须走柴阅的轻量浮层 + cookie 同步 ──');
{
  // ⭐⭐⭐⭐⭐ **真机「点段评反应很慢」的真正原因**（2026-11-27）⭐⭐⭐⭐⭐
  //   ① **cookie 同步被绕过**：柴阅把 `CookieSync.push/pull` 写在 `PlatformSourceUI.present` 里，
  //      而宿主**自己实现了 `presentBrowser`** ⇒ **绕过了那一层** ⇒
  //      ⇒ 段评页**没有站方登录态** ⇒ 页面在等站方/跳登录 ⇒ **用户感知 = 慢** ⭐⭐⭐
  //   ② **浏览器太重**：宿主用完整 `BrowserSheet`（每次现建 WKWebView + NavigationStack + 地址栏），
  //      而柴阅原版的段评是 **0.8 屏高轻量浮层** ⭐⭐⭐
  const overlay = read('LegadoEngine/Sources/ChaiyueReader/PublicBrowserOverlay.swift');
  const host = read('QiReaderLite/Core/ChaiyueSourceUI.swift');
  ok(overlay.length > 0, '⑤ 包里有浮层浏览器出口（ChaiyueBrowserOverlay）');
  ok(/CookieSync\.push/.test(overlay), '⑤ 浮层浏览器**呈现前**把引擎 cookie 推进共享罐');
  ok(/CookieSync\.pull/.test(overlay), '⑤ 浮层浏览器**关闭后**把 cookie 拉回引擎');
  ok(/SourcePresenter\(\)/.test(overlay) || /presenter\.presentBrowser/.test(overlay),
     '⑤ 复用柴阅的 SourcePresenter（顶层 present + 0.8 屏高轻量浮层）');
  ok(/case \.sheet = request\.style/.test(host),
     '⑤ 宿主把【浮层】请求（showReadingBrowser = 段评）分流到柴阅的轻量浮层');
  ok(/ChaiyueBrowserOverlay\.present\(/.test(host), '⑤ 宿主的段评走 ChaiyueBrowserOverlay');
  ok(/prepareCookies|collectCookies/.test(host),
     '⑤ 宿主自己的完整浏览器（登录等）也要同步 cookie（别再绕过柴阅那一层）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
