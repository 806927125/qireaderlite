#!/usr/bin/env node
/**
 * **发现页筛选栏：paramKey 为空时要执行站方 action**（2026-10-22 真机「平台切不了」）
 *
 * 跑法：node test/filter-action.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 站方有两种写法，宿主要分两条路：
 *
 *   ① 🍅大灰狼：`action: "show(infoMap['平台'],'find_source')"`
 *      ⇒ 引擎能抠出 paramKey（`find_source`）⇒ 宿主自己写这个源级变量 ✅
 *
 *   ② 🍒NovelHub 聚合源：action **自己读写源级变量、自己刷新发现页**
 *      (function(){var c={};try{c=JSON.parse(source.getVariable()||'{}');}catch(e){}
 *        var v=infoMap['平台'];if(v!==null&&v!==undefined){c['src']=v;
 *        try{source.setVariable(JSON.stringify(c));}catch(e1){}}
 *        try{java.refreshExplore();}catch(e2){}})()
 *      ⇒ 抠不出 paramKey（空）⇒ 宿主原来**直接 return** ⇒ **点了没反应** ⭐
 *
 * ⇒ 照栖阅的做法：把 `infoMap[标题] = 值` 喂给站方 action，让**站方自己**写变量
 *   （站方写完 `source.setVariable` ⇒ 标 dirty ⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎的 `filterAction` op ⇒ 老引擎删了 ⇒ 对象没了
 *   ⇒ 现在改成**跑新引擎**（`legado-engine`）
 *   ⇒ **语义等价在哪**：
 *     · 老门禁验的是「宿主把【标题=选中值】塞进 `infoMap` ⇒ 站方 action 读得到 ⇒
 *       站方自己写的变量会落盘」⇒ 新架构里这一步在**引擎的 `runFilterAction`**
 *       （`infoMap[标题] = 值` ⇒ 注入 JS 作用域）⇒ **断言对象换成引擎，语义一模一样** ⭐⭐⭐
 *     · 老门禁从**站方源文件**里读出筛选栏的定义 ⇒ 仍然这么做（**断言要作用于
 *       「从源文件解析出来的规则本身」**）⭐⭐⭐
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const crypto = require('crypto');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除（2026-10-25）⇒ 门禁改验【新引擎】**（`legado-engine` 的 Swift 实现）
const { engineAvailable } = require('./engine-bridge.js');

let pass = 0, fail = 0; const failures = [];
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; failures.push(m + (extra ? '\n    ' + extra : '')); console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};
const skip = (m) => console.log('  ⏭️  跳过：' + m + '（**没验到 ≠ 通过**）');

const root = path.join(__dirname, '..');
const ENGINE_SRC = path.join(root, '..', 'legado-engine', 'Sources', 'LegadoCore');
const PWD = 'nhub2026';
const PWD_HASH = crypto.createHash('md5').update(PWD).digest('hex');

/** ⭐⭐⭐ **跑引擎的 `--op`**（payload 可能很大 ⇒ 走文件形式） */
function runOp(payload) {
  // ⭐⭐⭐ **站方 jsLib 要单独传给引擎**（引擎的 `BookSource` 模型里**没有** jsLib 字段
  //   ⇒ 站方 jsLib 由宿主单独带进来 ⇒ 真机也是这么做的 ⇒ 门禁照抄这个口径）⭐⭐⭐
  if (payload.source && payload.source.jsLib && !payload.jsLib) {
    payload = Object.assign({}, payload, { jsLib: payload.source.jsLib });
  }
  const bin = process.env.ENGINE_BIN
    || path.join(root, '..', 'legado-engine', '.build', 'debug', 'conformance');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'qr-op-'));
  const file = path.join(tmp, 'payload.json');
  try {
    fs.writeFileSync(file, JSON.stringify(payload));
    // ⚠️ **重试**：引擎正在被重编时 ⇒ 这次调用会退出异常 ⇒ 重试几次（同步忙等）⭐⭐⭐
    for (let i = 0; i < 5; i++) {
      const r = spawnSync(bin, ['--op', file], { encoding: 'utf8', timeout: 180000, maxBuffer: 64 * 1024 * 1024 });
      if (r.status === 0 && r.stdout) {
        const line = r.stdout.trim().split('\n').filter(Boolean).pop();
        try { return JSON.parse(line); }
        catch (e) { return { ok: false, error: '引擎输出解析失败' }; }
      }
      const until = Date.now() + 3000;
      while (Date.now() < until) { /* 忙等 3 秒 */ }
    }
    return { ok: false, error: '引擎跑不起来（正在重编？）' };
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) {}
  }
}

