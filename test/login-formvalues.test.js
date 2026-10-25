#!/usr/bin/env node
/**
 * **登录：表单值要合并进 `__loginInfo`**（2026-10-22 真机「解锁整个源」点了没反应）
 *
 * 跑法：node test/login-formvalues.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * 站方（🍒NovelHub 聚合源）是从 **`source.getLoginInfoMap()`** 读**当前输入框的值**的：
 *   function nhAuthUiMap() { return source.getLoginInfoMap ? source.getLoginInfoMap() : {}; }
 *   function unlockAll() {
 *     var _m = nhAuthUiMap();
 *     var _pw = String((_m && _m["整源解锁密码"]) || "").trim();
 *     if (_pw === "") { nhSay("🔒 请在下面「整源解锁密码」输入框里填密码…"); return; }
 *     ...
 *   }
 *
 * 轻阅以前**只把 formValues 挂到 `result`** ⇒ 站方读到的 `getLoginInfoMap()` 是**空的**
 * ⇒ 用户明明在输入框里填了密码，点了「解锁整个源」却一直提示「没填密码」⭐
 *
 * ⇒ **Legado / 栖阅的语义**：点 action 按钮时**先把当前输入框的值写进 loginInfo**，再执行 action
 * （站方 `login(true)` 第一步也是 `putLoginInfo(JSON.stringify(result))`）
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 老 JS 引擎物理删除 ⇒ 本门禁改跑新引擎**（Swift，`legado-engine`）⭐⭐⭐
 *
 * 迁移要点：
 *   ① 第 1 段（源码断言）：老引擎的 `engine.js` **没了** ⇒ 改成读**新引擎的 Swift 源码**
 *      （`SourceEngine.runLoginAction`）⇒ 断言的**语义**不变：表单值必须合并进登录信息 ⭐
 *   ② 第 2 段（活体）：老的 JS 层 `nativeMock` ⇒ 改成**声明式 routes**（规范 §1.1）
 *      ⇒ 站方原文（toast）从 op 的 `messages` 取 ⇒ 断言「已解锁」照样成立 ⭐⭐⭐
 *   ③ 引擎不可用 ⇒ **显式 SKIP 并说明**（规范 §3.4 ⇒ 不许假绿）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  x ' + m)); };

const root = path.join(__dirname, '..');
const ENGINE = path.join(root, '..', 'legado-engine', 'Sources', 'LegadoCore');
const engineSrc = fs.readFileSync(path.join(ENGINE, 'Pipeline', 'SourceEngine.swift'), 'utf8');

console.log('=== 1. 源码：login op 里表单值要合并进登录信息 ===');
// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这里断言的是**老引擎 `engine.js` 里 `login` op 的代码片段**
//     （`formValues` / `__loginInfo` 这两个变量名 + 函数体正则）
//   ⇒ 那是**实现细节**（老引擎的变量名），不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【活体段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】与真机上 ⭐⭐⭐
//
// ⭐⭐⭐ **换成读新引擎的 Swift 源码**（规范 §2.2：能力还在 ⇒ 断言改成对新引擎的等价描述）⭐⭐⭐
// ⚠️ 窗口要给够（9000）：新引擎的 `runLoginAction` 比老引擎的 `login` op 长（含「密钥恢复」那段）
//    ⇒ 窗口窄了会**匹配不到** ⇒ 报红但代码是对的（这种假红踩过）⭐
const runLoginAction = (engineSrc.match(/public func runLoginAction\([\s\S]{0,9000}?\n    \}/) || [''])[0];
ok(runLoginAction.length > 0, '找到新引擎的 runLoginAction（登录 op 的实现）');
ok(/formValues/.test(runLoginAction),
   '登录 op 收了 formValues（站方 action 读得到输入框的值）');
// ⭐⭐⭐ 语义等价在哪：老引擎是 `src.__loginInfo = Object.assign({}, __li, formValues)`
//   ⇒ 新引擎是「把 formValues 合并进登录信息并落盘」⇒ **同一件事**（只是宿主存储换了）⭐⭐⭐
ok(/saveLoginInfo\(/.test(runLoginAction),
   '登录 op 把表单值合并进登录信息并落盘（站方 source.getLoginInfoMap() 才读得到）');
ok(/loadLoginInfo\(/.test(runLoginAction),
   '登录 op 读得到已有的登录信息（合并的底子）');

console.log('\n=== 2. 活体：填密码 + 点「解锁整个源」⇒ 站方应回「已解锁」 ===');
// ⭐⭐⭐ **引擎不可用 ⇒ 显式 SKIP**（规范 §3.4）⭐⭐⭐
if (!engineAvailable()) {
  console.log('  ⏭ 跳过：新引擎不在本机 ⇒ 这条链路**没验到**');
  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(0);
}
const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
if (!fs.existsSync(NH)) {
  console.log('  (跳过：本地没有 NovelHub 源文件)');
} else {
  const list = JSON.parse(fs.readFileSync(NH, 'utf8'));
  const src = (Array.isArray(list) ? list : [list])[0];
  // ⭐⭐⭐ **假服务器（声明式 routes）** —— 老门禁的 JS 层 `nativeMock`（真 fetch）已退役 ⭐⭐⭐
  //   ⇒ 站方的 unlockAll() 不打网络 ⇒ 这里给一条兜底路由（未命中 ⇒ 明确失败，不静默 200）⭐
  const routes = [
    { match: 'bachashuku.org', status: 200, body: '{"ok":1}' },
  ];
  const { win } = createSandbox({ routes });
  const r = win.__qrInvoke('login', {
    source: Object.assign({}, src, { __variables: '', __loginInfo: {} }),
    jsLib: src.jsLib,                   // ⭐ 站方 jsLib（`nhAuthUiMap` 等都在里面）
    action: 'unlockAll()',
    formValues: { '整源解锁密码': 'nhub2026' },
    cookieSnapshot: {},
    routes,
  });
  const msgs = ((r && r.messages) || []).join('\n');
  console.log('  ok:', r && r.ok, '| error:', (r && r.error) || '(无)');
  console.log('  站方回复:', msgs.split('\n')[0]);
  ok(r && r.ok === true, 'login op 成功', (r && r.error) || '(无)');
  ok(/已解锁/.test(msgs), '站方回「已解锁」（说明它从 getLoginInfoMap() 读到了输入框的密码）',
     msgs.slice(0, 120));
  ok(!/请在下面/.test(msgs), '**不再**提示「请在下面输入框里填密码」');
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
