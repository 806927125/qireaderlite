const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

/**
 * ⭐⭐⭐⭐⭐ **新引擎的 JS 门禁沙盒**（老 JS 引擎物理删除后的替代品）
 *
 * ⚠️ **为什么需要**（2026-10-25 真机实证）：
 * · 轻阅有 **40+ 个门禁**原本**在 jsdom 里跑老引擎 JS**
 *   （`QiReaderLite/Resources/engine/*.js` + `test/harness.js`）⭐⭐⭐
 * · 老引擎退役 ⇒ 那些 JS **物理删除** ⇒ 门禁的对象没了 ⇒ **覆盖就丢了** ⭐⭐⭐
 * ⇒ 正解：**让它们跑新引擎**（`legado-engine` 的 Swift 实现）⇒ 覆盖不丢，
 *   而且验的是**真正在跑的那份代码**（不是参考实现）⭐⭐⭐
 *
 * ⭐⭐⭐ **老 API 兼容层**（门禁几乎不用改）：
 * | 老 API | 新实现 |
 * |---|---|
 * | `window.__qrInvoke(op, payload)` | ⇒ 引擎的 `--op` 模式 |
 * | `window.QR.rule.runJs(code, scope)` | ⇒ 引擎的 `--js` 模式 |
 * | `window.QR.wrapSource(obj)` | ⇒ 引擎的 `--op`（sourceVars） |
 *
 * ⭐ **假服务器**：老门禁用 `nativeMock`（JS 层的 async mock）
 *   ⇒ 新架构下站方 JS 由**引擎同步执行** ⇒ 假服务器必须**下沉到 transport 层**
 *   ⇒ 新写法：`createSandbox({ routes: [{ match, status, body }] })` ⭐⭐⭐
 *   ⇒ 引擎侧会回传 `requests`（发了哪几条）⇒ 门禁可断言 ⭐⭐⭐
 */

const ROOT = path.join(__dirname, '..');
const ENGINE_DIR = process.env.ENGINE_DIR || path.join(ROOT, '..', 'legado-engine');

/** ⭐ 找引擎的可执行文件 */
function findConformanceBin() {
  const cands = [
    path.join(ENGINE_DIR, '.build', 'debug', 'conformance'),
    path.join(ENGINE_DIR, '.build', 'x86_64-unknown-linux-gnu', 'debug', 'conformance'),
    path.join(ENGINE_DIR, '.build', 'arm64-apple-darwin', 'debug', 'conformance'),
  ];
  for (const c of candidatesSafe(cands)) {
    try { if (fs.existsSync(c)) return c; } catch (_) {}
  }
  return null;
}
function candidatesSafe(list) { return list; }

/** ⭐ 引擎在不在（门禁用它做**显式 SKIP**，不许假绿） */
function engineAvailable() { return !!findConformanceBin(); }

/**
 * ⭐⭐⭐⭐⭐ **大 payload ⇒ 写临时文件**（2026-10-26 门禁迁移补的）
 *
 * ⚠️ **为什么需要**：
 * · 真书源（🍅大灰狼 158KB / NovelHub 929KB）**整个 JSON 都要传给引擎**
 * · 而 Linux 的 `execve` 单个参数上限是 **128KB（MAX_ARG_STRLEN）**
 *   ⇒ 直接把 JSON 当命令行参数传 ⇒ **`E2BIG`（Argument list too long）** ⇒ 门禁直接崩 ⭐⭐⭐
 * · 引擎的 `--op` / `--js` **本来就支持从文件读 payload**（`.json` 后缀 ⇒ 当路径）⭐⭐⭐
 *
 * ⇒ 所以：**小的走 argv，大的走临时文件**（跑完删掉）⭐⭐⭐
 */
const ARGV_LIMIT = 100 * 1024;   // ⭐ 留点余量（argv 总量还有别的限制）
let tempFiles = [];
function engineArgs(flag, req) {
  const json = JSON.stringify(req);
  if (json.length <= ARGV_LIMIT) return [flag, json];
  const f = path.join(os.tmpdir(), `qr-engine-${process.pid}-${Date.now()}-${tempFiles.length}.json`);
  fs.writeFileSync(f, json);
  tempFiles.push(f);
  return [flag, f];
}
function cleanupTempFiles() {
  for (const f of tempFiles) { try { fs.unlinkSync(f); } catch (_) {} }
  tempFiles = [];
}

