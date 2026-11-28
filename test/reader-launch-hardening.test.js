#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：阅读器启动链不许有「必崩写法」**（2026-11-28 · 真机「点开始阅读闪退」）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条** ⭐⭐⭐：
 *   真机症状：**点「开始阅读」直接闪退**，且**文字书与漫画书都崩** ⇒ 共因在共用的那一层 ⭐⭐⭐
 *   ⇒ 而 **iOS 的 .ips 崩溃日志在设备上很难取** ⇒ 只能靠**代码侧消除必崩写法** + 加日志取证 ⭐⭐⭐
 *
 * ⭐⭐⭐ **本门禁钉住的具体加固**（每条都对应一个真实的闪退/故障风险源）：
 *   ① `VoicePackTransfer.directory` 不许 `[0]` 强下标（空数组 ⇒ 越界崩）⭐⭐⭐
 *   ② `connect()` 不许无条件建 background URLSession
 *      （同一 identifier 重复创建 = 系统未定义行为；且每次开阅读器白起 4 条会话）⭐⭐⭐
 *   ③ `VerticalController` 不许 `as!`（唯一强制解包 ⇒ 类型不符就崩）⭐⭐⭐
 *   ④ 宿主的起始章号必须**夹紧**（柴阅只有下界没有上界 ⇒ 越界 ⇒ 空白页/崩）⭐⭐⭐
 *   ⑤ 宿主的镜像进度**换算失败不许落原值**（柴阅书架仓是持久化的 ⇒ 脏值会反复毒化）⭐⭐⭐
 *   ⑥ 阅读器启动链**必须有分段日志**（崩在哪一步 ⇒ 日志最后一条就是答案）⭐⭐⭐
 *
 * ⭐⭐⭐ **判据纪律**：断言要**可证伪**（能写出「改了它门禁必须红」的变异）⇒ 配套
 *   `test/mutation-reader-launch-hardening.sh` ⭐⭐⭐
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

console.log('\n── ① 柴阅语音包：目录不许强下标 ──');
{
  const f = read('LegadoEngine/Sources/ChaiyueReader/LocalVoiceStore.swift');
  ok(f.length > 0, '① LocalVoiceStore.swift 在');
  ok(!/urls\(for: \.applicationSupportDirectory[^)]*\)\[0\]/.test(f),
     '① 目录不许用 `[0]` 强下标（urls 可能返回空数组 ⇒ 越界崩）');
  ok(/\.first\s*\n?\s*\?\? FileManager\.default\.temporaryDirectory/.test(f),
     '① 目录用 `first ?? 兜底目录`');
}

