const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

/**
 * ⭐⭐⭐⭐⭐ **新引擎求值桥**（老 JS 引擎物理删除后的替代品）
 *
 * ⚠️ **为什么需要**（2026-10-25 真机实证）：
 * · 轻阅那 7 个「规则语义」门禁原本**在 jsdom 里跑老引擎 JS**
 *   （`Resources/engine/*.js` + `test/harness.js`）⭐⭐⭐
 * · 老引擎退役 ⇒ 那些 JS **物理删除** ⇒ 门禁的对象没了 ⇒ **覆盖就丢了** ⭐⭐⭐
 * · 正解：**让门禁跑新引擎**（`legado-engine` 的 Swift 实现）⭐⭐⭐
 *   ⇒ 门禁继续有效，而且验的是**真正在跑的那份代码**（不是参考实现）⭐⭐⭐
 *
 * ⭐ **怎么工作**：
 * · 调 `legado-engine` 的 `Conformance` 可执行文件的 `--eval` 模式
 * · 输入 = 一条 JSON（规则 + 基准 + 上下文）
 * · 输出 = 一行 JSON（值 / 文本 / 走的分支 / 失败原因）⭐⭐⭐
 *
 * ⚠️ **需要先 `swift build` 引擎**（`legado-engine/.build/debug/Conformance`）
 *   ⇒ 找不到 ⇒ **显式 SKIP**（不许假绿）⭐⭐⭐
 */

const ROOT = path.join(__dirname, '..');
const ENGINE_DIR = process.env.ENGINE_DIR || path.join(ROOT, '..', 'legado-engine');

/** ⭐ 找引擎的可执行文件（多个候选路径） */
function findConformanceBin() {
  const cands = [
    path.join(ENGINE_DIR, '.build', 'debug', 'conformance'),
    path.join(ENGINE_DIR, '.build', 'x86_64-unknown-linux-gnu', 'debug', 'conformance'),
    path.join(ENGINE_DIR, '.build', 'arm64-apple-darwin', 'debug', 'conformance'),
  ];
  for (const c of cands) {
    try { if (fs.existsSync(c)) return c; } catch (_) {}
  }
  return null;
}

/** ⭐⭐⭐ **新引擎在不在**（门禁用它做显式 SKIP 的判据） */
function engineAvailable() {
  return !!findConformanceBin();
}

/**
 * ⭐⭐⭐⭐⭐ **用新引擎求值一条规则**
 * @param {string} rule 规则
 * @param {object} opts { base, baseType, isJSON, raw, baseUrl, vars, baseJSON }
 * @returns {object|null} { ok, value, text, branch, failure } —— 引擎不可用时返回 null
 */
function evalRule(rule, opts = {}) {
  const bin = findConformanceBin();
  if (!bin) return null;
  const payload = {
    rule,
    base: opts.base ?? '',
    baseType: opts.baseType ?? 'page',
    isJSON: opts.isJSON ?? false,
    raw: opts.raw ?? opts.base ?? '',
    baseUrl: opts.baseUrl ?? '',
    vars: opts.vars ?? {},
  };
  if (opts.baseJSON !== undefined) payload.baseJSON = opts.baseJSON;
  // ⭐⭐⭐ **「要全部命中」模式**（2026-10-26 门禁迁移补的）
  //   ⇒ 引擎侧输出 `values` / `count`（老引擎的 `QR.rule.getElements(…).values`）⭐⭐⭐
  if (opts.all !== undefined) payload.all = opts.all;
  // ⭐⭐⭐ **条目级基准**（`baseType:"node"` ⇒ 按 CSS 选择器取节点）
  if (opts.selector !== undefined) payload.selector = opts.selector;
  const r = spawnSync(bin, ['--eval', JSON.stringify(payload)], {
    encoding: 'utf8',
    timeout: 20000,
  });
  if (r.status !== 0 || !r.stdout) {
    return { ok: false, error: (r.stderr || '').trim() || `引擎退出码 ${r.status}` };
  }
  const line = r.stdout.trim().split('\n').filter(Boolean).pop();
  try { return JSON.parse(line); } catch (e) {
    return { ok: false, error: '引擎输出解析失败：' + line };
  }
}

