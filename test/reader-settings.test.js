/**
 * 阅读设置面板门禁（照栖阅那一版布局）。
 *
 * 用户给了参考截图：字号滑杆 + 字体 → 浅色/深色两排配色格子
 * → 跟随系统深浅色 → 翻页方式（仿真/滑动/平移/无动画/上下滚动）
 * → 功能宫格（大小/间距/朗读/高亮/气泡/格式/标题样式/页眉页脚/更多）。
 *
 * 硬要求：**没接上的功能只摆位不点**（灰掉、disabled）。
 * 给用户一个点下去只会挨骂的按钮，比没有更糟。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

const web = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');
const view = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderView.swift'), 'utf8');

console.log('\n── 面板结构（照截图的层次）──');
for (const [label, re] of [
  ['字号滑杆 + 小/大',      /Slider\(value: \$fontSize/],
  ['字体下拉',             /Menu\s*\{[\s\S]*?ReaderFont\.all/],
  ['配色格子（浅色一排）', /paletteRow\(ReaderTheme\.light/],
  ['配色格子（深色一排）', /paletteRow\(ReaderTheme\.darkRow/],
  ['跟随系统深浅色',       /跟随系统深浅色/],
  ['翻页方式那一排',       /private var pageTurnRow/],
  ['功能宫格',             /private var featureTiles/]
]) ok(re.test(web), label);

console.log('\n── 5 种翻页方式（跟参考 App 一致）──');
// 空白宽度不该被门禁卡住；直接按 raw 名找，不去截区间
for (const [raw, name] of [['flip','仿真'],['slide','滑动'],['flat','平移'],['none','无动画'],['scroll','上下滚动']]) {
  const re = new RegExp('raw:\\s*"' + raw + '",\\s*\\n?\\s*name:\\s*"' + name + '"');
  ok(re.test(web), `${name}（${raw}）在列表里`);
}

console.log('\n── 没接的功能：摆位但不点 ──');
const tiles = web.slice(web.indexOf('private var featureTiles'), web.indexOf('private func featureTile'));
const notReady = (tiles.match(/ready:\s*false/g) || []).length;
ok(notReady >= 7, `7 个功能标了 ready:false`, `实际 ${notReady}`);
ok(/\.disabled\(!t\.ready\)/.test(web), 'ready:false 的宫格是 disabled');
ok(/guard t\.ready else \{ return \}/.test(web), '点击前先挡一道（不只靠 disabled）');
ok(/foregroundStyle\(t\.ready \? Theme\.ink : Theme\.sub\.opacity\(0\.45\)\)/.test(web),
   '未接的格子画成灰的，一眼看得出还没做');

console.log('\n── 真接上的功能 ──');
ok(/ready:\s*true/.test(tiles), '有 ready:true 的格子（不是全摆位）');
ok(tiles.includes('大小') && tiles.includes('间距'), '大小 / 间距 是接上的');
ok(/lineSpacing = lineSpacing >= 16 \? 6 : lineSpacing \+ 4/.test(web), '间距格子能改行距');

console.log('\n── 配色色板 ──');
ok(/static let light: \[ReaderTheme\]/.test(view) && /static let darkRow: \[ReaderTheme\]/.test(view),
   '色板分了浅色一排 / 深色一排');
ok((view.match(/static let \w+ = ReaderTheme\(key:/g) || []).length >= 12,
   '色板够铺满两排', String((view.match(/static let \w+ = ReaderTheme\(key:/g) || []).length));
ok(/static func isDark/.test(view), '有 isDark 判定（给 isNightMode 用）');

console.log('\n── 踩过的坑不能再踩 ──');
ok(/if row\.count < 4 \{/.test(web),
   'ForEach(0..<n) 前面有 if 挡着 —— ForEach(0..<0) 在 SwiftUI 里会崩');
ok(!/rows\[\.\.<0\]/.test(web), '没有那个恒等于 0 的 id 计算残留');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
