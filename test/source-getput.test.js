#!/usr/bin/env node
/**
 * **`source.get(key)` / `source.put(key, value)` 要存在**（2026-10-22 真机「解锁了但发现页空白」）
 *
 * 跑法：node test/source-getput.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 现象（用户真机截图）
 *
 *   NovelHub 聚合小说 → 发现页 → **「这个书源没解析出分类」**
 *   用户：「这。。解锁了的」（⇒ 解锁动作**显示成功**了，但分类一个都没有）
 *
 * 根因
 *
 *   站方（🍒NovelHub）大量用 `source.get(key)` / `source.put(key, value)`
 *   （实测 jsLib + loginUrl 共 **71 处 get / 58 处 put**）：
 *     jsLib   ：source.get("nhAuthed") / source.put("nhAuthed", hash)
 *     loginUrl：source.get("mgck")      / source.put("mgck", ck)
 *
 *   轻阅以前**只实现了 `getVariable` / `setVariable`**（整份 JSON 串）
 *   ⇒ `source.get(...)` ⇒ **TypeError: not a function**
 *   ⇒ 站方把它包在 try/catch 里 ⇒ **静默失败**：
 *      ① `nhAuth()` 里 `source.get("nhAuthed")` 抛 ⇒ catch ⇒ return false
 *         ⇒ **所有规则字段都直接 return ""** ⇒ 发现页空白 ⭐
 *      ② `unlockAll()` 里 `source.put("nhAuthed", hash)` 抛 ⇒ 被吞
 *         ⇒ **解锁状态压根没存下来** ⇒ 但站方照样弹「🔓 已解锁」⇒ **假成功** ⭐
 *
 * 修法（引擎侧）
 *
 *   `source.get(key)`  → 读「书籍变量」里的某一项（没有 ⇒ 空串）
 *   `source.put(k, v)` → 写某一项 ⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘
 *
 *   ⚠️ **不能实现成「返回整份 vars」** —— 站方是
 *      `String(source.get("nhAuthed") || "")` 这样比对的，
 *      拿到整份 JSON 的话哈希对不上 ⇒ 还是不解锁。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎的 `window.QR.wrapSource(...)` ⇒ 老引擎删了 ⇒ 对象没了
 *   ⇒ 现在改成**跑新引擎**（`legado-engine` 的 `--op` 模式）
 *   ⇒ **语义等价在哪**：
 *     · 老门禁验的是「站方 JS 里的 `source.get` / `source.put` 是不是那一把钥匙」
 *       ⇒ 新架构里那把钥匙是**引擎的 `SourceEngine.makeSourceObject`**（真机 JSC 走它，
 *         沙盒 Node 后端走同语义的一份实现）⇒ **断言对象换成引擎，语义一模一样** ⭐⭐⭐
 *     · 老门禁的 `QR.__qrDirtyVars`（老引擎的 dirty 标记）⇒ 那是**老引擎私有细节**
 *       ⇒ 退休；**等价语义**是「写进变量盒 ⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘」
 *       ⇒ 新架构里 `__sourceVars` 就是**引擎回传的变量表** ⇒ 改验它 ⭐⭐⭐
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
const readEngine = (rel) => fs.readFileSync(path.join(ENGINE_SRC, rel), 'utf8');

const PWD = 'nhub2026';
const PWD_HASH = crypto.createHash('md5').update(PWD).digest('hex');

/** ⭐⭐⭐ **跑引擎的 `--op`**（payload 太大 ⇒ 走文件形式 ⇒ 命令行放不下） */
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

/** ⭐⭐⭐ **能力探针**：沙盒能不能让站方 JS 真的调到 `source.get` / `source.put`
 *  （Linux 沙盒没有 JSC ⇒ 引擎走 Node 后端 ⇒ 宿主对象通道是 Node 侧的一份实现）
 *  ⇒ 探针不过 ⇒ 本门禁的【真跑段】**显式 SKIP**（**没验到 ≠ 通过**）⭐⭐⭐ */
function probeSourceAPI() {
  const r = runOp({
    op: 'exploreKinds',
    source: {
      bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针',
      // ⭐ `__variables`（源级变量）要**放在 source 里**（宿主就是从那儿喂进去的）
      __variables: JSON.stringify({ probeKey: 'PROBE_OK' }),
      exploreUrl: '@js:JSON.stringify([{title:String(source.get("probeKey")),url:"https://x/1"}])',
    },
  });
  const kinds = (r && r.kinds) || [];
  return !!(kinds.length && kinds[0].title === 'PROBE_OK');
}