module.exports = { evalRule, engineAvailable, findConformanceBin, ENGINE_DIR };

/**
 * ⭐⭐⭐⭐⭐ **问站方要默认变量表**（新引擎的 `sourceVars` op）
 *
 * ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
 *   轻阅的「站方默认变量」门禁原本在 jsdom 里跑老引擎 ⇒ 老引擎删了 ⇒ 门禁对象没了
 *   ⇒ 现在**直接调新引擎的 `sourceVars` op** ⇒ 语义完全对齐 + 覆盖不丢 ⭐⭐⭐
 *
 * ⚠️ **Linux 上没有 JSC** ⇒ jsLib 跑不了 ⇒ 返回 `{"__skip":"…"}`
 *   ⇒ 门禁必须**显式 SKIP**（「没验到」≠「验过了没问题」）⭐⭐⭐
 */
function sourceVars(src) {
  const bin = findConformanceBin();
  if (!bin) return { __skip: '没编译 legado-engine' };
  const r = spawnSync(bin, ['--sourceVars', JSON.stringify({
    bookSourceUrl: (src && src.bookSourceUrl) || '',
    jsLib: (src && src.jsLib) || '',
  })], { encoding: 'utf8', timeout: 20000 });
  if (r.status !== 0 || !r.stdout) return { __skip: '引擎执行失败' };
  const line = r.stdout.trim().split('\n').filter(Boolean).pop();
  try { return JSON.parse(line); } catch (e) { return { __skip: '引擎输出解析失败' }; }
}

module.exports.sourceVars = sourceVars;

/**
 * ⭐⭐⭐⭐⭐ **跑完整 op 链**（新引擎 + 假服务器）
 *
 * ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
 *   轻阅有一批门禁原本**在 jsdom 里跑老引擎的完整链**（explore / bookInfo / toc）
 *   ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ **覆盖就丢了** ⭐⭐⭐
 *   ⇒ 现在：**直接跑新引擎** ⇒ 门禁继续有效，而且验的是**真正在跑的那份**⭐⭐⭐
 *
 * @param {object} req { op, source, routes:[[pattern, file]], dir, kindUrl, bookUrl, jsLib }
 * @returns {object|null} { ok, books/…, error }
 */
function runOp(req) {
  const bin = findConformanceBin();
  if (!bin) return null;
  const r = spawnSync(bin, ['--op', JSON.stringify(withJsLib(normalizeRoutes(req)))], {
    encoding: 'utf8',
    timeout: 120000,
  });
  if (r.status !== 0 || !r.stdout) {
    return { ok: false, error: (r.stderr || '').trim() || `引擎退出码 ${r.status}` };
  }
  const line = r.stdout.trim().split('\n').filter(Boolean).pop();
  try { return JSON.parse(line); } catch (e) {
    return { ok: false, error: '引擎输出解析失败：' + line };
  }
}

/**
 * ⭐⭐⭐⭐⭐ **站方 jsLib 必须单独带进 op 的顶层**（2026-10-25 实证）
 *
 * ⚠️ **为什么**：
 *   · 引擎的 `BookSource` 模型**没有 jsLib 字段**（站方 jsLib 由宿主单独带进来）
 *   · `conformance --op` 读的键是**顶层** `jsLib`（`obj["jsLib"]`）⭐⭐⭐
 *   · 门禁把源整个塞进 `source` ⇒ jsLib 就**跟着源进去但没人读** ⇒ **静默不加载** ⭐⭐⭐
 *
 * ⇒ 后果（实测，不是推测）：
 *   大灰狼的 jsLib 定义了 `var host = [...]` 和 `function getArguments(...)`
 *   ⇒ jsLib 没加载 ⇒ 站方 exploreUrl 一跑就 **`host is not defined`** ⭐⭐⭐
 *   ⇒ 引擎报「Node JS 报错：host is not defined」⇒ 分类 0 个、书 0 本
 *   ⇒ **看着像站方挂了 / 引擎坏了**，其实是**门禁少传了一个键** ⭐⭐⭐
 *
 * ⇒ App 侧（真机）本来就会传（`LegadoEngineBackend` 里 `Session(…, jsLib: source.jsLib)`）
 *   ⇒ **真机没事，沙盒有事** ⇒ 沙盒必须补上这一键，否则门禁验不到真机那条路 ⭐⭐⭐
 */
