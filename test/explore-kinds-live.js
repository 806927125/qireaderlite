#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **端到端验证：真实 NovelHub 源 ⇒ 走【新引擎的 exploreKinds 路径】⇒ 出分类**
 *
 * ⚠️ **为什么要有它**（2026-11-19 真机 build296 实证）：
 *   真机报「发现页：未能完成操作。（LegadoEngine.LegadoError 错误 1。）」
 *   引擎日志：`新引擎跑「explore」失败：url 解析失败:`（冒号后为空）
 *   ⇒ 根因 = 新引擎的 `exploreKinds` **静态**读 exploreUrl、**从不求值 `@js:`** ⭐⭐⭐
 *   ⇒ 修法 = 宿主层补「先求值 `@js:`」
 *
 * ⭐⭐⭐ **本脚本验的是【端到端】，不是单元语义**：
 *   · 真的加载**产物里的 jsLib**（1.1MB，含站方 helper）
 *   · 真的跑**产物里的 exploreUrl**（`@js:` 薄壳）
 *   · 真的喂**宿主 API 垫片**（java.ajax / source.getVariable / infoMap …）
 *   ⇒ 证明「修完之后，发现页真的能出分类」⭐⭐⭐
 *
 * ⚠️ **和 jsdom/Node 的差异（诚实边界）**：
 *   · Node 不是 JSC ⇒ **Rhino 兼容 shim 不生效** ⇒ 站方 JS 里的 Rhino 写法可能报错
 *   · `java.ajax` 在 Node 里是**异步**的，而新引擎里是**同步**（`requestSync`）
 *     ⇒ 本脚本用同步垫片（child_process 同步跑 curl）来对齐引擎语义 ⭐⭐⭐
 *   ⇒ 结论分两层：**① 归一化语义**由 `explore-kinds-parity.js` 对拍证明；
 *     **② 能不能真跑出分类**由本脚本证明 ⇒ 两层合起来才完整 ⭐⭐⭐
 *
 * 用法：node test/explore-kinds-live.js <产物.json>
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const vm = require('vm');

const SRC = process.argv[2] || '/workspace/output/NovelHub聚合小说-轻阅新引擎适配.json';
const pack = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const source = Array.isArray(pack) ? pack[0] : pack;

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

// ── ① 宿主垫片：按【新引擎 JSBridge 的语义】造 ──────────────────────────
// ⭐ `java.ajax` = **同步**（引擎里是 requestSync）⇒ 用同步子进程跑 curl ⭐⭐⭐
const shim = `
var __httpCache = {};
function __syncGet(url) {
  if (__httpCache[url] !== undefined) return __httpCache[url];
  var out = '';
  try {
    out = require('child_process').execFileSync('curl', ['-sS', '-m', '20', '-A',
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
      url], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) { out = ''; }
  __httpCache[url] = out;
  return out;
}
var java = {
  ajax: function (url) { return __syncGet(String(url)); },
  log: function (m) {},
  toast: function (m) {},
  longToast: function (m) {},
  md5Encode: function (s) { return String(s); },
  timeFormat: function (n) { return String(n); },
  base64Encode: function (s) { return Buffer.from(String(s), 'utf8').toString('base64'); },
  base64Decode: function (s) { return Buffer.from(String(s), 'base64').toString('utf8'); },
  hexDecodeToString: function (s) { return String(s); },
  deviceID: function () { return 'probe-device'; },
  androidId: function () { return 'probe-android'; },
  startBrowserAwait: function () {},
  showBrowser: function () {},
  openVideoPlayer: function () {},
  refreshExplore: function () {},
  webViewUA: function () { return 'Mozilla/5.0'; }
};
var cookie = {
  getCookie: function () { return ''; },
  setCookie: function () {},
  removeCookie: function () {}
};
var cache = { put: function () {}, get: function () { return ''; } };
`;

