#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：站方 exploreUrl 的分类归一化 —— 旧引擎 JS ⇔ 新 Swift 双实现对拍**
 *
 * 为什么要这道门禁（2026-11-19 真机 build296 实证）：
 *   真机报「发现页：未能完成操作。（LegadoEngine.LegadoError 错误 1。）」
 *   引擎日志：`新引擎跑「explore」失败：url 解析失败:`（**冒号后为空**）
 *   ⇒ 根因 = `LegadoEngine.exploreKinds` **静态**读 `source.exploreUrl`、**从不求值 `@js:`**
 *     ⇒ NovelHub 的 `@js:` 薄壳被当静态文本切开 ⇒ 分类 url 为空 ⇒ `AnalyzeUrl` 抛「url 解析失败:」
 *   ⇒ 修法 = 宿主层补「先求值 `@js:`」的能力（照抄**已删旧引擎** `engine.js` 的 `exploreKinds` 语义）
 *
 * ⭐ **权威规格 = 已删的旧引擎**（git `0b5c481^:QiReaderLite/Resources/engine/engine.js`
 *   的 `normalizeKinds` / `filterParamKey`，+ `jsoup-compat.js` 的 `absolutize`）
 *   ⇒ 本门禁把那三个函数**原样抽出来**当 oracle ⇒ 新 Swift 实现必须**逐字段一致** ⭐⭐⭐
 *
 * ⭐⭐⭐ **Swift 侧怎么验（关键设计）**：
 *   **不写第二份 Swift 实现**（⇒ 必然漂）⇒ 而是**直接编 App 的真文件**
 *   `QiReaderLite/Core/LegadoEngineBackend.swift` ⇒ 里面的 `normalizeKinds` 等
 *   **就是 App 真跑的那份** ⇒ 改 App ⇒ 这里自动跟着变 ⇒ 永不漂 ⭐⭐⭐
 *   ⚠️ Linux 上 `#if canImport(JavaScriptCore)` 那段被排除 ⇒ 但**归一化函数是纯 Swift**
 *     ⇒ 照样能编能跑 ⇒ **3 秒反馈**（不用等 CI 5 分钟）⭐⭐⭐
 *
 * ⚠️ **为什么必须双实现对拍、而不是自己写断言**：
 *   「照抄旧引擎」最危险的失败模式 = **自以为抄对了，其实抄歪了**
 *   ⇒ 唯一能证伪的办法 = 同一批 fixture 喂两套实现 ⇒ 结果逐字段比 ⭐⭐⭐
 *
 * 用法：
 *   node test/explore-kinds-parity.js              # 跑对拍
 *   node test/explore-kinds-parity.js --mutate     # 变异对照（改坏 Swift 侧 ⇒ 必须红）
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
// ⭐⭐⭐ **Swift 侧 = App 的真文件**（独立成文件 ⇒ 只依赖 Foundation ⇒ 沙盒能编能跑）
const NORMALIZER_FILE = path.join(ROOT, 'QiReaderLite/Core/ExploreKindsNormalizer.swift');

// ── ① Oracle：从 git 历史里抽旧引擎的三个函数 ────────────────────────────
function gitShow(spec) {
  return execFileSync('git', ['show', spec], {
    cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
}

/** 从一段 JS 源码里按花括号配平抽出一个函数定义 */
function grabFunction(src, name) {
  const i = src.indexOf('function ' + name + '(');
  if (i < 0) throw new Error('oracle 里找不到函数 ' + name);
  let j = src.indexOf('{', i), depth = 0, k = j;
  while (k < src.length) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) break; }
    k++;
  }
  return src.slice(i, k + 1);
}

function buildOracle() {
  const engineJS = gitShow('0b5c481^:QiReaderLite/Resources/engine/engine.js');
  const jsoupJS = gitShow('0b5c481^:QiReaderLite/Resources/engine/jsoup-compat.js');
  return [
    grabFunction(engineJS, 'normalizeKinds'),
    grabFunction(engineJS, 'filterParamKey'),
    grabFunction(jsoupJS, 'protect'),
    grabFunction(jsoupJS, 'absolutize'),
  ].join('\n\n');
}

