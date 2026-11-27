#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：登录页必须是【柴阅的登录表单】**（2026-11-27 用户「登录的 ui 也适配一下柴阅」）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条** ⭐⭐⭐：
 *   用户明确要求「**登录的 ui 也给我适配一下柴阅**」⇒ 柴阅的登录表单观感与交互必须真的用上：
 *     · 连续输入项合成**一张卡片**（`CardGroup` + 行内标题 + 行高 52）⭐⭐⭐
 *     · 连续按钮排成**网格**（列数取站方给的 `flexBasisPercent`）⭐⭐⭐
 *     · 按钮**图标按关键字映射**（退出/注册/扫码/检测/登录/后台/清空/更新/切换/服务器…）⭐⭐⭐
 *     · 底部**主按钮条**（`AccentButton`）⭐⭐⭐
 *     · 网页登录分支（`loginUrl` 是 http ⇒ 用柴阅的网页登录，完成后把 Cookie 存给书源）⭐⭐⭐
 *
 * ⭐⭐⭐ **同时钉住「不能丢的轻阅真机修复」** ⭐⭐⭐：
 *   宿主那页有柴阅没有的能力（都是真机修过的）⇒ 换观感时**不能一起换掉**：
 *     · 表单值**写值即落盘**（重进面板/重启 App 还在）⭐⭐⭐
 *     · 番茄 sessionid 自动抓（用户在浏览器登录过 ⇒ 不用手抄）⭐⭐⭐
 *     · 「退出登录」按钮 + 引擎急救（卡死时点它）⭐⭐⭐
 *     · 登录状态检测 + 站方原文（判断登录成没成的真话）⭐⭐⭐
 *
 * ⭐⭐⭐ **命名纪律**（踩过两次） ⭐⭐⭐：
 *   宿主**不能** `import ChaiyueReader` ⇒ 它 `@_exported import ChaiyueModels`
 *   ⇒ 会把柴阅的 `Book`/`BookSource` 带进宿主命名空间 ⇒ **与宿主同名类型 ambiguous** ⭐⭐⭐
 *   ⇒ 必须走 `LegadoEngine` 的门面转发 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **init 必须在【LoginRow 的主声明】里**（CI336 实锤 · 2026-11-27 修正）⭐⭐⭐⭐⭐：
 *   `LoginRow` 有自定义 `init(from:)` ⇒ **memberwise init 被抑制**
 *   ⇒ **extension 里的 init 不能给存储属性赋值**（Swift 要求它调 `self.init`）
 *   ⇒ 而 `init(from:)` 要 decoder ⇒ ⇒ **extension 那条路根本不通**
 *   ⇒ CI336 报「'self' used before 'self.init' call」⇒ 整包编译失败 ⭐⭐⭐
 *   ⇒ ⚠️ **「init 得定义在宿主能看见的模块里」是误解**：
 *     `public init` 只要与类型**同模块**即可 ⇒ 宿主经 `LegadoEngineHost.LoginRow`（typealias）
 *     **照样能调**（沙盒用 swiftc 三模块实验实测过）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
};
const exists = (rel) => fs.existsSync(path.join(ROOT, rel));

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

