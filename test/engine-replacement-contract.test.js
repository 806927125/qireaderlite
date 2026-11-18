#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **引擎替换契约门禁**（2026-11-19 · 引擎整个换成 `LegadoEngine`）
 *
 * 跑法：node test/engine-replacement-contract.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * 用户决定：「把你现在的引擎全给我删了，替换成我这个」
 * ⇒ 老的两条引擎**物理删除**：
 *   ① WebView JS 引擎（`QiReaderLite/Resources/engine/*.js` + `Engine/WebViewJSExecutor.swift`）
 *   ② 自研 Swift 引擎（SPM 远程包 `legado-engine`）
 * ⇒ 新引擎 = `LegadoEngine`（**仓库内本地包** `LegadoEngine/`）
 *   （Legado 3.0 语义，从「六阅 LegadoR iOS」二进制逆向重建：SwiftSoup + **Kanna 真 XPath** + 1:1 提取的 Rhino 兼容 JS shim）
 *
 * 这个门禁钉住「替换后的不变量」，防回退：
 * ① **老引擎的痕迹必须为零**（文件、SPM 引用、分流开关）
 * ② **新引擎必须在位**（本地包 + 依赖 + 自带测试）
 * ③ **App 的接线必须覆盖全部 op**（含登录/筛选 action 这两个「要写变量」的）
 * ④ **变量回传契约不许丢**（`__sourceVars` / `__sourceVariable` / `__sourceVariableChanged`）
 */
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? (pass++, console.log('  ✓ ' + m)) : (fail++, console.log('  ✗ ' + m)); };
const read = (p) => { try { return fs.readFileSync(path.join(root, p), 'utf8'); } catch (e) { return ''; } };
const exists = (p) => fs.existsSync(path.join(root, p));

