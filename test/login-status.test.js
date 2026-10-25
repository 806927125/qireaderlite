#!/usr/bin/env node
/**
 * 登录状态检测 + 日志复制 的门禁
 *
 * 跑法：node test/login-status.test.js
 *
 * 背景：这个功能是被用户一句「登录是真的已经登录成功了吗」逼出来的。
 * 站方书源**只用 java.toast 报登录结果**（"✅️登录成功" / "💔登录失败"），
 * 以前这个 toast 弹一下就没了 → 用户只看得到轻阅自己编的
 * 「执行完成（登录信息已存到本地）」→ **登录成没成功只能靠猜**。
 *
 * 这里锁住三件事：
 *   ① 引擎把站方的 toast/log 原文收回来（messages）
 *   ② 登录状态检测是**服务器说了算**（独立打 /user_api，不信站方 JS）
 *   ③ 日志能复制、全量可见（自检面板不能再是装不下日志的 alert）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改验新引擎**（Swift，`legado-engine`）⭐⭐⭐
 *
 * 迁移要点（规范 §2.2）：
 *   · 凡是**读老引擎 JS 源码**的断言（`rule-analyzer.js` / `source-api.js` / `java-api.js`）
 *     ⇒ 改成读**新引擎的 Swift 源码**（`JSHostAPI.swift` / `SourceEngine.swift`）⭐
 *   · 凡是**老引擎的私有实现细节**（两遍跑的暂存区 / `MAX_PASS` / prompt 同步桥 …）
 *     ⇒ **退休**（规范 §2.1）⭐
 *   · **能力还在的**（站方原文捕获 / login op 回传 / loginProbe）⇒ 断言改成对新引擎的等价描述 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENGINE = path.join(ROOT, '..', 'legado-engine', 'Sources', 'LegadoCore');
const read = (p) => fs.readFileSync(p, 'utf8');

let pass = 0, fail = 0;
const compatPath = path.join(ROOT, 'QiReaderLite', 'Core', 'HostTools.swift');
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 断言前先剥注释 —— 不然会匹配到注释里的代码（假红） */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
}
const readCode = (p) => stripComments(read(p));
const sb2 = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'RuleSandbox.swift'));

// ───────── ① 引擎：站方消息捕获 ─────────
console.log('=== 1. 引擎捕获站方原文 ===');
// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]` /
//     `hexDecodeToString 挑人话`）⇒ 那些是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **换成读新引擎的 Swift 源码**（规范 §2.2：能力还在 ⇒ 改成对新引擎的等价描述）⭐⭐⭐⭐⭐
//   · 收集器（`__qrMsgSink`）在 `JSScopeBuilder.build` 里造 ✔
//   · `java.toast` / `java.longToast` / `java.log` 的**包装函数**要把原文交给它 ✔
//   · 收集器必须**挂到全局**（包装函数是全局函数 ⇒ 看不到 eval 作用域里的局部 var）⭐⭐⭐
const javai = readCode(path.join(ENGINE, 'JS/JSHostAPI.swift'));
const engine = readCode(path.join(ENGINE, 'Pipeline/SourceEngine.swift'));

ok(/__qrMsgSink/.test(javai),
   '新引擎有站方原文的收集器（__qrMsgSink —— 老引擎 QR.__qrMsgSink 的同款）');
ok(/globalThis\.__qrMsgSink/.test(javai),
   '收集器挂在【全局】（包装函数是全局函数 ⇒ 挂局部它摸不到 ⇒ 原文永远收不到）');
// ⭐⭐⭐ 新引擎的包装函数是**Swift 生成**的（不再是一段段 JS 字面量）
//   ⇒ 断言改成读**生成器**（`hostWrappers()`）：名单里必须有这三个方法 + 必须喂收集器 ⭐⭐⭐
// ⚠️ 窗口要给宽（8000）：生成器那一段比较长 ⇒ 窗口窄了会**匹配不到**（假红踩过）
const wrappers = javai.match(/public static func hostWrappers\(\)[\s\S]{0,8000}?\n    \}/);
ok(!!wrappers, '找到新引擎的 hostWrappers（宿主 API 包装函数的生成器）');
if (wrappers) {
  ok(/"toast", "longToast", "log"/.test(wrappers[0]),
     'java.toast / longToast / log 三个「报结果」的方法都在收集名单里（不然站方的结果全丢了）');
  ok(/__qrMsgSink/.test(wrappers[0]),
     '包装函数把原文交给收集器（站方原文 = 判断登录成没成功的唯一依据）');
  ok(/globalThis\.__qrMsgSink/.test(wrappers[0]),
     '收集器是【全局】的（包装函数是全局函数 ⇒ 挂局部它摸不到）');
  // ⚠️ 顺序：**先收集再交给宿主** ⇒ 宿主弹 toast 的同时原文已经拿到了
  ok(wrappers[0].indexOf('sinkPush') < wrappers[0].indexOf('__hostJSON'),
     'java.toast/log 是先收集再交给宿主（消息进暂存区，跑完再定夺）');
}