// ── ② Fixture：覆盖旧引擎 normalizeKinds 的每一条分支 ────────────────────
// ⚠️ 这些 case 是**照着旧引擎源码的分支**设计的（不是拍脑袋）
//   ① 对象项 + 有 url        ⇒ 分类
//   ② 对象项 + url 为空      ⇒ **组标题行**（不输出成分类）
//   ③ type:"select"          ⇒ **筛选栏**（不是分类）
//   ④ 字符串项 `标题::url`   ⇒ 分类
//   ⑤ 字符串项无 `::`        ⇒ **组标题**（装饰符号剥掉）
//   ⑥ style 是对象           ⇒ style 存 JSON 串
//   ⑦ 相对路径 / `{{page}}`  ⇒ absolutize 的占位保护
//   ⑧ `--` 垃圾行            ⇒ 不当组标题
//   ⑨ 站方自带 group 字段    ⇒ 优先于累积的 group
const BASE = 'https://host.example';
const FIXTURE = [
  {
    name: '混排：分类 + 组标题 + 筛选栏（站方真实形态）',
    base: BASE,
    input: [
      { title: '📚 全部', url: 'https://host.example/all/fl/1/', style: { layout_flexGrow: 1 } },
      { title: '○ *。*☆ 排行榜 ☆*。* ○', style: { layout_flexBasisPercent: 1 } },
      { title: '总排行', url: 'https://host.example/rank/allvisit/1/', style: { layout_flexBasisPercent: 0.25 } },
      { title: '平台', type: 'select', chars: ['书旗', '番茄', '七猫'], default: '书旗',
        action: "show(infoMap['平台'],'find_source')", style: { layout_flexBasisPercent: 0.33 } },
      { title: '当前为: QQ阅读 [小说]频道：男频', style: { layout_flexBasisPercent: 1 } },
      { title: '玄幻', url: 'https://host.example/f/xh/' },
      { title: '--', style: { layout_flexBasisPercent: 1 } },
      { title: '相对路径', url: '/rel/path' },
      { title: '带页码', url: 'https://host.example/list?p={{page}}' },
      // ⭐⭐⭐ **相对路径 + {{page}}** ⇒ absolutize 的【占位保护】真正生效的那条路径
      //   （绝对 URL 走协议白名单**提前返回** ⇒ 占位不会被编码 ⇒ 不测它）⭐⭐⭐
      { title: '相对带页码', url: '/rel/list?p={{page}}' },
    ],
  },
  {
    name: '纯文本两行式（`标题::url` + 组标题）',
    base: BASE,
    input: '玄幻::https://host.example/xh\n☆热门☆\n仙侠::https://host.example/xx',
  },
  {
    name: 'JSON 字符串形态（站方返回字符串而非数组）',
    base: BASE,
    input: JSON.stringify([
      { title: 'A', url: 'https://host.example/a' },
      { title: 'B', type: 'select', chars: 'x,y', default: 'x', action: "show('平台','find_tab')" },
    ]),
  },
  {
    name: 'select 的 chars 是字符串（逗号分隔）',
    base: BASE,
    input: [{ title: '模式', type: 'select', chars: '小说,听书,短剧', default: '小说', action: "show(infoMap['模式'],'find_tab')" }],
  },
  {
    name: '站方自带 group 字段（优先于累积的 group）',
    base: BASE,
    input: [
      { title: '组A', style: { a: 1 } },
      { title: '带组', url: 'https://host.example/g', group: '站方给的组' },
    ],
  },
  {
    name: '空数组',
    base: BASE,
    input: [],
  },
];

