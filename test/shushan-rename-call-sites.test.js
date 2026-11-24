#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：书山适配版的「顶层符号隔离化」必须【完整】且【可复现】** ⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **真机事故（2026-11-24）**：发现页筛选「切平台」无效（切到 QQ 阅读，分类还在番茄）⭐⭐⭐
 *   根因：站方的**筛选 action 是一段字符串** ⭐⭐⭐
 *     `action: "(function(){ … setConfig.call(this,{source:v}); java.refreshExplore(); })()"`
 *   ⇒ 「顶层符号隔离化」改名时**只按 AST 的标识符**改 ⭐⭐⭐
 *   ⇒ **AST 看不见字符串里的标识符** ⇒ **`setConfig` 漏改** ⭐⭐⭐
 *   ⇒ jsLib 里它已叫 `ssh_setConfig` ⇒ 引擎里 `setConfig` **未定义** ⇒ **ReferenceError** ⭐⭐⭐
 *   ⇒ ⇒ 筛选 action **静默失败** ⇒ 宿主兜底因 paramKey 为空**什么都不写** ⇒ **平台没切** ⭐⭐⭐
 *   ⇒ ⇒ 界面上**零报错**（用户只看到「切了但没变」）⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **本门禁钉死两件事**（都能被「变异对照」证伪）⭐⭐⭐⭐⭐
 *   ① **可复现**：适配版必须能由 `rename-shushan.mjs` 从**原源**原样重新生成出来 ⭐⭐⭐
 *      ⇒ ⇒ 任何**手改适配版**的行为（哪怕改对了）都会被抓到 ⇒ **单一真相** ⭐⭐⭐
 *      ⇒ ⇒ 而且**改名脚本本身漏了什么，也会在这里暴露**（因为它就是生成器）⭐⭐⭐
 *   ② **无残留**：适配版里**不许**出现旧名的**调用点**（`旧名(` / `旧名.call(`）⭐⭐⭐
 *      ⇒ ⚠️ 判据是「调用点」不是「出现」⇒ **URL 里的 `fb.shushan.vip` 不会被误伤** ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const ORIGINAL = path.join(ROOT, 'test/fixtures/shushan-original.json');
const ADAPTED = path.join(ROOT, 'sources/书山聚合v6-轻阅适配版.json');
const FIXTURE = path.join(ROOT, 'test/fixtures/shushan-adapted.json');
const SCRIPT = path.join(ROOT, 'test/rename-shushan.mjs');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

for (const f of [ORIGINAL, ADAPTED, FIXTURE, SCRIPT]) {
  ok(fs.existsSync(f), `文件在：${path.relative(ROOT, f)}`);
}

// ── ① ⭐⭐⭐⭐⭐ **可复现**：由脚本从原源重新生成 ⇒ 必须与提交的适配版**逐字相同** ⭐⭐⭐⭐⭐
const tmp = path.join('/tmp', `shushan-regen-${Date.now()}.json`);
let regen = null;
try {
  execFileSync('node', [SCRIPT, ORIGINAL, tmp], { stdio: 'pipe' });
  regen = fs.readFileSync(tmp, 'utf8');
} catch (e) {
  console.log('  ✗ 改名脚本跑失败：', String(e.stderr || e.message).slice(0, 300));
  fail++;
}
if (regen !== null) {
  const committed = fs.readFileSync(ADAPTED, 'utf8');
  const same = regen === committed;
  ok(same, '⭐⭐⭐⭐⭐ 适配版能由脚本从原源**原样重新生成**（手改适配版会被抓到）',
     same ? '' : '重新生成的内容与提交的适配版不同 ⇒ 要么改了适配版、要么改了脚本');
  // 探针用的 fixture 也必须一致（否则 CI 探针跑的是另一份源）⭐⭐⭐
  ok(fs.readFileSync(FIXTURE, 'utf8') === committed,
     '⭐⭐⭐ 探针用的 fixture 与 sources/ 里的适配版**逐字一致**（CI 跑的就是同一份源）');
}

// ── ② ⭐⭐⭐⭐⭐ **无残留**：旧名的【调用点】必须为零 ⭐⭐⭐⭐⭐
const mapPath = ADAPTED.replace(/\.json$/, '.map.json');
ok(fs.existsSync(mapPath), `映射表在：${path.relative(ROOT, mapPath)}`);
if (fs.existsSync(mapPath)) {
  const map = JSON.parse(fs.readFileSync(mapPath, 'utf8'));
  const oldNames = Object.keys(map.all || {});
  ok(oldNames.length > 0, `映射表里有 ${oldNames.length} 个改名记录`);
  const adapted = JSON.parse(fs.readFileSync(ADAPTED, 'utf8'));
  const src = Array.isArray(adapted) ? adapted[0] : adapted;
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // ⭐⭐⭐ 判据 = **调用点**：`旧名(` 或 `旧名.call(` ⇒ URL 里的 `fb.shushan.vip` 不算 ⭐⭐⭐
  const re = new RegExp('(?<![A-Za-z0-9_$.])(' + oldNames.map(esc).join('|') +
                        ')(?=\\s*\\(|\\s*\\.\\s*call\\s*\\()', 'g');
  const leftovers = [];
  for (const [k, v] of Object.entries(src)) {
    if (typeof v !== 'string') continue;
    let m;
    const r = new RegExp(re.source, 'g');
    while ((m = r.exec(v)) !== null) {
      leftovers.push(`${k}: ${m[1]} ⇒ …${v.slice(Math.max(0, m.index - 50), m.index + 60).replace(/\n/g, '\\n')}…`);
    }
  }
  ok(leftovers.length === 0,
     '⭐⭐⭐⭐⭐ 适配版里没有「旧名调用点」残留（漏改 ⇒ 引擎里未定义 ⇒ 筛选静默失效）',
     leftovers.slice(0, 5).join(' | '));

  // ── ③ ⭐⭐⭐ 引用计数守恒：每个旧名在新版里都该出现（改名不是删除）⭐⭐⭐
  const lib = src.jsLib || '', lui = src.loginUrl || '';
  const allText = JSON.stringify(src);
  const missing = oldNames.filter(n => {
    const nu = map.all[n];
    return !new RegExp('(?<![A-Za-z0-9_])' + esc(nu) + '(?![A-Za-z0-9_])').test(allText);
  });
  ok(missing.length === 0, '⭐⭐⭐ 每个旧名都有对应的新名（改名不是删除）', missing.join(','));
}

console.log(fail === 0 ? `通过 ${pass} / 失败 ${fail}` : `通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