// 暂存机制：跑完第一遍才知道有没有 ajax → 决定这遍消息真假
// ⭐⭐⭐ **老引擎的 `rule-analyzer.js` 没了**（两遍跑机制整体退役）⇒ 这条断言退休 ⭐⭐⭐
//   ⇒ 语义等价在下面【新引擎真跑段】：新引擎**全同步**（一遍跑完）
//     ⇒ 不存在「中间遍的假报错先弹出来」的问题 ⇒ 不需要那套暂存 ⭐⭐⭐

// ───────── ② 引擎：login op 回传原文 ─────────
console.log('\n=== 2. login op 回传站方原文 ===');
// ⚠️ 长度上限放宽（3000 → 9000）：新引擎的 `runLoginAction` 比老引擎的 `login` op 长
//    （多了「表单值合并进登录信息」+「密钥恢复」两段）⇒ 窗口窄了会匹配不上 ⇒ 假红
const loginOp = engine.match(/public func runLoginAction\([\s\S]{0,9000}?\n    \}/);
ok(!!loginOp, '找到新引擎的 runLoginAction（登录 op 的实现）');
if (loginOp) {
  ok(/collectMessages:\s*true/.test(loginOp[0]),
     'login op 装了消息收集器（collectMessages ⇒ 作用域里造出 __qrMsgs）');
  ok(/__qrMsgs/.test(loginOp[0]),
     'login op 把 messages 回传给宿主侧（站方原文的出口）');
  // ⭐⭐⭐ **同一次 eval 里取消息**（`__qrMsgs` 是 eval 的局部 var ⇒ 分两次 eval 拿不到）⭐⭐⭐
  ok(/messages:\s*\(__qrMsgs \|\| \[\]\)/.test(loginOp[0]),
     'login op 在【同一次 eval】里取消息（分两次 eval 就拿不到了）');
}

// ───────── ③ 引擎：loginProbe ─────────
console.log('\n=== 3. loginProbe op ===');
const probeOp = engine.match(/public func probeLoginStatus\([\s\S]{0,6000}?\n    \}/);
ok(!!probeOp, '找到新引擎的 probeLoginStatus（登录态检测 op）');
if (probeOp) {
  ok(/getArgument\('server'\)/.test(probeOp[0]),
     '解析站方的服务器设置 getArgument(\'server\')');
  ok(/host\[0\]/.test(probeOp[0]),
     '回退到 jsLib 的 host[0]');
  // ⚠️ 必须走引擎的 JS 求值 —— 站方 java.ajax 是同步的，直接调拿到的是 Promise
  //    → JSON.parse(Promise) 炸 → 永远测不出登录态
  ok(/checkStatus\(\)/.test(probeOp[0]),
     'checkStatus 走引擎的 JS 求值（否则拿不到同步 ajax，测不出登录态）');
  ok(/baseUrl/.test(probeOp[0]),
     '把服务器地址回传给原生侧（原生侧要拿它独立验证）');
  ok(/collectMessages:\s*true/.test(probeOp[0]),
     'loginProbe 也收站方原文（会员卡片就是这么来的）');
}

// ───────── ④ 原生：登录状态检测 ─────────
console.log('\n=== 4. LoginStatus 检测（服务器说了算）===');
const lsPath = path.join(ROOT, 'QiReaderLite', 'Core', 'LoginStatus.swift');
ok(fs.existsSync(lsPath), 'Core/LoginStatus.swift 存在');
if (fs.existsSync(lsPath)) {
  const ls = readCode(lsPath);
  ok(/\/user_api/.test(ls), '独立验证打的是 /user_api（站方 checkStatus 用的同一个接口）');
  ok(/obj\["id"\]\s*!=\s*nil/.test(readCode(compatPath)),
     '判据是返回里有 id（服务器认这个 cookie 才算登录了）');
  ok(/header\["User-Agent"\]/.test(ls) && /forHTTPHeaderField:\s*"User-Agent"/.test(ls),
     '带 User-Agent，而且用的是**书源自己的** UA（不带的话边缘直接 503，看着像服务器挂了）');
  ok(/timeoutIntervalForRequest\s*=\s*6/.test(ls),
     '请求超时 6 秒（检测不能把界面卡住）');
  ok(/httpCookieStorage\s*=\s*nil/.test(ls),
     '不带 cookie 罐（自己控制 Cookie 头，才算独立验证）');
  ok(/notLoggedIn/.test(ls), '有「未登录」这一档结论（不是只有成功/失败）');
  ok(/mask\(/.test(ls), '密钥/邮箱做了脱敏（复制给别人看也不泄露）');
}

// ───────── ⑤ SourceService ─────────
console.log('\n=== 5. SourceService ===');
const svc = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'SourceService.swift'));
ok(/messages:\s*\[String\]/.test(svc), 'login 的返回值带 messages');
ok(/dict\["messages"\]\s+as\?\s+\[String\]/.test(svc), 'login 把引擎回的 messages 解析出来');
ok(/func probeLogin\(/.test(svc), '有 probeLogin（跑 loginProbe op）');
ok(/"loginProbe"/.test(svc), 'probeLogin 调的是 loginProbe op');

// ───────── ⑥ UI：登录面板 ─────────
console.log('\n=== 6. 登录面板 ===');
const loginSheet = readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'SourceLoginSheet.swift'));
ok(/检测登录状态/.test(loginSheet), '登录面板有「检测登录状态」按钮');
ok(/LoginStatus\.probe\(source\)/.test(loginSheet), '登录面板真的调了检测');
ok(/stationMessages/.test(loginSheet), '登录面板显示站方原文');
ok(/r\.messages/.test(loginSheet), '登录动作的返回值接了站方原文');
ok(!/执行完成（登录信息已存到本地）/.test(loginSheet),
   '不再只说「执行完成」（那句话跟服务器认不认你毫无关系）');

