#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **「生成的 JS」必须过一次语法检查**（2026-10-25 真机级事故）
 *
 * 跑法：node test/generated-js-syntax.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景（这不是假想，是今天真发生的事）
 *
 * 引擎的 Node 后端是一大段**写在 Swift 里的 JS**（`NodeJSExecutor.harnessSource`）。
 * 那天有人在里面加了一行注释：
 *
 *     // ⭐⭐⭐⭐⭐ **登录信息：优先读引擎发布的那份**（`__qrLoginInfo`）⭐⭐⭐⭐⭐
 *
 * 看着只是注释 ⇒ 但这一行**在 JS 模板字符串（`...`）里面** ⇒
 * **反引号把模板字符串截断了** ⇒ 后面那段 `__qrLoginInfo` 变成了裸表达式
 * ⇒ `node -e` 直接语法错 ⇒ **整个 Node 后端起不来**。
 *
 * 症状极具误导性：
 *   · 门禁大面积变红（engine-smoke / 会员卡片 / live-* 全挂）
 *   · 报的是「Expression expected / Unexpected identifier」⇒ 跟"注释"八竿子打不着
 *   · 真正的原因藏在**几百行之外**的一段注释里 ⇒ 靠肉眼翻几乎翻不到 ⭐⭐⭐
 *
 * ────────────────────────────────────────────────────────────
 * ⇒ 这条门禁锁死三件事：
 *   ① 引擎里**每一件「当 JS 用的产物」**（Swift 里的 raw string 数组/字面量）
 *      拼起来之后都能过 `node --check`（**按产物查，不按片段查**）
 *   ② 模板字符串里的**反引号不许藏在注释里**（藏了就等于提前截断模板）
 *   ③ **变异测试**：把事故原样注回去 ⇒ 这条门禁**必须红**（不然它就是个摆设）
 *
 * ⚠️ 为什么不用「跑一遍引擎看看崩不崩」代替：
 *   引擎起不来 ⇒ 报的是**运行期**的错 ⇒ 离根因十万八千里；
 *   而这里检查的是**产物本身**⇒ 错在哪一行就指哪一行 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const ENGINE_ROOT = path.join(ROOT, '..', 'legado-engine', 'Sources');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

function hash(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) { h = ((h << 5) - h + s.charCodeAt(i)) | 0; }
  return h;
}

// ────────────────────────────────────────────────────────────
// ① 从 Swift 源码里抠出「当 JS 用的产物」
// ────────────────────────────────────────────────────────────
//
// ⚠️⚠️ **必须按【产物】抠，不能按【片段】抠**（今天踩过）：
//   `JavaCompat.packagesStubSource` 是**一个数组**（`[ ##"""…"""#, ##"""…"""# ]`）
//   ⇒ 单独一块是**残缺的**（`{ getInstance: function(…){…}` 少了外壳）⇒ `node --check` 必挂
//   ⇒ 真正的产物 = **整组拼起来**（`.joined(separator: "\n")`）⭐⭐⭐
//
// ⇒ 规则：相邻的 raw string 之间，若只隔着 `,` / 空白 ⇒ 属于**同一件产物**
//    若隔着 `].joined` / `static let` / `func` ⇒ 是**不同件** ⇒ 分组断开
const RAW_RE = /(#{0,2})"""\n([\s\S]*?)\n"""\1/g;

function extractArtifacts(swiftSrc) {
  const blocks = [];
  let m;
  while ((m = RAW_RE.exec(swiftSrc)) !== null) {
    blocks.push({ text: m[2], from: m.index, to: m.index + m[0].length });
  }
  const groups = [];
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    const prev = groups.length ? groups[groups.length - 1] : null;
    let sameGroup = false;
    if (prev && prev.blocks.length) {
      const last = prev.blocks[prev.blocks.length - 1];
      const gap = swiftSrc.slice(last.to, b.from);
      if (!/\]\s*\.\s*joined|\b(static|public|private|func|let|var)\b/.test(gap)) {
        sameGroup = true;
      }
    }
    if (sameGroup) {
      groups[groups.length - 1].blocks.push(b);
    } else {
      groups.push({ blocks: [b] });
    }
  }
  return groups.map(g => ({
    text: g.blocks.map(b => b.text).join('\n'),
    count: g.blocks.length,
  })).filter(g => g.count > 0);
}

/** 这段文本像不像 JS？（别把 Swift 注释块、Markdown 也拿去 node --check） */
function looksLikeJS(text) {
  if (text.length < 40) return false;
  if (!/\bfunction\b|=>|\bvar\s|\blet\s|\bglobalThis\b|\bthis\b/.test(text)) return false;
  return true;
}

/** Swift 字符串插值 `\(` … `)` ⇒ 把插值整体替换成占位符（让 JS 能过语法检查） */
function neutralizeInterpolation(text) {
  let out = '';
  let i = 0;
  while (i < text.length) {
    const idx = text.indexOf('\\(', i);
    if (idx < 0) { out += text.slice(i); break; }
    out += text.slice(i, idx);
    let depth = 1;
    let j = idx + 2;
    while (j < text.length && depth > 0) {
      if (text[j] === '(') depth++;
      else if (text[j] === ')') depth--;
      if (depth === 0) break;
      j++;
    }
    out += 'null';
    i = j + 1;
  }
  return out;
}

