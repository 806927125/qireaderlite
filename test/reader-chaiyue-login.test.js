#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：登录页必须是【柴阅的登录表单】**（2026-11-27 用户「登录的 UI 也适配柴阅」）⭐⭐⭐⭐⭐
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
 * ⭐⭐⭐ **命名纪律**（踩过两次）⭐⭐⭐：
 *   宿主**不能** `import ChaiyueReader` ⇒ 它 `@_exported import ChaiyueModels`
 *   ⇒ 会把柴阅的 `Book`/`BookSource` 带进宿主命名空间 ⇒ **与宿主同名类型 ambiguous** ⭐⭐⭐
 *   ⇒ 必须走 `LegadoEngine` 的门面转发 ⭐⭐⭐
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
  else { fail(); console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
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
  // ⚠️ **init 必须在【宿主门面模块 `LegadoEngine`】里**（CI334/335 实锤）：
  //   public init 只有「调用方能看见定义它的模块」时才可用 ⇒ 宿主只 import LegadoEngine
  //   ⇒ init 若定义在 ChaiyueEngine ⇒ 宿主报 "initializer is inaccessible" ⭐⭐⭐
  const initSrc = read('LegadoEngine/Sources/LegadoEngine/LoginRow+PublicInit.swift');
  ok(/public extension LoginRow/.test(initSrc), '② LoginRow 有 public init（宿主要自己造行）');
  ok(/import ChaiyueModels/.test(initSrc),
     '② init 文件 import 了 ChaiyueModels（`ExploreKind` 在那儿 ⇒ 漏了会 cannot find type）');
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

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