// ── ③ 跑 oracle ───────────────────────────────────────────────────────
function runOracle(fixture) {
  const vm = require('vm');
  const sandbox = { JSON, String, Array, Object, Math, RegExp, console, URL };
  vm.createContext(sandbox);
  // ⚠️ 旧引擎的 normalizeKinds 里用 `dom.absolutize(...)` ⇒ 造个 dom 垫片
  vm.runInContext(buildOracle()
    + '\n;var dom = { absolutize: absolutize };'
    + '\n;globalThis.__nk = normalizeKinds; globalThis.__fp = filterParamKey;', sandbox);
  const nk = sandbox.__nk;

  // ⚠️⚠️ **旧引擎的字符串形态解析在 `exploreKinds` 里，不在 `normalizeKinds` 里**
  //   （跑完 JS 后，若结果是字符串 ⇒ ① 以 `[`/`{` 开头 ⇒ JSON.parse
  //      ② 否则按 (&&|\n)+ 切 ⇒ `标题::url` 两行式）
  //   ⇒ 这段**必须一起当 oracle** ⇒ 否则「字符串形态」这条分支就没有对照物 ⭐⭐⭐
  let arr = fixture.input;
  if (typeof arr === 'string') {
    const t = arr.trim();
    if (t.startsWith('[') || t.startsWith('{')) {
      try { arr = JSON.parse(t); } catch (e) { arr = []; }
    } else {
      arr = t.split(/(&&|\n)+/).map((l) => String(l).trim()).filter(Boolean)
        .map((l) => { const q = l.split('::'); return { title: q[0], url: q[1] || '' }; });
    }
  }
  const out = nk(arr, fixture.base);
  return {
    kinds: (out.kinds || []).map((k) => ({
      title: String(k.title ?? ''), url: String(k.url ?? ''),
      style: String(k.style ?? ''), group: String(k.group ?? ''),
    })),
    filters: (out.filters || []).map((f) => ({
      title: String(f.title ?? ''), type: String(f.type ?? ''),
      chars: (f.chars || []).map((c) => String(c)),
      default: String(f.default ?? ''),
      // ⚠️ 旧引擎的 normalizeKinds **自己**就算 paramKey（`paramKey: filterParamKey(k)`）
      //   ⇒ 这里**不许**在外面再算一遍 ⇒ 否则 oracle 是假象 ⭐⭐⭐
      paramKey: String(f.paramKey ?? ''), action: String(f.action ?? ''),
    })),
  };
}

// ── ④ 跑新 Swift 实现（直接编 App 的真文件 ⇒ 永不漂）────────────────────
// ⚠️ App 文件 import LegadoEngine / 依赖一堆宿主类型 ⇒ 这里**只抽归一化那几段**
//   但抽取方式 = **按方法边界切**（不是整文件）⇒ 抽出来的就是 App 真代码的逐字副本 ⭐⭐⭐
const SWIFT_ENTRY = `
import Foundation

struct Shim {
    static func main() {
        let path = CommandLine.arguments[1]
        let data = FileManager.default.contents(atPath: path)!
        let fixture = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var results: [[String: Any]] = []
        for f in fixture {
            let name = f["name"] as! String
            let base = f["base"] as! String
            let input = f["input"]!
            let norm = ExploreKindsNormalizer.normalizeKinds(input, baseUrl: base)
            results.append([
                "name": name,
                "kinds": norm.kinds.map { k -> [String: Any] in
                    var o: [String: Any] = [:]
                    for key in ["title", "url", "style", "group"] { o[key] = k[key] ?? "" }
                    return o
                },
                "filters": norm.filters.map { f -> [String: Any] in
                    var o: [String: Any] = [:]
                    for key in ["title", "type", "chars", "default", "paramKey", "action"] { o[key] = f[key] ?? "" }
                    return o
                },
            ])
        }
        let out = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(out)
    }
}
Shim.main()
`;

/** ⭐⭐⭐ **Swift 侧 = 直接编 App 的真文件**（不是抽取 ⇒ 永不漂）⭐⭐⭐ */
function swiftSource() {
  // ⚠️ `ExploreKindsNormalizer.swift` 只依赖 Foundation ⇒ 沙盒能独立编 ⭐⭐⭐
  return fs.readFileSync(NORMALIZER_FILE, 'utf8');
}

