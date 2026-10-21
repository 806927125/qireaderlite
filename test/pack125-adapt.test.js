#!/usr/bin/env node
/**
 * 125 源聚合包 × 轻阅 的结构适配门禁
 *
 * 本轮适配做了两件事，各自对应一个「不修就会出事」的结构坑：
 *   ① enabledExplore=true 但 exploreUrl 空 → 发现页点进去是空白
 *   ② loginUrl 有但 loginUi 空 → BaseSource.login() 强检 loginUi，点登录必崩
 *
 * 门禁要对**输出文件本身**断言，不是复述实现意图。
 * 同时钉死用户硬性禁令：书源 JSON 永不含 canReName。
 */
const fs = require('fs');
const path = require('path');

// ⚠️ 原始 125 源包在 /workspace/attachments（沙盒外，新沙盒没有）→
//    **缺文件必须优雅跳过，不能崩**（崩的门禁不产汇总行 → 整轮门禁看起来像挂了）。
//    适配版本身在仓库里：sources/配置文件125个-轻阅适配版.json
function firstExisting(paths) {
  for (const p of paths) { if (fs.existsSync(p)) return p; }
  return '';
}
const SRC = process.env.SRC_RAW
  || firstExisting([
    '/workspace/attachments/0522cfc6e1cde02d/配置文件_125个.json',
    '/workspace/out/配置文件_125个.json',
  ]);
const OUT = process.env.SRC_OUT
  || firstExisting([
    '/workspace/out/配置文件125个-轻阅适配版.json',
    path.join(__dirname, '..', 'sources', '配置文件125个-轻阅适配版.json'),
  ]);

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

if (!SRC || !OUT) {
  console.log('=== 125 源适配门禁 ===');
  console.log('  ℹ️  125 源原件 / 适配版都不在本机 → 跳过（引擎侧断言照跑）');
  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(0);
}

const raw = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const out = JSON.parse(fs.readFileSync(OUT, 'utf8'));

ok(Array.isArray(out), '输出是数组');
ok(out.length === raw.length, `条数没变（${out.length}/${raw.length}）`);

// ① 发现页
const badExplore = out.filter(s => s.enabledExplore && !(s.exploreUrl || '').trim());
ok(badExplore.length === 0, `还有 ${badExplore.length} 个 enabledExplore 但 exploreUrl 空：` +
   badExplore.map(s => s.bookSourceName).join(', '));
ok(out.filter(s => !s.enabledExplore).length >= raw.filter(s => s.enabledExplore && !s.exploreUrl).length,
   '原来空 exploreUrl 的源都关掉了');

// ② 登录
const badLogin = out.filter(s => s.loginUrl && !(s.loginUi || '').trim());
ok(badLogin.length === 0, `还有 ${badLogin.length} 个 loginUrl 但 loginUi 空：` +
   badLogin.map(s => s.bookSourceName).join(', '));
// 真有 loginUi 的源，loginUrl 必须在（别把好的也清了）
const keepLogin = raw.filter(s => s.loginUrl && (s.loginUi || '').trim());
const keptOk = keepLogin.filter(s => {
  const t = out.find(x => x.bookSourceUrl === s.bookSourceUrl && x.bookSourceName === s.bookSourceName);
  return t && t.loginUrl;
});
ok(keptOk.length === keepLogin.length,
   `有 loginUi 的 ${keepLogin.length} 个源 loginUrl 都保留着（只清了 ${raw.filter(s => s.loginUrl && !(s.loginUi || '').trim()).length} 个没 UI 的）`);

// ③ 用户硬性禁令
const withCanReName = out.filter(s => 'canReName' in s);
ok(withCanReName.length === 0, `输出含 canReName 的源：${withCanReName.length} 个（一律不许出现）`);

// ④ 不能把别的字段改坏：逐源 diff 只能出现在白名单字段上
const ALLOWED = new Set(['enabledExplore', 'loginUrl', 'loginCheckJs', 'canReName']);
let dirty = 0;
for (let i = 0; i < out.length; i++) {
  const a = raw[i], b = out[i];
  if (a.bookSourceName !== b.bookSourceName || a.bookSourceUrl !== b.bookSourceUrl) {
    ok(false, `第 ${i} 条对不上（顺序/身份被改）`); dirty++; break;
  }
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
    if (k === 'lastUpdateTime') continue;
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k]) && !ALLOWED.has(k)) {
      ok(false, `${b.bookSourceName} 的 ${k} 被改了（不在白名单里）`); dirty++;
    }
  }
}
ok(dirty === 0, '除了白名单字段，其余字段逐字节没动');

// ⑤ 关键规则不能被**我**清空。
// ⚠️ 不能断言「非空」—— 这个包里有 4 个原生就是「（发现）」专属源
//    （searchUrl 和 bookList 都是空的，是包作者故意的），我一开始
//    按「必须非空」写，结果门禁红的是我自己没改过的东西。
//    判据应该是「相对原始文件有没有丢东西」。
function lostByMe(path_) {
  return out.filter((b, i) => {
    const a = raw[i];
    const g = o => path_.reduce((x, k) => (x == null ? x : x[k]), o);
    return Boolean(g(a)) && !g(b);
  });
}
[['ruleContent', 'content'], ['ruleToc', 'chapterList'], ['ruleSearch', 'bookList'],
 ['ruleContent', 'nextContentUrl'], ['ruleToc', 'nextTocUrl']].forEach(([p1, p2]) => {
  const lost = lostByMe([p1, p2]);
  ok(lost.length === 0, `${p1}.${p2} 被我清空了 ${lost.length} 个：` +
     lost.map(s => s.bookSourceName).join(', '));
});
// 原生就空的那些，要在报告里点名，别让人以为是适配搞坏的
const bornEmpty = raw.filter((s, i) => !(s.ruleSearch || {}).bookList);
console.log(`  ℹ️  原生就没有搜索 bookList 的源（包作者标了「（发现）」专属，不是适配改的）：` +
  bornEmpty.map(s => s.bookSourceName).join(', '));

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
