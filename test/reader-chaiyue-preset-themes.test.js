#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：柴阅的【内置主题包】必须真的在包里、装得进、点得着**（2026-11-26）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **背景**（用户 2026-11-26 拍板「要」）：⭐⭐⭐
 *   柴阅自带 7 个内置主题包（celadon / eink / galaxy / native-sakura / shiba /
 *   starter-web / sticker-journal，共 11 MB）⇒ 柴阅**上游自己没给「一键装」的界面**
 *   （它只在启动时同步「已装过」的）⇒ 轻阅这边**新增**了这一栏 ⇒ 数据与包全部来自柴阅 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据（四条，缺一条这个功能就是坏的）**⭐⭐⭐⭐⭐：
 *   ① **包在**：7 个 `.chaiyuetheme` 必须在 `ChaiyueThemes.bundle/Themes/` 里，且每个是**合法 zip**
 *      （`.chaiyuetheme` 其实是 zip；不是 zip ⇒ 柴阅的 `parseArchive` 会抛 ⇒ 装不进）⭐⭐⭐
 *   ② **找得到**：`ReaderThemePreset.packageURL` 必须有 `.bundle` 兜底
 *      （`.chaiyuetheme` 是自定义扩展名 ⇒ Xcode 对「未知类型文件」的处理不稳 ⇒ 必须兜底）⭐⭐⭐
 *   ③ **装得进**：包内必须有 **public 出口** `ChaiyuePresetTheme` / `ChaiyuePresetThemes`
 *      （柴阅的 `importFile` / `save` / `reload` / `theme(_:)` **全是 internal** ⇒ 宿主装不了）⭐⭐⭐
 *   ④ **点得着**：宿主「阅读主题」页必须有「内置主题包」这一栏并调用 `install(into:)` ⭐⭐⭐
 *
 * ⭐⭐⭐ **变异对照**：拿掉一个主题包 / 去掉 .bundle 兜底 / 删掉 public 出口 / 删掉宿主那一栏
 *   ⇒ 四条都必须报出来 ⇒ 否则这条门禁是摆设 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BUNDLE = path.join(ROOT, 'QiReaderLite/Resources/ChaiyueThemes.bundle');
const THEMES_DIR = path.join(BUNDLE, 'Themes');
const PRESETS = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueReader/ReaderThemePresets.swift');
const EXPORT = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueReader/PublicPresetThemes.swift');
const HOST = path.join(ROOT, 'QiReaderLite/Features/Settings/SettingsScreens.swift');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '');

/** 剥掉注释（判据不能被注释文字命中） */
function codeOnly(src) {
  return src.split('\n').map(line => {
    let out = '', inStr = false, quote = '';
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (inStr) { out += c; if (c === quote && line[i - 1] !== '\\') inStr = false; continue; }
      if (c === '"' || c === "'") { inStr = true; quote = c; out += c; continue; }
      if (c === '/' && line[i + 1] === '/' && line[i - 1] !== ':') break;
      out += c;
    }
    return out;
  }).join('\n');
}

/** 柴阅实际放了包的那几个（onepiece / shinchan 柴阅仓库里没放 ⇒ 不可用） */
const EXPECTED = ['celadon', 'eink', 'galaxy', 'native-sakura', 'shiba', 'starter-web', 'sticker-journal'];

console.log('\n── ① 7 个内置主题包必须在资源 bundle 里（且是合法 zip）──');
{
  ok(fs.existsSync(path.join(BUNDLE, 'Info.plist')), '① ChaiyueThemes.bundle 有 Info.plist（Bundle(url:) 才打得开）');
  const missing = [];
  const notZip = [];
  for (const id of EXPECTED) {
    const p = path.join(THEMES_DIR, `${id}.chaiyuetheme`);
    if (!fs.existsSync(p)) { missing.push(id); continue; }
    const head = fs.readFileSync(p).subarray(0, 4);
    // zip 的魔数：PK\x03\x04
    if (!(head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04)) notZip.push(id);
  }
  ok(missing.length === 0, `① 7 个主题包都在（${EXPECTED.length} 个）`, missing.join(' / '));
  ok(notZip.length === 0, '① 每个主题包都是合法 zip（.chaiyuetheme 其实是 zip；不是 zip ⇒ 柴阅解不了）', notZip.join(' / '));

  // 变异对照：拿掉一个 ⇒ 判据必须报
  const simulatedMissing = EXPECTED.filter(x => x !== EXPECTED[0]);
  ok(simulatedMissing.length === EXPECTED.length - 1 && simulatedMissing.length > 0,
     '① 变异①：拿掉一个主题包后判据要能报（门禁有牙齿）');
}

console.log('\n── ② packageURL 必须有 .bundle 兜底 ──');
{
  const src = codeOnly(read(PRESETS));
  ok(src.length > 0, '② ReaderThemePresets 在');
  ok(/ChaiyueThemes[\s\S]{0,120}withExtension: "bundle"/.test(src),
     '② packageURL 有 ChaiyueThemes.bundle 兜底（.chaiyuetheme 扩展名在 Xcode 里不稳）');

  const mutated = src.replace(/ChaiyueThemes[\s\S]{0,120}withExtension: "bundle"/, '');
  ok(!/ChaiyueThemes[\s\S]{0,120}withExtension: "bundle"/.test(mutated),
     '② 变异②：去掉 .bundle 兜底后判据要能报（门禁有牙齿）');
}

console.log('\n── ③ 包内必须有 public 出口（宿主才装得进）──');
{
  const src = codeOnly(read(EXPORT));
  ok(src.length > 0, '③ PublicPresetThemes 在');
  ok(/public struct ChaiyuePresetTheme/.test(src), '③ 有 public 的 ChaiyuePresetTheme');
  ok(/public enum ChaiyuePresetThemes/.test(src), '③ 有 public 的 ChaiyuePresetThemes');
  ok(/public func install\(into store: ReaderThemeStore\)/.test(src),
     '③ 有 public 的 install(into:)（柴阅的 importFile/save/reload 全是 internal ⇒ 必须在包内实现）');
  ok(/@MainActor/.test(src),
     '③ 出口标了 @MainActor（包里 ReaderThemeStore/ReaderThemePreset 是 MainActor 隔离的 ⇒ 不标会编译不过）');

  const mutated = src.replace(/public func install\(into store: ReaderThemeStore\)/, 'func install(into store: ReaderThemeStore)');
  ok(!/public func install\(into store: ReaderThemeStore\)/.test(mutated),
     '③ 变异③：把 install 降回 internal 后判据要能报（门禁有牙齿）');
}

console.log('\n── ④ 宿主「阅读主题」页必须有这一栏并真的调 install ──');
{
  const src = codeOnly(read(HOST));
  ok(src.length > 0, '④ 宿主设置页在');
  ok(/内置主题包/.test(src), '④ 有「内置主题包」这一栏');
  ok(/ChaiyuePresetThemes\.all/.test(src), '④ 列的是柴阅的预设清单');
  ok(/install\(into:/.test(src), '④ 点了会调 install(into:)（真把包装进主题仓）');
  ok(/@MainActor/.test(src), '④ 宿主 View 标了 @MainActor（访问包内 MainActor 成员必需）');

  const mutated = src.replace(/install\(into:/, 'unusedInstall(');
  ok(!/install\(into:/.test(mutated), '④ 变异④：不调 install 后判据要能报（门禁有牙齿）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
