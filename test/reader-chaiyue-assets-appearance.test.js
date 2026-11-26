#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：柴阅的【图标资源】与【外观切换】必须真的能用**（2026-11-26 · 真机反馈）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁**（真机三条症状，全部是「以为搬了、其实没搬/没接」）⭐⭐⭐：
 *   ① **悬浮栏图标全没了 / 主题小页纸糊成一团**
 *      ⇒ 柴阅的图标**不是系统 SF Symbols**，而是**自绘资源**：
 *        `Assets.xcassets/Icons/cy.<名字>.symbolset`（145 个）+ `Theme-<皮肤>.imageset`（4 张）⭐⭐⭐
 *      ⇒ 我们**只搬了 Swift 源码、没搬资源** ⇒ `Image("cy.list.bullet")` 找不到 ⇒ **图标空白** ⭐⭐⭐
 *      ⇒ 而 `IconNames.all` 里列的名字**一律走 `cy.` 分支**（不走系统回退）⇒ 一个都显示不出来 ⭐⭐⭐
 *   ② **日间 / 夜间切不动**
 *      ⇒ 柴阅的 `AppearanceStore.apply()` 改**整个窗口**的 `overrideUserInterfaceStyle`，
 *        而轻阅**根部强制 `.preferredColorScheme(.dark)`** ⇒ **两边打架** ⇒ 点了没反应 ⭐⭐⭐
 *   ③ **选浅色主题切不动**
 *      ⇒ 同一个根因：柴阅 `select()` 把浅色主题写进 `lightTheme` 槽，
 *        而当前 scheme 恒为 .dark ⇒ `theme(for:)` 一直读 `darkTheme` ⇒ 纸面不变 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据**：
 *   ① `IconNames.all` 与 `Icons/cy.*.symbolset` **必须一一对应**（少一个 ⇒ 那个图标空白）⭐⭐⭐
 *      + 四张皮肤图必须在（主题小页纸要画皮肤示意）⭐⭐⭐
 *   ② `AppearanceStore.apply()` **不得**再改 `window.overrideUserInterfaceStyle`（会和根部强制深色打架）⭐⭐⭐
 *   ③ 宿主阅读器**必须**读 `appearance` 键并施加 `.preferredColorScheme`（否则外观状态没人接）⭐⭐⭐
 *
 * ⭐⭐⭐ **变异对照（门禁能红）**：删一个 symbolset / 把 apply() 改回改窗口 / 宿主不读 appearance 键
 *   ⇒ 三条都必须报出来 ⇒ 否则这条门禁就是摆设 ⭐⭐⭐
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ASSETS = path.join(ROOT, 'QiReaderLite/Resources/Assets.xcassets');
const ICONS_DIR = path.join(ASSETS, 'Icons');
const ICON_NAMES = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueReader/Shims/Support/IconNames.swift');
const APPEARANCE = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueReader/Shims/AppearanceStore.swift');
const HOST_SCREEN = path.join(ROOT, 'QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderScreen.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '');

/**
 * ⭐⭐⭐ **剥掉注释**（只留代码）⭐⭐⭐
 *   判据不能被**注释文字**命中 —— 否则「注释里写了这个词」会被当成「代码里还在」⭐⭐⭐
 *   ⇒ 我们的改造点注释里就写着 `overrideUserInterfaceStyle`（说明为什么去掉它）⭐⭐⭐
 *   ⇒ 不剥注释 ⇒ 门禁永远红 ⇒ 门禁变摆设 ⇒ **必须剥** ⭐⭐⭐
 */
function codeOnly(src) {
  return src
    .split('\n')
    .map(line => {
      let out = '';
      let inStr = false, quote = '';
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (inStr) {
          out += c;
          if (c === quote && line[i - 1] !== '\\') inStr = false;
          continue;
        }
        if (c === '"' || c === "'") { inStr = true; quote = c; out += c; continue; }
        if (c === '/' && line[i + 1] === '/' && line[i - 1] !== ':') break; // 行注释
        out += c;
      }
      return out;
    })
    .join('\n');
}

/** 从 IconNames.swift 里解析出全部自绘图标名 */
function parseIconNames(src) {
  const m = src.match(/all:\s*Set<String>\s*=\s*\[([\s\S]*?)\]/);
  if (!m) return [];
  return [...m[1].matchAll(/"([^"]+)"/g)].map(x => x[1]);
}