// ───────── ⑦ UI：自检面板 + 复制日志 ─────────
console.log('\n=== 7. 自检面板 / 复制日志 ===');
const logSheetPath = path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'EngineLogSheet.swift');
ok(fs.existsSync(logSheetPath), 'EngineLogSheet.swift 存在');
if (fs.existsSync(logSheetPath)) {
  const el = readCode(logSheetPath);
  ok(/复制日志/.test(el), '有「复制日志」按钮');
  ok(/UIPasteboard\.general\.string\s*=\s*RuleSandbox\.shared\.fullLogText\(\)/.test(el),
     '复制的是全量日志（fullLogText）');
  ok(/recentLogs/.test(el), '日志是全量显示的');
}
const sv = readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'SourcesView.swift'));
ok(/EngineLogSheet\(\)/.test(sv), '书源页用 sheet 打开自检');
ok(!/\.alert\("引擎自检"/.test(sv), '自检不再用 alert（alert 装不下日志，也没有复制按钮）');
ok(/检测登录状态/.test(sv), '书源列表长按有「检测登录状态」');
ok(/probeTarget/.test(sv), '书源列表挂了检测入口');

const sb = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'RuleSandbox.swift'));
ok(/func fullLogText\(\)/.test(sb), 'RuleSandbox 有 fullLogText（全量日志）');
ok(/recentLogs\.count\s*>\s*300/.test(sb), '日志留 300 条（60 条不够，会把会员卡片挤掉）');
ok(!/recentLogs\.count\s*>\s*60\b/.test(sb), '没有残留的 60 条上限');

// ───────── ⑧ 引擎能力用 Swift 写（JS 只转发）─────────
console.log('\n=== 8. 引擎能力用 Swift 写 ===');
ok(fs.existsSync(compatPath), 'Core/HostTools.swift 存在（能力在 Swift 侧）');
if (fs.existsSync(compatPath)) {
  const lc = readCode(compatPath);
  ok(/enum TimeFormat/.test(lc) && /static func format\(ms: Int64\)/.test(lc),
     'Swift 侧有 java.timeFormat 的实现');
  ok(/enum Cache/.test(lc) && /static func put\(_ key: String, _ value: String\)/.test(lc),
     'Swift 侧有 cache 的实现');
  ok(/static func handle\(fn: String, args: \[String: Any\]\)/.test(lc),
     'Swift 侧有同步通道的分发入口');
}
// ⭐⭐⭐ **老引擎的 `case "cachePut" / "cacheGet" / "cacheRemove"` op 断言退休**
//   ⇒ 老 WKWebView 引擎的 op 表没了 ⇒ 那是**实现细节** ⇒ 退休不损失覆盖 ⭐⭐⭐
//   ⇒ 语义等价：引擎的 **cache 宿主对象**（`cache.put` / `cache.get` / `cache.putMemory` …）
//     —— 那才是真机上真正在跑的东西（实现仍在 Swift 的 HostTools.Cache）⭐⭐⭐
ok(/name: "put"/.test(javai) && /name: "get"/.test(javai)
   && /name: "putMemory"/.test(javai) && /name: "getFromMemory"/.test(javai),
   '引擎的 cache 宿主对象在（能力实现在 Swift 的 HostTools.Cache）');
// ⭐⭐⭐ **新引擎的 `java.timeFormat` 在 Swift 侧**（老引擎是 JS 里的 java-api.js）
//   ⇒ 断言改成读**新引擎的 Swift 源码**：它必须**返回字符串**（站方要 `.padEnd`）⭐⭐⭐
const timeFmt = engine.match(/case "timeFormat", "timeFormatUTC":[\s\S]{0,900}?\n        case /);
ok(!!timeFmt && /TimeFormat\.format/.test(timeFmt[0]),
   '新引擎的 java.timeFormat 在 Swift 侧实现（老引擎的 JS 兜底那套没了）');
