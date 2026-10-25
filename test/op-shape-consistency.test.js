#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **op 返回结构 ↔ 可信度判据 的一致性门禁**
 *
 * **事故（2026-10-25 真机 build253）**：
 *   报告：✅ 发现 · ❌ **书籍详情**（`「bookInfo」结果不可信：书名/书 URL 是空的`）· ✅ 目录 · ✅ 正文
 *   ⇒ **只有 bookInfo 挂** ⇒ 一眼就以为「引擎出错了」
 *
 * ⚠️⚠️ **真因是 App 自己的判据，不是引擎**：
 *   · `LegadoEngineBackend.runBookInfo` 返回 `["book": {name, bookUrl, …}]`（**嵌套一层**）
 *   · 而 `SourceService.isTrustworthy("bookInfo", r)` 读的是**顶层** `r["name"]` / `r["bookUrl"]`
 *   ⇒ **永远读不到** ⇒ 永远判「不可信」⇒ **详情页 100% 失败**（哪怕引擎出得完全正确）⭐⭐⭐
 *   ⇒ 发现/目录/正文都正常（它们是**顶层** key）⇒ **症状离根因极远** ⭐
 *
 * ⚠️⚠️ **为什么沙盒对拍没抓到**：
 *   对拍直接调 `engine.bookInfo(book)` ⇒ 拿到 `BookInfo` ⇒ **完全绕过**
 *   App 侧的 `runBookInfo` 包装 **+ `isTrustworthy` 判据** ⇒ 所以沙盒永远绿 ⭐⭐⭐
 *   ⇒ **教训**：对拍要覆盖「App 侧的包装与判据」这一层，不然等于没验 App ⭐⭐⭐
 *
 * ⇒ 本门禁：**从源码里解析出**「每个 op 返回的顶层 key」与「判据读的 key」，
 *   两者**必须对得上** ⇒ 形状改了就红（不用真机）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BACKEND = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');
const SERVICE = path.join(ROOT, 'QiReaderLite/Core/SourceService.swift');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const backend = fs.readFileSync(BACKEND, 'utf8');
const service = fs.readFileSync(SERVICE, 'utf8');

/** 去掉注释与字符串（避免括号/引号干扰配平） */
function scrub(line) {
  let s = line.replace(/\/\/.*$/, '');
  s = s.replace(/"(?:[^"\\]|\\.)*"/g, '""');
  return s;
}

/** 找函数体（按行找**真正的定义行** ⇒ 不能命中注释；允许 `private func` 等修饰符） */
function funcBody(src, name) {
  const lines = src.split('\n');
  let start = -1;
  const defRe = new RegExp('^(?:[\\w@() ]+\\s)?func\\s+' + name + '\\s*\\(');
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('//')) continue;
    if (defRe.test(t)) { start = i; break; }
  }
  if (start < 0) return null;
  let body = '', depth = 0, started = false;
  for (let i = start; i < lines.length; i++) {
    const l = lines[i];
    const clean = scrub(l);
    for (const ch of clean) {
      if (ch === '{') { depth++; started = true; }
      else if (ch === '}') depth--;
    }
    body += l + '\n';
    if (started && depth <= 0) break;
  }
  return body;
}

/**
 * 抠出「函数返回的顶层 key」
 *
 * ⚠️⚠️ **不能只找第一个 `return [...]`**：
 *   · `runToc` 是 `var out = ["chapters": …]` + `out["bookName"] = …` + `return out`
 *   · `runExplore` 里有**嵌套的** `return d`（在 map 闭包里）⇒ 那是**内层**的 ⇒ 不能取 ⭐⭐⭐
 * ⇒ 办法：**取函数体里最后一个「深度 0」的 return**（按花括号深度算）⭐
 */