console.log('\n── ① 柴阅的登录表单组件在包里 ──');
{
  const form = read('LegadoEngine/Sources/ChaiyueReader/ChaiyueLoginForm.swift');
  ok(form.length > 0, '① ChaiyueLoginForm.swift 在');
  ok(/public struct ChaiyueLoginForm/.test(form), '① 有 public 的 ChaiyueLoginForm');
  ok(/CardGroup\(separatorInset:/.test(form), '① 输入项用柴阅的 CardGroup 合成卡片');
  ok(/LazyVGrid\(columns: columns\(section\)/.test(form), '① 按钮用 LazyVGrid 网格');
  ok(/flexBasisPercent/.test(form), '① 网格列数取站方的 flexBasisPercent');
  ok(/AccentButton\(title:/.test(form), '① 底部是柴阅的 AccentButton 主按钮');
  ok(/ChaiyueLoginBottomBar/.test(form), '① 用了柴阅的 BottomBar');
  ok(/"rectangle.portrait.and.arrow.right"|person.crop.circle|qrcode.viewfinder/.test(form),
     '① 按钮图标按关键字映射（退出/登录/扫码…）');
  ok(/public struct ChaiyueLoginWebView/.test(form), '① 有柴阅的网页登录（loginUrl 走它）');
}

console.log('\n── ② 宿主走门面转发（不能直接 import ChaiyueReader）──');
{
  const host = read('QiReaderLite/Features/Sources/SourceLoginSheet.swift');
  const bridge = read('LegadoEngine/Sources/LegadoEngine/ChaiyueLoginFormBridge.swift');
  const facade = read('LegadoEngine/Sources/LegadoEngine/LegadoEngineHost.swift');
  ok(bridge.length > 0, '② 门面转发文件在（Sources/LegadoEngine/）');
  ok(/public struct ChaiyueLoginFormBridge/.test(bridge), '② 有 public 的转发组件');
  ok(/public typealias LoginRow = ChaiyueEngine\.LoginRow/.test(facade), '② LegadoEngineHost 有 LoginRow 别名');
  ok(/public typealias Row = ChaiyueEngine\.LoginRow/.test(bridge), '② 门面转发的行类型 = 柴阅的 LoginRow');

  // ⚠️⭐⭐⭐ **init 必须在【主声明】里**（CI336 实锤）⭐⭐⭐
  const webBook = read('LegadoEngine/Sources/ChaiyueEngine/Engine/WebBook.swift');
  ok(/public struct LoginRow/.test(webBook), '② LoginRow 的主声明在 WebBook.swift');
  ok(/public init\(name: String/.test(webBook), '② LoginRow 主声明里有 public init');
  ok(/type: Kind = \.text/.test(webBook), '② init 的参数与 LoginRow 的字段对齐');
  ok(!/public extension LoginRow/.test(webBook),
     '② init 不在 extension 里（Swift 禁止 extension 的 init 赋存储属性 ⇒ CI336 编译失败）');
  ok(!exists('LegadoEngine/Sources/LegadoEngine/LoginRow+PublicInit.swift'),
     '② 旧的 extension 版 init 文件已删（那条路已证明编译不过）');
  ok(/import ChaiyueModels/.test(webBook),
     '② WebBook.swift import 了 ChaiyueModels（`ExploreKind` 在那儿 ⇒ 漏了会 cannot find type）');

  // ⚠️ **不能用 `/import ChaiyueReader/`**（正则里有空格 ⇒ JS 会提前结束正则 ⇒ 语法错）⭐⭐⭐
  const importsChaiyueReader = new RegExp('^\\s*import\\s+ChaiyueReader\\s*$', 'm').test(host);
  ok(!importsChaiyueReader, '② 宿主**没有** import ChaiyueReader（会撞名）');
  ok(/ChaiyueLoginFormBridge\(/.test(host), '② 宿主用的是门面转发组件');
  ok(/LegadoEngineHost\.LoginRow\(/.test(host), '② 宿主造行走 LegadoEngineHost.LoginRow');
}

console.log('\n── ③ 轻阅的真机修复不能被换掉 ──');
{
  const host = read('QiReaderLite/Features/Sources/SourceLoginSheet.swift');
  ok(/SourceVariables\.setLoginFormValues/.test(host), '③ 表单值写值即落盘（重进面板/重启还在）');
  ok(/autoFillFQSessionId\(\)/.test(host), '③ 番茄 sessionid 自动抓（用户不用手抄）');
  ok(/hasLogoutAction/.test(host), '③ 保留「退出登录」按钮');
  ok(/resetEngine\(\)/.test(host), '③ 保留引擎急救（卡死时点它，不用重装）');
  ok(/detectBox|report/.test(host), '③ 保留登录状态检测');
  ok(/stationMessages/.test(host), '③ 保留站方原文（判断登录成没成的真话）');
}

console.log('\n── ④ 柴阅登录表单自己得站得住（这份文件此前从未编译过）──');
{
  // ⭐⭐⭐ CI335/336 实锤：表单里 `running` / `run(...)` **被调用但没定义**
  //   ⇒ "cannot find 'running' in scope" ⇒ 整包编译失败 ⭐⭐⭐
  const form = read('LegadoEngine/Sources/ChaiyueReader/ChaiyueLoginForm.swift');
  ok(/private var running: Int\?/.test(form), '④ 有 running（按钮转圈要按 action 反查行号）');
  ok(/private func run\(_ row: LoginRow\)/.test(form), '④ 有 run（点按钮要回调宿主跑站方 JS）');
  ok(/onRun\(row, formData\(\)\)/.test(form), '④ 跑动作时把表单值带过去（柴阅语义：先存表单再跑 action）');
  ok(/rows\.firstIndex \{ \$0\.action == runningAction \}/.test(form), '④ running 按 action 匹配行号');

  // ⭐⭐⭐⭐⭐ **闭包类型不能写成【元组】**（CI337 实锤 · 一处根因报 7 条）⭐⭐⭐⭐⭐
  //   踩法：`public var onToast: (String, String, Bool) = { _, _, _ in }`
  //   ⇒ 这个类型是**元组**不是**函数** ⇒ 默认值（3 参闭包）塞不进去 ⇒
  //     "cannot convert value of type '(_, _, _) -> ()' to specified type '(String, String, Bool)'"
  //   ⇒ 而且 `onToast("x", "y", false)` 这种**调用**也会报
  //     "cannot call value of non-function type" ⇒ **一处写错 ⇒ 7 条报错** ⭐⭐⭐
  //   ⇒ 正解：`(String, String, Bool) -> Void`（**带箭头**）⭐⭐⭐
  //   ⇒ ⚠️ 判据：**闭包属性/参数的类型里出现 `)` 后面没有 `->`** ⇒ 就是元组型 ⇒ 红 ⭐⭐⭐
  const tupleClosure = [];
  const scanTupleClosure = (rel) => {
    const src = read(rel);
    if (!src) return;
    const re = /\b(?:var|let)\s+\w+\s*:\s*\([^)]*\)\s*(?:=\s*\{|,\s*$)/gm;
    let m;
    while ((m = re.exec(src)) !== null) tupleClosure.push(`${rel}:${src.slice(0, m.index).split('\n').length}`);
    // 参数位同理：`onToast: @escaping (A, B, C) = {`
    const re2 = /\w+\s*:\s*@escaping\s*\([^)]*\)\s*(?:=\s*\{|,\s*$)/gm;
    while ((m = re2.exec(src)) !== null) tupleClosure.push(`${rel}:${src.slice(0, m.index).split('\n').length}`);
  };
  scanTupleClosure('LegadoEngine/Sources/ChaiyueReader/ChaiyueLoginForm.swift');
  scanTupleClosure('LegadoEngine/Sources/LegadoEngine/ChaiyueLoginFormBridge.swift');
  ok(tupleClosure.length === 0,
     '④ 闭包类型都写成函数型（`(A, B) -> Void`）而不是元组型（`(A, B)`）',
     tupleClosure.join(' / '));
  ok(/onToast: \(String, String, Bool\) -> Void/.test(form), '④ onToast 是函数型（3 参 + -> Void）');
}

console.log('\n── ⑤ 表单键必须是【技术名】，不能被显示名顶掉 ──');
{
  const host = read('QiReaderLite/Features/Sources/SourceLoginSheet.swift');
  ok(/let displayName: String/.test(host), '⑤ Field 带 displayName（人话名）');
  ok(/LegadoEngineHost\.LoginRow\(name: f\.name/.test(host), '⑤ 技术名进 LoginRow.name（= 表单键）');
  ok(/viewName: f\.displayName/.test(host), '⑤ 人话名进 LoginRow.viewName（= 显示）');
  ok(!/Field\(name: d,/.test(host), '⑤ 求值 viewName 只改 displayName（不改 name ⇒ 表单键不被污染）');
  ok(!/loginRowsState/.test(host), '⑤ 不存中间 DTO 态（行直接由 fields 映射，少一层就不容易漂）');
  ok(/runningAction: runningAction/.test(host), '⑤ 转圈按 action 匹配（不是按行名）');
  ok(/onRun: \{ row, _ in self\.run/.test(host), '⑤ escaping closure 要显式 self（否则编译不过）');
  ok(/onSubmit: \{ self\.submitLogin\(\) \}/.test(host), '⑤ 主按钮也要显式 self');
  ok(!/private var loginFields: some View/.test(host), '⑤ 旧的手写输入框已删（整页换成柴阅的）');
  ok(!/private var actionButtonsGrid: some View/.test(host), '⑤ 旧的按钮网格已删');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