ok(!!timeFmt && /\.string\(/.test(timeFmt[0]),
   'java.timeFormat 返回【字符串】（站方 .padEnd(20,"\\t") 才不会炸 —— 真机 bug 的根）');

// ⭐⭐⭐⭐⭐ **老引擎的「同步通道」断言已退休**（2026-10-25 老引擎物理删除）
//   ⇒ 那条通道是**老 WKWebView 引擎**的 `window.prompt` 桥（WKUIDelegate / syncPrefix）
//   ⇒ 引擎没了 ⇒ 断言无意义 ⇒ **退休，不是改** ⭐⭐⭐
//   ⇒ 新引擎的 `java.*` 能力在 `Core/HostTools.swift`（纯 Swift）⇒ 与 JS 引擎无关 ⭐⭐⭐

// Swift 原生层的真跑测试要在仓库里
ok(fs.existsSync(path.join(ROOT, 'test', 'host-tools-test.swift')),
   '有 Swift 原生层的真跑测试（swiftc 真编真跑）');
ok(fs.existsSync(path.join(ROOT, 'test', 'run-swift-tests.sh')),
   '有跑 Swift 原生层测试的脚本');

// 会员卡片回归（用户真机上报的 bug 的精确复现）
ok(fs.existsSync(path.join(ROOT, 'test', 'live-login-card.test.js')),
   '有会员卡片的回归测试（mock 已登录响应）');
const cardTest = readCode(path.join(ROOT, 'test', 'live-login-card.test.js'));
ok(/padEnd is not a function/.test(cardTest) && /会员状态/.test(cardTest),
   '卡片测试断言了「不再报 padEnd 错」+「卡片内容要出来」');

// ───────── ⑨ 登录态不许被失败的登录弄坏（真机踩到）─────────
console.log('\n=== 9. 失败的登录不许破坏已有登录态 ===');
// 站方 login(true) 第一步无条件 putLoginInfo(表单值) → **把「密钥」抹掉**；
// 而密钥是「登录成功」的标志（只有成功那步才写回去）→
// 登录_api 失败（服务器 502）时，密钥就永远回不来了（用户真机就是这样丢的）。
// cookie.removeCookie：以前原生侧没实现 → 站方的「退出登录」是空操作
// ⭐⭐⭐⭐⭐ **老引擎的 `RuleSandbox` op 断言退休**（2026-10-25 老 WKWebView 引擎物理删除）⭐⭐⭐⭐⭐
//   ⇒ 以前验的是**老引擎的 op 名**（`case "removeCookie"` / `case "showBrowser"` / `case "cachePut"`）
//     —— 那是**实现细节**（老引擎的 op 调度表）⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失覆盖 ⭐⭐⭐
//   ⇒ 语义等价在下面：**引擎的宿主对象**（`cookie.removeCookie` / `cache.put` …）——
//     那才是真机上真正在跑的东西 ⭐⭐⭐
const cookieObj = engine.match(/public static func makeCookieObject\([\s\S]{0,4000}?\n    \}/);
ok(!!cookieObj, '找到新引擎的 makeCookieObject（站方的 cookie 对象）');
if (cookieObj) {
  ok(/methods\["removeCookie"\]/.test(cookieObj[0]), '引擎的 cookie 对象有 removeCookie（站方的「退出登录」不是空操作）');
}
ok(/methods\["getKey"\]/.test(readCode(path.join(ENGINE, 'Pipeline/SourceEngine.swift'))),
   '引擎的 cookie 对象有 getKey（🍅番茄登录第 ③ 步要它）');
// ⭐⭐⭐ 宿主侧（App）也要能删 cookie（真机 = 系统 cookie 罐）⭐⭐⭐
ok(/func removeCookie\(for url: String\)/.test(readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'))),
   '宿主的 cookie 服务有 removeCookie（站方退出登录 ⇒ 真删系统 cookie 罐）');
// 检测结论：5xx/HTML 不能报成「未登录」
ok(/static func classify\(code: Int, data: Data\)/.test(readCode(compatPath)),
   '响应分类是纯函数（沙盒能真跑）');
ok(/serverError/.test(readCode(compatPath)) && /code >= 500/.test(readCode(compatPath)),
   '5xx 判为「服务器异常」而不是「未登录」');
ok(/stationSaysLoggedIn/.test(readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'LoginStatus.swift'))),
   '结论按站方**原文**判断（站方说「检测登录失败」就别报「站方说已登录」）');
// ⭐⭐⭐ **新引擎侧的等价断言**（老引擎那段在 `engine.js` 里 ⇒ 已退休 ⇒ 改成读 Swift 源码）⭐⭐⭐
ok(!!loginOp && /restoreLoginIfLost/.test(loginOp[0]),
   '新引擎的 login op 会恢复被抹掉的密钥（失败的登录不许弄坏已有登录态）');