// ── ② 宿主 source 对象：按【引擎 bootstrap 的 __mkSource 语义】造 ─────────
function makeSource(varsJson) {
  // ⭐⭐⭐⭐⭐ **两格独立**（模拟真实：站方变量那格 ≠ 书籍变量那格）⭐⭐⭐
  //   `vars` = **书籍变量**那格（引擎的 RuleVariables map）
  //   `stationVariable` = **站方变量**那格（引擎的 BookSource.variable）⭐⭐⭐
  let vars = varsJson ? JSON.parse(varsJson) : {};
  // ⭐⭐⭐ **站方的登录门**：`nhAuth()` 要求 `source.get("nhAuthed")` == `NH_PWD_HASH`
  //   ⇒ 没登录 ⇒ exploreUrl **主动降级返空**（不是 bug ⇒ 是站方的设计）⭐⭐⭐
  //   ⇒ 本脚本要验「求值 + 归一化」这条路 ⇒ 必须给登录态 ⭐⭐⭐
  //   （`NH_PWD_HASH` 从**产物自己的 jsLib** 里读 ⇒ 不写死 ⇒ 换源也准）⭐⭐⭐
  const m = /var NH_PWD_HASH\s*=\s*"([^"]+)"/.exec(source.jsLib || '');
  if (m && vars.nhAuthed === undefined) { vars.nhAuthed = m[1]; }
  // ⭐⭐⭐⭐⭐ **站方变量那一格**（宿主灌进引擎 `BookSource.variable` 的那份 JSON 对象串）⭐⭐⭐
  //   ⚠️⚠️⚠️ **早先这个脚本是「手工往 source.get 的 map 里塞 nhAuthed」** ⇒ 那是**假接线** ⭐⭐⭐
  //     ⇒ 掩盖了真机故障（真机 0 分类的根因正是「宿主灌的那格、引擎压根不读」）⭐⭐⭐
  //     ⇒ 现在：**整格灌进 `variable`** ⇒ `source.get` 从 `variable` 里读 ⇒ 与真机同构 ⭐⭐⭐
  // ⭐⭐⭐⭐⭐ **两格必须【独立】**（2026-11-19 实证）：
  //   早先把 `stationVariable` 和 `vars` 设成同一份 ⇒ 无论从哪读都一样
  //   ⇒ 变异「读错的格」**照样绿** ⇒ 端到端门禁**抓不到真机故障** ⇒ 门禁是摆设 ⭐⭐⭐
  //   ⇒ 正解：**站方变量那格独立**（只放站方变量；书籍变量那格空）
  //     ⇒ 「读错的格」必然读不到 nhAuthed ⇒ 门禁当场红 ⭐⭐⭐
  // ⭐⭐⭐ **站方变量那格**（宿主灌进引擎 `BookSource.variable` 的那份）⭐⭐⭐
  //   ⚠️⚠️⚠️ **必须与 `vars`（书籍变量那格）独立**（2026-11-19 实证）：
  //     早先两者是同一份 ⇒ 无论从哪读都一样 ⇒ 变异「读错的格」照样绿
  //     ⇒ **端到端门禁抓不到真机故障** ⇒ 门禁是摆设 ⭐⭐⭐
  //   ⇒ 现在：`vars` 只放**书籍变量**（真实场景里书源变量 map 另有一格）
  // ⭐⭐⭐⭐⭐ **书籍变量那格【不许含 nhAuthed】**（否则读错格也读得到 ⇒ 变异抓不到）⭐⭐⭐
  //   ⇒ 真实场景：书籍变量 = 书/用户级变量；站方变量 = 书源级变量 ⇒ **两格内容不同** ⭐⭐⭐
  // ⭐⭐⭐⭐⭐ **模拟【宿主真实的合并接线】**（2026-11-19 真机 build297/298 实证）⭐⭐⭐
  //
  //   ⚠️⚠️⚠️ **引擎只有一格 `BookSource.variable`（一个 JSON map）**，而站方**两格混用** ⭐⭐⭐
  //     · `source.get("nhAuthed")` / `source.put(k,v)` ⇒ **map 的某一项** ⭐⭐⭐
  //     · `source.getVariable()` / `source.setVariable(str)` ⇒ **整份 map 的 JSON 串** ⭐⭐⭐
  //   ⇒ 宿主必须把【书籍变量 map 的项】+【站方变量整串的项】**合并成一份 map** 灌进去 ⭐⭐⭐
  //   ⇒ `nhAuthed` 在**书籍变量那格** ⇒ 只灌「站方整串」⇒ 读不到 ⇒ **交白卷**（真机症状）⭐⭐⭐
  //
  //   ⭐⭐⭐ **两格必须【内容不同】**（否则「读错的格」照样读得到 ⇒ 变异抓不到 ⇒ 门禁没牙齿）⭐⭐⭐
  //     · 书籍变量那格：`{ nhAuthed:<hash>, nhPlatSwitch:'' }`  ← `source.get/put` 的项 ⭐⭐⭐
  //     · 站方变量那格：`{ src:'书旗', gender:'全部', ... }`   ← `source.getVariable()` 的内容 ⭐⭐⭐
  const bookVarsOnly = { nhAuthed: vars.nhAuthed, nhPlatSwitch: '' };
  const stationOnly = { src: '书旗', gender: '全部', status: '不限', sort: '最热', line: '自动' };
  vars = bookVarsOnly;                                // 书籍变量那格（**含 nhAuthed**）
  // ⭐ **合并成一份 map**（= 宿主灌进引擎 `variable` 的那份）⇒ 与真机同构 ⭐⭐⭐
  let stationVariable = JSON.stringify(Object.assign({}, stationOnly, bookVarsOnly));
  const src = {
    bookSourceUrl: source.bookSourceUrl || '',
    bookSourceName: source.bookSourceName || '',
    getKey: function () { return this.bookSourceUrl; },
    // ⭐⭐⭐ **引擎语义**：`srcGet`/`srcPut` 读写的是 **`variable` 那一格**（不是别处）⭐⭐⭐
    getVariable: function () { return stationVariable; },
    setVariable: function (v) {
      stationVariable = String(v == null ? '' : v);
      try { vars = JSON.parse(stationVariable) || {}; } catch (e) { vars = {}; }
    },
    putVariable: function (v) { this.setVariable(v); },
    get: function (k) {
      /*__VAR_CHANNEL__*/
      try {
        const o = JSON.parse(stationVariable || '{}');
        return o[String(k)] === undefined ? '' : String(o[String(k)]);
      } catch (e) { return ''; }
    },
    put: function (k, v) {
      try {
        const o = JSON.parse(stationVariable || '{}');
        o[String(k)] = String(v);
        stationVariable = JSON.stringify(o);
        vars = o;
        return String(v);
      } catch (e) { return ''; }
    },
    getLoginInfoMap: function () { return {}; },
    getLoginInfo: function () { return ''; },
    putLoginInfo: function () {},
    getTag: function () { return this.bookSourceName; },
    refreshExplore: function () {},
    getHeaderMap: function () { return {}; },
    evalJS: function (s) { return eval(String(s)); }
  };
  return src;
}