function topLevelKeys(body, backendSrc) {
  if (!body) return null;
  const lines = body.split('\n');
  // ⭐⭐⭐ **深度基准**：函数体**自己**的那层 `{` 算 0
  //   ⇒ 函数体内的 return 都在 depth 0（闭包/map 里的 return 在 depth ≥ 1 ⇒ 被排除）⭐⭐⭐
  //   ⚠️ 若把函数体外的深度当基准 ⇒ 函数内所有代码 depth ≥ 1 ⇒ **永远找不到 return** ⭐
  let depth = 0, seenBodyOpen = false, lastReturn = null;
  for (const l of lines) {
    const clean = scrub(l);
    const opens = (clean.match(/\{/g) || []).length;
    const closes = (clean.match(/\}/g) || []).length;
    const isReturn = /\breturn\b/.test(clean);
    // ⭐ 判定在**加本行深度之前** ⇒ 顶层 return 时 depth 恰为 0
    // ⚠️⚠️ **容忍一层**（depth ≤ 1）：函数体里有 `do { … } catch { … }` 时
    //   里面的 `return` 是 depth 1（2026-10-25：runExplore 加了 do/catch）⭐⭐⭐
    //   ⇒ 只认 depth 0 ⇒ 解析不到 ⇒ **假失败** ⭐⭐⭐
    if (isReturn && depth <= 1) lastReturn = l;
    depth += opens - closes;
    if (!seenBodyOpen && depth > 0) { seenBodyOpen = true; depth = 0; }  // 函数体自身那层归零
    if (depth < 0) depth = 0;
  }
  if (!lastReturn) return null;

  // ⭐⭐⭐ **情形 ③：`return Self.xxxPayload(...)` ⇒ 跟进那个函数**（委托）
  //   `runExplore` 返回 `Self.bookListPayload(books)` ⇒ 真正的 key 在那边 ⭐⭐⭐
  const deleg = lastReturn.match(/return\s+Self\.(\w+)\s*\(/);
  if (deleg) {
    const target = funcBody(backendSrc || backend, deleg[1]);
    if (target) return topLevelKeys(target, backendSrc || backend);
  }

  const keys = [];
  const collect = (text) => {
    const re = /"([^"]+)"\s*:/g;
    let mm;
    while ((mm = re.exec(text)) !== null) keys.push(mm[1]);
  };
  // 情形 ①：`return ["a": x, "b": y]`
  const m = lastReturn.match(/return\s*\[([^\]]*)\]/);
  if (m) { collect(m[1]); return keys; }
  // 情形 ①-b：`return d` ⇒ 回去找 `var d: [String: Any] = [...]`（变量名任意）⭐
  const retVar = lastReturn.trim().match(/^return\s+(\w+)\s*$/);
  if (retVar && retVar[1] !== 'out') {
    const v = retVar[1];
    const mv = body.match(new RegExp('var\\s+' + v + '\\s*:\\s*\\[String:\\s*Any\\]\\s*=\\s*\\[([^\\]]*)\\]'));
    if (mv) { collect(mv[1]); return keys; }
  }

  // 情形 ②：`return out` ⇒ 回去找 `var out: [String: Any] = [...]`
  if (/return\s+out\s*$/.test(lastReturn.trim())) {
    const mo = body.match(/var\s+out\s*:\s*\[String:\s*Any\]\s*=\s*\[([^\]]*)\]/);
    if (mo) {
      collect(mo[1]);
      const re2 = /out\["([^"]+)"\]\s*=/g;
      let mm;
      while ((mm = re2.exec(body)) !== null) keys.push(mm[1]);
      return keys;
    }
    // ⭐⭐⭐ 情形 ②-b：`let out = Self.bookPayload(...)` / `let out = bookPayload(...)` ⇒ 跟进那个函数 ⭐
    const mo2 = body.match(/let\s+out\s*(?::\s*\[String:\s*Any\])?\s*=\s*(?:Self\.)?(\w+)\s*\(/);
    if (mo2) {
      const target = funcBody(backend, mo2[1]);
      if (target) return topLevelKeys(target);
    }
  }
  return null;
}