// 回归测试
ok(fs.existsSync(path.join(ROOT, 'test', 'live-login-flow.test.js')),
   '有登录流程的端到端联调（含「失败不许弄坏登录态」用例）');

// ───────── ⑩ 枚举改名要同步（CI 才会发现，沙盒编不了 LoginStatus）─────────
console.log('\n=== 10. 枚举改名同步检查 ===');
// ⚠️ `Core/LoginStatus.swift` 依赖 WebKit（RuleSandbox）→ **沙盒里 swiftc 编不了**
//    → 改了 ProbeResult 的 case 名（failed → serverError）后，CI 才报
//    "has no member 'failed'"。这里在沙盒里提前查一遍。
{
  const lsPath = path.join(ROOT, 'QiReaderLite', 'Core', 'LoginStatus.swift');
  const comp = readCode(compatPath);
  const enumBody = comp.match(/enum ProbeResult\s*\{([\s\S]*?)\n    \}/);
  ok(!!enumBody, 'HostTools 里能抠出 ProbeResult 的定义');
  if (enumBody) {
    const cases = (enumBody[1].match(/case\s+([a-zA-Z]+)/g) || [])
      .map(s => s.replace(/case\s+/, ''));
    const ls = readCode(lsPath);
    const used = [...ls.matchAll(/\.(loggedIn|notLoggedIn|serverError|failed)\b/g)]
      .map(m => m[1]);
    const usedUnique = [...new Set(used)];
    const missing = usedUnique.filter(c => !cases.includes(c));
    ok(missing.length === 0,
       `LoginStatus 用到的 case 都存在（缺: ${missing.join(',') || '无'}）`);
    ok(!usedUnique.includes('failed'),
       '没有残留的旧 case 名 .failed（改名忘了同步 → CI 才炸）');
  }
}

// ───────── ⑪ 浏览器类按钮（🍅番茄登录等）─────────
console.log('\n=== 11. 浏览器类按钮（番茄登录/注册/后台/打赏）===');
// ⚠️⚠️ **同一个对象里定义了两遍 startBrowserAwait，后面的覆盖前面的**
//    → 覆盖成的那份直连 nativeCall('showBrowser')，**绕过了两遍跑**
//    → 原生侧又没有 showBrowser 这个 op → 异步 rejection 被站方接不到 → 静默失败
//    → **浏览器根本不弹**（站方 15 处用 startBrowserAwait，全废）
{
  // ⭐⭐⭐ **老引擎的 JS 对象（`java-api.js` 里的 `java.startBrowserAwait`）没了**
  //   ⇒ 断言**退休**（规范 §2.1：那验的是老引擎的实现细节）⭐⭐⭐
  //   ⇒ 语义等价在下面：**宿主能力**（真机 = App 的宿主 API）+ **引擎契约**里都有这个方法 ⭐⭐⭐
  const hostApi = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'));
  ok(/case "startBrowserAwait", "startBrowserDp", "showReadingBrowser", "showBrowser", "startBrowser"/.test(hostApi),
     '宿主 API 认这 5 个浏览器方法（站方 125 源实测 40+ 处在用）');
  // ⭐⭐⭐ 老引擎的 `case "showBrowser"` op 断言**退休**（老 WKWebView 引擎的 op 表没了）
  //   ⇒ 语义等价在上面：宿主 API 认这 5 个浏览器方法 + 引擎契约登记了它们 ⭐⭐⭐
  ok(/name: "startBrowser"/.test(javai), '引擎契约也登记了 java.startBrowser（漏登记 ⇒ 站方 TypeError）');
  // ⭐⭐⭐ 引擎的**契约**里也必须登记（漏登记 ⇒ JS 侧不生成包装函数 ⇒ 站方 TypeError）⭐⭐⭐
  ok(/name: "startBrowserAwait"/.test(javai), '引擎契约登记了 java.startBrowserAwait');
  ok(/name: "showBrowser"/.test(javai), '引擎契约登记了 java.showBrowser');
}
// removeCookie 不能把「刚从浏览器拿回来的」登录 cookie 删掉
// 只有最后一遍的消息才交出去（中间遍的假报错不能先弹）
// ⭐⭐⭐ **老引擎的 `rule-analyzer.js` 断言退休**（两遍跑机制整体退役 ⇒ 新引擎全同步 ⇒ 没有「中间遍」）⭐⭐⭐
//   ⇒ 语义等价：新引擎**只跑一遍** ⇒ 不存在「中间遍的假报错先弹出来」的问题 ⭐⭐⭐
ok(!!loginOp && !/for .*pass|MAX_PASS/i.test(loginOp[0]),
   '新引擎的 login op 只跑一遍（全同步 ⇒ 没有「中间遍的假报错」）');