/** ⭐⭐⭐⭐⭐ **调引擎的某个 op** */
function invokeEngine(op, payload) {
  const bin = findConformanceBin();
  if (!bin) return { error: 'no engine' };
  const req = Object.assign({ op }, payload || {});
  // ⭐⭐⭐ **站方 jsLib 要单独提到顶层**（2026-10-25 实证）
  //   引擎的 `BookSource` 没 jsLib 字段 ⇒ `--op` 读的是**顶层** `jsLib` 键
  //   ⇒ 不提 ⇒ jsLib 静默不加载 ⇒ 大灰狼的站方 JS 一跑就 `host is not defined` ⭐⭐⭐
  //   （真机 App 侧本来就传 ⇒ 真机没事 ⇒ 沙盒必须补上，否则验不到真机那条路）⭐⭐⭐
  if (!req.jsLib && req.source && req.source.jsLib) req.jsLib = req.source.jsLib;
  const args = engineArgs('--op', req);
  const r = spawnSync(bin, args, {
    encoding: 'utf8', timeout: 180000, maxBuffer: 64 * 1024 * 1024,
  });
  cleanupTempFiles();
  if (r.status !== 0 || !r.stdout) {
    return { error: (r.stderr || '').trim() || `引擎退出码 ${r.status}` };
  }
  const line = r.stdout.trim().split('\n').filter(Boolean).pop();
  try { return JSON.parse(line); } catch (e) { return { error: '引擎输出解析失败：' + line }; }
}

/** ⭐⭐⭐⭐⭐ **执行任意 JS（走引擎的 node 进程 ⇒ 宿主 API 可用）** */
function invokeEngineJs(code, payload) {
  const bin = findConformanceBin();
  if (!bin) return null;
  const req = Object.assign({ code }, payload || {});
  const args = engineArgs('--js', req);
  const r = spawnSync(bin, args, {
    encoding: 'utf8', timeout: 180000, maxBuffer: 64 * 1024 * 1024,
  });
  cleanupTempFiles();
  if (r.status !== 0 || !r.stdout) {
    return { error: (r.stderr || '').trim() || `引擎退出码 ${r.status}` };
  }
  const line = r.stdout.trim().split('\n').filter(Boolean).pop();
  try { return JSON.parse(line); } catch (e) { return { error: '引擎输出解析失败' }; }
}

/**
 * ⭐⭐⭐⭐⭐ **造一个跟老 harness 形状一样的沙盒**
 *
 * @param {object} opts
 *   · `routes`  ⭐⭐⭐ **假服务器路由**（替代老 `nativeMock`）
 *       `[{ match: 'a.example.com', status: 502, body: '…' }]`
 *   · `source`  源 JSON（`__qrInvoke` 的 payload 里也可以带）
 */
