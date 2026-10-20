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
const ENGINE = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');

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
console.log('\n=== 2. 引擎侧 Legado 兼容层 ===');
const api = stripComments(fs.readFileSync(path.join(ENGINE, 'source-api.js'), 'utf8'));
const analyzer = stripComments(fs.readFileSync(path.join(ENGINE, 'rule-analyzer.js'), 'utf8'));
const eng = stripComments(fs.readFileSync(path.join(ENGINE, 'engine.js'), 'utf8'));
const javai = stripComments(fs.readFileSync(path.join(ENGINE, 'java-api.js'), 'utf8'));

ok(/function wrapSource/.test(api) && /getVariable/.test(api) && /setVariable/.test(api),
   'source.getVariable / setVariable 有实现');
ok(/getLoginInfoMap/.test(api) && /putLoginInfo/.test(api) && /getLoginInfo/.test(api),
   'source.getLoginInfoMap / putLoginInfo / getLoginInfo 有实现');
ok(/function wrapBook/.test(api) && /wrapped\.getVariable/.test(api),
   'book.getVariable 有实现（站方会调 book.getVariable("custom")）');
ok(/getCookie:\s*function/.test(api) && /setCookie:\s*function/.test(api) &&
   /removeCookie:\s*function/.test(api) && /getKey:\s*function/.test(api),
   'cookie.getCookie / setCookie / removeCookie / getKey 有实现');
ok(/QR\.wrapSource \? QR\.wrapSource\(ctx\.source\)/.test(analyzer),
   'jsScope 里的 source 是包过 API 的（裸对象 → TypeError → 规则静默失效）');
ok(/QR\.wrapBook\(ctx\.book\)/.test(analyzer),
   'jsScope 里的 book 是包过 API 的');

ok(/function isBlockRule/.test(analyzer) && /isBlockRule\(line\)/.test(analyzer),
   '`<js>…</js>` 整块不按行切、也不按 || 拆（否则代码被腰斩 → Unexpected token <）');
ok(/function splitJsWithTail/.test(analyzer) && /selectFromJsResult/.test(analyzer),
   '支持复合规则 <js>代码</js>选择器（$.data / $.content）');
ok(/function selectFromJsResult/.test(analyzer) && /evalJsonPath/.test(analyzer),
   '复合规则的尾部选择器能取字段');

ok(/dataUrlContent/.test(eng) && /indexOf\('data:'\) === 0/.test(eng),
   'data: 伪 URL 不 fetch（聚合源用它塞参数）');
ok(/g\.source = wrappedSrc/.test(eng),
   'op 期间把 source 挂到全局（jsLib 里的函数在全局作用域）');
ok(/\[URL 里的 JS 出错\]/.test(eng),
   'URL 里的 JS 出错会打日志（不再默默吞掉 → 静默失效）');

ok(/hexDecodeToString: function/.test(javai) && /b64decode\(s\)/.test(javai),
   'hexDecodeToString 对 base64 串容错（站方写 base64 却按 hex 读）');

// 登录通道
ok(/function ensureLoginLib/.test(eng), 'loginUrl 能像 jsLib 一样加载进全局');
ok(/login: function \(p\)/.test(eng), '引擎有 login 操作');
ok(/result: formValues/.test(eng), '表单值挂在 result 上（站方读 result[\'邮箱\']）');
ok(/ensureJsLib\(source\)\.then/.test(eng), 'loginUrl 之前先加载 jsLib（它依赖 jsLib 的 host）');
ok(/g\.result = scope\.result/.test(analyzer),
   'jsLib 函数在全局作用域 → 全局要同步 source/result/book');
ok(/setUseReplaceRule/.test(api) && /wrapped\[fn\]/.test(api),
   'book 上补了 Legado 的 Book 方法（setUseReplaceRule 等）');
ok(/var key: ''/.test(analyzer) || /key: ''/.test(analyzer), 'scope 里有 key（站方 jsLib 常用）');

// 同步 ajax（两遍跑）—— Legado 的 java.ajax 是同步的，我们原生桥是异步的
ok(/__qrAjaxRecord/.test(javai) && /__qrAjaxCache/.test(javai),
   'java.ajax 支持录制/缓存（两遍跑的第一遍录 URL，第二遍同步返回正文）');
ok(/__qrSuppressToast/.test(javai), '第一遍静音 toast（免得报「登录失败」假错）');
ok(/function fetchRecorded/.test(analyzer) && /QR\.analyzeUrl/.test(analyzer),
   '抓回来的 URL 认 ,{json} 后缀（method/headers/body 不丢）');
ok(/QR\.analyzeUrl = analyzeUrl/.test(eng), 'engine.js 把 analyzeUrl 暴露给规则层');

// ───────── ③ 脚本清单三处一致 ─────────
console.log('\n=== 3. 引擎脚本清单三处一致 ===');
const swift = fs.readFileSync(path.join(__dirname, '..', 'QiReaderLite', 'Core', 'RuleSandbox.swift'), 'utf8');
const harness = fs.readFileSync(path.join(__dirname, 'harness.js'), 'utf8');
const toplevel = fs.readFileSync(path.join(__dirname, 'engine-script-toplevel.test.js'), 'utf8');
ok(/"source-api\.js"/.test(swift), 'RuleSandbox.scripts 里有 source-api.js');
ok(/'source-api\.js'/.test(harness), 'test/harness.js 的 FILES 里有 source-api.js');
ok(/'source-api\.js'/.test(toplevel), 'engine-script-toplevel.test.js 的清单里有 source-api.js');
ok(swift.indexOf('source-api.js') < swift.indexOf('rule-analyzer.js'),
   'source-api.js 排在 rule-analyzer.js 前面（它要提供 wrapSource）');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
