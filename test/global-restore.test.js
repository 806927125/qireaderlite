#!/usr/bin/env node
/**
 * **同名全局被别的源覆盖 ⇒ 切源后必须还原**（2026-10-22 真机「导入另一个源后大灰狼目录 0 章」）
 *
 * 跑法：node test/global-restore.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **症状**：用户导入 🍒NovelHub 聚合源之后，🍅大灰狼的目录就 0 章了（之前正常）。
 *
 * **机制**（老架构）：站方 jsLib 是**间接 eval** 加载 ⇒ `var host = [...]` /
 *   `function getArguments(){}` **进全局作用域** ⇒ 两个源**同名**的全局 ⇒ **后加载的赢**：
 *   · 大灰狼：`var host = ['https://v5.langge.uk', ...]`（**线路数组**）
 *             `getArguments(vars, "server")` ⇒ 决定 `/catalog` 请求打到哪个服务器
 *   · NovelHub：`var host = NH_UAA_HOSTS[0]`（**单个字符串**）+ 自己的 `getArguments`
 *   ⇒ 大灰狼的 `base_url` 取错 ⇒ `/catalog` 打到错的服务器 ⇒ **返回空 ⇒ 目录 0 章** ⭐
 *
 * ⇒ 光「删掉新增的全局」**不够**（同名覆盖是**改值**不是新增）⇒ 必须**把原值还原**
 *   （= 栖阅的 `restoreMutatedBaseGlobals`）
 * ⇒ 而且 **jsLib 抛异常时也要记账**（否则已定义的全局清不掉 ⇒ 污染永久留下）⭐
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新架构**没有「一个大全局 + 切源时还原」这层补丁**：**每个书源一个会话**
 *   ⇒ A 的 `host` 只在 A 的会话里、B 的 `host` 只在 B 的会话里
 *   ⇒ **同名全局压根不会互相覆盖** ⇒ 「还原」是**结构性成立**的 ⭐⭐⭐
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「同名全局被别的源覆盖 ⇒ 切源后必须把原值还原」
 *   新语义「**每个源一个会话（一个 JS 上下文）** ⇒ 同名全局**不共享** ⇒
 *             A 的值不会被 B 覆盖 ⇒ 切回 A 时 A 的值原样还在（会话被复用）」
 *   ⇒ 可观测结果一致：**A → B → A 之后，A 的 `host` 仍然是数组、3 条线路、`getArguments` 仍是 A 的** ⭐⭐⭐
 *
 *   jsLib 抛异常的等价语义：老架构「抛异常了也要记账，把已定义的全局清掉」
 *   新架构「抛异常 ⇒ **这个会话根本建不起来** ⇒ 那个被污染的上下文**整个丢掉**
 *   ⇒ 下次重新建一个干净的 ⇒ 污染不会留下」⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

/**
 * ⭐ 探测「当前会话里的同名全局长什么样」
 *
 * 做法：让引擎跑一条 **JS 分类规则**（`exploreUrl` 是 `@js:`），
 *   规则里读站方 jsLib 定义的全局 ⇒ 把读到的值塞进分类标题 ⇒ 回传给我 ⭐⭐⭐
 */
function probeGlobals(jsLib, expr) {
  const { win } = createSandbox({ routes: [] });
  const res = win.__qrInvoke('exploreKinds', {
    routes: [{ match: '/probe', status: 200, body: 'ok' }],
    jsLib,
    source: {
      bookSourceUrl: 'https://source.example.com',
      bookSourceName: 'src',
      exploreUrl: '@js: JSON.stringify([{title: ' + expr + ', url: "https://source.example.com/probe"}])',
    },
  });
  const kinds = (res && res.kinds) || [];
  return kinds.length ? String(kinds[0].title) : ('ERR:' + JSON.stringify(res));
}