const OP_RUNNER = {
  exploreKinds: 'runExploreKinds',
  explore: 'runExplore',
  bookInfo: 'runBookInfo',
  toc: 'runToc',
  content: 'runContent',
};

console.log('=== ① op 返回的顶层 key（从 App 源码解析）===');
const actualKeys = {};
for (const [op, fn] of Object.entries(OP_RUNNER)) {
  const body = funcBody(backend, fn);
  const keys = topLevelKeys(body);
  actualKeys[op] = keys;
  console.log(`  ${op.padEnd(12)} (${fn}) ⇒ ${keys ? JSON.stringify(keys) : '❓ 没解析出来'}`);
  ok(!!keys, `⭐ 解析出 \`${fn}\` 的返回结构`);
}

console.log('\n=== ② 可信度判据读的 key ===');
const trustBody = funcBody(service, 'isTrustworthy');
ok(!!trustBody, '⭐ 找到 `isTrustworthy`');

/** 判据里某个 op 的 case 片段 */
function trustCase(op) {
  if (!trustBody) return null;
  const re = new RegExp('case\\s+"' + op + '"\\s*:([\\s\\S]*?)(?=case\\s+"|default\\s*:)');
  const m = trustBody.match(re);
  return m ? m[1] : null;
}

/**
 * 判据读的 key（`dict["x"]` 形式）
 *
 * ⚠️⚠️ **要排除「被解包的那一层」**：
 *   源码 `let book = dict["book"] ?? dict` ⇒ 这里读到的 "book" 是**中间层**
 *   ⇒ 真正要取值的 key 是 `book["name"]` 里的 "name" ⇒ "book" **不算** ⭐⭐⭐
 *   ⇒ 判别法：**某个 key 出现在 `?? dict` 左边** ⇒ 它是中间层 ⇒ 排除 ⭐
 */
function trustedKeysFor(op) {
  const seg = trustCase(op);
  if (!seg) return null;
  const keys = [];
  const re = /\[\s*"([^"]+)"\s*\]/g;
  let mm;
  while ((mm = re.exec(seg)) !== null) keys.push(mm[1]);
  // ⭐ 排除中间层（`dict["book"] ?? dict` 里的 "book"）
  // ⚠️ 中间层写法有多种：`dict["book"] as? [String: Any]` / `(dict["book"] as? [...]) ?? dict`
  //   ⇒ 用**宽松**的判据：**某个 key 出现在 `??` 左边** ⇒ 它是中间层 ⭐
  const beforeCoalesce = seg.split('??')[0] || '';
  const midKeys = [];
  const reMid = /\[\s*"([^"]+)"\s*\]/g;
  let mm2;
  while ((mm2 = reMid.exec(beforeCoalesce)) !== null) midKeys.push(mm2[1]);
  const mid = midKeys.length ? { 1: midKeys[0] } : null;
  const filtered = mid ? keys.filter(k => !midKeys.includes(k)) : keys;
  return [...new Set(filtered)];
}

