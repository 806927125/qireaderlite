#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：`loginHeader` 槽只能装「站方的 token」，不能装宿主自己的「Cookie: …」** ⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **真机实证（2026-11-24，书山聚合 v6 发现页 toast「Token 格式错误」）** ⭐⭐⭐：
 *   · 站方（书山聚合）把 **token 本身**存进 `loginHeader`（`source.putLoginHeader(token)`）⭐⭐⭐
 *   · 宿主 UI 的「🍅番茄 sessionid」兜底**也**写**同一个槽**（写成 `"Cookie: sessionid=xxx"`）⭐⭐⭐
 *   ⇒ ⇒ **两个用途抢一个槽** ⇒ ⇒ 番茄那次写就把站方的 token **冲掉** 💥⭐⭐⭐
 *   ⇒ ⇒ 站方下一次请求把 `"Cookie: sessionid=xxx"` 当 token 发出去 ⭐⭐⭐
 *   ⇒ ⇒ 站方解不出 base64 ⇒ ⇒ 回「**Token 格式错误**」⭐⭐⭐⭐⭐
 *   （站方判定表是**沙盒直连实测**的，不是推测：
 *      空 ⇒「非法请求，请先登录」/ 非 base64 ⇒「Token 格式错误」/
 *      长度不对 ⇒「Token 长度不正确」/ 其它 ⇒「Token 无效或已失效」）⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **而且那个写法在柴阅引擎里本来就注入不了请求头** ⭐⭐⭐⭐⭐
 *   （引擎只认 **JSON 形态**的 loginHeader ⇒ `"Cookie: …"` 形态**是纯破坏、零收益**）⭐⭐⭐
 *
 * ⭐⭐⭐ **本门禁钉死三件事**（都能被「变异对照」证伪：把实现改回去 ⇒ 必须红）⭐⭐⭐
 *   ① **任何 App 源码都不许把 `"Cookie: …"` 写进 loginHeader 槽** ⭐⭐⭐
 *   ② **自愈必须在**：每个 op 都要清掉宿主旧格式（用户的设备不用重装源就能恢复）⭐⭐⭐
 *   ③ **cookie 快照必须真被引擎吃掉**：站方 `cookie.getCookie('fanqienovel.com')` 才有值 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APP_DIR = path.join(ROOT, 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

/** 收集 App 源码（递归 .swift） */
function swiftFiles(dir, out = []) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) { if (name !== '.build') swiftFiles(p, out); }
    else if (name.endsWith('.swift')) out.push(p);
  }
  return out;
}

/** 剥注释（注释里写「不要 xxx」会被当成「有 xxx」⇒ 假红） */
function stripComments(t) {
  return t
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ');
}

const files = swiftFiles(APP_DIR);
ok(files.length > 20, `扫到 ${files.length} 个 App 源文件`);

// ── ① ⭐⭐⭐ 不许把 "Cookie: …" 写进 loginHeader 槽 ⭐⭐⭐
//   判据：`setLoginHeader(` 的实参里出现 `"Cookie:` ⇒ 就是那次破坏性写入 ⭐⭐⭐
const offenders = [];
for (const f of files) {
  const code = stripComments(fs.readFileSync(f, 'utf8'));
  const lines = code.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!/setLoginHeader\s*\(/.test(line)) continue;
    // 取这一行 + 下一行（参数可能换行）
    const chunk = line + ' ' + (lines[i + 1] || '');
    if (/setLoginHeader\s*\(\s*"Cookie\s*:/.test(chunk)) {
      offenders.push(`${path.relative(ROOT, f)}:${i + 1}`);
    }
  }
}
ok(offenders.length === 0,
   '① 没有任何地方把 "Cookie: …" 写进 loginHeader 槽（它会摧毁站方的 token）',
   offenders.join(', '));

// ── ② ⭐⭐⭐ 自愈必须在（op 路径上清掉宿主旧格式）⭐⭐⭐
const varsFile = path.join(APP_DIR, 'Core/SourceVariables.swift');
const svcFile = path.join(APP_DIR, 'Core/SourceService.swift');
const varsCode = stripComments(fs.readFileSync(varsFile, 'utf8'));
const svcCode = stripComments(fs.readFileSync(svcFile, 'utf8'));

ok(/static func clearLegacyCookieLoginHeader/.test(varsCode),
   '②a SourceVariables 里有 clearLegacyCookieLoginHeader（定义）');
ok(/clearLegacyCookieLoginHeader\(for:/.test(svcCode),
   '②b SourceService 的 op 路径上调用了它（自愈 ⇒ 用户不用重装源）');
ok(/isLegacyCookieLoginHeader/.test(varsCode),
   '②c 有「是不是宿主旧格式」的判据（"Cookie: " 开头）');

// ── ③ ⭐⭐⭐ cookie 快照必须真被引擎吃掉 ⭐⭐⭐
const backendFile = path.join(APP_DIR, 'Core/LegadoEngineBackend.swift');
const backendCode = stripComments(fs.readFileSync(backendFile, 'utf8'));
ok(/cookieSnapshot/.test(backendCode),
   '③a 引擎桥里读得到 cookieSnapshot');
ok(/env\.cookies\.(replaceCookie|setCookie)/.test(backendCode),
   '③b cookieSnapshot 真被灌进引擎的 cookie 罐（站方 cookie.getCookie 才有值）');

// ── ④ ⭐⭐⭐ 引擎只认 JSON 形态的 loginHeader（⇒ "Cookie: …" 形态本来就是死的）⭐⭐⭐
//   这条是**依据**：证明「删掉那次写入」不会造成功能回退 ⭐⭐⭐
const ruleSession = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueEngine/Engine/RuleSession.swift');
const rsCode = stripComments(fs.readFileSync(ruleSession, 'utf8'));
ok(/stringMap\(login\)/.test(rsCode),
   '④ 引擎注入 loginHeader 用的是 LenientJSON.stringMap（⇒ 只认 JSON 形态）');

// ⚠️ 汇总行格式必须被 `test/parse-summary.py` 认出来（「通过 N / 失败 M」）⭐⭐⭐
console.log(fail === 0 ? `通过 ${pass} / 失败 ${fail}` : `通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