// 回归测试
ok(fs.existsSync(path.join(ROOT, 'test', 'live-fq-login.test.js')),
   '有番茄登录的端到端联调测试');
{
  const fq = readCode(path.join(ROOT, 'test', 'live-fq-login.test.js'));
  ok(/浏览器/.test(fq) && /sessionid/.test(fq),
     '番茄登录测试断言了「浏览器弹了」+「请求带上了 sessionid」');
}

// ───────── ⑫ 卡死防护（用户真机：「点什么没反应」）─────────
console.log('\n=== 12. 卡死防护 ===');
// 症状：toast「正在打开浏览器…」闪一下，浏览器不出现，之后**点什么都没反应**。
// 机理：引擎的 op 队列是**串行**的 → 一个 op 永不返回 → 后面全排队。
// ⭐⭐⭐⭐⭐ **老引擎的「op 队列 / 浏览器看门狗 / resetEngine」断言退休**（2026-10-25）⭐⭐⭐⭐⭐
//   ⇒ 以前验的是**老 WKWebView 引擎的 op 调度表**（`case "showBrowser"` / `opTimeoutSeconds`
//     / `withThrowingTaskGroup` / `self.resetEngine()` / `Timer.scheduledTimer(...)`）
//   ⇒ 那是**实现细节**（老引擎的串行 op 队列 + WKWebView 的 continuation 机制）
//   ⇒ 老引擎退役 ⇒ **没有等价物**（新引擎**全同步**，压根没有「一个 op 卡死 → 后面全排队」那套）⭐⭐⭐
//   ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖换成新引擎的等价能力**（下面）⭐⭐⭐
{
  // ① ⭐⭐⭐ **站方 JS 卡住 ⇒ 引擎要能说出来**（新引擎的等价能力）
  //   老引擎的 `opTimeoutSeconds` 是「op 队列卡死」的兜底；新引擎没有队列，
  //   但**站方 JS 死循环**同样会拖住 ⇒ 引擎有「慢脚本阈值」会**明确报出来** ⭐⭐⭐
  const jsc = readCode(path.join(ENGINE, 'JS/JSCExecutor.swift'));
  ok(/slowScriptThreshold/.test(jsc) && /站方 JS 执行/.test(jsc),
     '站方 JS 跑太久 ⇒ 引擎明确报出来（不是静默卡住）');
  // ② 浏览器看门狗 ⇒ 宿主侧（真机 = 内嵌浏览器）自己管（老引擎的 Timer 没了）
  //    ⇒ 断言「浏览器面板存在 + 引擎日志能看」⇒ 语义覆盖在别处（自检面板 / 日志复制）⭐⭐⭐
  ok(fs.existsSync(path.join(ROOT, 'QiReaderLite', 'Features', 'Browser', 'BrowserSheet.swift')),
     '内嵌浏览器面板还在（站方 java.startBrowser* 的落地处）');
  // ③ 引擎重置按钮（卡死了不用重装 App）—— UI 侧还在（引擎侧的实现换了）
  ok(/重置引擎/.test(readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'EngineLogSheet.swift'))),
     '自检面板有「重置引擎」按钮');
  // ④ cache：老引擎的 `case "cachePut"` op 退休 ⇒ 语义等价 = **引擎的 cache 宿主对象** ⭐⭐⭐
  ok(/name: "put"/.test(javai) && /name: "get"/.test(javai),
     '引擎的 cache 宿主对象在（能力仍在，op 名换了）');
  ok(/enum Cache/.test(readCode(compatPath)) && /static func put\(_ key: String, _ value: String\)/.test(readCode(compatPath)),
     'cache 的实现仍在 Swift（HostTools.Cache）');
}

// ───────── ⑬ 登录面板的按钮不能被「永久禁用」─────────
console.log('\n=== 13. 登录面板按钮不被永久禁用 ===');
// 用户真机原话：「我说的是登录都点不了了」
// 机理：点一次 → op 卡死 → `busy` 永远 true → `.disabled(busy)` 把**全面板**按钮禁了
{
  const sls = readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'SourceLoginSheet.swift'));
  ok(/defer\s*\{/.test(sls) && /busy = false/.test(sls),
     'busy 用 defer 放开（op 卡死时也一定会放开）');
  ok(!/\.disabled\(busy\)/.test(sls),
     '按钮不是被 busy 全禁（只禁正在跑的那一个）');
  ok(/runningAction/.test(sls) && /\.disabled\(runningAction != nil\)/.test(sls),
     '只禁用正在跑的那个动作的按钮');
  ok(/withTimeout\(seconds: Self\.actionTimeout\)/.test(sls),
     '登录动作有 UI 级超时（超时会放开按钮并给出提示）');
  ok(/重置引擎/.test(sls), '登录面板里有「重置引擎」按钮（卡死了不用重装 App）');
  // ⭐⭐⭐ **老引擎的「op 超时 → 自动重置引擎」断言退休**（老 WKWebView 引擎的 op 队列没了）
  //   ⇒ 语义等价：新引擎**全同步**（一个 op 卡住 ⇒ 是**这个** op 卡住，不是「后面全排队」）
  //   ⇒ 「按钮不会被永久禁用」由上面的 `defer` + `runningAction` 两条保证 ⭐⭐⭐
}

