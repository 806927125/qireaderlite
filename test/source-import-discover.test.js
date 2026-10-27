/**
 * **发现页过滤 + 文件导入**门禁（2026-10-26 用户反馈三条）
 *
 * ① 发现页不该出现「只有搜索」的源（旧写法 `exploreUrl != nil` 漏了空串 ⇒ 等于没过滤）⭐
 * ② 不许再有「粘贴 JSON 导入」（粘贴大文本 ⇒ CoreText 排版 ⇒ 杀进程）⭐
 * ③ 文件导入要能用 ⇒ Info.plist 声明文档类型 + App 有 onOpenURL + 安全作用域 ⭐
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}
const read = (p) => fs.existsSync(p) ? stripComments(fs.readFileSync(p, 'utf8')) : '';

const discover = read(path.join(APP, 'Features/Explore/DiscoverView.swift'));
const sources = read(path.join(APP, 'Features/Sources/SourcesView.swift'));
const app = read(path.join(APP, 'App/QiReaderLiteApp.swift'));
const importer = read(path.join(APP, 'Core/SourceFileImport.swift'));
const plistRaw = fs.existsSync(path.join(ROOT, 'Config/Info.plist'))
  ? fs.readFileSync(path.join(ROOT, 'Config/Info.plist'), 'utf8') : '';

console.log('▶ ① 发现页只列「真的有发现页」的源');
ok(!/store\.enabled\.filter\s*\{\s*\$0\.exploreUrl\s*!=\s*nil\s*\}/.test(discover),
   '不许再用 `exploreUrl != nil`（漏空串 ⇒ 等于没过滤）');
ok(/trimmingCharacters\(in:\s*\.whitespacesAndNewlines\)/.test(discover),
   '判据要「去掉空白后还剩东西」（空串也不算有发现页）');

console.log('▶ ② 粘贴导入：**可以有，但大文件不许裸粘**（用户 2026-10-27 澄清）');
ok(/粘贴 JSON 导入/.test(sources), '菜单里要有「粘贴 JSON 导入」');
ok(/PasteImportView/.test(sources), '要有 PasteImportView');
ok(/BigPasteTextEditor/.test(sources),
   '粘贴必须用 BigPasteTextEditor（裸 TextEditor 粘大文本 ⇒ CoreText 排版 10 秒 ⇒ 杀进程）');
ok(!/limit = 20_000/.test(sources), '粘贴**不带上限**（用户 2026-10-27 明确要求）');
ok(!/(?<![\w])TextEditor\(/.test(sources), '不许用裸 TextEditor 接收粘贴');
// ⭐ 大文本**不进气泡**（只进缓冲区）⇒ 零排版 ⇒ 永不卡
const editor = read(path.join(APP, 'App/BigPasteTextEditor.swift'));
ok(/override func paste/.test(editor), 'BigPasteTextView 要拦下粘贴（大文本不进 UITextView ⇒ 不排版）');
ok(/onPaste\?\(s\)/.test(editor), '粘贴内容走 onPaste 回调进缓冲区（全量保留）');

console.log('▶ ③ 文件导入能用');
ok(/CFBundleDocumentTypes/.test(plistRaw), 'Info.plist 声明 CFBundleDocumentTypes（否则 iOS 不把文件路由给我们）');
ok(/public\.json/.test(plistRaw), '声明能打开 public.json');
ok(/onOpenURL/.test(app), 'App 必须有 onOpenURL 入口（文件送进来要有人接）');
ok(/startAccessingSecurityScopedResource/.test(importer), '必须开安全作用域（自签包尤其需要）');
ok(/SourceFileImport\.importFile/.test(app) && /SourceFileImport\.importFile/.test(sources),
   '两条入口共用同一个导入器（行为一致）');
ok(/SourceImportError/.test(importer), '导入失败要区分「读不到」和「解析不了」');

console.log(`\n通过 ${pass} / 失败 ${fail}`);
if (fail > 0) process.exit(1);