// ── ③ 组装沙箱：jsLib + 垫片 + source ────────────────────────────────────
function runExploreUrl(varsJson) {
  const sandbox = {
    console, JSON, String, Number, Boolean, Array, Object, Math, RegExp, Date,
    Error, TypeError, RangeError, parseInt, parseFloat, isNaN, isFinite,
    encodeURIComponent, decodeURIComponent, encodeURI, decodeURI,
    Buffer, require, setTimeout, clearTimeout, URL, URLSearchParams,
    Promise, Map, Set, Symbol, Proxy, Reflect,
  };
  vm.createContext(sandbox);
  try { vm.runInContext(shim, sandbox); } catch (e) { /* 垫片失败不致命 */ }

  // ⭐⭐⭐ **infoMap**：新引擎里是 UserDefaults 存的一格（`infoMapGet`/`infoMapPut`）
  const infoMap = { '平台': '书旗', '📚类型': '📖小说' };
  sandbox.infoMap = infoMap;
  sandbox.infoMap.get = function () { return undefined; };
  sandbox.infoMap.put = function (k, v) { infoMap[String(k)] = String(v); };

  const src = makeSource(varsJson);
  sandbox.source = src;

  // ⭐⭐⭐ **加载产物里的 jsLib**（真实站方 helper 都在里面）
  const jsLib = source.jsLib || '';
  try {
    vm.runInContext(jsLib, sandbox, { filename: 'jsLib' });
  } catch (e) {
    return { error: 'jsLib 加载失败: ' + (e && e.message), kinds: [], filters: [] };
  }

  // ⭐ 跑**产物里的 exploreUrl**（`@js:` 薄壳）
  const spec = source.exploreUrl || '';
  if (!/^\s*@js:/i.test(spec)) {
    return { error: 'exploreUrl 不是 @js: 形态（无法验这条路）', kinds: [], filters: [] };
  }
  const code = spec.replace(/^\s*@js:/i, '');
  let raw;
  try {
    raw = vm.runInContext(code, sandbox, { filename: 'exploreUrl' });
  } catch (e) {
    return { error: 'exploreUrl 求值失败: ' + (e && e.message), kinds: [], filters: [] };
  }
  return { raw, kinds: [], filters: [] };
}

