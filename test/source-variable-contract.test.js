#!/usr/bin/env node
/**
 * ⭐⭐⭐ **站方变量 / 书源变量 的通用契约**（2026-10-27）
 *
 * 跑法：node test/source-variable-contract.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **Legado 是两套**（这是「通用书源系统」的地基）：
 *
 * | API | 语义 |
 * |---|---|
 * | `source.getVariable()` / `setVariable(str)` | **站方变量**（一整串） |
 * | `source.get(key)` / `put(key, value)` | **书源变量**（map） |
 *
 * ⚠️⚠️ **轻阅以前把两套混成一份** ⇒ 三个真 bug：
 *   ① 聚合源（UAA）把 token 存站方变量 ⇒ 请求头 `Bearer {"androidId":"…"}`
 *      ⇒ 服务端 **403「无效JWT」** ⇒ **永远拿不到 token** ⭐⭐⭐
 *   ② 聚合源（NovelHub）改一次发现页筛选（`setVariable(JSON…)`）⇒ **解锁态被冲掉** ⭐
 *   ③ 站方 `setVariable(token)` 会把 `put` 存的项**整份冲掉** ⭐
 *
 * ⚠️ **为什么不能改 `getVariable()` 的老行为**（老宿主兜底）：
 *   没塞 `__variable` 的宿主 ⇒ `getVariable()` 仍返回整份书籍变量 ⇒ 零影响 ⭐
 *
 * ────────────────────────────────────────────────────────────
 * 本门禁：
 *   ① 跑**同一份契约**（`test/fixtures/source-variable-contract.json`）的三种用法
 *   ② 断言 **App 侧接线**（喂 `__variable` / 落盘 `__sourceVariable`）
 *   ③ **变异对照**：把老引擎的拆分改回混着 ⇒ 必须红（证明门禁抓得住）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const root = path.join(__dirname, '..');
const CONTRACT = path.join(root, 'test', 'fixtures', 'source-variable-contract.json');
const API = path.join(root, 'QiReaderLite', 'Resources', 'engine', 'source-api.js');
const APP = path.join(root, 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log(`  ✓ ${m}`); }
  else { fail++; console.log(`  ✗ ${m}${extra ? '  → ' + extra : ''}`); }
};

(async () => {
  console.log('=== 0. 文件在不在 ===');
  ok(fs.existsSync(CONTRACT), '契约文件在');
  ok(fs.existsSync(API), '老引擎 source-api.js 在');
  if (!fs.existsSync(CONTRACT) || !fs.existsSync(API)) {
    console.log(`\n通过 ${pass} / 失败 ${fail}`); process.exit(1);
  }
  const contract = JSON.parse(fs.readFileSync(CONTRACT, 'utf8'));

  console.log('\n=== 1. 老引擎：跑同一份契约 ===');
  const { win } = createSandbox({});
  for (const c of contract.cases) {
    const steps = c.steps.map(s => (s.capture
      ? `out[${JSON.stringify(s.capture)}] = String(${s.js});`
      : `${s.js};`)).join('\n');
    const code = `
      var source = QR.wrapSource(${JSON.stringify(c.source)});
      var out = {};
      ${steps}
      JSON.stringify(out);
    `;
    let got = {};
    try { got = JSON.parse(await win.eval(code)); }
    catch (e) { ok(false, `${c.name} ⇒ 跑挂了`, String(e && e.message || e)); continue; }
    let allOk = true;
    for (const [k, v] of Object.entries(c.expect)) {
      if (got[k] !== v) { allOk = false; ok(false, `${c.name} ⇒ ${k}`, `期望 ${JSON.stringify(v)}，实际 ${JSON.stringify(got[k])}`); }
    }
    if (allOk) ok(true, `${c.name} ✔`);
  }

  console.log('\n=== 2. App 侧接线（喂进去 / 落盘回来）===');
  const sv = fs.readFileSync(path.join(APP, 'Core', 'SourceVariables.swift'), 'utf8');
  ok(/static func variable\(for sourceUrl: String\)/.test(sv), '有「站方变量」独立槽位');
  ok(/static func setVariable\(_ value: String, for sourceUrl: String\)/.test(sv), '站方变量能落盘');
  ok(/sourcevariable\./.test(sv), '站方变量用**独立的** UserDefaults 键（不跟书籍变量混）');

  const svc = fs.readFileSync(path.join(APP, 'Core', 'SourceService.swift'), 'utf8');
  const feedCount = (svc.match(/srcDict\["__variable"\]/g) || []).length;
  ok(feedCount >= 6, `每个 op 都喂了 __variable（现在 ${feedCount} 处）`);
  const saveCount = (svc.match(/__sourceVariable/g) || []).length;
  ok(saveCount >= 3, `站方变量会落盘（现在 ${saveCount} 处）`);

  const backend = fs.readFileSync(path.join(APP, 'Core', 'LegadoEngineBackend.swift'), 'utf8');
  ok(/sourceVariable: sourceVariable/.test(backend), '新引擎的站方变量槽位接上了');
  ok(/dict\["__sourceVariable"\]/.test(backend), '新引擎回传站方变量');

  console.log('\n=== 3. 变异对照：把老引擎改回「混成一份」⇒ 必须红 ===');
  const src = fs.readFileSync(API, 'utf8');
  const mutated = src.replace(
    "      if (hasVariable) return variable;   // ⭐ Legado 语义\n      return vars;                          // 老宿主兜底",
    "      return vars;");
  ok(mutated !== src, '变异成功（把 getVariable 改回整份书籍变量）');
  if (mutated !== src) {
    // ⚠️ **必须真的改文件**再跑（harness 是从磁盘加载脚本的）
    const bak = src;
    try {
      fs.writeFileSync(API, mutated, 'utf8');
      const { win: win2 } = createSandbox({});
      const c = contract.cases.find(x => x.name.indexOf('UAA') >= 0);
      const steps = c.steps.map(s => (s.capture
        ? `out[${JSON.stringify(s.capture)}] = String(${s.js});`
        : `${s.js};`)).join('\n');
      const code = `
        var source = QR.wrapSource(${JSON.stringify(c.source)});
        var out = {};
        ${steps}
        JSON.stringify(out);
      `;
      let got = {};
      try { got = JSON.parse(await win2.eval(code)); } catch (e) {}
      ok(got.variable !== c.expect.variable,
         '变异版「UAA 式」那条**会红**（token 被整份 map 污染）',
         `实际 ${JSON.stringify(got.variable)}`);
    } finally {
      fs.writeFileSync(API, bak, 'utf8');   // ⭐ 还原
    }
    // 还原后再跑一次 ⇒ 必须绿（证明还原干净）
    const { win: win3 } = createSandbox({});
    const c = contract.cases.find(x => x.name.indexOf('UAA') >= 0);
    const steps = c.steps.map(s => (s.capture
      ? `out[${JSON.stringify(s.capture)}] = String(${s.js});`
      : `${s.js};`)).join('\n');
    const got = JSON.parse(await win3.eval(`
      var source = QR.wrapSource(${JSON.stringify(c.source)});
      var out = {};
      ${steps}
      JSON.stringify(out);
    `));
    ok(got.variable === c.expect.variable, '还原后「UAA 式」恢复绿 ✔');
  }

  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
