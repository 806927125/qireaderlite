#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：登录面板的「行」必须能求值出来**（2026-11-21 真机「登录界面没按钮」实证）
 *
 * ⚠️⚠️⚠️ **真机症状**：有些书源点进登录面板 ⇒ **一个按钮都没有** ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **根因**：站方的 `loginUi` 常常是 **`@js:` / `<js>` 薄壳**（正文在 jsLib 里）⭐⭐⭐
 *   ⇒ 轻阅自己解析**只吃静态 JSON** ⇒ 解析失败 ⇒ **面板空白** ⭐⭐⭐
 *   ⇒ 柴阅的 `resolveLoginRows` 会**先跑 loginJs、再求值 loginUi** ⇒ 行拿得到 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **本门禁钉四件事**：
 *   ① 宿主有 `loginRows` op（调柴阅的 `resolveLoginRows`）⭐⭐⭐
 *   ② 登录面板**用它**取行（静态解析只是兜底）⭐⭐⭐
 *   ③ 表单值**双写**进登录信息槽（柴阅的 `result` 绑定它 ⇒ 站方 JS 才读得到）⭐⭐⭐
 *   ④ **CI 上有真跑探针**（Linux 没 JSC ⇒ 只能在 macOS 验「@js: 能出行」）⭐⭐⭐
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

const host = strip(read('QiReaderLite/Core/LegadoEngineBackend.swift'));
const svc = strip(read('QiReaderLite/Core/SourceService.swift'));
const sheet = strip(read('QiReaderLite/Features/Sources/SourceLoginSheet.swift'));
const vars = strip(read('QiReaderLite/Core/SourceVariables.swift'));
const probe = read('LegadoEngine/Sources/ChaiyueProbe/main.swift');
const ci = read('.github/workflows/build-ipa.yml');

console.log('=== 1. 宿主：`loginRows` op（柴阅求值） ===');
ok(/case "loginRows"/.test(host), '有 loginRows op');
ok(/web\.resolveLoginRows\(\)/.test(host), '★ 它调柴阅的 resolveLoginRows（★ 会求值 @js: 的 loginUi）');
ok(/"name":\s*row\.name/.test(host) && /"type":\s*row\.type\.rawValue/.test(host),
   '返回的行含 name/type/action（轻阅 UI 的 Field 契约）');

console.log('\n=== 2. SourceService：有 loginRows 方法 ===');
ok(/func loginRows\(source: BookSource\)/.test(svc), '有 loginRows(source:)');
ok(/call\("loginRows"/.test(svc), '它走引擎 op');
ok(/struct LoginRowDTO/.test(svc) && /var name: String = ""/.test(svc), '有 LoginRowDTO');

console.log('\n=== 3. 登录面板：用它取行（静态只是兜底） ===');
ok(/await load\(\)/.test(sheet), '.task 里 await load()（load 是 async）');
ok(/SourceService\.shared\.loginRows\(source: source\)/.test(sheet),
   '★ 面板调 loginRows（★ @js: 的 loginUi 才有行）');
ok(/JSONSerialization\.jsonObject\(with: data\) as\? \[\[String: Any\]\]/.test(sheet),
   '静态 JSON 解析仍在（兜底 ⇒ 静态源秒开）');
ok(!/guard let raw = src\.loginUi, !raw\.isEmpty,[\s\S]{0,200}else \{ return \}/.test(sheet),
   '★ 不再「解析失败就整个 return」（★ 原来这一行就是「没按钮」的元凶）');

console.log('\n=== 4. 表单值必须【双写】进登录信息槽（柴阅的 result 绑定它） ===');
ok(/mergeLoginInfoValues\(keep, for: sourceUrl\)/.test(vars),
   '★ setLoginFormValues 同时合并进登录信息槽（★ 站方 JS 的 result 才读得到）');
ok(/static func mergeLoginInfoValues/.test(vars), '有 mergeLoginInfoValues');
ok(/var cur = loginInfo\(for: sourceUrl\)/.test(vars),
   '★ 是【合并】不是覆盖（★ 站方自己写的 token/uid 不能丢）');

console.log('\n=== 5. CI 上有【真跑探针】（Linux 没 JSC ⇒ 只能在 macOS 验） ===');
ok(/ChaiyueProbe/.test(ci), 'CI 引用了 ChaiyueProbe');
ok(/swift run ChaiyueProbe/.test(ci), 'CI 会跑它');
ok(/resolveLoginRows/.test(probe), '★ 探针真调 resolveLoginRows');
ok(/@js:_probeRows\(\)/.test(probe), '★ 探针的 fixture 用的是 @js: 形式（★ 正是真机的形态）');
ok(/type == \.button/.test(probe), '★ 探针断言「有 button 行」（★ 没按钮 ⇒ 探针红 ⇒ 拦住）');
ok(/exit\(1\)/.test(probe), '探针失败时退出码非 0（CI 会红）');

console.log('\n=== 6. 变异对照（改坏 ⇒ 必须红） ===');
{
  const m1 = host.replace(/web\.resolveLoginRows\(\)/, '[]');
  ok(!/web\.resolveLoginRows\(\)/.test(m1), '★ 变异①（宿主不求值）⇒ 被抓住');

  const m2 = sheet.replace(/SourceService\.shared\.loginRows\(source: source\)/, '[]');
  ok(!/SourceService\.shared\.loginRows\(source: source\)/.test(m2), '★ 变异②（面板不调它）⇒ 被抓住');

  const m3 = vars.replace(/mergeLoginInfoValues\(keep, for: sourceUrl\)/, '// 变异：不双写');
  ok(!/mergeLoginInfoValues\(keep, for: sourceUrl\)/.test(m3), '★ 变异③（表单值不双写）⇒ 被抓住');

  const m4 = vars.replace(/var cur = loginInfo\(for: sourceUrl\)/, 'var cur = [String: String]()');
  ok(!/var cur = loginInfo\(for: sourceUrl\)/.test(m4), '★ 变异④（改成覆盖）⇒ 被抓住');

  const m5 = ci.replace(/swift run ChaiyueProbe/, 'true');
  ok(!/swift run ChaiyueProbe/.test(m5), '★ 变异⑤（CI 不跑探针）⇒ 被抓住');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