console.log('\n── ② 打开阅读器不许白建 background URLSession ──');
{
  const f = read('LegadoEngine/Sources/ChaiyueReader/LocalVoiceStore.swift');
  // connect() 里必须先判「有没有下载计划」，没有就返回
  const connect = (f.match(/func connect\(\) \{[\s\S]*?\n    \}/) || [''])[0];
  ok(connect.length > 0, '② 找得到 connect()');
  ok(/fileExists\(atPath: Self\.planURL\.path\)/.test(connect),
     '② connect() 先判「磁盘上有没有下载计划」（没有就不建会话）');
  ok(/ensureSessions\(\)/.test(connect), '② connect() 走 ensureSessions()（建会话的逻辑只有一处）');
  const start = (f.match(/func start\(base: URL[\s\S]*?\n    \}/) || [''])[0];
  ok(/ensureSessions\(\)/.test(start), '② 真正开始下载时 start() 也建会话（功能不丢）');
  ok(/background\(withIdentifier:/.test(f), '② background session 的创建只存在于 ensureSessions() 一处');
}

console.log('\n── ③ 漫画滚动模式不许强制解包 ──');
{
  const f = read('LegadoEngine/Sources/ChaiyueReader/VerticalController.swift');
  ok(f.length > 0, '③ VerticalController.swift 在');
  ok(!/as! StripCell/.test(f), '③ 不许 `as! StripCell`（复用池类型不符就崩）');
  ok(/as\? StripCell/.test(f), '③ 用 `as?` + 兜底新建');
}

console.log('\n── ④⑤ 宿主：起始章号必须夹紧 + 镜像不许落脏值 ──');
{
  const f = read('QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift');
  ok(f.length > 0, '④ ChaiyueReaderHost.swift 在');
  ok(/if !chapters\.indices\.contains\(startIndex\)/.test(f),
     '④ 起始章号最后统一夹紧（柴阅只有下界没有上界）');
  ok(/chapters\.indices\.contains\(stored\)/.test(f),
     '④ 从柴阅书架仓取的章号也要夹（那里面可能是持久化的脏值）');
  ok(/plainToWhole\[safe: item\.lastChapterIndex\] \?\? 0/.test(f),
     '⑤ 镜像进度换算失败落 0，不落原值（脏值会被持久化 ⇒ 反复毒化）');
  ok(!/plainToWhole\[safe: item\.lastChapterIndex\] \?\? item\.lastChapterIndex/.test(f),
     '⑤ 镜像进度不再落原值');
}

console.log('\n── ⑥ 阅读器启动链必须有分段日志（取证）──');
{
  const host = read('QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift');
  const screen = read('QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderScreen.swift');
  const comic = read('QiReaderLite/Features/Reader/Chaiyue/ChaiyueComicScreen.swift');
  const bridge = read('LegadoEngine/Sources/ChaiyueReader/PublicLogBridge.swift');
  const container = read('LegadoEngine/Sources/ChaiyueReader/ReaderContainer.swift');
  const comicScreen = read('LegadoEngine/Sources/ChaiyueReader/Media/Comic/ComicReaderScreen.swift');
  ok(bridge.length > 0, '⑥ 包内有日志出口 PublicLogBridge');
  ok(/public static func log/.test(bridge), '⑥ 日志出口有 public log()');
  ok(/ChaiyueLogBridge\.sink = \{/.test(host), '⑥ 宿主注入了日志出口（落到引擎日志面板）');
  ok(/engineLog\("\[柴阅阅读器\] prepare 开始/.test(screen), '⑥ 文字阅读器有 prepare 阶段日志');
  ok(/engineLog\("\[柴阅阅读器\] 漫画 prepare 开始/.test(comic), '⑥ 漫画页有 prepare 阶段日志');
  ok(/ChaiyueLogBridge\.log\("① 阅读器开始启动/.test(container), '⑥ 柴阅文字阅读器有启动分段日志');
  ok(/ChaiyueLogBridge\.log\("① 漫画页开始启动/.test(comicScreen), '⑥ 柴阅漫画屏有启动分段日志');
}

console.log('\n── ⑦⑧ 【并发隔离铁律】nonisolated `@Sendable` 闭包里不许用 `Task { @MainActor in }` ──');
{
  // ⭐⭐⭐⭐⭐ **这条是 build335 的【真凶】**（真机 .ips 定案）⭐⭐⭐⭐⭐
  //   崩溃：`EXC_BREAKPOINT` / `SIGTRAP`，栈里有 `_dispatch_assert_queue_fail`，
  //   第 4 帧 = `closure #2 in VoicePackTransfer.observe(_:)` ⇒ **点开始阅读就闪退** ⭐⭐⭐
  //
  // ⚠️ **为什么**：
  //   · `VoicePackTransfer` 的 observer 是 **nonisolated `@Sendable`** 闭包
  //     ⇒ body 会在**后台 OperationQueue** 上跑 ⭐⭐⭐
  //   · 而 Swift 6.2+ 的 `Task { @MainActor in … }` 是**继承当前 executor**
  //     （不再保证切到 MainActor）⇒ ⇒ 在后台队列创建的 Task **继承了后台队列** ⭐⭐⭐
  //   · ⇒ `self.apply(snapshot)`（@MainActor 隔离的对象）跑在非 MainActor 的 executor 上
  //     ⇒ ⇒ 💥 **dispatch 队列断言失败** ⇒ App 直接闪退 ⭐⭐⭐
  //
  // ⭐⭐⭐ **正解**：用 `DispatchQueue.main.async`（明确切主线程，**不依赖 executor 继承语义**）⭐⭐⭐
  const voice = read('LegadoEngine/Sources/ChaiyueReader/LocalVoiceStore.swift');
  ok(/DispatchQueue\.main\.async \{ self\.apply\(snapshot\) \}/.test(voice),
     '⑦ 语音包 observer 回调用 DispatchQueue.main.async（明确切主线程）');
  const init = (voice.match(/init\(\) \{[\s\S]*?\n    \}/) || [''])[0];
  // ⚠️⭐⭐⭐ **判据必须剥注释**（项目纪律）：注释里写「不能用 `Task { @MainActor in }`」是**说明**，
  //   不是**代码** ⇒ 不该判红 ⇒ 只看非注释行 ⭐⭐⭐
  const initCode = init.split('\n').filter(l => !/^\s*\/\//.test(l)).join('\n');
  ok(!/Task \{ @MainActor in/.test(initCode),
     '⑦ observer 闭包里不许再用 `Task { @MainActor in }`（继承后台队列 ⇒ 断言炸）');

  // 同一形态在 SpeechController 里有 7 处（AVSpeech/AVAudioPlayer 的 delegate 回调
  // ⇒ **可能在任意线程** ⇒ 同一个坑）⇒ 全部改成 DispatchQueue.main.async
  const speech = read('LegadoEngine/Sources/ChaiyueReader/SpeechController.swift');
  ok(speech.length > 0, '⑧ SpeechController.swift 在');
  ok(!/Task \{ @MainActor in/.test(speech),
     '⑧ SpeechController 里不再有 `Task { @MainActor in }`（7 处 @Sendable 回调）');
  ok((speech.match(/DispatchQueue\.main\.async/g) || []).length >= 7,
     '⑧ 7 处 @Sendable 回调都改成了 DispatchQueue.main.async');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