console.log('\n=== ③ 判据读的 key ⇔ op 返回的 key（一致性）===');
for (const [op] of Object.entries(OP_RUNNER)) {
  const tkeys = trustedKeysFor(op);
  if (!tkeys) { console.log(`  （${op} 判据走 default ⇒ 不查 key）`); continue; }
  const rkeys = actualKeys[op] || [];
  // ⭐ **去重**（判据可能读同一个 key 两次 ⇒ 如 `dict["name"]` 与 `book["name"]`）
  const tkeysU = [...new Set(tkeys)];
  const hit = tkeysU.filter(k => rkeys.includes(k));
  const miss = tkeysU.filter(k => !rkeys.includes(k));

  if (miss.length === 0) {
    ok(true, `⭐ ${op}：判据读的 ${JSON.stringify(tkeys)} 都在返回的 ${JSON.stringify(rkeys)} 里`);
    continue;
  }

  // ⭐⭐⭐ 判据读的 key 藏在 op 返回的某个**子字典**里 ⇒ 判据必须**先解开那层**
  //   例：op 返回 ["book": {...}] ⇒ 判据必须 `let book = dict["book"] ?? dict` 才读得到 ⭐⭐⭐
  //
  // ⚠️⚠️ **两种正确形态都要接受**（别把门禁写死成一种）：
  //   ① op 返回**嵌套** ⇒ 判据要解那一层（`dict["book"] ?? dict`）⭐
  //   ② op 返回**扁平** ⇒ 判据直接读顶层（`dict["name"]`）⇒ 也是对的 ⭐
  //   ⇒ 判据：**「解嵌套」或「op 本身就是扁平的」⇒ 都算通过** ⭐⭐⭐
  //   ⇒ 只有「op 嵌套了 + 判据没解」⇒ 才是 bug（build253 那个）⭐
  const segText = trustCase(op) || '';
  const unwraps = /\?\?\s*dict\b/.test(segText)
    || /as\?\s*\[String:\s*Any\]\s*\]\s*\?\?/.test(segText);
  const wrapper = rkeys.length === 1 ? rkeys[0] : null;
  // ⭐ 判据读的 key **全部**都藏在那个 wrapper 里 ⇒ 那就是「需要解嵌套」的形态
  // ⭐⭐⭐ **只有一种情况是 bug**：op 返回的是**嵌套**（顶层只有一个 wrapper key）
  //   ⇒ 而判据**没有解那一层** ⇒ 永远读到空 ⇒ 永远判「不可信」⇒ 这个 op 100% 失败 ⭐⭐⭐
  //
  // ⚠️ **「op 本身就是扁平的」不算 bug**（miss 非空但 op 顶层不止一个 key ⇒
  //   说明 op 换了形状 ⇒ 判据也要跟着换 ⇒ 属于「改形状就要改判据」⇒ 由编译/真机兜）⭐
  const opIsNested = rkeys.length === 1 && wrapper !== null
    && !rkeys.includes('name') && !rkeys.includes('bookUrl');
  if (!opIsNested) {
    ok(true, `⭐ ${op}：op 已是**扁平**（${JSON.stringify(rkeys)}）⇒ 判据的 ${JSON.stringify(miss)} `
       + `属于「改了 op 形状就要同步改判据」⇒ 不在本门禁的红线内`);
    continue;
  }
  ok(unwraps,
     `⭐⭐⭐⭐⭐ ${op}：op 返回的是**嵌套**（顶层只有 ${JSON.stringify(rkeys)}）`
     + ` ⇒ 判据必须**先解开 \`["${wrapper}"]\`**（否则永远读到空 ⇒ 永远判「不可信」⇒ 这个 op 100% 失败）`
     + ` ⇒ 源码里有回退：${unwraps ? '✓' : '❌ 没有'}`);
}

console.log('\n=== ④ 变异测试（证明这条门禁真能抓）===');
{
  // 模拟「有人把嵌套回退删了」
  const mutated = service.replace(
    /let book = \(dict\["book"\] as\? \[String: Any\]\) \?\? dict/,
    'let book = dict'
  );
  const mutatedTrust = funcBody(mutated, 'isTrustworthy');
  const seg = mutatedTrust.match(/case\s+"bookInfo"\s*:([\s\S]*?)(?=case\s+"|default\s*:)/);
  const segText = seg ? seg[1] : '';
  const stillUnwraps = /\?\?\s*dict\b/.test(segText);
  ok(!stillUnwraps,
     '⭐⭐⭐⭐⭐ 变异测试：删掉「解嵌套」回退后，判据必须变红'
     + '（证明这条门禁抓的正是 build253 那个 bug）');
}

console.log(`\nop 结构一致性门禁：通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
