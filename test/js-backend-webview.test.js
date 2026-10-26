/**
 * **JS 后端门禁**（2026-10-26 · 站方 JS 搬到 WKWebView 独立进程）
 *
 * ⭐⭐⭐ **为什么要有这条**：
 *   jetsam 6.8GB 实证 ⇒ **站方 JS 跑在 App 进程内（JSC）** ⇒ 它一次吃几 GB ⇒ jetsam 秒杀 App。
 *   ⇒ 老引擎免疫是因为它的 JS 跑在 **WKWebView 的 WebContent 独立进程** ⇒ 炸的也是那个进程 ⭐⭐⭐
 *   ⇒ 本门禁钉住「**新引擎的 JS 也必须走独立进程**」这件事 ⇒ 以后谁把它改回 JSC ⇒ 门禁立刻红 ⭐
 *
 * ⚠️ **断言前先剥注释**（自己写词法器：字符串里的 `//` 不能砍）
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

function stripComments(src) {
  let out = '', i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === '"' || c === "'") {
      const q = c; out += c; i++;
      while (i < n) {
        if (src[i] === '\\') { out += src[i] + (src[i + 1] || ''); i += 2; continue; }
        out += src[i];
        if (src[i] === q) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') { i += 2; while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++; i += 2; continue; }
    out += c; i++;
  }
  return out;
}

const read = (p) => fs.existsSync(p) ? stripComments(fs.readFileSync(p, 'utf8')) : '';
const host = read(path.join(APP, 'Engine/WebViewJSHost.swift'));
const exec = read(path.join(APP, 'Engine/WebViewJSExecutor.swift'));
const factory = read(path.join(APP, 'Core/JSEngineFactory.swift'));
const backend = read(path.join(APP, 'Core/LegadoEngineBackend.swift'));
const app = read(path.join(APP, 'App/QiReaderLiteApp.swift'));

console.log('▶ JS 后端门禁（站方 JS 必须在独立进程里跑）');

// ① ⭐⭐⭐ 主链路不许再直接写死 JSC
ok(/JSEngineFactory\.make\(/.test(backend),
   '引擎会话必须通过 JSEngineFactory 取执行器（不许写死 JSC ⇒ 否则又回到 App 进程内）');
ok(!/JSCExecutor\(api:\s*api\)/.test(backend),
   'LegadoEngineBackend 里不许再直接 new JSCExecutor');

// ② ⭐⭐⭐ 默认后端 = WKWebView（跟老引擎一样）
ok(/case webView = "WKWebView/.test(factory), 'JS 后端枚举里必须有 WKWebView（独立进程）');
ok(/_kind:\s*Kind\s*=\s*\.webView/.test(factory), '默认后端 = WKWebView（老引擎同款 ⇒ 闪退免疫）');

// ③ ⭐⭐⭐ 真的用了一台 WKWebView
ok(/WKWebView\(/.test(host), 'JS 宿主必须真的建一台 WKWebView（⇒ JS 跑在 WebContent 独立进程）');
ok(/runJavaScriptTextInputPanelWithPrompt/.test(host),
   '必须实现 prompt 同步通道（老引擎同款 ⇒ 站方 JS 的同步调用能拿到返回值）');
ok(/__qrSync:/.test(host), '同步通道前缀必须是 __qrSync:（与老引擎一致）');
ok(/__hostJSON/.test(host), '必须在 WebView 里提供 __hostJSON（引擎的 JS 侧全靠它调宿主）');

// ④ ⭐⭐⭐ 形态链必须用引擎的同一份真相（两个后端不许漂）
ok(/JSEvalShape\.scripts\(for:/.test(exec), '必须用 JSEvalShape.scripts(for:scope:)（与 JSC 版同一份形态链）');
ok(/JSScopeBuilder\.build\(/.test(exec), '必须用 JSScopeBuilder.build(_:)（与 JSC 版同一份 scope 前导）');
ok(/JSHostAPI\.hostWrappers\(\)/.test(host), '必须注入引擎的宿主对象包装 JSHostAPI.hostWrappers()');
ok(/JavaCompat\.sources/.test(host), '必须注入引擎的 Java 兼容层 JavaCompat.sources');
ok(/JSScopeBuilder\.documentStub/.test(host), '必须注入 document 替身（站方 jsLib 有 117 处 document.）');

// ⑤ ⭐⭐⭐ 启动时必须真的把 WebView 后端装上
ok(/WebViewJSHost\.shared\.boot\(\)/.test(app), '启动时必须 boot WebView 宿主');
ok(/WebViewJSExecutor\(api:/.test(app), '启动时必须把 WKWebView 执行器装进工厂');
ok(/syncHandler\s*=/.test(app), '必须装上同步通道的 Swift 侧分发');

// ⑥ 主线程不许阻塞（会死锁）
ok(/Thread\.isMainThread/.test(exec), '必须挡掉「主线程调用引擎」（否则 WebView 回话死锁）');

console.log(`\n通过 ${pass} / 失败 ${fail}`);
if (fail > 0) process.exit(1);
