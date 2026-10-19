/**
 * 阅读器翻页模式门禁（逻辑部分，纯离线）。
 *
 * 背景（2026-10-19 用户反馈）：「想看第二章必须进目录点第二章才出正文」。
 * 底栏其实早就有 ‹ › 按钮（调 session.jump），但要点一下才出现，
 * 等于没有。改成阅读器标准的翻页交互：
 *   点正文左 32% = 上一章 / 点右 32% = 下一章 / 点中间 = 出菜单
 *   左右滑动 = 翻章
 * 翻到头/尾要弹一句提示，不能装没听见。
 *
 * 这里只测**纯逻辑**（分区判定 + 滑动方向 + 边界），
 * Swift 那层的编译由 CI 真 Xcode 负责。
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
const sess = fs.readFileSync(path.join(ROOT, 'Core/ReaderSession.swift'), 'utf8');
const host = fs.readFileSync(path.join(ROOT, 'Core/ReaderHost.swift'), 'utf8');

console.log('\n── 分区判定 ──');
ok(/x < 0\.32/.test(web), '左 32% → 上一章');
ok(/x > 0\.68/.test(web), '右 32% → 下一章');
ok(web.indexOf('0.32') < web.indexOf('0.68'), '左右阈值有序（0.32 < 0.68）');

console.log('\n── 滑动翻页 ──');
ok(/g\.direction = \[\.left, \.right\]/.test(web),
   '手势只认左右（不能抢纵向滚动）');
// 拼装出来再查，避免命中注释里的文字
const code = web.replace(/\/\/.*$/gm, '');
ok(!/direction = \.horizontal/.test(code),
   '没有用编译期不存在的 Direction.horizontal');
ok(/cancelsTouchesInView = false/.test(web),
   'cancelsTouchesInView = false —— 否则 web view 收不到触摸，正文滚不动');
ok(/case \.left:\s*cb\(1\)/.test(web.replace(/\s+/g, ' ')), '左滑 = 下一章');
ok(/case \.right:\s*cb\(-1\)/.test(web.replace(/\s+/g, ' ')), '右滑 = 上一章');

console.log('\n── 边界必须提示，不能装没听见 ──');
ok(/func step\(_ delta: Int\)/.test(sess), 'ReaderSession 有 step(delta)');
ok(/已经是第一章/.test(sess) && /已经是最后一章/.test(sess), '两头都有提示文案');
ok(/onPageEdge\?/.test(sess), '到头会回调 onPageEdge');
ok(/next < 0/.test(sess) && /next >= flat\.count/.test(sess), '两个边界都判了');

console.log('\n── 坐标要能从 web view 传回来 ──');
ok(/onTapZone/.test(host), 'ReaderHost 有 onTapZone 回调');
ok(/m\["x"\] as\? Double/.test(host), 'tap 消息里读 x');
ok(/__qrTapPos/.test(host), '注入了 tap 坐标补丁（reader.js 原文件不动）');
ok(!/preventDefault\(\)\s*;\s*\}\s*,\s*true/.test(host),
   '补丁不 preventDefault —— 段评点按/选词/长按不受影响');

console.log('\n── 开关与默认值 ──');
ok(/@AppStorage\("reader\.pageTurn"\) private var pageTurn: Bool = true/.test(web),
   '翻页模式默认开（用户明确要的）');
// 开关现在长成「翻页方式那一排」，选「上下滚动」就等于关掉分页
ok(/private var pageTurnRow/.test(web), '设置里有翻页方式那一排（在上半卡片里）');
ok(/pageTurnMode = m\.raw\s*\n\s*pageTurn = m\.raw != "scroll"/.test(web)
   || /pageTurnMode = m\.raw[\s\S]{0,80}pageTurn = m\.raw != "scroll"/.test(web),
   '选「上下滚动」= 关掉分页，能回到老行为');
ok(/pageTurn = m\.raw != "scroll"/.test(web), '上下滚动会自动把 pageTurn 置 false');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