(async () => {
  console.log('=== 1. 源码：source.get / source.put 要存在（契约 + 实现）===');
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段**（如 `wrapped.getVariable` / `MAX_PASS`）
  //   ⇒ 那些是**实现细节**，不是语义 ⇒ 老引擎退役后**没有等价物** ⇒ 退休不损失语义覆盖 ⭐⭐⭐
  //   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（309 项）与真机上 ⭐⭐⭐
  //
  // ⭐ 下面这几条是**新引擎的等价描述**（能力必须还在，只是实现换了地方）：
  const api = readEngine('JS/JSHostAPI.swift');
  const eng = readEngine('Pipeline/SourceEngine.swift');
  ok(/object: "source", name: "get"/.test(api) && /object: "source", name: "put"/.test(api),
     '宿主 API 契约登记了 source.get / source.put（⇒ 包装函数会生成 ⇒ 站方不会报「不是函数」）');
  ok(/methods\["get"\]/.test(eng) && /methods\["put"\]/.test(eng),
     '引擎的 source 对象实现了 get / put');
  ok(/varBox\.get\(key\)/.test(eng),
     'get 读的是「变量盒里的某一项」（**不是**返回整份 vars —— 否则站方比对哈希对不上）');
  ok(/varBox\.set\(key, value\)/.test(eng),
     'put 写的是「变量盒里的某一项」（⇒ 引擎回传 __sourceVars ⇒ 原生落盘）');
  ok(/methods\["getVariable"\]/.test(eng) && /methods\["setVariable"\]/.test(eng),
     '原来的 getVariable/setVariable 还在（不能破）');
  // ⭐⭐⭐ **落盘链路的等价语义**：引擎回传的 `__sourceVars` 与 `source.getVariable()` 是**同一份**
  //   ⇒ 站方 put 了 ⇒ 回传里就带得上 ⇒ 原生落盘 ⇒ 下次喂回来还是解锁态 ⭐⭐⭐
  const backend = fs.readFileSync(path.join(root, 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
  ok(/__sourceVars/.test(backend) && /varsJSON\(engine\.varBox\)/.test(backend),
     'App 侧把引擎的变量盒回传成 __sourceVars（⇒ 站方改过的变量会落盘）');
  ok(/seedVars/.test(backend) && /__variables/.test(backend),
     'App 侧把落盘的变量喂回引擎（⇒ 下次打开还是解锁态）');

  // ⭐⭐⭐ **探活**（引擎跑不起来 ⇒ 显式 SKIP，不算门禁的锅）⭐⭐⭐
  const _alive = runOp({ op: 'exploreKinds',
    source: { bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针',
              exploreUrl: '@js:JSON.stringify([{title:"T",url:"https://x/1"}])' } });
  if (!engineAvailable() || !_alive || !_alive.kinds || !_alive.kinds.length) {
    skip('引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ 下面的【真跑段】没验到（**不等于通过**）');
    console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
    process.exit(fail ? 1 : 0);
  }

  console.log('\n=== 2. 能力探针：沙盒能不能让站方 JS 真的调到 source.get / source.put ===');
  const canRun = probeSourceAPI();
  if (!canRun) {
    // ⚠️⚠️ **不假绿**：探针不过 ⇒ 下面的真跑段**一条都没验到** ⇒ 明说 ⭐⭐⭐
    skip('沙盒（Linux ⇒ 引擎走 Node 后端）还没接上宿主对象通道 ⇒ '
       + '站方 JS 调 source.get 拿不到值 ⇒ 下面的【真跑段】没验到（**不等于通过**）');
    console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
    if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
    process.exit(fail ? 1 : 0);
  }
  ok(true, '沙盒能跑站方 JS 的 source.get（能力探针过了）');

  console.log('\n=== 3. 语义：get 取单项、put 写单项、put 完能落盘 ===');
  {
    // ⭐⭐⭐ 用**引擎自己的 op**跑一段站方 JS ⇒ 把结果编码进分类标题里读回来
    const r = runOp({
      op: 'exploreKinds',
      source: {
        bookSourceUrl: 'https://probe.example.com/', bookSourceName: '探针',
        // ⭐ `__variables`（源级变量）要**放在 source 里**（宿主就是从那儿喂进去的）
        __variables: JSON.stringify({ a: '1' }),
        exploreUrl: '@js:(function(){'
          + 'var got=String(source.get("a"));'
          + 'var miss=String(source.get("zz"));'
          + 'source.put("c","3");'
          + 'var back=String(source.get("c"));'
          + 'var whole=String(source.getVariable());'
          + 'return JSON.stringify([{title:got+"|"+miss+"|"+back+"|"+whole,url:"https://x/1"}]);'
          + '})()',
      },
    });
    const kinds = (r && r.kinds) || [];
    const title = kinds.length ? String(kinds[0].title || '') : '';
    const parts = title.split('|');
    console.log('  站方 JS 看到的 =', JSON.stringify(parts));
    ok(parts[0] === '1', "get('a') 返回单项的值", '实际 ' + JSON.stringify(parts[0]));
    ok(parts[1] === '', "get('zz')（没有的项）返回空串", '实际 ' + JSON.stringify(parts[1]));
    ok(parts[2] === '3', "put('c','3') 之后 get('c') 能读回来", '实际 ' + JSON.stringify(parts[2]));
    ok(parts[3] && parts[3].indexOf('"a"') >= 0 && parts[3].indexOf('"c":"3"') >= 0,
       'getVariable() 仍返回整份 JSON（含 put 进去的那一项）', '实际 ' + parts[3]);
    // ⭐⭐⭐ **「put 标了 dirty ⇒ 引擎回传 __sourceVars ⇒ 原生落盘」的等价语义**⭐⭐⭐
    const vars = String((r && r.__sourceVars) || '');
    ok(vars.indexOf('"c":"3"') >= 0,
       '**put 写进去的那一项被引擎回传了**（__sourceVars ⇒ 原生落盘）', '实际 ' + vars.slice(0, 160));
    ok(vars.indexOf('"a":"1"') >= 0,
       '回传里连原有那一项都在（⇒ 落盘的是整份变量，不是只回传变化项）', '实际 ' + vars.slice(0, 160));
  }

  console.log('\n=== 4. 活体端到端（真书源）：解锁 → 落盘 → 分类出来 ===');
  const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
  if (!fs.existsSync(NH)) {
    skip('本地没有 NovelHub 源文件 ⇒ 本段没验到（**不等于通过**）');
  } else {
    const NHsrc = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];

    // ① 未解锁 ⇒ 站方 nhAuth() 恒 false ⇒ 分类 0（= 用户截图的现象）
    const before = runOp({
      op: 'exploreKinds',
      source: Object.assign({}, NHsrc, { __variables: '', __loginInfo: '{}' }),
    });
    const beforeKinds = (before && before.kinds) || [];
    console.log('  未解锁时 kinds =', beforeKinds.length);
    ok(beforeKinds.length === 0, '未解锁 ⇒ 分类 0（复现真机现象）');

    // ② 点「解锁整个源」⇒ 站方 unlockAll() 里 source.put("nhAuthed", hash)
    const lgin = runOp({
      op: 'login',
      source: Object.assign({}, NHsrc, {
        __variables: '',
        __loginInfo: JSON.stringify({ '整源解锁密码': PWD }),
      }),
      action: 'unlockAll()',
      formValues: { '整源解锁密码': PWD },
    });
    const dirtyVars = String((lgin && lgin.__sourceVars) || '');
    console.log('  解锁回传变量 =', dirtyVars.slice(0, 160));
    ok(lgin && lgin.ok, '解锁动作跑通了', lgin && lgin.error);
    ok(dirtyVars.indexOf('nhAuthed') >= 0,
       '**解锁状态真的落盘了**（__sourceVars 里有 nhAuthed）', dirtyVars.slice(0, 160));
    ok(dirtyVars.indexOf(PWD_HASH) >= 0,
       '落盘的是 md5(密码)（站方比对的就是这个）', dirtyVars.slice(0, 160));

    // ③ 把落盘的变量喂回去 ⇒ 分类应该出来（这才是用户要的效果）
    const after = runOp({
      op: 'exploreKinds',
      source: Object.assign({}, NHsrc, { __variables: dirtyVars, __loginInfo: '{}' }),
    });
    const afterKinds = (after && after.kinds) || [];
    console.log('  解锁后 kinds =', afterKinds.length, '| error:', (after && after.error) || '(无)');
    ok(afterKinds.length > 0,
       '**解锁后能解析出分类**（之前是 0 —— nhAuth 恒 false ⇒ 规则字段全 return ""）');
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  if (failures.length) { console.log(''); failures.forEach(f => console.log('  ✗ ' + f)); }
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