function runSwift(fixturePath) {
  const shimPath = path.join(os.tmpdir(), 'nh-explore-kinds-shim.swift');
  // ⭐⭐⭐ **编 App 的真文件**（不是抽取的副本 ⇒ 改 App 这里自动跟着变 ⇒ 永不漂）⭐⭐⭐
  fs.writeFileSync(shimPath, swiftSource() + '\n' + SWIFT_ENTRY, 'utf8');
  const bin = path.join(os.tmpdir(), 'nh-explore-kinds-parity');
  try { fs.unlinkSync(bin); } catch (e) {}
  execFileSync('swiftc', ['-O', '-swift-version', '5', shimPath, '-o', bin], {
    stdio: 'pipe', maxBuffer: 64 * 1024 * 1024,
  });
  const out = execFileSync(bin, [fixturePath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(out);
}

// ── ⑤ 比对 ────────────────────────────────────────────────────────────
const canonKinds = (kinds) => kinds.map((k) => ({
  title: String(k.title ?? ''), url: String(k.url ?? ''),
  style: String(k.style ?? ''), group: String(k.group ?? ''),
}));
const canonFilters = (filters) => filters.map((f) => ({
  title: String(f.title ?? ''), type: String(f.type ?? ''),
  chars: (f.chars ?? []).map((c) => String(c)),
  default: String(f.default ?? ''),
  paramKey: String(f.paramKey ?? ''), action: String(f.action ?? ''),
}));

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const MUTATE = process.argv.includes('--mutate');

console.log('=== 1. Oracle 抽取（git 里的旧引擎）===');
let oracleOK = true;
try { buildOracle(); ok(true, '旧引擎 normalizeKinds / filterParamKey / absolutize 抽出来了'); }
catch (e) { oracleOK = false; ok(false, 'oracle 抽取失败', String(e.message || e)); }
if (!oracleOK) { console.log('\n基线坏了 ⇒ 停'); process.exit(1); }

const fixturePath = path.join(os.tmpdir(), 'nh-explore-kinds-fixture.json');
fs.writeFileSync(fixturePath, JSON.stringify(FIXTURE), 'utf8');

console.log('\n=== 2. 双实现对拍（同一批 fixture）===');
const oracleResults = FIXTURE.map((f) => ({ name: f.name, ...runOracle(f) }));
let swiftResults;
try {
  swiftResults = runSwift(fixturePath);
  ok(true, '新 Swift 实现跑起来了（编的是 App 真文件的逐字副本）');
} catch (e) {
  ok(false, '新 Swift 实现编译/运行失败', String(e.stderr || e).slice(0, 1500));
  console.log('\n通过 ' + pass + ' / 失败 ' + fail);
  process.exit(1);
}

ok(oracleResults.length === swiftResults.length, `case 数一致（${oracleResults.length}）`);

for (let i = 0; i < Math.max(oracleResults.length, swiftResults.length); i++) {
  const o = oracleResults[i], s = swiftResults[i];
  if (!o || !s) { ok(false, `case #${i} 缺失`); continue; }
  const okKinds = JSON.stringify(canonKinds(o.kinds)) === JSON.stringify(canonKinds(s.kinds));
  const okFilters = JSON.stringify(canonFilters(o.filters)) === JSON.stringify(canonFilters(s.filters));
  ok(okKinds && okFilters, `case「${o.name}」分类+筛选栏与旧引擎逐字段一致`,
     okKinds ? ('筛选栏不一致：\n  旧=' + JSON.stringify(canonFilters(o.filters)) + '\n  新=' + JSON.stringify(canonFilters(s.filters)))
             : ('分类不一致：\n  旧=' + JSON.stringify(canonKinds(o.kinds)) + '\n  新=' + JSON.stringify(canonKinds(s.kinds))));
}

console.log('\n=== 3. 关键语义钉死（防「对拍全绿但语义错」）===');
{
  const r = oracleResults[0], s = swiftResults[0];
  const oK = canonKinds(r.kinds), sK = canonKinds(s.kinds);
  const oF = canonFilters(r.filters), sF = canonFilters(s.filters);

  ok(!oK.some((k) => k.title === '平台') && !sK.some((k) => k.title === '平台'),
     '筛选栏项（平台）没混进分类');
  ok(oF.length === 1 && sF.length === 1, `筛选栏 1 项（旧=${oF.length} 新=${sF.length}）`);
  ok(sF[0] && sF[0].paramKey === 'find_source', `paramKey = find_source（实得「${sF && sF[0] ? sF[0].paramKey : '无'}」）`);
  ok(!sK.some((k) => k.title === '○ *。*☆ 排行榜 ☆*。* ○'), '组标题行没被当成分类');
  const rank = sK.find((k) => k.title === '总排行');
  ok(rank && rank.group === '○ *。*☆ 排行榜 ☆*。* ○', `分类项继承组标题（实得「${rank ? rank.group : '无'}」）`);
  const pg = sK.find((k) => k.title === '带页码');
  ok(pg && pg.url.indexOf('{{page}}') >= 0, `{{page}} 占位保住了（实得「${pg ? pg.url : '无'}」）`);
  // ⭐⭐⭐ **相对路径**那条才是占位保护的真路径（绝对 URL 走白名单提前返回）
  const pgRel = sK.find((k) => k.title === '相对带页码');
  ok(pgRel && pgRel.url.indexOf('{{page}}') >= 0,
     `相对路径的 {{page}} 占位保住了（实得「${pgRel ? pgRel.url : '无'}」）`);
  const last = sK[sK.length - 1];
  ok(last && last.group !== '--', '「--」没被当成组标题');
  // 站方自带 group 优先
  const own = (swiftResults[4] && canonKinds(swiftResults[4].kinds).find((k) => k.title === '带组'));
  ok(own && own.group === '站方给的组', `站方自带 group 优先（实得「${own ? own.group : '无'}」）`);
}

console.log('\n=== 4. 变异对照（改坏 Swift 侧 ⇒ 必须红）===');
if (MUTATE) {
  const orig = fs.readFileSync(NORMALIZER_FILE, 'utf8');
  const cases = [
    ['筛选栏项不再分流（type:select 当普通分类）',
      (t) => t.replace('if ktype == "select" {', 'if false {')],
    ['paramKey 抠不出来（恒返回空串）',
      (t) => t.replace('if let v = Self.secondQuotedArg(in: action, pattern: #"infoMap',
                       'if let v: String? = nil, _ = action, false { let _ = #"infoMap')],
    ['{{page}} 占位不再保护',
      (t) => t.replace('holes.append(String(u[i..<close.upperBound]))', 'holes.append("")')],
    ['组标题行不再被识别（url 空也当分类）',
      (t) => t.replace('if objURL.isEmpty {', 'if false {')],
    ['站方自带 group 不再优先',
      (t) => t.replace('"group": ownGroup.isEmpty ? group : ownGroup]', '"group": group]')],
  ];
  try {
    for (const [name, fn] of cases) {
      const mutated = fn(orig);
      if (mutated === orig) { ok(false, `变异「${name}」：锚点命中`, '锚点没命中 ⇒ 变异无效'); continue; }
      fs.writeFileSync(NORMALIZER_FILE, mutated, 'utf8');
      let red = false;
      try {
        const res = runSwift(fixturePath);
        for (let i = 0; i < Math.max(res.length, oracleResults.length); i++) {
          const a = oracleResults[i], b = res[i];
          if (!a || !b) { red = true; break; }
          if (JSON.stringify(canonKinds(a.kinds)) !== JSON.stringify(canonKinds(b.kinds))) { red = true; break; }
          if (JSON.stringify(canonFilters(a.filters)) !== JSON.stringify(canonFilters(b.filters))) { red = true; break; }
        }
      } catch (e) { red = true; }
      ok(red, `变异「${name}」⇒ 对拍变红`, red ? '' : '变异后仍然一致 ⇒ 这条断言是摆设');
    }
  } finally {
    fs.writeFileSync(NORMALIZER_FILE, orig, 'utf8');
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