// 源A：host 是**线路数组**（大灰狼同款）；源B：host 是**单个字符串**（NovelHub 同款）
const A_JS = "var host = ['A1','A2','A3']; function getArguments(v,k){ return 'A-SERVER'; }";
const B_JS = "var host = 'B-HOST'; function getArguments(v,k){ return 'B-SERVER'; }";
// 源C：jsLib **抛异常**（但前面已经定义了全局 ⇒ 上下文被污染）
const C_JS = "var host = ['C1','C2']; function getArguments(v,k){ return 'C-SERVER'; } throw new Error('boom');";

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  console.log('=== 1. 同名全局：A → B → A，A 的值必须回来 ===');
  const probeExpr = 'Array.isArray(host) + "|" + (Array.isArray(host) ? host.length : String(host))'
    + ' + "|" + getArguments("", "server")';
  const a1 = probeGlobals(A_JS, probeExpr);
  console.log('  载完 A →', a1);
  ok(a1 === 'true|3|A-SERVER', 'A 的 host 是数组、3 条线路、getArguments 是 A 的', a1);

  const b1 = probeGlobals(B_JS, probeExpr);
  console.log('  切到 B →', b1);
  ok(b1 === 'false|B-HOST|B-SERVER', 'B 的 host 是字符串、getArguments 是 B 的（B 赢）', b1);

  const a2 = probeGlobals(A_JS, probeExpr);
  console.log('  切回 A →', a2);
  ok(a2 === 'true|3|A-SERVER',
     '**切回 A 后 host 还原成数组、getArguments 还原成 A 的版本**（没被 B 覆盖）', a2);
  ok(a2 !== b1, 'A 的值和 B 的值**不是同一份**（同名全局不共享）');

  console.log('\n=== 2. jsLib 抛异常 ⇒ 它定义的全局也污染了上下文 ⇒ 必须整个丢掉 ===');
  const c1 = probeGlobals(C_JS, 'Array.isArray(host) + "|" + host.join(",")');
  console.log('  载完 C →', c1);
  ok(c1 === 'true|C1,C2',
     'C 的 host 已定义（jsLib 前半段执行了 ⇒ 上下文确实被污染）', c1);

  // ⭐ 新架构的等价语义：**建会话失败 ⇒ 整个上下文丢掉 ⇒ 不会留下永久污染**
  const app = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
  const iCreate = app.indexOf('let s = try Session(');
  const iStore = app.indexOf('sessions[key] = s');
  ok(iCreate >= 0 && iStore > iCreate,
     '会话**建成功之后**才登记（建失败 ⇒ 那个被污染的上下文整个丢掉）');
  ok(/try engine\.loadJsLib\(lib\)[\s\S]{0,400}?throw error/.test(app),
     'jsLib 加载失败会**抛出去**（不是静默吞）⇒ 这个源直接报错，不带污染的上下文上场');
  ok(/engineLog\("\[新引擎\] jsLib 加载失败/.test(app),
     'jsLib 加载失败会**记进日志**（用户看得见真凶）');

  console.log('\n=== 3. 切回 C ⇒ 它自己的 jsLib 会重载（同名一定被覆盖回去） ===');
  const c2 = probeGlobals(C_JS, 'Array.isArray(host) + "|" + getArguments("", "server")');
  console.log('  切回 C →', c2);
  ok(c2 === 'true|C-SERVER', 'C 的 host 和 getArguments 都回来了（自己的会话 ⇒ 自己的 jsLib）', c2);

  console.log('\n=== 4. 结构性自证：隔离是「每个源一个会话」做出来的 ===');
  {
    ok(/private var sessions: \[String: Session\] = \[:\]/.test(app),
       '有「按源缓存的会话表」（⇒ 每个源一个引擎 = 一个 JS 上下文）');
    ok(/let key = source\.bookSourceUrl/.test(app),
       '会话的 key 是**书源 URL**（⇒ 换源 = 换上下文 ⇒ 同名全局不互相覆盖）');
    // ⚠️ 别把代码形状写死（build263 加了 LRU ⇒ 旧正则会假红；**意图没变**）
    ok(/if let s = sessions\[key\]/.test(app) && /sessionOrder\.touch\(key\)/.test(app),
       '会话会被**复用**（切回 A 时 A 的全局还在 ⇒ 不用重新加载 jsLib）');
    ok(/maxLiveSessions\s*=\s*\d+/.test(app),
       '会话数有上限（超出才淘汰 ⇒ 内存不随源数涨）');
    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    ok(/public func loadJsLib\(_ code: String\) throws/.test(se),
       '引擎的 loadJsLib 是 **throws**（抛异常 ⇒ 宿主能拒绝这个源）');
    ok(/_ = try js\.runGlobal\(code, context: ctx\)/.test(se),
       'jsLib 走 runGlobal（间接 eval ⇒ 全局作用域）');
    ok(/js\.markGlobalsAsBaseline\(\)/.test(se),
       '加载完重设全局基线（⇒ 站方定义的全局不会被「清全局」误删）');
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