// ── ④ 归一化：用【Swift 那份的同源逻辑】——直接跑编译好的 Swift 产物 ──────
function normalizeViaSwift(raw) {
  // ⚠️ 复用门禁编译出来的 Swift 二进制（App 真文件）⇒ 语义与 App 完全一致 ⭐⭐⭐
  const bin = path.join(os.tmpdir(), 'nh-explore-kinds-parity');
  if (!fs.existsSync(bin)) return null;
  const fx = [{ name: 'live', base: source.bookSourceUrl || '', input: raw }];
  const fxPath = path.join(os.tmpdir(), 'nh-live-fixture.json');
  fs.writeFileSync(fxPath, JSON.stringify(fx), 'utf8');
  const out = execFileSync(bin, [fxPath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const arr = JSON.parse(out);
  return arr[0];
}

console.log('=== 1. 准备（编译 Swift 归一化器）===');
try {
  // ⚠️⭐⭐⭐ **Swift 顶层代码入口必须叫 main.swift** ⇒ 复制成一份再编
  //   （SwiftPM 的 `main.swift` 规则；文件名不对 ⇒ 报「statements are not allowed at the top level」）⭐⭐⭐
  const shimDir = fs.mkdtempSync(path.join(os.tmpdir(), 'nh-live-'));
  fs.copyFileSync(path.join(__dirname, 'main.swift'), path.join(shimDir, 'main.swift'));
  execFileSync('swiftc', ['-O', '-swift-version', '5',
    path.join(__dirname, '..', 'QiReaderLite/Core/ExploreKindsNormalizer.swift'),
    path.join(shimDir, 'main.swift'),
    '-o', path.join(os.tmpdir(), 'nh-explore-kinds-parity')], { stdio: 'pipe' });
  ok(true, 'Swift 归一化器编好了');
} catch (e) {
  ok(false, 'Swift 归一化器编译失败', String(e.stderr || e).slice(0, 800));
  console.log('\n通过 ' + pass + ' / 失败 ' + fail);
  process.exit(1);
}

console.log('\n=== 2. 真实跑站方 exploreUrl（产物里的 jsLib + @js: 薄壳）===');
const res = runExploreUrl(process.env.NH_VARS || '');
if (res.error) {
  ok(false, 'exploreUrl 跑通', res.error);
  console.log('\n通过 ' + pass + ' / 失败 ' + fail);
  process.exit(1);
}
ok(true, 'exploreUrl 求值成功');

console.log('\n--- 站方 exploreUrl 的原始返回（前 1200 字）---');
{
  let r = res.raw;
  if (typeof r === 'object') {
    try { r = JSON.stringify(r); } catch (e) { r = String(r); }
  }
  console.log('   type=' + (Array.isArray(res.raw) ? 'array' : typeof res.raw)
    + ' len=' + (r ? r.length : 0));
  console.log('   ' + String(r).slice(0, 1200));
}

console.log('\n=== 3. 归一化（Swift 真文件）===');
const norm = normalizeViaSwift(res.raw);
if (!norm) {
  ok(false, 'Swift 归一化器可用');
  console.log('\n通过 ' + pass + ' / 失败 ' + fail);
  process.exit(1);
}
const kinds = norm.kinds || [], filters = norm.filters || [];

ok(kinds.length > 0, `分类数 ${kinds.length} > 0（发现页能出东西了）`);
ok(kinds.every((k) => k.url && String(k.url).length > 0),
   '每个分类都有非空 url（★ 这正是旧引擎炸掉的地方：url 为空 ⇒ url 解析失败）');
ok(kinds.every((k) => !String(k.url).startsWith('@js:')),
   '没有分类的 url 是 "@js:"（旧引擎静态解析会把 @js: 当标题）');
ok(filters.length > 0, `筛选栏 ${filters.length} 项（平台/类型/频道…）`);
ok(filters.some((f) => f.title === '平台' && f.paramKey === 'find_source'),
   '筛选栏有「平台」且 paramKey=find_source（切台要靠它）');

console.log('\n--- 前 8 个分类 ---');
for (const k of kinds.slice(0, 8)) {
  console.log('   ', String(k.title).slice(0, 40), '→', String(k.url).slice(0, 90));
}
console.log('--- 筛选栏 ---');
for (const f of filters) {
  console.log('   ', f.title, '| chars=', (f.chars || []).length, '| default=', f.default, '| paramKey=', f.paramKey);
}

// ── ⑥ 变异对照：把「读错的格」改回去 ⇒ 必须红（精确复现真机症状）⭐⭐⭐ ──
console.log('\n=== 4. 变异对照（读错的格 ⇒ 必须复现真机症状）===');
{
  const self = __filename;
  const orig = fs.readFileSync(self, 'utf8');
  // ⚠️⚠️ **锚点用【唯一标记】而不是长正则**（长正则会被空白/换行差异打脸）⭐⭐⭐
  //   ⇒ 在 `source.get` 的实现里插一个标记行 ⇒ 变异时整段替换 ⇒ 稳 ⭐⭐⭐
  const ANCHOR = '/*__VAR_CHANNEL__*/';
  if (orig.indexOf(ANCHOR) < 0) {
    ok(false, '变异「读错的格」：锚点命中', '源码里找不到锚点标记 ⇒ 变异无效');
    // 直接跳过变异段
    console.log(`\n通过 ${pass} / 失败 ${fail}`);
    process.exit(1);
  }
  // ⭐⭐⭐ **变异要真的「读不到」**（2026-11-19 实证）：
  //   合并后 `stationVariable` 里**也含** nhAuthed ⇒ 变异若读它 ⇒ 照样读得到 ⇒ 变异无效 ⭐⭐⭐
  //   ⇒ 正解：变异读**【不含 nhAuthed 的那一格】**（站方变量那格的内容）⇒ 读不到 ⇒ 必须红 ⭐⭐⭐
  const mutated = orig.replace(
    /get: function \(k\) \{[\s\S]*?\n    \},/,
    "get: function (k) { var o = { src: '书旗', gender: '全部' };"
    + " return o[String(k)] === undefined ? '' : String(o[String(k)]); },")
  if (mutated === orig) {
    ok(false, '变异「读错的格」：锚点命中', '锚点没命中 ⇒ 变异无效');
  } else {
    const tmpSelf = self + '.mutate-bak';
    try {
      fs.writeFileSync(self, mutated, 'utf8');
      let red = false, detail = '';
      try {
        execFileSync('node', [self, SRC], { stdio: 'pipe', maxBuffer: 64 * 1024 * 1024 });
      } catch (e) {
        red = true;
        detail = String(e.stdout || e.stderr || '').slice(0, 300);
      }
      ok(red, '变异「读错的格」⇒ 端到端必须红（★ 精确复现真机症状「0 个分类」）',
         red ? '' : '变异后仍然通过 ⇒ 这道门禁抓不到真机故障 ⇒ 是摆设');
    } finally {
      fs.writeFileSync(self, orig, 'utf8');
      try { fs.unlinkSync(tmpSelf); } catch (e) {}
    }
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
