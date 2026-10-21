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
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENGINE = path.join(ROOT, 'QiReaderLite', 'Resources', 'engine');
const read = (p) => fs.readFileSync(p, 'utf8');

let pass = 0, fail = 0;
const compatPath = path.join(ROOT, 'QiReaderLite', 'Core', 'LegadoCompat.swift');
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
const javai = readCode(path.join(ENGINE, 'java-api.js'));
const engine = readCode(path.join(ENGINE, 'engine.js'));

ok(/QR\.__qrMsgSink\s*=\s*null/.test(javai),
   '有消息收集器 QR.__qrMsgSink');
ok(/function pushMsg\(/.test(javai) && /QR\.__qrPushMsg\s*=\s*pushMsg/.test(javai),
   '有 pushMsg 收集函数');

// ⚠️ 窗口要给宽：log 函数的体比较长（Error 对象的处理），
//    窗口窄了会**匹配不到函数体** → 报红但代码是对的（这种假红踩过）。
['toast', 'longToast', 'log'].forEach((fn) => {
  const m = javai.match(new RegExp(fn + ':\\s*function[\\s\\S]{0,1400}?\\n\\s*\\},'));
  ok(!!m && /pushMsg\(/.test(m[0]),
     `java.${fn} 会把原文交给 pushMsg（不然站方的结果全丢了）`);
});

// ⚠️ 顺序：**先收集（进暂存区），再决定要不要显示**
//    以前是「先静音再收集」→ 第一遍一律静音
//    → 副作用是**没用到 ajax 的真结果也被吃掉**：
//    站方 login() 发现邮箱密码为空 → toast「请先填写邮箱和密码」
//    → 那一遍没有 ajax → 不会有第二遍 → 那句话永远不出现。
//    （真机联调实测踩到：login op 什么原文都收不到）
['toast', 'longToast', 'log'].forEach((fn) => {
  const m = javai.match(new RegExp(fn + ':\\s*function[\\s\\S]{0,1400}?\\n\\s*\\},'));
  ok(!!m && m[0].indexOf('pushMsg(') < m[0].indexOf('__qrSuppressToast'),
     `java.${fn} 是先收集再静音（消息进暂存区，跑完再定夺）`);
});

// 暂存机制：跑完第一遍才知道有没有 ajax → 决定这遍消息真假
ok(/QR\.__qrHoldBegin\s*=\s*function/.test(javai), '有暂存区开/关接口');
ok(/QR\.__qrHoldEnd\s*=\s*function/.test(javai), '有暂存区收尾接口');
ok(/if \(keep && h\.list\.length\)/.test(javai), '暂存消息按 keep 决定要不要交出去');
const analyzer = readCode(path.join(ENGINE, 'rule-analyzer.js'));
ok(/QR\.__qrHoldBegin/.test(analyzer) && /QR\.__qrHoldEnd\(real\)/.test(analyzer),
   'runJs 第一遍用暂存区，跑完按「有没有录到 ajax」定夺真假');
ok(/var real = \(recorded\.length === 0\)/.test(analyzer),
   '「没录到 ajax = 这一遍是真的」这条判据在');
ok(/holdingAll = !!\(QR\.__qrMsgSink && QR\.__qrHoldBegin\)/.test(analyzer),
   '只有装了 sink 的 op 才暂存（别的 op 行为完全不变）');

// ───────── ② 引擎：login op 回传原文 ─────────
console.log('\n=== 2. login op 回传站方原文 ===');
const loginOp = engine.match(/login:\s*function\s*\(p\)\s*\{[\s\S]{0,2000}?\n    \},/);
ok(!!loginOp, 'engine.js 里有 login op');
if (loginOp) {
  ok(/QR\.__qrMsgSink\s*=\s*msgs/.test(loginOp[0]),
     'login op 装了消息收集器');
  ok(/messages:\s*msgs/.test(loginOp[0]),
     'login op 把 messages 回传给原生侧');
  ok(/QR\.__qrMsgSink\s*=\s*prevSink/.test(loginOp[0]),
     'login op 结束时把收集器还原（别污染别的 op）');
}

// ───────── ③ 引擎：loginProbe ─────────
console.log('\n=== 3. loginProbe op ===');
const probeOp = engine.match(/loginProbe:\s*function\s*\(p\)\s*\{[\s\S]{0,3000}?\n    \},/);
ok(!!probeOp, 'engine.js 里有 loginProbe op');
if (probeOp) {
  ok(/getArgument\('server'\)/.test(probeOp[0]),
     '解析站方的服务器设置 getArgument(\'server\')');
  ok(/host\[0\]/.test(probeOp[0]),
     '回退到 jsLib 的 host[0]');
  // ⚠️ 必须走 rule.runJs —— 站方 java.ajax 是同步的，直接调拿到的是 Promise
  //    → JSON.parse(Promise) 炸 → 永远测不出登录态
  ok(/rule\.runJs\('checkStatus\(\)'/.test(probeOp[0]),
     'checkStatus 走 rule.runJs（否则拿不到同步 ajax，测不出登录态）');
  ok(!/^\s*checkStatus\(\);/m.test(probeOp[0]),
     '不直接裸调 checkStatus()（那样 ajax 是异步的）');
  ok(/baseUrl:\s*base/.test(probeOp[0]),
     '把服务器地址回传给原生侧（原生侧要拿它独立验证）');
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
ok(fs.existsSync(compatPath), 'Core/LegadoCompat.swift 存在（能力在 Swift 侧）');
if (fs.existsSync(compatPath)) {
  const lc = readCode(compatPath);
  ok(/enum TimeFormat/.test(lc) && /static func format\(ms: Int64\)/.test(lc),
     'Swift 侧有 java.timeFormat 的实现');
  ok(/enum Cache/.test(lc) && /static func put\(_ key: String, _ value: String\)/.test(lc),
     'Swift 侧有 cache 的实现');
  ok(/static func handle\(fn: String, args: \[String: Any\]\)/.test(lc),
     'Swift 侧有同步通道的分发入口');
}
ok(/QR\.__qrSync = function/.test(javai), 'JS 侧有同步通道的转发函数');
ok(/QR\.__qrSync\('timeFormat'/.test(javai),
   'java.timeFormat 转发给 Swift（不再在 JS 里实现）');
ok(/nativeCall\('cachePut'/.test(javai) && /nativeCall\('cacheRemove'/.test(javai),
   'cache 转发给 Swift（异步 nativeCall，不用可能卡死的同步通道）');
ok(/case "cachePut"/.test(sb2) && /case "cacheGet"/.test(sb2) && /case "cacheRemove"/.test(sb2),
   '原生侧有 cache 的三个 op（能力实现在 Swift 的 LegadoCompat.Cache）');
// ⚠️ JS 里**不该**有主实现：timeFormat 必须**先**走同步通道（Swift），
//    纯 JS 只剩「通道不可用时」的兜底（真机上万一 prompt 通道不通，
//    没有兜底 → 章节时间戳全空 → 一堆源直接回归）。
const tfBody = javai.match(/timeFormat: function[\s\S]{0,1200}?\n    \},/);
ok(!!tfBody && tfBody[0].indexOf('__qrSync') < tfBody[0].indexOf('javaTimeFormatFallback'),
   'timeFormat **主路径**走 Swift（同步通道），JS 兜底只排在后面');
ok(/javaTimeFormatFallback/.test(javai),
   '留了纯 JS 兜底（同步通道万一在真机上不通，章节时间戳不能全空）');

// 同步通道：RuleSandbox 必须实现 WKUIDelegate 的 prompt 回调

ok(/extension RuleSandbox: WKUIDelegate/.test(sb2), 'RuleSandbox 实现了 WKUIDelegate');
ok(/runJavaScriptTextInputPanelWithPrompt/.test(sb2),
   '实现了 prompt 回调（同步通道唯一可用的口子）');
ok(/wv\.uiDelegate = self/.test(sb2), '引擎 WebView 挂了 uiDelegate');
ok(/static let syncPrefix = "__qrSync__"/.test(sb2), '同步通道前缀跟 JS 侧一致');
ok(/LegadoCompat\.handle\(fn: fn, args: args\)/.test(sb2),
   '原生侧把请求交给 LegadoCompat（能力都在 Swift）');

// Swift 原生层的真跑测试要在仓库里
ok(fs.existsSync(path.join(ROOT, 'test', 'legado-compat-test.swift')),
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
ok(/beforeLogin/.test(engine) && /restoreLoginIfLost/.test(engine),
   'login op 会给登录信息拍快照');
ok(/b\['密钥'\]\s*&&\s*!n\['密钥'\]/.test(engine),
   '跑完检查「密钥」没了但原来有 → 恢复回去');
ok(/isLoginAction\s*=\s*\/login/.test(engine) && /!\/logout\/i\.test\(action\)/.test(engine),
   '只对 login 动作生效（logout 要能真的清掉登录态）');
// cookie.removeCookie：以前原生侧没实现 → 站方的「退出登录」是空操作
ok(/case "removeCookie"/.test(sb2), '原生侧有 removeCookie op');
ok(/static func remove\(for url: String\)/.test(sb2), 'CookieJar 有 remove');
ok(/removeCookie:\s*function/.test(javai), 'java-api 有 removeCookie');
ok(/QR\.java\.removeCookie\(url\)/.test(readCode(path.join(ENGINE, 'source-api.js'))),
   'cookie.removeCookie 会通知原生（以前只删了本地快照 → 真 cookie 还在）');
// 检测结论：5xx/HTML 不能报成「未登录」
ok(/static func classify\(code: Int, data: Data\)/.test(readCode(compatPath)),
   '响应分类是纯函数（沙盒能真跑）');
ok(/serverError/.test(readCode(compatPath)) && /code >= 500/.test(readCode(compatPath)),
   '5xx 判为「服务器异常」而不是「未登录」');
ok(/stationSaysLoggedIn/.test(readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'LoginStatus.swift'))),
   '结论按站方**原文**判断（站方说「检测登录失败」就别报「站方说已登录」）');
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
  ok(!!enumBody, 'LegadoCompat 里能抠出 ProbeResult 的定义');
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
  const defs = (javai.match(/startBrowserAwait\s*:\s*function/g) || []).length;
  ok(defs === 1,
     `java 对象里 startBrowserAwait 只定义一次（现在 ${defs} 次 —— 定义两遍后者覆盖前者）`);
  const sbDefs = (javai.match(/startBrowserAwait\s*:\s*function/g) || []).length;
  const awBody = javai.match(/startBrowserAwait\s*:\s*function[\s\S]{0,700}?\n    \},/);
  ok(!!awBody && /__qrAjaxRecord\(u,\s*'browser'/.test(awBody[0]),
     'startBrowserAwait 走两遍跑录制器（kind=browser）');
  ok(!/nativeCall\('showBrowser'/.test(awBody ? awBody[0] : ''),
     'startBrowserAwait 不直连 nativeCall（那会绕过两遍跑）');
  ok(/showBrowser\s*:\s*function[\s\S]{0,400}?java\.startBrowser\(/.test(javai),
     'showBrowser 路由到 startBrowser（走两遍跑）');
  ok(/case "showBrowser"/.test(sb2), '原生侧也有 showBrowser（兜底）');
}
// removeCookie 不能把「刚从浏览器拿回来的」登录 cookie 删掉
ok(/mergedHosts/.test(readCode(path.join(ENGINE, 'source-api.js'))),
   '引擎记着本次 op 合并回来的域（mergedHosts）');
ok(/mergedHosts\[host\]/.test(readCode(path.join(ENGINE, 'source-api.js'))),
   'removeCookie 会跳过这些域（两遍跑下站方会重复执行「清旧 cookie」）');
// 只有最后一遍的消息才交出去（中间遍的假报错不能先弹）
const ra2 = readCode(path.join(ENGINE, 'rule-analyzer.js'));
ok(/holdingAll/.test(ra2), '装了 sink 的 op 每一遍都暂存消息');
ok(/QR\.__qrSuppressToast = holdingAll \? true : \(depth === 0\)/.test(ra2),
   '装了 sink 的 op 每一遍都静音 toast（中间遍的假报错不能弹）');
ok(/__qrHoldEnd\(real\)/.test(ra2), '按「这一遍有没有录到 ajax」定夺真假');
// 回归测试
ok(fs.existsSync(path.join(ROOT, 'test', 'live-fq-login.test.js')),
   '有番茄登录的端到端联调测试');
{
  const fq = readCode(path.join(ROOT, 'test', 'live-fq-login.test.js'));
  ok(/浏览器弹了/.test(fq) && /sessionid/.test(fq),
     '番茄登录测试断言了「浏览器弹了」+「请求带上了 sessionid」');
}

// ───────── ⑫ 卡死防护（用户真机：「点什么没反应」）─────────
console.log('\n=== 12. 卡死防护 ===');
// 症状：toast「正在打开浏览器…」闪一下，浏览器不出现，之后**点什么都没反应**。
// 机理：引擎的 op 队列是**串行**的 → 一个 op 永不返回 → 后面全排队。
{
  // ① 内嵌浏览器：present 失败时没人 resume continuation → op 永远挂着
  ok(/vc\.view\.window == nil/.test(sb2),
     '浏览器 present 失败会被检测到（0.8 秒内没进窗口就报错，不挂死）');
  ok(/Timer\.scheduledTimer\(withTimeInterval: 300/.test(sb2),
     '浏览器有 5 分钟看门狗（用户一直不关也会自动收场）');
  // ② op 队列：任何 op 卡死都不能永久堵死引擎
  ok(/opTimeoutSeconds/.test(sb2) && /withThrowingTaskGroup/.test(sb2),
     'op 有超时保护（一个 op 卡死不会把整个引擎拖死）');
  ok(/static let opTimeoutSeconds: Double = 360/.test(sb2),
     'op 超时是 6 分钟（比浏览器看门狗长 1 分钟）');
  // ③ 同步通道（window.prompt）有把 JS 线程卡死的风险 → **默认关**
  ok(/QR\.__qrSyncEnabled = false;/.test(javai),
     '同步通道默认关闭（prompt 不回调 → JS 线程永久卡死 → 引擎死掉）');
  ok(/if \(!QR\.__qrSyncEnabled\) return null;/.test(javai),
     '同步通道没开时直接走兜底，不碰 prompt');
  // ④ 引擎重置按钮（卡死了不用重装 App）
  ok(/func resetEngine\(\)/.test(sb2), '有 resetEngine（换掉卡死的 JS 线程）');
  ok(/重置引擎/.test(readCode(path.join(ROOT, 'QiReaderLite', 'Features', 'Sources', 'EngineLogSheet.swift'))),
     '自检面板有「重置引擎」按钮');
  // ⑤ cache 不走同步通道（少一个可能卡住的调用点）
  ok(/nativeCall\('cachePut'/.test(javai), 'cache 走异步 nativeCall（不用同步通道）');
  ok(/case "cachePut"/.test(sb2), '原生侧有 cachePut op（能力仍在 Swift）');
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
  // 引擎侧：op 超时要自动重置引擎（队列才能疏通）
  ok(/self\.resetEngine\(\)/.test(sb2),
     'op 超时 → 自动重置引擎（串行队列里的卡死 op 不死，队列就一直堵）');
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
  ok(/function jsonListOf\(result\)/.test(engine),
     '有 jsonListOf（把命中的数组摊平成元素）');
  ok(/items = jsonListOf\(QR\.jsonpath\.select/.test(engine),
     'extractBooks 用 jsonListOf 取列表（发现页/搜索页）');
  ok(/jItems = jsonListOf\(QR\.jsonpath\.select/.test(engine),
     '目录（JSON 章节）也摊平');
  ok(/result\.length === 1 && Array\.isArray\(result\[0\]\)/.test(engine),
     '只摊平一层（数组的元素），不深摊');
}
{
  // 联调测试要在
  ok(fs.existsSync(path.join(ROOT, 'test', 'live-explore.test.js')),
     '有发现页的真机联调测试');
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
  ok(/chapter: p\.chapter, book: p\.book/.test(engine),
     'content op 的 ctx 带 book');
  // 复合规则要保留 JSON 对象
  ok(/function getJsonList\(rule, base, ctx\)/.test(readCode(path.join(ENGINE, 'rule-analyzer.js'))),
     '有 getJsonList（复合规则 <js>…</js>$.data 保留 JSON 对象，不被 stringify）');
  ok(/function evalJsonPathList\(text, rule\)/.test(readCode(path.join(ENGINE, 'rule-analyzer.js'))),
     '有 evalJsonPathList（摊平一层数组 + 保留对象）');
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

// ───────── 汇总 ─────────
console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