/**
 * ⭐⭐⭐⭐⭐ **Swift 驱动**：直接调【引擎自己的 `runFilterAction`】⇒ 跑站方 action
 *
 * ⚠️ **为什么需要**：
 *   这条路的宿主 API 入口是 App 侧的 `LegadoEngineBackend.invoke("filterAction", …)`
 *   ⇒ 沙盒里编不了 App（iOS-only）⇒ 而引擎的 conformance `--op` **还没开** filterAction
 *   ⇒ 正解：**swiftc 真编真跑引擎的 `SourceEngine.runFilterAction`**
 *     ⇒ 验的是**App 真正调的那个函数**（同一份实现）⭐⭐⭐
 *
 * @returns {object|null} null = 环境不具备（调用方要**显式 SKIP**，不许假绿）
 */
function buildSwiftDriver() {
  const ENGINE_DIR = process.env.ENGINE_DIR || path.join(root, '..', 'legado-engine');
  const swiftc = [
    process.env.SWIFT ? path.join(process.env.SWIFT, 'usr', 'bin', 'swiftc') : '',
    '/workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc',
    '/workspace/.toolchain/swift/usr/bin/swiftc',
    '/usr/bin/swiftc', '/usr/local/bin/swiftc',
  ].find(c => c && fs.existsSync(c));
  const build = [
    path.join(ENGINE_DIR, '.build', 'debug'),
    path.join(ENGINE_DIR, '.build', 'x86_64-unknown-linux-gnu', 'debug'),
    path.join(ENGINE_DIR, '.build', 'arm64-apple-darwin', 'debug'),
  ].find(d => fs.existsSync(path.join(d, 'Modules', 'LegadoCore.swiftmodule'))
             && fs.existsSync(path.join(d, 'LegadoCore.build'))
             && fs.existsSync(path.join(d, 'SwiftSoup.build')));
  if (!swiftc || !build) return null;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'qr-filter-'));
  const bin = path.join(tmp, 'driver');
  const swiftSrc = [
    'import Foundation',
    'import LegadoCore',
    'let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""',
    'let data = try Data(contentsOf: URL(fileURLWithPath: path))',
    'let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]',
    'let action = obj["action"] as? String ?? ""',
    'let title = obj["title"] as? String ?? ""',
    'let value = obj["value"] as? String ?? ""',
    'let jsLib = obj["jsLib"] as? String ?? ""',
    'let url = obj["sourceUrl"] as? String ?? "https://probe.example.com/"',
    'let src = BookSource(bookSourceName: "探针", bookSourceUrl: url)',
    'let engine = SourceEngine(source: src,',
    '                          fetcher: PageFetcher(transport: RouteTransport(rules: [])),',
    '                          js: try NodeJSExecutor())',
    'if !jsLib.isEmpty { try? engine.loadJsLib(jsLib) }',
    'let r = try engine.runFilterAction(action: action, title: title, value: value)',
    '// ⭐ 站方 JS 侧记下的宿主对象状态 ⇒ 收回来（与 App 侧 __sourceVars 同款）',
    'if let node = engine.evaluator.js as? NodeJSExecutor {',
    '    let st = node.hostState()',
    '    if let srcState = st["source"] as? [String: Any],',
    '       let vars = srcState["vars"] as? [String: String] {',
    '        for (k, v) in vars { engine.varBox.set(k, v) }',
    '    }',
    '}',
    'print("OK \\(r.ok)")',
    'print("ERR \\(r.error)")',
    'print("VARS \\(SourceEngine.varsJSON(engine.varBox))")',
  ].join('\n');
  try {
    fs.writeFileSync(path.join(tmp, 'main.swift'), swiftSrc);
    const env = Object.assign({}, process.env);
    const swRoot = path.dirname(path.dirname(swiftc));
    env.LD_LIBRARY_PATH = path.join(swRoot, 'usr', 'lib', 'swift', 'linux')
      + (env.LD_LIBRARY_PATH ? ':' + env.LD_LIBRARY_PATH : '');
    const objs = (dir) => fs.readdirSync(path.join(build, dir))
      .filter(f => f.endsWith('.o')).map(f => path.join(build, dir, f));
    const r = spawnSync(swiftc, ['-O', '-I', path.join(build, 'Modules'),
      path.join(tmp, 'main.swift'), ...objs('LegadoCore.build'), ...objs('SwiftSoup.build'),
      '-o', bin], { encoding: 'utf8', timeout: 300000, env });
    if (r.status !== 0) { fs.rmSync(tmp, { recursive: true, force: true }); return { error: 'swiftc 编译失败' }; }
    return { bin, dir: tmp, env };
  } catch (e) {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e2) {}
    return { error: String(e && e.message) };
  }
}