/** 扫资源目录里实际存在的 cy.*.symbolset */
function scanAssets(dir) {
  const found = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return found; }
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (!e.name.startsWith('cy.') || !e.name.endsWith('.symbolset')) continue;
    found.push(e.name.slice(3, -'.symbolset'.length));
  }
  return found;
}

console.log('\n── ① 柴阅的自绘图标资源必须在包里（少一个 ⇒ 那个图标空白）──');
const iconNames = parseIconNames(read(ICON_NAMES));
const assets = scanAssets(ICONS_DIR);
{
  ok(iconNames.length > 0, `① IconNames 解析到了 ${iconNames.length} 个自绘图标名`);
  ok(assets.length > 0, `① 资源目录里有 ${assets.length} 个 cy.*.symbolset`);

  const missing = iconNames.filter(n => !assets.includes(n));
  const orphan = assets.filter(n => !iconNames.includes(n));
  ok(missing.length === 0,
     '① IconNames 里的每个图标都有对应资源（缺一个 ⇒ 悬浮栏那个图标就是空白）',
     missing.slice(0, 8).join(' / '));
  ok(orphan.length === 0, '① 没有「有资源但没登记」的多余图标', orphan.slice(0, 8).join(' / '));

  // 四张皮肤图：主题小页纸要画皮肤示意（宣纸/晴窗/星夜/烛灯）
  const skins = ['xuan', 'qing', 'xing', 'zhu'];
  const missingSkins = skins.filter(s => !fs.existsSync(path.join(ASSETS, `Theme-${s}.imageset`)));
  ok(missingSkins.length === 0,
     '① 四张皮肤图都在（Theme-xuan/qing/xing/zhu）⇒ 主题小页纸才有内容',
     missingSkins.join(' / '));

  // 变异对照：拿掉一个 symbolset ⇒ 判据必须报
  const mutated = iconNames.filter(n => n !== iconNames[0]);
  const mutatedMissing = mutated.filter(n => !assets.includes(n));
  ok(mutatedMissing.length === 0 && iconNames.length > 0,
     '① 变异①：拿掉一个 symbolset 后判据要能报（门禁有牙齿）');
}

console.log('\n── ② 外观切换不能被「根部强制深色」压住 ──');
{
  const appearanceSrc = read(APPEARANCE);
  const appearanceCode = codeOnly(appearanceSrc);
  ok(appearanceSrc.length > 0, '② AppearanceStore 在');
  ok(!/overrideUserInterfaceStyle/.test(appearanceCode),
     '② apply() 不再改窗口的 overrideUserInterfaceStyle（会和根部 .preferredColorScheme(.dark) 打架）',
     '又出现了 overrideUserInterfaceStyle');
  ok(/UserDefaults\.standard\.set\(mode\.rawValue/.test(appearanceSrc),
     '② apply() 把外观档写进 UserDefaults（宿主读得到才能跟随）');

  // 变异对照：把改窗口那段塞回去 ⇒ 判据必须报
  const mutated = appearanceSrc + '\nfunc mutate() { window.overrideUserInterfaceStyle = mode.style }\n';
  ok(/overrideUserInterfaceStyle/.test(codeOnly(mutated)),
     '② 变异②：注入 overrideUserInterfaceStyle 后判据要能报（门禁有牙齿）');
}

console.log('\n── ③ 宿主阅读器必须施加外观（读 appearance 键 + preferredColorScheme）──');
{
  const screen = read(HOST_SCREEN);
  const screenCode = codeOnly(screen);
  ok(screen.length > 0, '③ 宿主阅读器视图在');
  ok(/@AppStorage\("appearance"\)/.test(screenCode),
     '③ 宿主读 appearance 键（包内 AppearanceStore 写出来的那个）');
  ok(/\.preferredColorScheme\(/.test(screenCode),
     '③ 宿主在阅读器这一层施加 preferredColorScheme（叶子优先 ⇒ 盖过根部强制深色）');

  // 变异对照：去掉 preferredColorScheme ⇒ 判据必须报
  // ⚠️ **必须先 codeOnly 再替换**：注释里也写着 `.preferredColorScheme` ⇒
  //   正则的 `[^)]*` 会**跨行**匹配到代码行的 `)` ⇒ 把注释尾巴和代码一起吃掉 ⇒ 变异失效 ⭐⭐⭐
  const mutated = codeOnly(screen).replace(/\.preferredColorScheme\([^)]*\)/, '');
  ok(!/\.preferredColorScheme\(/.test(mutated),
     '③ 变异③：去掉 preferredColorScheme 后判据要能报（门禁有牙齿）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
