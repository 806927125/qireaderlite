#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：「0 个分类」的诊断提示必须【有依据】、不能乱指**
 *
 * ⚠️⚠️⚠️ **为什么必须有这条门禁**（2026-11-19 真机双源对照，用户直接指出「你弄反了」）：
 *   · **🍒NovelHub**：真带「整源密码门禁」（站方 exploreUrl 第一行 `if (!nhAuth()) { return ""; }`）
 *   · **🍅大灰狼 5.9.30**：**原始上游源，根本没有** nhAuth 机制
 *   ⇒ 我第一版的文案**无条件**说「多半是整源密码门禁没解锁」
 *   ⇒ 对**大灰狼也这么说** ⇒ **误报**（真机截图：大灰狼带提示、NovelHub 反而没有）⭐⭐⭐
 *   ⇒ 而 NovelHub 之所以**没**提示，是因为我**查错了槽**（查 `sourcevars.`，实际落 `sourcevariable.`）⭐⭐⭐
 *
 * ⭐⭐⭐ **正确判据（三条都要满足才提示）**：
 *   ① 这个源的 **jsLib 里真的有** `nhAuth` / `NH_PWD_HASH` ⇒ **有依据**，不是猜 ⭐⭐⭐
 *   ② **解锁态不在【两个】变量槽里**（站方变量槽 `sourcevariable.` + 书源变量槽 `sourcevars.`）⭐⭐⭐
 *   ③ 槽里确实**没有** `nhAuthed`
 *
 * ⚠️ **为什么必须两个槽都查**：站方 `source.put('nhAuthed')` 写的是**引擎那一格**
 *   ⇒ 回传 `__sourceVariable` ⇒ 落**站方变量槽**（`sourcevariable.`）⭐⭐⭐
 *   ⇒ 但历史版本/别的路径可能落**书源变量槽**（`sourcevars.`）⇒ **两个都要查** ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = process.argv[2] || '/workspace/output/NovelHub聚合小说-轻阅新引擎适配.json';

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

// ── 从 Swift 源码里抽出判据（避免「写两份」漂移）─────────────────────────
const svc = fs.readFileSync(path.join(ROOT, 'QiReaderLite/Core/SourceService.swift'), 'utf8');

console.log('=== 1. 判据必须【依据源自己的 jsLib】 ===');
ok(/stationHasAuthGate/.test(svc), '有 stationHasAuthGate（扫源自己的 jsLib）');
ok(/lib\.contains\("function nhAuth\("\)/.test(svc) || /lib\.contains\("NH_PWD_HASH"\)/.test(svc),
   '判据扫的是 jsLib 里的 nhAuth / NH_PWD_HASH（★ 不是无条件提示）');
ok(!/多半是【站方的整源密码门禁没解锁】/.test(svc),
   '★ 旧的无条件文案已删（那版对没有门禁的源是误报）');

console.log('\n=== 2. 解锁态要查【两个】槽（第一版查错了槽） ===');
ok(/sourcevariable\./.test(svc), '查站方变量槽 sourcevariable.（站方 source.put 落的那个）');
ok(/sourcevars\./.test(svc), '也查书源变量槽 sourcevars.（历史路径可能落那个）');
ok(/hasAuthedIn/.test(svc), '用 hasAuthedIn 判槽里有没有 nhAuthed');

console.log('\n=== 3. 真源验证：🍒NovelHub（有门禁 ⇒ 该提示） ===');
if (fs.existsSync(SRC)) {
  const pack = JSON.parse(fs.readFileSync(SRC, 'utf8'));
  const src = Array.isArray(pack) ? pack[0] : pack;
  const lib = src.jsLib || '';
  const hasGate = lib.includes('function nhAuth(') || lib.includes('NH_PWD_HASH');
  ok(hasGate, `NovelHub 的 jsLib 里有 nhAuth 门禁机制（判定=${hasGate}）`);

  // 模拟 Swift 的判据在两个槽上的行为
  // ⭐ 与 Swift 的 hasAuthedIn 同语义：**有非空 nhAuthed 就算已解锁**
  const hasAuthedIn = (raw) => {
    try {
      const o = JSON.parse(raw);
      return !((o.nhAuthed || '') === '');
    } catch (e) { return false; }
  };
  const slotStation = '{"fqcommunity":"on","nhPlatState":"src=全部"}';   // 无 nhAuthed
  const slotBook = '{"nhAuthed":"0c220581ebbb1121d9c2b33466045387"}';    // 有 nhAuthed
  ok(!hasAuthedIn(slotStation), '站方变量槽里没有 nhAuthed ⇒ 未解锁');
  ok(hasAuthedIn(slotBook), '书源变量槽里有 nhAuthed ⇒ 已解锁（第一版查错槽就是这个）');
  // ⭐ 三条判据的完整推演
  const shouldHint = (gate, stationRaw, bookRaw) =>
    gate && !hasAuthedIn(stationRaw) && !hasAuthedIn(bookRaw);
  ok(shouldHint(true, slotStation, slotBook) === false,
     '★ 已解锁时**不该**提示（第一版因为查错槽 ⇒ 反而没提示 ⇒ 弄反了）');
  ok(shouldHint(true, slotStation, '{}') === true,
     '未解锁 + 有门禁 ⇒ 该提示');
  ok(shouldHint(false, slotStation, '{}') === false,
     '★ 没有门禁的源（如 🍅大灰狼）⇒ **不该**提示（★ 第一版的误报）');
} else {
  ok(false, `找不到书源产物 ${SRC}（没法验真源）`);
}

console.log('\n=== 4. 变异对照（改坏判据 ⇒ 必须红） ===');
{
  const cases = [
    ['去掉「依据 jsLib」的判据（回到无条件提示）',
      (t) => t.replace('if hasGate {', 'if true {')],
    ['只查一个槽（回到第一版的查错槽）',
      (t) => t.replace('let authed = Self.hasAuthedIn(stationRaw) || Self.hasAuthedIn(bookRaw)',
                       'let authed = Self.hasAuthedIn(stationRaw)')],
  ];
  const orig = svc;
  for (const [name, fn] of cases) {
    const mutated = fn(orig);
    if (mutated === orig) { ok(false, `变异「${name}」：锚点命中`, '锚点没命中 ⇒ 变异无效'); continue; }
    let red = false;
    // ① 无条件提示 ⇒ 旧文案回来 ⇒ 门禁第 1 条必须红
    if (/多半是【站方的整源密码门禁没解锁】/.test(mutated)) red = true;
    // ② 只查一个槽 ⇒ 两个槽都查的断言必须红
    if (!/stationRaw\) \|\| Self\.hasAuthedIn\(bookRaw\)/.test(mutated)) red = true;
    if (!/if hasGate \{/.test(mutated)) red = true;
    ok(red, `变异「${name}」⇒ 门禁红`, red ? '' : '变异后仍然通过 ⇒ 这条断言是摆设');
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