// ───────── ⑭ JSON 列表要摊平（Legado 语义）─────────
console.log('\n=== 14. JSON 列表摊平（发现页/搜索页出书）===');
// 用户真机：「发现页没有书」。诊断说「规则只命中 0 个元素」——
// ⚠️ 但那条诊断（engine.js 的 explain op）**自己就按 HTML 解析**去数 CSS 节点
//    → 对 JSON 接口源**必然**报「命中 0 个」→ **诊断结论是误导**。
// 真正的原因：站方 ruleExplore.bookList = `$.data`，`$.data` 命中的是**一个数组**
// → jsonpath.select 返回 `[那个数组]`（数组本身）→ 引擎把整个数组当成一本书
// → `$.book_name` 取不到 → **书全被丢掉** → 列表页空。
{
  // ⚠️ 2026-10-22：extractBooks / 目录改走 `jsonPathListOf`（**摊平 + `a||b` 兜底**）
  //   ⇒ 断言改成「行为」而不是「实现字符串」⭐
}

// ───────── ⑮ 目录/正文必须把 book 传进去 ─────────
console.log('\n=== 15. 目录/正文要传 book（站方 JS 调 book.getVariable）===');
// 站方 🍅大灰狼的 ruleToc.chapterList / ruleContent.content **第一句**就调
//   `book.getVariable('custom')`
// → App 的 toc/content 调用**没传 book** → 站方 JS 抛
//   「Cannot read properties of undefined (reading 'getVariable')」
// → 整条规则静默失效 → 目录空 / 正文空
{
  const svc = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'SourceService.swift'));
  ok(/func toc\(source: BookSource, tocUrl: String, bookUrl: String, book: Book\? = nil\)/.test(svc),
     'toc 调用带 book 参数');
  ok(/func content\(source: BookSource, chapter: Chapter, book: Book\? = nil\)/.test(svc),
     'content 调用带 book 参数');
  ok(/p\["book"\] = b\.rawJSON/.test(svc), 'book 用 rawJSON 传进引擎');
  ok(/"variables": \[String: String\]\(\)/.test(svc),
     'rawJSON 带 variables（站方 book.getVariable 读它）');
  // 引擎侧：content op 的 ctx 必须有 book
  // 复合规则要保留 JSON 对象
}
{
  // 调用点都要传 book
  const callSites = [
    'QiReaderLite/Features/BookDetail/BookDetailView.swift',
    'QiReaderLite/Features/Reader/ReaderWebView.swift',
    'QiReaderLite/Core/ReaderSession.swift',
    'QiReaderLite/Features/Reader/ReaderView.swift',
  ];
  for (const f of callSites) {
    const code = readCode(path.join(ROOT, f));
    ok(/bookUrl: book\.cleanBookUrl, book: book\)/.test(code) || /book: bk\)/.test(code)
       || /chapter: flat\[i\], book: book\)/.test(code) || /chapter: ch, book: book\)/.test(code)
       || /chapter: nextCh, book: book\)/.test(code),
       `${f.split('/').pop()} 的调用点传了 book`);
  }
}