/** ⭐ 跑一次站方 action（走 Swift 驱动） */
function runFilterActionViaSwift(driver, payload) {
  const file = path.join(driver.dir, 'in-' + Math.random().toString(36).slice(2) + '.json');
  fs.writeFileSync(file, JSON.stringify(payload));
  const r = spawnSync(driver.bin, [file], { encoding: 'utf8', timeout: 120000, env: driver.env });
  try { fs.rmSync(file, { force: true }); } catch (e) {}
  const out = {};
  for (const line of String(r.stdout || '').split('\n')) {
    const i = line.indexOf(' ');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  if (out.OK === undefined) return { ok: false, error: 'Swift 驱动没返回结果' };
  return { ok: out.OK === 'true', error: out.ERR || '', vars: out.VARS || '' };
}

/** ⭐⭐⭐ **从站方源文件里抠出「筛选栏」的 action 表达式**
 *  （⇒ 断言作用在「从源文件解析出来的规则本身」上，不是复述实现意图） */
function extractFilterAction(exploreUrlText, filterTitle) {
  const t = exploreUrlText.indexOf('"title": "' + filterTitle + '"');
  if (t < 0) return '';
  const marker = '"action": "';
  const i = exploreUrlText.indexOf(marker, t);
  if (i < 0) return '';
  let j = i + marker.length, out = '';
  while (j < exploreUrlText.length) {
    const c = exploreUrlText[j];
    if (c === '\\') { out += c + exploreUrlText[j + 1]; j += 2; continue; }
    if (c === '"') break;
    out += c; j++;
  }
  try { return JSON.parse('"' + out + '"'); } catch (e) { return ''; }
}

(async () => {
  console.log('=== 1. 源码：要有 filterAction 这条路 + 宿主两条路 ===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]` /
  //     `hexDecodeToString 挑人话`）⇒ 那些是**实现细节**，不是语义
  //   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（309 项）与真机上 ⭐⭐⭐
  //
  // ⭐ 下面这几条是**新引擎 / App 侧的等价描述**（能力必须还在）：
  const engSrc = fs.readFileSync(path.join(ENGINE_SRC, 'Pipeline', 'SourceEngine.swift'), 'utf8');
  const exploreSrc = fs.readFileSync(
    path.join(root, 'QiReaderLite', 'Features', 'Explore', 'ExploreView.swift'), 'utf8');
  const svcSrc = fs.readFileSync(
    path.join(root, 'QiReaderLite', 'Core', 'SourceService.swift'), 'utf8');
  const backendSrc = fs.readFileSync(
    path.join(root, 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');

  ok(/func runFilterAction\(action: String, title: String, value: String\)/.test(engSrc),
     '引擎有 runFilterAction（跑站方的筛选栏 action）');
  ok(/infoMap\[title\] = \.string\(value\)/.test(engSrc),
     'filterAction 把选中值按【标题】塞进 infoMap');
  ok(/extra: \["infoMap": \.object\(infoMap\)\]/.test(engSrc),
     'infoMap 真的注进站方 JS 的作用域（⇒ 站方 action 读得到）');
  ok(/applySourceFilter/.test(svcSrc), 'SourceService 有 applySourceFilter');
  ok(/applyFilter\(f, c\)/.test(exploreSrc), '筛选按钮传的是整个筛选项（含 action）');
  ok(/f\.paramKey\.isEmpty/.test(exploreSrc) && /applySourceFilter/.test(exploreSrc),
     'paramKey 为空时走「执行站方 action」那条路');
  ok(/setFilterChoice/.test(exploreSrc) && /filterChoice/.test(svcSrc),
     '宿主自己记「用户选了什么」（paramKey 为空时读不到源级变量 ⇒ 胶囊要显示这个）');
  ok(/func paramKey\(from action: String\?\)/.test(backendSrc) || /paramKey\(from:/.test(backendSrc),
     '宿主能从站方 action 里抠出 paramKey（抠不出 ⇒ 空 ⇒ 走执行 action 那条路）');

  if (!engineAvailable()) {
    skip('没编译 legado-engine ⇒ 下面的【真跑段】没验到（**不等于通过**）');
    console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
    if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
    process.exit(fail ? 1 : 0);
  }

  console.log('\n=== 2. 能力探针：能不能真的跑一次站方 action ===');
  // ⭐⭐⭐ **两条路**（哪条能用走哪条）：
  //   ① 引擎的 conformance `--op filterAction`（= App 走的宿主 API 口径）
  //   ② swiftc 真编真跑**引擎自己的 `runFilterAction`**（= App 真正调的那个函数）
  let runAction = null, driver = null;
  const probe = runOp({
    op: 'filterAction',
    source: { bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针' },
    action: '1', title: '平台', value: '番茄',
  });
  if (probe && !/unknown op/.test(String(probe.error || ''))) {
    console.log('  ⇒ 走【引擎的 --op filterAction】');
    runAction = (payload) => runOp(Object.assign({
      op: 'filterAction',
      source: { bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针' },
    }, payload));
  } else {
    console.log('  ⇒ 引擎的 --op 还没开 filterAction ⇒ 改走【swiftc 直调引擎的 runFilterAction】');
    driver = buildSwiftDriver();
    if (driver && !driver.error) {
      runAction = (payload) => runFilterActionViaSwift(driver, payload);
    } else {
      skip('这台机器上编不了引擎的 Swift 驱动（'
           + (driver && driver.error ? driver.error : '没找到 swiftc / 引擎构建产物')
           + '）⇒ 下面的【真跑段】没验到');
      console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
      if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
      process.exit(fail ? 1 : 0);
    }
  }
  ok(true, '有办法真的跑站方 action（infoMap 那把钥匙）');

  console.log('\n=== 3. 真跑：引擎把【标题=选中值】塞进 infoMap ⇒ 站方 action 读得到 ===');
  {
    // ⭐⭐⭐ 用一段「会自己检查 infoMap」的站方 action：
    //   读不到 / 读错 ⇒ 抛 ⇒ 引擎把错误带回来（ok=false）⇒ **有判别力** ⭐⭐⭐
    const action = "(function(){ var v = infoMap ? infoMap['平台'] : null; "
      + "if (v === undefined || v === null) { throw new Error('infoMap 里没有【平台】'); } "
      + "if (String(v) !== '番茄') { throw new Error('infoMap 的值不是选中的那个：' + String(v)); } "
      + "return ''; })()";
    const good = await runAction({ action, title: '平台', value: '番茄' });
    ok(good && good.ok, '站方 action 读到了 infoMap["平台"] = 选中值', good && good.error);
    // ⭐⭐⭐ **反证**：标题给错 ⇒ 站方读不到 ⇒ 必须红（证明上面那条不是恒真）⭐⭐⭐
    const bad = await runAction({ action, title: '不是平台', value: '番茄' });
    ok(bad && bad.ok === false, '反证：标题给错 ⇒ 站方 action 失败（检查有判别力）',
       JSON.stringify(bad && bad.ok));
  }

  console.log('\n=== 4. 活体：NovelHub 的「平台」筛选项能不能切 ===');
  const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
  if (!fs.existsSync(NH)) {
    skip('本地没有 NovelHub 源文件 ⇒ 本段没验到（**不等于通过**）');
  } else {
    const NHsrc = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];
    // ⭐ 已解锁的源级变量（否则 nhAuth() 恒 false ⇒ 一个分类都没有）
    const authVars = JSON.stringify({ nhAuthed: PWD_HASH });

    const ex = runOp({
      op: 'exploreKinds',
      source: Object.assign({}, NHsrc, { __variables: authVars, __loginInfo: '{}' }),
    });
    const filters = (ex && ex.filters) || [];
    const kinds = (ex && ex.kinds) || [];
    console.log('  filters:', filters.length, '| kinds:', kinds.length);
    ok(filters.length > 0, '筛选项能解析出来');
    const plat = filters.find(f => f && f.title === '平台');
    ok(!!plat, '有「平台」筛选项');

    // ⭐⭐⭐ **从站方源文件里抠出「平台」这一项的 action**（不写死实现）⭐⭐⭐
    const action = extractFilterAction(String(NHsrc.exploreUrl || ''), '平台');
    ok(!!action, '站方源文件里能抠出「平台」筛选栏的 action 表达式');
    ok(/infoMap\['平台'\]/.test(action),
       '站方 action 确实读 infoMap["平台"]（⇒ 宿主必须按【标题】塞进去）');
    ok(/source\.setVariable/.test(action),
       '站方 action 自己写源级变量（⇒ 宿主不写变量，让站方写）');

    if (plat && action) {
      // 选一个真存在的平台（不是第一个，避免跟默认值撞上）
      const target = '番茄';
      const act = await runAction({
        action, title: '平台', value: target,
        sourceUrl: String(NHsrc.bookSourceUrl || ''),
      });
      const dirty = String((act && act.vars) || '');
      console.log('  切平台后引擎里的变量 =', dirty.slice(0, 160));
      ok(act && act.ok, '站方 action 跑通了', act && act.error);
      ok(dirty.indexOf('"src":"' + target + '"') >= 0,
         '**站方把选中的平台写进源级变量了**（⇒ 原生落盘 ⇒ 下次打开还是这个平台）',
         dirty.slice(0, 160));

      // 端到端：把落盘的变量喂回去 ⇒ 站方重跑后**分类应该按新平台变了**
      //
      // ⚠️ 不能断言「站方给的 default 变了」—— 站方（🍒NovelHub）的 default 恒为
      //    `nhPlatChars()[0]`（第一个），**不是当前值** ⇒ 拿它当判据必假红
      //    （胶囊上的当前值由宿主自己记，见 SourceVariables.filterChoice）
      const merged = JSON.stringify(Object.assign({}, JSON.parse(authVars), JSON.parse(dirty || '{}')));
      const ex2 = runOp({
        op: 'exploreKinds',
        source: Object.assign({}, NHsrc, { __variables: merged, __loginInfo: '{}' }),
      });
      const before = kinds.map(k => k.title).join('|');
      const after = ((ex2 && ex2.kinds) || []).map(k => k.title).join('|');
      ok(after.length > 0, '切完平台后分类还在');
      ok(after !== before,
         '**切平台真的生效了**（站方按新平台返回了不同的分类）',
         '切前 ' + before.length + ' 字 / 切后 ' + after.length + ' 字');
      ok(((ex2 && ex2.kinds) || []).length !== kinds.length,
         '切前后的分类数量不一样（书旗 799 → 番茄 280 这种）',
         '切前 ' + kinds.length + ' / 切后 ' + ((ex2 && ex2.kinds) || []).length);
    }
  }

  if (driver && driver.dir) { try { fs.rmSync(driver.dir, { recursive: true, force: true }); } catch (e) {} }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
