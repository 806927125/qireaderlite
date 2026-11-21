#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：GitHub Actions workflow 的 YAML 合法性 + 保留指示符**
 *
 * ⚠️⚠️⚠️ **为什么必须有这条门禁**（2026-11-19 CI run 468 实证）：
 *   我给 workflow 加了个 step，name 里写了 **`@js:`**
 *   ⇒ YAML 里 **`@` 是保留指示符**（不能裸用）⇒ **整个 workflow 解析失败** ⭐⭐⭐
 *   ⇒ 症状 = **CI run 立刻失败、且【一个 job 都没有】**（`jobs: []`）⭐⭐⭐
 *   ⇒ 报错信息极不直观 ⇒ 容易误以为是编译问题 ⇒ **白等/白查一轮 CI** ⭐⭐⭐
 *   ⇒ **正解：本地先 parse 一遍**（3 秒）⇒ 门禁当场报「哪个文件、哪一行」⭐⭐⭐
 *
 * ⚠️ **为什么这条尤其值钱**：
 *   编译错误 ⇒ CI 会把 `error:` 打出来 ⇒ 一眼看见
 *   **workflow 解析失败 ⇒ 连 job 都不建 ⇒ 什么都看不见** ⇒ 最难查的一类 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const ROOT = path.resolve(__dirname, '..');
const DIR = path.join(ROOT, '.github/workflows');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const files = fs.existsSync(DIR)
  ? fs.readdirSync(DIR).filter((f) => /\.ya?ml$/.test(f)).sort()
  : [];

ok(files.length > 0, `找到 ${files.length} 个 workflow 文件`);

for (const f of files) {
  const full = path.join(DIR, f);
  const text = fs.readFileSync(full, 'utf8');

  // ① YAML 必须能解析（**这是 run 468 失败的真因**）
  let doc = null;
  try {
    doc = yaml.load(text);
    ok(true, `${f}：YAML 解析通过`);
  } catch (e) {
    ok(false, `${f}：YAML 解析失败`, String(e.message || e).slice(0, 300));
    continue;
  }

  // ② 结构：至少一个 job，每个 job 有 steps
  ok(!!doc && !!doc.jobs && Object.keys(doc.jobs).length > 0,
     `${f}：有 job（${doc && doc.jobs ? Object.keys(doc.jobs).length : 0}）`);
  for (const [jn, job] of Object.entries((doc && doc.jobs) || {})) {
    ok(Array.isArray(job.steps) && job.steps.length > 0, `${f}：job「${jn}」有 steps（${(job.steps || []).length}）`);
  }

  // ③ ⭐⭐⭐ **裸 `@` 保留指示符**（run 468 的真凶）⇒ 扫 step name / 键名
  //    ⚠️ YAML 1.1/1.2：`@` 开头是保留指示符（`@text` 之类）
  //    ⇒ 解析器会直接报错 ⇒ **整个 workflow 挂掉** ⇒ 必须静态挡住 ⭐⭐⭐
  const lines = text.split('\n');
  let bad = 0;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    // 只看「键的位置」和「值以 @ 开头」两种 ⇒ 其余 @（如 @js: 在 run 块里）是字符串内容，没问题
    const mKey = l.match(/^\s*(?:-\s*)?([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$/);
    if (mKey && mKey[2].startsWith('@')) {
      console.log(`     ⛔ ${f}:${i + 1} 键「${mKey[1]}」的值以裸 @ 开头 ⇒ YAML 保留指示符`);
      bad++;
    }
    // step name 里的裸 @（`- name: xxx @yy`）—— 这也是 run 468 的真凶
    const mName = l.match(/^\s*-\s*name\s*:\s*(.*)$/);
    if (mName && /(^|\s)@[^A-Za-z]/.test(mName[1])) {
      console.log(`     ⛔ ${f}:${i + 1} step name 里有裸 @ ⇒ YAML 保留指示符`);
      bad++;
    }
  }
  ok(bad === 0, `${f}：没有裸 @ 保留指示符`, bad ? `有 ${bad} 处` : '');

  // ④ step 必须有 run 或 uses
  for (const [jn, job] of Object.entries((doc && doc.jobs) || {})) {
    for (const [sn, st] of (job.steps || []).entries()) {
      ok(!!(st.run || st.uses), `${f}：job「${jn}」step#${sn + 1}「${st.name || '?'}」有 run/uses`);
    }
  }
}


// ⭐⭐⭐⭐⭐ **YAML 的 plain scalar 里不能有裸的「ASCII 冒号 + 空格」**（2026-11-21 实证）⭐⭐⭐
//   ⇒ 症状：workflow **解析失败** ⇒ run 有 0 个 job ⇒ 「CI 红了但一个步骤都没跑」⭐⭐⭐
//   ⇒ 极易误判成「代码有问题」⇒ 实际是 **YAML 语法**问题 ⭐⭐⭐
//   ⇒ 判据：`- name: xxx: yyy` ⇒ 冒号后跟空格 ⇒ 被当成「键: 值」⇒ 解析失败 ⭐⭐⭐
{
  const fs2 = require('fs');
  const path2 = require('path');
  const wf = path2.join(__dirname, '..', '.github/workflows/build-ipa.yml');
  const lines = fs2.readFileSync(wf, 'utf8').split('\n');
  const bad = [];
  lines.forEach((ln, i) => {
    const m = ln.match(/^\s*-?\s*name:\s+(.*)$/);
    if (!m) return;
    const val = m[1].trim();
    if (val.startsWith('"') || val.startsWith("'")) return;      // 已加引号 ⇒ 安全
    // 去掉行尾注释后再找「ASCII 冒号 + 空白」
    const bare = val.replace(/\s+#.*$/, '');
    if (/[^\s]:\s/.test(bare)) bad.push(`${i + 1}: ${ln.trim()}`);
  });
  ok(bad.length === 0, `所有 - name: 的值都安全（裸的「ASCII 冒号+空格」会让整个 workflow 解析失败）`,
     bad.join(' | '));
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);