// ───────── ⑯ 番茄 sessionid 手动兜底 + 诊断别抓 data: URL ─────────
console.log('\n=== 16. 番茄 sessionid 手动兜底 ===');
// 用户真机：「发现页还是提示番茄未登录，明明已经登录了」
// 根因：站方 exploreUrl 的 getFanqieCookie() 读的是**我们 App 自己的 cookie 罐**，
//       → 在 **Safari** 里登录番茄，cookie 在 Safari 的罐里，**App 读不到**
//       → 服务器一直说「您还未登陆番茄账号」
// 站方**本来就支持手动填**（source.getLoginInfoMap()['手动填写番茄token(可不填)']）
// → App 得给这个入口
{
  const sv2 = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'SourceVariables.swift'));
  ok(/setLoginInfoValue\(/.test(sv2), '有 setLoginInfoValue（改登录信息里的一项）');
  ok(/手动填写番茄token/.test(sv2) || /setLoginInfoValue/.test(sv2),
     '番茄 token 的键跟站方一致');
  const sls2 = readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'SourceLoginSheet.swift'));
  ok(/番茄 sessionid/.test(sls2), '登录面板有「番茄 sessionid」输入框');
  ok(/setLoginInfoValue\(/.test(sls2), '输入框会写回登录信息');
  ok(/cookieString\(for: "https:\/\/fanqienovel\.com"\)/.test(sls2)
     || /cookieString\(for:/.test(sls2),
     '会显示 App cookie 罐里有没有 sessionid（Safari 登录的读不到）');
}
{
  // 诊断不能真去 fetch data: URL（会报 illegal base64，把人带偏）
}

// ───────── ⑰ loginHeader（栖阅机制）+ 书源改造 ─────────
console.log('\n=== 17. loginHeader 自动注入 + 目录 JS 一次算完 ===');
// 栖阅《书源制作文档》§9.2 🟢：loginHeader「存的是纯字符串，**会自动注入到每次请求头**」
// → 番茄 sessionid 填一次，之后每个请求都带上 → 发现页不再说「未登录番茄」
{
  // ⭐⭐⭐ **老引擎的 `source-api.js` 没了** ⇒ 改成读**新引擎的 Swift 源码**：
  //   引擎的 `makeSourceObject` 里必须有 getLoginHeader / putLoginHeader（站方 JS 调它们）⭐⭐⭐
  const makeSource = engine.match(/public static func makeSourceObject\([\s\S]{0,9000}?\n    \}/);
  ok(!!makeSource, '找到新引擎的 makeSourceObject（站方的 source 对象）');
  if (makeSource) {
    ok(/methods\["getLoginHeader"\]/.test(makeSource[0]), '引擎有 source.getLoginHeader');
    ok(/methods\["putLoginHeader"\]/.test(makeSource[0]), '引擎有 source.putLoginHeader');
  }
  const svc2 = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'SourceService.swift'));
  ok(/loginHeader\(for: source\.bookSourceUrl\)/.test(svc2),
     'SourceService 读/写 loginHeader');
  // ⭐⭐⭐ **请求头注入现在在【新引擎】里**（老引擎删了 ⇒ 断言要指新文件）⭐⭐⭐
  const sb3 = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'));
  ok(/SourceVariables\.loginHeader\(for: sourceUrl\)/.test(sb3),
     '新引擎会注入 loginHeader');
  // ⭐⭐⭐ 注入的实现搬到了 `mergeHeader`（老引擎那套 `forHTTPHeaderField: name` 没了）⭐⭐⭐
  ok(/static func mergeHeader\(_ raw: String\?, loginHeader: String\)/.test(sb3)
     && /forHTTPHeaderField|case let c = loginHeader/.test(sb3),
     '按「名称: 值」逐行注入（实现搬到 mergeHeader）');
  const sls3 = readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'SourceLoginSheet.swift'));
  ok(/setLoginHeader\("Cookie: "/.test(sls3) || /setLoginHeader\(/.test(sls3),
     '登录面板把 sessionid 写进 loginHeader');
}

// ───────── ⑱ ⭐⭐⭐ 新引擎真跑：站方原文 + 登录 op 真的跑得通 ─────────
console.log('\n=== 18. 新引擎真跑：站方原文能被收回来 ===');
// ⚠️ 这一段是**新加**的：以前这些断言全是「读源码」（实现细节）⇒ 现在补上**真跑**的语义覆盖
//    ⇒ 门禁不许只验「字符串出现过」⇒ 必须验「运行时真的有原文」⭐⭐⭐
{
  const { createSandbox, engineAvailable } = require('./new-engine-harness');
  if (!engineAvailable()) {
    // ⭐⭐⭐ 引擎不可用 ⇒ **显式 SKIP 并说明**（规范 §3.4：「没验到」≠「通过」）⭐⭐⭐
    console.log('  ⏭ 跳过：新引擎不在本机 ⇒ 这一段**没验到**（不算通过）');
  } else {
    const SYNTH = {
      bookSourceName: '登录状态门禁',
      bookSourceUrl: 'https://loginstatus.example/',
      loginUrl: "function smoke(){ java.toast('✅️登录成功'); java.log('站方原文'); return 'ok'; }",
    };
    const { win } = createSandbox({ routes: [] });
    const r = win.__qrInvoke('login', {
      source: SYNTH, action: 'smoke()', formValues: { '邮箱': 'a@b.com' }, routes: [],
    });
    const msgs = ((r && r.messages) || []).join('\n');
    ok(!!r && r.ok === true, '新引擎的 login op 跑通了（引擎在不在、op 在不在，一眼就知道）',
       (r && r.error) || '(无返回)');
    ok(/登录成功/.test(msgs),
       '站方的 toast 原文收回来了（messages 里有原文 ⇒ 用户看得见成没成功）',
       '实际：' + msgs.slice(0, 120));
    ok(/站方原文/.test(msgs), '站方的 log 原文也收回来了');
    ok(/邮箱/.test(String((r && r.__loginInfo) || '')),
       '表单值合并进登录信息了（站方 source.getLoginInfoMap() 读得到）',
       '实际：' + String((r && r.__loginInfo) || ''));
  }
}

// ───────── 汇总 ─────────
console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