// ────────────────────────────────────────────────────────────
// ② ⭐⭐⭐ **模板字符串的「反引号藏在注释里」检测**（今天事故的直接判据）
// ────────────────────────────────────────────────────────────
//
// 机理（精确版）：
//   · JS 的**模板字符串**（`…`）到**下一个反引号**就结束 —— **注释不保护它** ⭐⭐⭐
//   · 所以模板里的 `// 注释` 里只要有一个反引号 ⇒ 模板**提前结束**
//   ⇒ 模板剩下的内容（真正的代码）被当成 JS 源码解析 ⇒ `Expression expected` ⇒ 整个后端起不来
//
// ⇒ 判据：扫到「代码位置」的反引号 ⇒ 进入模板 ⇒ 模板区间里
//    若某行 `//` 之后还有反引号 ⇒ 那个反引号就是「提前结束」的那一个 ⇒ 报出来
function scanTemplates(js) {
  const dangers = [];
  const regions = [];
  const lines = js.split('\n');
  let i = 0;
  const n = js.length;
  let line = 1;
  while (i < n) {
    const c = js[i];
    if (c === '\n') { line++; i++; continue; }
    if (c === '/' && js[i + 1] === '/') {           // 行注释（代码位置）
      while (i < n && js[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && js[i + 1] === '*') {           // 块注释
      i += 2;
      while (i < n && !(js[i] === '*' && js[i + 1] === '/')) { if (js[i] === '\n') line++; i++; }
      i += 2;
      continue;
    }
    if (c === "'" || c === '"') {                   // 普通字符串
      const q = c; i++;
      while (i < n) {
        if (js[i] === '\\') { i += 2; continue; }
        if (js[i] === q) { i++; break; }
        if (js[i] === '\n') line++;
        i++;
      }
      continue;
    }
    if (c === '`') {                                 // ← 模板字符串开始
      const tplStartLine = line;
      // 模板区间 = 到下一个反引号
      let j = i + 1;
      let tplLine = line;
      while (j < n) {
        if (js[j] === '\\') { j += 2; continue; }
        if (js[j] === '\n') { tplLine++; j++; continue; }
        if (js[j] === '`') break;
        j++;
      }
      const region = js.slice(i + 1, Math.min(j, n));
      regions.push({ startLine: tplStartLine, endLine: tplLine, text: region });

      // ⭐⭐⭐ **判据（精确版）**：
      //   模板在**下一个反引号**处结束 ⇒ 那个反引号所在的行，
      //   如果它的**前面**有 `//`（行注释）⇒ 这个反引号**本该在注释里**
      //   ⇒ 模板**提前结束** ⇒ 模板剩下的内容被当成代码 ⇒ 语法错 ⇒ 整个后端起不来 ⭐⭐⭐
      if (j < n) {
        // 终止反引号所在行：从上一个换行到 j
        const lineStart = js.lastIndexOf('\n', j - 1) + 1;
        const head = js.slice(lineStart, j);
        const ci = head.indexOf('//');
        if (ci >= 0) {
          dangers.push({
            line: tplLine,
            text: js.slice(lineStart, js.indexOf('\n', j) < 0 ? n : js.indexOf('\n', j)).trim().slice(0, 110),
          });
        }
      }

      i = (j < n) ? j + 1 : n;                       // 模板结束（从结束处继续当代码扫）
      line = tplLine;
      continue;
    }
    i++;
  }
  return { dangers, regions };
}

function findBacktickInTemplateComment(js) {
  return scanTemplates(js).dangers;
}

/** 真的拿 node 去检查（唯一权威） */
function nodeCheck(js, label) {
  const tmp = path.join(os.tmpdir(), `qr-genjs-${process.pid}-${Math.abs(hash(label))}.js`);
  fs.writeFileSync(tmp, js, 'utf8');
  const r = spawnSync('node', ['--check', tmp], { encoding: 'utf8' });
  try { fs.unlinkSync(tmp); } catch (_) {}
  const err = ((r.stderr || '') + (r.stdout || '')).trim();
  return { ok: r.status === 0, err };
}

// ────────────────────────────────────────────────────────────
// ③ 扫引擎源码
// ────────────────────────────────────────────────────────────
console.log('=== 1. 引擎里当 JS 用的产物（Swift raw string）===');

const JS_DIRS = [
  path.join(ENGINE_ROOT, 'LegadoCore', 'JS'),
  path.join(ENGINE_ROOT, 'LegadoCore', 'Host'),
  path.join(ENGINE_ROOT, 'LegadoCore', 'Evaluator'),
  path.join(ENGINE_ROOT, 'LegadoCore', 'DOM'),
  path.join(ENGINE_ROOT, 'LegadoCore', 'Support'),
  path.join(ENGINE_ROOT, 'Conformance'),
];

if (!fs.existsSync(ENGINE_ROOT)) {
  console.log('  ⚠️ 找不到引擎源码（' + ENGINE_ROOT + '）⇒ 跳过');
  console.log('\n⏭ 跳过：引擎源码不在本机 ⇒ 这条链路**没验到**');
  process.exit(0);
}

const artifacts = [];
for (const dir of JS_DIRS) {
  if (!fs.existsSync(dir)) continue;
  for (const f of fs.readdirSync(dir).sort()) {
    if (!f.endsWith('.swift')) continue;
    const p = path.join(dir, f);
    const src = fs.readFileSync(p, 'utf8');
    for (const g of extractArtifacts(src)) {
      if (!looksLikeJS(g.text)) continue;
      artifacts.push({ file: path.relative(ROOT, p), text: g.text, blocks: g.count });
    }
  }
}

ok(artifacts.length > 0, `扫到 ${artifacts.length} 件 JS 产物（扫不到 ⇒ 抽取逻辑坏了，门禁在演戏）`);

// ────────────────────────────────────────────────────────────
// ④ 每件产物都要过 node --check
// ────────────────────────────────────────────────────────────
console.log('\n=== 2. 逐件 node --check（产物本身必须是合法 JS）===');
for (const a of artifacts) {
  const label = a.file + '#' + hash(a.text);
  const hasI = a.text.includes('\\(');
  const js = neutralizeInterpolation(a.text);
  const r = nodeCheck(js, label);
  ok(r.ok,
     `${a.file}（${a.blocks} 块拼起来）的 JS 语法错：${(r.err || '').split('\n').slice(0, 3).join(' / ').slice(0, 220)}`);
  if (hasI) {
    const inI = a.text.match(/\\\([\s\S]{0,200}?\)/g) || [];
    const bad = inI.filter(s => s.includes('`'));
    ok(bad.length === 0, `${a.file} 的插值里有反引号（会截断模板字符串）：${bad[0] || ''}`);
  }
}

// ────────────────────────────────────────────────────────────
// ⑤ 模板字符串里的反引号不许藏在注释里（今天事故的直接判据）
// ────────────────────────────────────────────────────────────
console.log('\n=== 3. 模板字符串：反引号不许藏在注释里（今天事故的直接判据）===');
for (const a of artifacts) {
  const dangers = findBacktickInTemplateComment(a.text);
  ok(dangers.length === 0,
     `${a.file}：模板里的注释藏了反引号（⇒ 模板提前截断 ⇒ 整个后端语法错）` +
     (dangers.length ? `：第 ${dangers[0].line} 行 ${dangers[0].text}` : ''));
}

// ────────────────────────────────────────────────────────────
// ⑥ ⭐⭐⭐ **变异测试**：把事故原样注回去 ⇒ 门禁必须红 ⭐⭐⭐
// ────────────────────────────────────────────────────────────
//   门禁自己不动手 ⇒ 没人知道它到底能不能抓 ⭐⭐⭐
//   ⇒ 这里**故意制造**事故（模板里的注释塞反引号）⇒ 断言检查器**确实报错**
console.log('\n=== 4. 变异测试（门禁必须能抓到自己）===');
{
  // 找一件「模板字符串里有注释」的产物
  let victim = null, victimRegions = null;
  for (const a of artifacts) {
    const s = scanTemplates(a.text);
    if (s.dangers.length) continue;                 // 已经有问题 ⇒ 不用它做变异
    const withComment = s.regions.find(r => r.text.includes('//'));
    if (withComment) { victim = a; victimRegions = s.regions; break; }
  }
  if (!victim) {
    ok(false, '找不到「模板字符串里有注释」的产物 ⇒ 变异测试没意义（抽取逻辑坏了？）');
  } else {
    // 事故原样：在**模板里**的一行注释中塞一个反引号
    const region = victimRegions.find(r => r.text.includes('//'));
    const regionLines = region.text.split('\n');
    const ci = regionLines.findIndex(l => l.includes('//'));
    ok(ci >= 0, '变异点找不到（模板里没有注释行 ⇒ 场景变了？）');
    if (ci >= 0) {
      const mutatedRegionLines = regionLines.slice();
      mutatedRegionLines[ci] = mutatedRegionLines[ci] + ' `mutated`';
      const mutatedRegion = mutatedRegionLines.join('\n');
      const mText = victim.text.replace(region.text, mutatedRegion);

      const dangers = findBacktickInTemplateComment(mText);
      ok(dangers.length > 0,
         '模板里的注释塞反引号 ⇒ 检查器必须报错（现在没报 ⇒ 这条门禁抓不住今天这个事故 ⇒ 白写）');

      const r = nodeCheck(mText, 'mutant');
      ok(!r.ok, '模板里的注释塞反引号 ⇒ node --check 必须失败（现在没失败 ⇒ 门禁没抓到 ⇒ 白写）');
    }
  }
}

// ────────────────────────────────────────────────────────────
// 汇总
// ────────────────────────────────────────────────────────────
console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
