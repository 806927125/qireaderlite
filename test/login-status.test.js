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
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 断言前先剥注释 —— 不然会匹配到注释里的代码（假红） */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
}
const readCode = (p) => stripComments(read(p));

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
ok(/if \(keep && h\.length\)/.test(javai), '暂存消息按 keep 决定要不要交出去');
const analyzer = readCode(path.join(ENGINE, 'rule-analyzer.js'));
ok(/QR\.__qrHoldBegin/.test(analyzer) && /QR\.__qrHoldEnd\(real\)/.test(analyzer),
   'runJs 第一遍用暂存区，跑完按「有没有录到 ajax」定夺真假');
ok(/var real = \(recorded\.length === 0\)/.test(analyzer),
   '「没录到 ajax = 这一遍是真的」这条判据在');
ok(/depth === 0 && QR\.__qrMsgSink && QR\.__qrHoldBegin/.test(analyzer),
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
  ok(/obj\["id"\]\s*!=\s*nil/.test(ls),
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
const compatPath = path.join(ROOT, 'QiReaderLite', 'Core', 'LegadoCompat.swift');
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
ok(/QR\.__qrSync\('cachePut'/.test(javai) && /QR\.__qrSync\('cacheGet'/.test(javai),
   'cache 转发给 Swift');
// ⚠️ JS 里**不该**有主实现：timeFormat 必须**先**走同步通道（Swift），
//    纯 JS 只剩「通道不可用时」的兜底（真机上万一 prompt 通道不通，
//    没有兜底 → 章节时间戳全空 → 一堆源直接回归）。
const tfBody = javai.match(/timeFormat: function[\s\S]{0,1200}?\n    \},/);
ok(!!tfBody && tfBody[0].indexOf('__qrSync') < tfBody[0].indexOf('javaTimeFormatFallback'),
   'timeFormat **主路径**走 Swift（同步通道），JS 兜底只排在后面');
ok(/javaTimeFormatFallback/.test(javai),
   '留了纯 JS 兜底（同步通道万一在真机上不通，章节时间戳不能全空）');

// 同步通道：RuleSandbox 必须实现 WKUIDelegate 的 prompt 回调
const sb2 = readCode(path.join(ROOT, 'QiReaderLite', 'Core', 'RuleSandbox.swift'));
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

// ───────── 汇总 ─────────
console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
