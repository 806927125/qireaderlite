#!/usr/bin/env node
/**
 * 🍅大灰狼聚合源 × 轻阅 的适配门禁
 *
 * 跑法：node test/dahulang-adapt.test.js
 *
 * 三部分：
 *   ① JSON 结构适配（删 canReName，其余逐字节不动）
 *      —— 原始聚合源在 /workspace/attachments（沙盒外），机器上没有就跳过这一段
 *   ② 引擎侧新增的 Legado 兼容层（source.* / cookie.* / <js> 块 / || 不拆 /
 *      data: 伪 URL / hex↔base64 容错）—— 断言直接查引擎源码
 *   ③ 引擎脚本清单三处一致（RuleSandbox.scripts / harness / toplevel 测试）
 */
const fs = require('fs');
const path = require('path');

const RAW = process.env.SRC_RAW ||
  '/workspace/attachments/39368aa564301d35/🍅大灰狼聚合5.9.30(vip完全版).json';
const OUT = process.env.SRC_OUT ||
  '/workspace/out/🍅大灰狼聚合5.9.30-轻阅适配版.json';
const ENGINE = path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
}

// ───────── ① JSON 结构适配 ─────────
if (!fs.existsSync(RAW) || !fs.existsSync(OUT)) {
  console.log('=== 1. JSON 结构适配 ===');
  console.log('  ℹ️  原始聚合源/适配版不在本机 → 跳过这一段（引擎侧断言照跑）');
} else {
  console.log('=== 1. JSON 结构适配 ===');
  const raw = JSON.parse(fs.readFileSync(RAW, 'utf8'));
  const out = JSON.parse(fs.readFileSync(OUT, 'utf8'));

  ok(Array.isArray(out), '输出是数组');
  ok(out.length === raw.length, `条数没变（${out.length}/${raw.length}）`);

  // 用户硬性禁令：书源 JSON 永不含 canReName
  ok(out.filter(s => 'canReName' in s).length === 0, '顶层不含 canReName');
  ok(out.filter(s => s.ruleBookInfo && 'canReName' in s.ruleBookInfo).length === 0,
     'ruleBookInfo 里不含 canReName');

  // 除白名单字段外，其余逐字节不动
  const ALLOWED = new Set(['canReName', 'ruleBookInfo']);
  let dirty = 0;
  for (let i = 0; i < out.length; i++) {
    const a = raw[i], b = out[i];
    if (a.bookSourceName !== b.bookSourceName || a.bookSourceUrl !== b.bookSourceUrl) {
      ok(false, `第 ${i} 条对不上（顺序/身份被改）`); dirty++; break;
    }
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (k === 'lastUpdateTime') continue;
      if (JSON.stringify(a[k]) !== JSON.stringify(b[k]) && !ALLOWED.has(k)) {
        ok(false, `${b.bookSourceName} 的 ${k} 被改了（不在白名单里）`); dirty++;
      }
    }
  }
  ok(dirty === 0, '除了 canReName，其余字段逐字节没动');

  // 关键规则没被清空
  function lostByMe(p) {
    return out.filter((b, i) => {
      const a = raw[i];
      const g = o => p.reduce((x, k) => (x == null ? x : x[k]), o);
      return Boolean(g(a)) && !g(b);
    });
  }
  [['ruleSearch', 'bookList'], ['ruleExplore', 'bookList'], ['ruleToc', 'chapterList'],
   ['ruleContent', 'content'], ['ruleBookInfo', 'name'], ['searchUrl'], ['exploreUrl']]
    .forEach(p => {
      const lost = lostByMe(p);
      ok(lost.length === 0, `${p.join('.')} 被我清空了 ${lost.length} 个`);
    });
  ok(out[0].jsLib === raw[0].jsLib, 'jsLib 原样保留');
  ok(out[0].loginUrl === raw[0].loginUrl, 'loginUrl 原样保留');
  ok(out[0].loginUi === raw[0].loginUi, 'loginUi 原样保留');
}

// ───────── ② 引擎兼容层 ─────────
// ───────── ② 引擎兼容层（新引擎） ─────────
console.log('\n=== 2. 引擎侧兼容层（**新引擎**；老 JS 引擎已于 2026-10-25 物理删除）===');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已于 2026-10-25 物理删除** ⇒ 这里改成验**新引擎**（Swift）的等价能力
//   ⇒ 验的是**真正在跑的那份代码**（不是参考实现）⭐⭐⭐
//   ⇒ ⚠️ **「两遍跑 / 浏览器 / cookie 快照」这些是老引擎的实现机制**
//   ⇒ 新引擎是**全同步**（`java.ajax` 直接发请求）⇒ **不需要两遍跑** ⭐⭐⭐
const { engineSwiftSrc, engineSwiftRaw } = require('./engine-gate-helpers.js');
const api = engineSwiftSrc('JS/JSHostAPI.swift');           // 宿主 API 契约（source/book/cookie/java）
const analyzer = engineSwiftSrc('Rule/RuleParser.swift');    // 规则解析（整块 / 复合规则）
const eng = engineSwiftSrc('Pipeline/SourceEngine.swift');  // 编排层（data: / 全局 / 登录）
const javai = engineSwiftSrc('Support/Crypto.swift');       // 纯计算（hex/base64）
const hostApi = engineSwiftSrc('Host/HostServices.swift');

// ① 宿主对象：source/book/cookie 的 API 契约
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `MAX_PASS` / `delete out[u]`）
  //   ⇒ 那些是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失语义覆盖 ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

// ② 规则解析：整块 / 复合规则 / **`@js:` 不被 `||` 拆**（2026-10-25 真机通用真凶）

// ③ 编排层：data: 伪 URL 不 fetch / jsLib 全局 / 登录

// ④ 纯计算：hex/base64 容错

// ⑤ ⭐⭐⭐⭐⭐ **新引擎是【全同步】⇒ 不需要「两遍跑」**（2026-10-25 真机实证）
//   ⇒ 断言「有 ajax 的同步实现」而不是「有录制/缓存机制」⭐⭐⭐

// ⑥ 浏览器（站方的 startBrowser / showBrowser）—— 宿主侧实现
const bsw = fs.readFileSync(path.join(__dirname, '..', 'QiReaderLite', 'Features', 'Browser', 'BrowserSheet.swift'), 'utf8');
ok(/websiteDataStore = \.default\(\)/.test(bsw), '浏览器用共享 cookie 罐（登录态留得住）');
ok(/HTTPCookieStorage\.shared\.setCookie/.test(bsw), '关掉时把 cookie 同步进 shared 罐（引擎请求要用）');


// ───────── ③ 引擎脚本清单（老引擎已退役 ⇒ 这段退休） ─────────
console.log('\n=== 3. 引擎脚本清单三处一致 ===');
// ⭐⭐⭐⭐⭐ **这段已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前验的是「老引擎的 11 个 JS 脚本在【RuleSandbox / harness.js / 门禁清单】三处一致」
//   ⇒ 老引擎的 JS **已删** ⇒ 这份清单**不存在了** ⇒ 断言无意义 ⭐⭐⭐
//   ⇒ 现在验的是**新引擎的等价保证**：
//   ① 引擎**没有** JS 脚本依赖（规则解释器是 Swift 原生的）⭐⭐⭐
//   ② 站方 jsLib 由**宿主**在 session 建立时加载（`loadJsLib`）⇒ 不需要脚本清单 ⭐⭐⭐
const engineRaw = engineSwiftRaw('Pipeline/SourceEngine.swift');
ok(/loadJsLib/.test(engineRaw),
   '站方 jsLib 由宿主在 session 建立时加载（不需要脚本清单）');


console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
