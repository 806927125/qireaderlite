/**
 * ⭐⭐⭐ **从引擎的 Swift 源码里抠出「当 JS 用的产物」**
 *
 * 背景（2026-10-25 老 JS 引擎物理删除）：
 *   · 老引擎的 JS 是**独立文件**（`QiReaderLite/Resources/engine/*.js`）⇒ **已删**
 *   · 新引擎的 JS 是**写在 Swift 里的 raw string**（`JavaCompat.sources` / `NodeJSExecutor.harnessSource`）
 *   ⇒ 门禁不能再去读老路径（⇒ ENOENT 崩掉）⇒ 得从 Swift 里抠 ⭐⭐⭐
 *
 * ⚠️⚠️ **必须按【产物】抠，不能按【片段】抠**（踩过）：
 *   `JavaCompat.packagesStubSource` 是**一个数组**（`[ ##"""…"""#, ##"""…"""# ]`）
 *   ⇒ 单独一块是**残缺的**（`{ getInstance: function(…){…}` 少了外壳）⇒ `node --check` 必挂
 *   ⇒ 真正的产物 = **整组拼起来**（Swift 侧 `.joined(separator: "\n")`）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ENGINE_SOURCES = path.join(__dirname, '..', '..', 'legado-engine', 'Sources');
const LEGADO_CORE = path.join(ENGINE_SOURCES, 'LegadoCore');

/** Swift 的 raw string：`#"""…"""#` / `##"""…"""##` / `"""…"""` */
const RAW_RE = /(#{0,2})"""\n([\s\S]*?)\n"""\1/g;

/**
 * 把一个 Swift 文件里的 raw string 按「产物」分组。
 *
 * 相邻两块之间若只隔着 `,` / 空白 ⇒ 属于**同一件产物**；
 * 若隔着 `].joined` / `static let` / `func` ⇒ 是**不同件** ⇒ 分组断开。
 */
function extractArtifacts(swiftSrc) {
  const blocks = [];
  let m;
  while ((m = RAW_RE.exec(swiftSrc)) !== null) {
    blocks.push({ text: m[2], from: m.index, to: m.index + m[0].length });
  }
  const groups = [];
  for (const b of blocks) {
    const prev = groups.length ? groups[groups.length - 1] : null;
    let sameGroup = false;
    if (prev && prev.blocks.length) {
      const last = prev.blocks[prev.blocks.length - 1];
      const gap = swiftSrc.slice(last.to, b.from);
      if (!/\]\s*\.\s*joined|\b(static|public|private|func|let|var)\b/.test(gap)) sameGroup = true;
    }
    if (sameGroup) prev.blocks.push(b);
    else groups.push({ blocks: [b] });
  }
  return groups.map(g => ({ text: g.blocks.map(b => b.text).join('\n'), blocks: g.blocks.length }));
}

/**
 * 取某个具名产物：`static let <name>: String = [ … ].joined(separator: "\n")`
 *
 * ⇒ 返回**拼好之后**的完整 JS（这才是真正跑起来的那段）⭐⭐⭐
 */
function namedArtifact(swiftSrc, name) {
  const decl = new RegExp(`static\\s+let\\s+${name}\\b`);
  const m = decl.exec(swiftSrc);
  if (!m) return null;
  // 找到这个声明所属的数组区间：从声明处到 `].joined`（或 `]`）
  const end = swiftSrc.indexOf('].joined', m.index);
  const region = swiftSrc.slice(m.index, end < 0 ? swiftSrc.length : end);
  const blocks = [];
  let b;
  const re = new RegExp(RAW_RE.source, 'g');
  while ((b = re.exec(region)) !== null) blocks.push(b[2]);
  if (!blocks.length) return null;
  return blocks.join('\n');
}

/** 读引擎里某个 Swift 文件并取具名产物 */
function artifactFrom(file, name) {
  const p = path.join(LEGADO_CORE, file);
  if (!fs.existsSync(p)) return null;
  return namedArtifact(fs.readFileSync(p, 'utf8'), name);
}

module.exports = { ENGINE_SOURCES, LEGADO_CORE, extractArtifacts, namedArtifact, artifactFrom };
