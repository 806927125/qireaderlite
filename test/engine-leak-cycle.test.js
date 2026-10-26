/**
 * **引擎会话泄漏门禁**（2026-10-26 · jetsam 6.8GB 闪退真凶）
 *
 * 背景（真机实证）：
 *   jetsam 记录里 `QingYue` **单进程** `rpages = 425984` ⇒ ×16KB = **6.8GB**
 *   ⇒ 被系统内存杀（jetsam，不是崩溃）⇒ 现象 =「闪退」+ **没有 .ips** ⭐⭐⭐
 *
 * ⭐⭐⭐ **真凶 = retain cycle（不是「JSC 太能吃」）**：
 *   ```
 *   Session ──▶ api（强）──▶ session（强）──▶ Session
 *   ```
 *   ⇒ 被 LRU 淘汰的会话**永远不释放** ⇒ 连带它的 JSC 上下文 / HTTP 缓存 / 整份源**永久占着**
 *   ⇒ `maxLiveSessions = 4` 的封顶**完全失效**（踢掉的还活着）
 *   ⇒ 用户有 125 个源 ⇒ 每碰一个源永久多一份 ⇒ 几十个源就 GB 级 ⇒ jetsam 杀进程 ⭐⭐⭐
 *
 * ⭐ **老引擎为什么免疫**：它的 JS 跑在 **WKContent 独立进程** ⇒ 泄漏在那边 ⇒ App 进程不受影响
 *
 * ⚠️⚠️ **断言必须先剥注释再匹配**（注释里写「不许 weak」会被当成「有 weak」⇒ 假红/假绿）
 * ⚠️⚠️ **剥注释不能粗暴切行**（文件里有 `"https://…"` ⇒ 按 `//` 切会把整行砍掉 ⇒ 断言落空）
 *   ⇒ 自己写个小词法器：字符串字面量原样保留，只真的剥注释 ⭐
 *
 * ⚠️ **变异要求**：把 `weak` 去掉 / 把 `removeValue` 删掉 ⇒ 本门禁**必须变红**
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

/** ⭐ 剥注释的小词法器：字符串字面量**原样保留**（`"https://…"` 不能被砍） */
function stripComments(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === '"' || c === "'") {
      const quote = c;
      out += c; i++;
      while (i < n) {
        if (src[i] === '\\') { out += src[i] + (src[i + 1] || ''); i += 2; continue; }
        out += src[i];
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2; continue;
    }
    out += c; i++;
  }
  return out;
}

/** 取一个 class 的类体（大括号配平） */
function classBody(src, marker) {
  const i = src.indexOf(marker);
  if (i < 0) return '';
  let depth = 0, started = false;
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') { depth++; started = true; }
    else if (src[j] === '}') {
      depth--;
      if (started && depth === 0) return src.slice(i, j + 1);
    }
  }
  return src.slice(i);
}

const raw = fs.readFileSync(SRC, 'utf8');
const code = stripComments(raw);

console.log('▶ 引擎会话泄漏门禁（App 侧 retain cycle）');

// ① ⭐⭐⭐ 核心：EngineHostAPI 持有的 session 必须是 weak
const apiBody = classBody(code, 'final class EngineHostAPI');
ok(apiBody.length > 0, '找得到 EngineHostAPI 的类体');
const decls = apiBody.match(/(?:weak\s+)?(?:let|var)\s+session\s*:/g) || [];
ok(decls.length > 0, 'EngineHostAPI 里确实声明了 session',
   '一条声明都没找到 ⇒ 断言可能落空（结构变了？）');
ok(decls.length > 0 && decls.every(d => /^weak\s/.test(d)),
   'EngineHostAPI 持有的 session 必须是 weak（强引用 = Session ⟷ api 互指 ⇒ 会话永不释放）',
   '实际声明: ' + JSON.stringify(decls));

// ② 淘汰必须真的从字典里删（否则 maxLiveSessions 封顶是假的）
ok(/sessions\.removeValue\(forKey:\s*evictedKey\)/.test(code),
   'LRU 淘汰必须真的把会话从 sessions 字典里删掉');

// ③ 清会话必须作废 JS 上下文（否则 JSC 堆不还回去 ⇒ 「清完内存没降」）
ok(/func dropAllSessions\(\)[\s\S]{0,800}?invalidate\(\)/.test(code),
   'dropAllSessions 必须 invalidate() JS 上下文（JSC 堆才真还回去）');

// ④ 单源清会话也要从字典里删
ok(/func dropSession\(for sourceUrl: String\)[\s\S]{0,300}?sessions\.removeValue\(forKey:\s*sourceUrl\)/.test(code),
   'dropSession 必须从 sessions 字典里删掉该会话');

// ⑤ 会话上限必须存在（封顶 + 淘汰才有意义）
ok(/static let maxLiveSessions = \d+/.test(code), '会话上限 maxLiveSessions 还在（封顶 ⇒ 内存有界）');

console.log(`\n通过 ${pass} / 失败 ${fail}`);
if (fail > 0) process.exit(1);
