#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：`Self.<方法>` 必须【在外层类型存在】**（Linux 沙盒编不到的那一半）
 *
 * ⚠️⚠️⚠️ **为什么必须有这条门禁**（2026-11-19 CI build300 实证）：
 *   我把 `mergeLoginInfo` / `stripLoginInfo` / `variableDict` / `loginInfoDict`
 *   加在**嵌套的 `Session` 类**里 ⇒ 调用点却写成 `Self.xxx`
 *   ⇒ 而那些调用点在**外层类型的方法体**里 ⇒ 那里 `Self` = **外层 `LegadoEngineBackend`**
 *   ⇒ 外层没有这些方法 ⇒ **Apple 平台编译失败**：
 *     `type 'Self' has no member 'stripLoginInfo'` ⭐⭐⭐
 *
 *   ⚠️⚠️⚠️ **而 Linux 沙盒的编译门禁【抓不到】**：
 *     那段代码在 `#if canImport(JavaScriptCore) && !os(Linux)` **里面**
 *     ⇒ Linux 编译时整段被排除 ⇒ **沙盒全绿、CI 才红** ⭐⭐⭐
 *     ⇒ 「沙盒门禁绿」≠「代码能编」——**这次落在 Apple-only 块上** ⭐⭐⭐
 *
 * ⭐⭐⭐ **本门禁的判据（简单但够用）**：
 *   `Self.<方法>` 的 `<方法>` 必须在**外层类型**里定义 ⭐⭐⭐
 *   · 若只在**嵌套类型**里定义 ⇒ 报红（**外层作用域拿不到** ⇒ 编译失败）⭐⭐⭐
 *   · 若外层也有 ⇒ 放行（嵌套类型里调 `Self.` 指的是**嵌套类型自己** ⇒ 也合法）⭐⭐⭐
 *   ⇒ **两种情况都编译得过** ⇒ 判据不会误报 ⭐⭐⭐
 *   ⇒ 而「外层没有、只有嵌套有」⇒ **必定编译失败** ⇒ 判据不会漏报 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

function stripComments(t) {
  return t
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ');
}

const raw = fs.readFileSync(APP, 'utf8');
const code = stripComments(raw);
const lines = code.split('\n');

// ── ① 类型声明（顶层 / 嵌套）───────────────────────────────────────────
const typeDecls = [];
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^(\s*)(?:public\s+|private\s+|fileprivate\s+|internal\s+|final\s+|open\s+)*(class|struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/);
  if (m) typeDecls.push({ name: m[3], kind: m[2], indent: m[1].length, line: i, members: new Set() });
}
ok(typeDecls.length > 0, `扫到 ${typeDecls.length} 个类型声明`);
const outer = typeDecls.filter((t) => t.indent === 0);
ok(outer.length > 0, `顶层类型：${outer.map((t) => t.name).join(', ')}`);

// ── ② 收集每个类型的 static 成员（按「类型体范围」= 到下一个同/更浅缩进声明）──
// ⚠️⚠️⚠️ **类型体结束【不能靠缩进】**（2026-11-19 实证）：
//   Swift 的缩进不固定（continuation 行、闭包、字符串都会干扰）
//   ⇒ 「缩进回退」判据会让嵌套类型的范围吞掉外层 ⇒ 成员收错 ⇒ 门禁失灵 ⭐⭐⭐
//   ⇒ 正解：**花括号配平**（类型体的 `{ … }`）⇒ 与编译器看到的结构一致 ⭐⭐⭐
function bodyEnd(t) {
  let depth = 0, seen = false;
  for (let k = t.line; k < lines.length; k++) {
    const l = lines[k];
    for (const ch of l) {
      if (ch === '{') { depth++; seen = true; }
      else if (ch === '}') {
        depth--;
        if (seen && depth === 0) return k + 1;   // 类型体闭合
      }
    }
    // ⚠️ 类型声明行本身没有 '{'（Swift 允许 `class X {` 或 `class X` 换行）
    if (k === t.line && l.includes('{')) { /* 已在上面处理 */ }
  }
  return lines.length;
}
for (const t of typeDecls) {
  const end = bodyEnd(t);
  for (let i = t.line + 1; i < end; i++) {
    const m = lines[i].match(/static\s+(?:func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)/);
    if (!m) continue;
    // ⭐⭐⭐ **必须【排除嵌套类型内部的成员】**（2026-11-19 实证）：
    //   外层的范围**包含**嵌套类型 ⇒ 不排除的话 ⇒ 嵌套的成员会被算成外层的
    //   ⇒ 「外层没有、只有嵌套有」判不出来 ⇒ **门禁失灵** ⭐⭐⭐
    let inNested = false;
    for (const o of typeDecls) {
      if (o === t) continue;
      // ⚠️⚠️ **只当 o 比 t 【更内层】才算「在嵌套类型里」**（2026-11-19 实证）：
      //   否则**外层类型**也会把嵌套类型的成员收进来 ⇒ 判据失灵 ⭐⭐⭐
      if (o.indent <= t.indent) continue;
      if (o.line < i && i < bodyEnd(o)) { inNested = true; break; }
    }
    if (inNested) continue;
    t.members.add(m[1]);
  }
}

// ── ③ 逐个 `Self.<方法>` 调用点判定 ───────────────────────────────────
console.log('\n=== 逐个 Self.<方法> 调用点判定 ===');
const calls = [];
for (let i = 0; i < lines.length; i++) {
  for (const m of lines[i].matchAll(/\bSelf\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
    calls.push({ line: i + 1, name: m[1], text: lines[i].trim().slice(0, 70) });
  }
}
ok(calls.length > 0, `扫到 ${calls.length} 处 Self.<方法> 调用`);

// ⭐⭐⭐ **调用点归属**：它在【哪个类型】里？⇒ 那里 `Self` = 那个类型 ⭐⭐⭐
//   （Swift 语义：嵌套类型里的 `Self` = **嵌套类型自己**，不是外层！）⭐⭐⭐
function ownerOf(lineNo) {
  const idx = lineNo - 1;
  let best = null;
  for (const t of typeDecls) {
    if (!(t.line < idx && idx < bodyEnd(t))) continue;
    if (!best || t.indent > best.indent) best = t;   // 最内层
  }
  return best;
}

for (const c of calls) {
  const owner = ownerOf(c.line);
  if (!owner) {
    ok(false, `第 ${c.line} 行 Self.${c.name}(…) 找不到所属类型`, c.text);
    continue;
  }
  const has = owner.members.has(c.name);
  ok(has,
     `第 ${c.line} 行 Self.${c.name}(…) ⇒ 所属类型「${owner.name}」里有 static ${c.name}`,
     `★ 所属类型「${owner.name}」里**没有** static ${c.name}`
     + ` ⇒ 编译失败「type 'Self' has no member '${c.name}'」`
     + `（⚠️ 若这段在 \`#if canImport(JavaScriptCore)\` 里 ⇒ Linux 沙盒门禁编不到 ⇒ 只有 CI 能抓）`);
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