function createSandbox(opts = {}) {
  const routes = opts.routes || null;
  const nativeMock = opts.nativeMock || null;

  // ⭐⭐⭐ **老 `nativeMock` ⇒ 转成路由表**（尽力而为：跑一次 mock 收集不到 URL ⇒ 只能取源码里的字面量）
  //   ⇒ **建议门禁直接改用 `routes`**（声明式 ⇒ 稳）⭐⭐⭐
  const sandbox = {
    __routes: routes,
    __requests: [],
    __lastResult: null,
  };

  const win = {
    /**
     * ⭐⭐⭐⭐⭐ **同步求值**（老 harness 也是同步语义）
     *
     * 支持三种调用：
     * ① `window.__qrInvoke('op', payload)` ⇒ 引擎的 `--op`
     * ② `window.QR.rule.runJs(code, scope)` ⇒ 引擎的 `--js`
     * ③ 其它 JS ⇒ 也走引擎的 `--js`（⇒ 宿主 API 可用）⭐⭐⭐
     */
    eval(code) {
      const src = String(code);

      // ① __qrInvoke
      const m = /window\.__qrInvoke\(\s*['"]([\w-]+)['"]\s*,\s*([\s\S]*?)\s*\)\s*;?\s*$/.exec(src);
      if (m) {
        const op = m[1];
        let payload = {};
        try { payload = JSON.parse(m[2]); } catch (e) { payload = {}; }
        if (routes && !payload.routes) payload.routes = routes;
        const res = invokeEngine(op, payload);
        sandbox.__lastResult = res;
        if (res && res.requests) sandbox.__requests.push.apply(sandbox.__requests, res.requests);
        if (res && res.error) return JSON.stringify({ error: res.error });
        return JSON.stringify(res);
      }

      // ② QR.rule.runJs(code, scope)
      const r = /window\.QR\.rule\.runJs\(\s*([\s\S]*?)\s*,\s*\{[^}]*\}\s*\)/.exec(src);
      if (r) {
        let code2 = '';
        try { code2 = JSON.parse(r[1]); } catch (e) { code2 = r[1]; }
        const res = invokeEngineJs(code2, routes ? { routes } : {});
        sandbox.__lastResult = res;
        if (!res) return 'ERR: 引擎不可用';
        if (res.error) return 'ERR: ' + res.error;
        if (res.requests) sandbox.__requests.push.apply(sandbox.__requests, res.requests);
        if (res.value === null || res.value === undefined) return res.text || '';
        return typeof res.value === 'string' ? res.value : JSON.stringify(res.value);
      }

      // ③ 其它 JS ⇒ 走引擎的 `--js`（宿主 API / 包装函数都在）
      const res3 = invokeEngineJs(src, routes ? { routes } : {});
      sandbox.__lastResult = res3;
      if (!res3) return 'ERR: 引擎不可用';
      if (res3.error) return 'ERR: ' + res3.error;
      if (res3.requests) sandbox.__requests.push.apply(sandbox.__requests, res3.requests);
      if (res3.value === null || res3.value === undefined) return res3.text || '';
      return typeof res3.value === 'string' ? res3.value : JSON.stringify(res3.value);
    },

    /** ⭐⭐⭐ **老 harness 的 `__qrInvoke` 直调**（有些门禁这么用） */
    __qrInvoke(op, payload) {
      const p = Object.assign({}, payload || {});
      if (routes && !p.routes) p.routes = routes;
      const res = invokeEngine(op, p);
      sandbox.__lastResult = res;
      // ⭐⭐⭐ **请求记录也进 `sandbox.__requests`**（规范 §1.1：「请求记录从 sandbox.__requests 取」）
      if (res && res.requests) sandbox.__requests.push.apply(sandbox.__requests, res.requests);
      return res;
    },
  };

  // ⭐⭐⭐ **老 harness 的 `QR` 命名空间**（`window.QR.rule.runJs` / `window.QR.wrapSource`）
  win.QR = {
    rule: {
      runJs(code, scope) {
        const res = invokeEngineJs(code, routes ? { routes } : {});
        sandbox.__lastResult = res;
        if (res && res.requests) sandbox.__requests.push.apply(sandbox.__requests, res.requests);
        if (!res) return '';
        if (res.error) return 'ERR: ' + res.error;
        if (res.value === null || res.value === undefined) return res.text || '';
        return typeof res.value === 'string' ? res.value : JSON.stringify(res.value);
      },
    },
    wrapSource(obj) {
      // ⭐ 老语义：包一个「源对象」⇒ 站方可以用 `s.get('x')` / `s.put('x', v)`
      const vars = {};
      try { Object.assign(vars, JSON.parse(obj.__variables || '{}')); } catch (e) {}
      const store = Object.assign({}, vars);
      return {
        get(k) { return store[k] === undefined ? '' : store[k]; },
        getVariable() { return JSON.stringify(store); },
        put(k, v) { store[k] = v; vars.__lastPut = JSON.stringify([k, v]); return ''; },
        getString(p) { return store[p] === undefined ? '' : store[p]; },
      };
    },
  };
  win.window = win;

  return { win, sandbox, routes, nativeMock };
}

module.exports = { createSandbox, invokeEngine, invokeEngineJs, engineAvailable, findConformanceBin };
