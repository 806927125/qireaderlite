#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：登录配套设施（柴阅 ReaderPlatform）必须真的接上**（2026-11-21 移植）
 *
 * ⚠️⚠️⚠️ **为什么要有它**：
 *   柴阅的引擎把「浏览器 / 验证码 / 后台渲染 / toast / 复制 / 外链 / 视频」交给宿主 ⭐⭐⭐
 *   ⇒ 轻阅之前**没有实现这个委托** ⇒ 站方登录要开浏览器/要验证码时 ⇒ **静默失败** ⭐⭐⭐
 *   ⇒ 聚合源的「🍅番茄登录 / 🔐注册书源 / 🏝用户后台」**全是浏览器流程** ⭐⭐⭐
 *     ⇒ 浏览器不工作 ⇒ 拿不到 token/cookie ⇒ **登录永远失败** ⭐⭐⭐
 *
 * ⭐⭐⭐ **本门禁钉死六件事**：
 *   ① 柴阅的 `ReaderPlatform` 已 vendor 进引擎包（`Platform/`）⭐⭐⭐
 *   ② 宿主实现了柴阅的 `SourceInteractionPresenter`（浏览器/验证码/复制/外链）⭐⭐⭐
 *   ③ 引擎环境**装上了**柴阅的 `SourceUIDelegate` ⭐⭐⭐
 *   ④ 轻阅的 `BrowserSheet`（早就写好、一直没人调用）**接上了** ⭐⭐⭐
 *   ⑤ App 根挂了 `.sheet(item:)`（引擎 → 主线程 → SwiftUI 的唯一桥梁）⭐⭐⭐
 *   ⑥ 初始化**没有循环**（`environment` ↔ `platformUI`）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const P = (p) => path.join(ROOT, p);

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
const read = (p) => fs.readFileSync(P(p), 'utf8');
const strip = (t) => t.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');

console.log('=== 1. 柴阅的 ReaderPlatform 已 vendor ===');
{
  const dir = P('LegadoEngine/Sources/ChaiyueEngine/Platform');
  ok(fs.existsSync(dir), 'Platform/ 目录在');
  for (const f of ['PlatformSourceUI.swift', 'WebViewRenderer.swift', 'CookieSync.swift']) {
    ok(fs.existsSync(path.join(dir, f)), `vendor 了 ${f}`);
  }
  const ps = read('LegadoEngine/Sources/ChaiyueEngine/Platform/PlatformSourceUI.swift');
  ok(/canImport\(WebKit\)/.test(ps), '整体条件编译（WebKit ⇒ Apple only ⇒ Linux 包仍能编）');
  ok(/public final class PlatformSourceUI: SourceUIDelegate/.test(ps),
     '★ PlatformSourceUI 实现了 SourceUIDelegate（★ 浏览器/验证码/渲染/ toast 全套）');
  const pkg = read('LegadoEngine/Package.swift');
  ok(!/name:\s*"ChaiyuePlatform"/.test(pkg), '并入 ChaiyueEngine target（⇒ xcodeproj 不用改）');
}

console.log('\n=== 2. 宿主实现了柴阅的交互协议 ===');
{
  const ui = read('QiReaderLite/Core/ChaiyueSourceUI.swift');
  ok(/final class ChaiyueInteractionPresenter: NSObject, SourceInteractionPresenter/.test(ui),
     '★ 实现了 SourceInteractionPresenter');
  ok(/func presentBrowser\(/.test(ui), '★ presentBrowser（java.startBrowser / startBrowserAwait）');
  ok(/func presentVerificationCode\(/.test(ui), '★ presentVerificationCode（验证码）');
  ok(/func copyText\(/.test(ui), '★ copyText（java.copyText）');
  ok(/func openExternalURL\(/.test(ui), '★ openExternalURL（java.openUrl 的非网页 scheme）');
  ok(/func presentVideoPlayer\(/.test(ui), '★ presentVideoPlayer（java.openVideoPlayer）');
  ok(/BrowserPresenter\.shared\.present\(/.test(ui), '★ 浏览器用轻阅自己的 BrowserSheet（不是柴阅的渲染器）');
  ok(/renderWebView\(/.test(ui), 'html/js 场景交给柴阅的后台渲染');
}

console.log('\n=== 3. 引擎环境装上了 delegate ===');
{
  const rt = strip(read('QiReaderLite/Core/ChaiyueRuntime.swift'));
  ok(/environment\.setUIDelegate\(platformUI\)/.test(rt), '★ environment.setUIDelegate(platformUI)');
  ok(/static func installUI\(\)/.test(rt), '有 installUI（★ 避免初始化循环）');
  ok(!/let env = LegadoEngineHost\.Environment\(store: store\)[\s\S]{0,200}setUIDelegate/.test(rt),
     '★ environment 的 init 里不装 delegate（★ 否则 platformUI ↔ environment 初始化循环）');
  ok(/ui\.presenter = ChaiyueInteractionPresenter\.shared/.test(rt), '把轻阅的 presenter 交给柴阅');
  ok(/ui\.onToast = /.test(rt), 'toast 接到轻阅的 Toast（站方登录结果就是用 toast 报的）');
}

console.log('\n=== 4. 浏览器真的能弹出来（App 根接线） ===');
{
  const app = read('QiReaderLite/App/QiReaderLiteApp.swift');
  ok(/ChaiyueRuntime\.installUI\(\)/.test(app), '★ App 启动时装 delegate');
  ok(/Task \{ @MainActor in ChaiyueRuntime\.installUI\(\) \}/.test(app), '★ 在主线程装（init 不是 MainActor 隔离的）');
  ok(/@StateObject private var browserPresenter = BrowserPresenter\.shared/.test(app), '有浏览器 presenter 的 StateObject');
  ok(/\.sheet\(item: \$browserPresenter\.item\)/.test(app), '★ 挂了 .sheet(item:)（引擎 → 主线程 → SwiftUI 的桥梁）');
  ok(/BrowserSheet\(url: item\.url, title: item\.title, onFinish: item\.onFinish\)/.test(app),
     '★ sheet 里用轻阅的 BrowserSheet（它早就写好、一直没人调用）');
}

console.log('\n=== 5. 变异对照（改坏 ⇒ 必须红） ===');
{
  const rt = read('QiReaderLite/Core/ChaiyueRuntime.swift');
  const app = read('QiReaderLite/App/QiReaderLiteApp.swift');
  const ui = read('QiReaderLite/Core/ChaiyueSourceUI.swift');

  const m1 = rt.replace('environment.setUIDelegate(platformUI)', '// 变异：不装 delegate');
  ok(!/environment\.setUIDelegate\(platformUI\)/.test(m1), '★ 变异①（不装 delegate）⇒ 被抓住');

  const m2 = app.replace('.sheet(item: $browserPresenter.item)', '// 变异：不挂 sheet');
  ok(!/\.sheet\(item: \$browserPresenter\.item\)/.test(m2), '★ 变异②（不挂 sheet）⇒ 被抓住');

  const m3 = ui.replace('BrowserPresenter.shared.present(', '// 变异：不用轻阅的浏览器');
  ok(!/BrowserPresenter\.shared\.present\(/.test(m3), '★ 变异③（不用轻阅的浏览器）⇒ 被抓住');

  const m4 = rt.replace('static func installUI()', 'static func installUI_disabled()');
  ok(!/static func installUI\(\)/.test(m4), '★ 变异④（installUI 改名 ⇒ App 调不到）⇒ 被抓住');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