const root = path.join(__dirname, '..');
const stripComments = (s) => s
  .replace(/\/\*[\s\S]*?\*\//g, ' ')
  .replace(/(^|[^:"'\\])\/\/[^\n]*/g, '$1 ');

console.log('=== ① 老引擎必须【物理删除干净】===');
for (const p of [
  'QiReaderLite/Resources/engine',
  'QiReaderLite/Engine/WebViewJSExecutor.swift',
  'QiReaderLite/Engine/WebViewJSHost.swift',
  'QiReaderLite/Core/EngineMode.swift',
  'QiReaderLite/Core/JSEngineFactory.swift',
  'QiReaderLite/Core/RuleSandbox.swift',
]) {
  ok(!exists(p), `已删：${p}`);
}
{
  const pbx = read('QiReaderLite.xcodeproj/project.pbxproj');
  ok(!/legado-engine/.test(pbx), 'pbxproj 里不再有远程 `legado-engine` 依赖');
  ok(/XCLocalSwiftPackageReference "LegadoEngine"/.test(pbx), 'pbxproj 里是**本地包** `LegadoEngine`');
  ok(/productName = LegadoEngine;/.test(pbx), '产品名 = LegadoEngine');
  const svc = stripComments(read('QiReaderLite/Core/SourceService.swift'));
  ok(!/EngineMode/.test(svc), 'SourceService 里不再有 `EngineMode` 分流（只有一个引擎）');
  ok(!/invokeWebViewEngine/.test(svc), 'SourceService 里不再有 WebView 引擎通路');
}

console.log('\n=== ② 新引擎必须在位 ===');
ok(exists('LegadoEngine/Package.swift'), '本地引擎包 `LegadoEngine/Package.swift` 在');
{
  const pkg = read('LegadoEngine/Package.swift');
  ok(/name:\s*"LegadoEngine"/.test(pkg), '包名 = LegadoEngine');
  ok(/SwiftSoup/.test(pkg), '依赖 SwiftSoup（默认规则解析）');
  ok(/Kanna/.test(pkg), '依赖 Kanna（**真 XPath**）');
  ok(/resources:\s*\[.copy\("JS\/Resources"\)\]/s.test(pkg) || /copy\("JS\/Resources"\)/.test(pkg),
     'JS shim 资源随包走（Rhino 兼容层）');
}
ok(exists('LegadoEngine/Sources/LegadoEngine/LegadoEngineHost.swift'),
   '宿主适配入口在（`LegadoEngineHost` ⇒ 避免与宿主同名类型撞车）');
ok(exists('LegadoEngine/Sources/LegadoEngine/JS/Resources'), 'JS shim 资源在');
{
  const files = fs.existsSync(path.join(root, 'LegadoEngine/Sources/LegadoEngine/JS/Resources'))
    ? fs.readdirSync(path.join(root, 'LegadoEngine/Sources/LegadoEngine/JS/Resources')) : [];
  ok(files.length >= 3, `JS shim 文件数 = ${files.length}（原样提取的 bootstrap）`);
}

console.log('\n=== ③ App 的接线必须覆盖全部 op ===');
{
  const be = stripComments(read('QiReaderLite/Core/LegadoEngineBackend.swift'));
  // ⭐⭐⭐ **必须精确到 dispatch 结构**（不能只找 `"op"` 字样 ⇒ 会被别处的同名字串骗过）⭐⭐⭐
  //   ⇒ 变异把 `if op == "login"` 改成 `if false` ⇒ 这里必须红 ⭐⭐⭐
  for (const op of ['search', 'exploreKinds', 'explore', 'bookInfo', 'toc', 'content']) {
    ok(be.includes(`case "${op}":`), `接线覆盖 op：${op}（case 分派）`);
  }
  for (const op of ['login', 'loginProbe', 'filterAction']) {
    ok(be.includes(`op == "${op}"`), `接线覆盖 op：${op}（if 分派）`);
  }
  ok(/import LegadoEngine/.test(be), '接线层 import 新引擎');
  ok(!/LegadoCore/.test(be), '接线层**不再**引用老引擎包（`LegadoCore`）');
  // op 的返回形状（宿主 UI 靠这些字段）
  for (const k of ['"books"', '"chapters"', '"content"', '"kinds"', '"book"']) {
    ok(be.includes(k), `返回契约含 ${k}`);
  }
}

console.log('\n=== ④ 变量回传契约不许丢（站方变量/解锁态要能落盘）===');
{
  const be = stripComments(read('QiReaderLite/Core/LegadoEngineBackend.swift'));
  // ⭐⭐⭐ **计数**（不能只判「在不在」⇒ 注释里同名也能骗过 ⇒ 变异打掉一处就红）⭐⭐⭐
  const countOf = (needle) => (be.split(needle).length - 1);
  // ⭐⭐⭐ **每个分支各自都要回传**（不能只数总数 ⇒ 变异打掉一处就红）⭐⭐⭐
  const branches = [
    ['login', be.slice(be.indexOf('if op == "login"'), be.indexOf('if op == "login"') + 2600)],
    ['filterAction', be.slice(be.indexOf('if op == "filterAction"'), be.indexOf('if op == "filterAction"') + 1600)],
    ['主链路', be.slice(be.indexOf('switch op {'), be.indexOf('switch op {') + 4200)],
  ];
  for (const [name, seg] of branches) {
    if (!seg) { ok(false, `分支「${name}」没找到（⇒ 接线结构变了？）`); continue; }
    ok(seg.includes('"__sourceVars"'), `分支「${name}」回传 __sourceVars（书源变量）`);
    ok(seg.includes('"__sourceVariable"'), `分支「${name}」回传 __sourceVariable（站方变量）`);
    ok(seg.includes('"__sourceVariableChanged"'),
       `分支「${name}」回传 __sourceVariableChanged（**证据不许自证** ⇒ 与种子比较）`);
  }
  ok(countOf('"__sourceVariableChanged"') >= 3, `__sourceVariableChanged 共出现 ${countOf('"__sourceVariableChanged"')} 处`);
  const svc = stripComments(read('QiReaderLite/Core/SourceService.swift'));
  ok(/LegadoEngineBackend\.shared\.invoke/.test(svc), 'SourceService 走新引擎后端');
}

console.log('\n=== ⑤ 新引擎自带测试（规则语义的真实回归）===');
{
  const engineDir = path.join(root, 'LegadoEngine');
  const swift = ['/workspace/.toolchain/swift/usr/bin/swift',
                 '/usr/bin/swift', '/usr/local/bin/swift'].find(p => fs.existsSync(p));
  if (!swift) {
    console.log('  ⏭ 跳过：没装 swift（**没验到** ⇒ 不等于通过）');
  } else if (!fs.existsSync(path.join(engineDir, '.build'))) {
    console.log('  ⏭ 跳过：引擎包还没编过（**没验到** ⇒ 不等于通过）');
  } else {
    const r = spawnSync(swift, ['test', '--disable-automatic-resolution'], {
      cwd: engineDir, encoding: 'utf8', timeout: 15 * 60 * 1000,
      env: Object.assign({}, process.env, {
        LD_LIBRARY_PATH: '/workspace/.toolchain/swift/usr/lib/swift/linux',
      }),
    });
    const out = (r.stdout || '') + (r.stderr || '');
    const m = out.match(/Executed (\d+) tests?[\s\S]{0,80}?(\d+) failures?/);
    if (m) {
      ok(Number(m[2]) === 0, `新引擎自带测试：${m[1]} 项 / 失败 ${m[2]}`);
    } else {
      ok(false, '新引擎自带测试没跑出汇总行（**崩了**）\n' + out.split('\n').slice(-12).join('\n'));
    }
  }
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