function withJsLib(req) {
  if (!req || typeof req !== 'object') return req;
  if (req.jsLib) return req;                       // 显式传了 ⇒ 不动
  const src = req.source;
  const lib = src && (src.jsLib || src.jsLibSource);
  if (!lib) return req;
  return Object.assign({}, req, { jsLib: lib });
}

/**
 * ⭐⭐⭐ **老写法 ⇒ 新写法的翻译层**（2026-10-25 老引擎退役 ⇒ 假服务器换了协议）
 *
 * 老写法（老 harness 的 fixture 约定）：
 *     { dir: 'test/fixtures', routes: [['htmlpage', 'fake-htmlpage.html']] }
 * 新写法（引擎现在的协议，声明式 ⇒ 不用造文件）：
 *     { routes: [{ match: 'htmlpage', status: 200, body: '<html>…' }] }
 *
 * ⚠️⚠️ **为什么要有这层**（不修的话，症状极具误导性）：
 *   引擎把 `routes` 按 `[[String: Any]]` 解 ⇒ **老写法整个解不出来** ⇒ 路由表是空的
 *   ⇒ 请求落到「没有这个 fixture」⇒ 门禁报「书出不来 / 详情读不到」
 *   ⇒ **看着像引擎坏了，其实是门禁的协议过期了** ⭐⭐⭐
 *   （引擎侧老写法挪到了 `fileRoutes` 这个键上）
 *
 * ⇒ 这里**读文件 → 内联 body** ⇒ 翻译成新写法 ⇒ 门禁不用一个个改 ⭐⭐⭐
 */
function normalizeRoutes(req) {
  const rs = req && req.routes;
  if (!Array.isArray(rs) || rs.length === 0) return req;
  // 已经是新写法（对象数组）⇒ 原样
  if (!Array.isArray(rs[0])) return req;
  const dir = req.dir || path.join(__dirname, 'fixtures');
  const routes = [];
  for (const r of rs) {
    if (!Array.isArray(r) || r.length < 2) continue;
    const [pat, file] = r;
    let body = '';
    try { body = fs.readFileSync(path.join(dir, file), 'utf8'); }
    catch (e) { body = ''; }               // 读不到 ⇒ 空 body（引擎会返回空页 ⇒ 门禁红）
    routes.push({ match: pat, status: 200, body });
  }
  return Object.assign({}, req, { routes });
}

module.exports.runOp = runOp;

/**
 * ⭐⭐⭐⭐⭐ **URL 规则解析**（新引擎的 `URLBuilder`）
 *
 * ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
 *   轻阅的 `qiyue-parity` 门禁原本在 jsdom 里跑老引擎的 `QR.analyzeUrl(...)`
 *   ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ 改成**直接调新引擎** ⭐⭐⭐
 *
 * @param {object} req { url, baseUrl }
 * @returns {object|null} { ok, url, method, body, headers }
 */
function analyzeUrl(req) {
  const bin = findConformanceBin();
  if (!bin) return null;
  const r = spawnSync(bin, ['--analyzeUrl', JSON.stringify(req)], {
    encoding: 'utf8', timeout: 20000,
  });
  if (r.status !== 0 || !r.stdout) {
    return { ok: false, error: (r.stderr || '').trim() || `引擎退出码 ${r.status}` };
  }
  const line = r.stdout.trim().split('\n').filter(Boolean).pop();
  try { return JSON.parse(line); } catch (e) { return { ok: false, error: '引擎输出解析失败' }; }
}

module.exports.analyzeUrl = analyzeUrl;
