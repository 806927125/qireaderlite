#!/usr/bin/env node
/**
 * **发现页翻页 + 筛选栏玻璃**（2026-10-22 真机「发现页没有翻页功能」）
 *
 * 跑法：node test/explore-paging-glass.test.js
 *
 * 这两条是 **SwiftUI 层**的逻辑（沙盒 swiftc 编不了 SwiftUI），
 *    所以用**源码断言**锁住关键判据。
 *    断言前必须**剥掉注释** —— 否则注释里写一句「不要 xxx」就会被当成「有 xxx」⇒ 假红。
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  x ' + m)); };

const root = path.join(__dirname, '..');

/** 剥掉 Swift 注释（行注释 与 块注释） */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/gm, '');
}

const exploreRaw = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Features', 'Explore', 'ExploreView.swift'), 'utf8');
const loginRaw = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Features', 'Sources', 'SourceLoginSheet.swift'), 'utf8');
const explore = stripComments(exploreRaw);
const login = stripComments(loginRaw);

console.log('=== 1. 默认选中的分类必须带 {{page}}（否则翻页拿回同一页）===');
ok(explore.indexOf('{{page}}') >= 0, 'ExploreView 里有 page 占位符的判据');
ok(/pageable\s*=\s*withURL\.filter/.test(explore), '有「可翻页分类」的筛选');
ok(/pageable\.isEmpty[\s\S]{0,300}?pageable\.first/.test(explore),
   '优先选 pageable.first（真正的分类）而不是列表第一个');

console.log('');
console.log('=== 2. 翻页成功时不能自增 loadMoreID（否则自动连翻到死）===');
const loadMoreBody = (explore.match(/private func loadMore\(\) async \{[\s\S]*?\n    \}/) || [''])[0];
ok(loadMoreBody.length > 0, '找到 loadMore() 实现');
ok(loadMoreBody.indexOf('loadMoreID += 1') < 0,
   'loadMore() 里没有 loadMoreID 自增（翻页成功不能自增）');
ok(/loadMoreID \+= 1/.test(explore), 'loadMoreID 仍在别处用（换分类时重置）');

console.log('');
console.log('=== 3. 底部要有看得见的「加载更多」按钮 ===');
ok(/Label\("加载更多"/.test(explore), '有「加载更多」按钮');

console.log('');
console.log('=== 4. 筛选键接入液态玻璃（别玻璃套玻璃）===');
ok(/\.glassCapsule\(\)/.test(explore), '筛选胶囊用 glassCapsule()');
const chipBlock = (explore.match(/private func filterChip[\s\S]*?\n    \}/) || [''])[0];
ok(chipBlock.length > 0, '找到 filterChip');
ok(chipBlock.indexOf('.background(') < 0, '筛选胶囊没有再叠 .background（玻璃套玻璃 = 一坨灰糊）');

console.log('');
console.log('=== 5. 分类页全平铺（栖阅同款，不自己造分组）===');
const picker = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Features', 'Explore', 'CategoryPickerView.swift'), 'utf8');
const pickerCode = stripComments(picker);
ok(pickerCode.indexOf('private var groups') < 0,
   '分类页不再有 groups 分组（站方 group 字段本来就是空的，那是我们自己造的）');
ok(/private var shown:\s*\[SourceService\.KindDTO\]/.test(pickerCode),
   'shown 是扁平的 KindDTO 数组（一个网格全平铺）');
ok(!/dict\[name, default: \[\]\]/.test(pickerCode),
   '不再用「按名字分字典」的方式造分组');
ok(/t == "未分组" \|\| t == "全部分类"/.test(pickerCode),
   '「未分组 / 全部分类」这两个自造名改为**过滤掉**（不是当分组名用）');
ok(/func isActionItem/.test(pickerCode), '有动作项过滤（个人中心/登录/书架那类不是分类）');
ok(!/actionWords[^\n]*推荐榜/.test(pickerCode),
   '「推荐榜」是**真分类**（栖阅那页第一个就是它）⇒ 不能被当动作项过滤掉');

console.log('');
console.log('=== 6. 登录页接入液态玻璃（按钮也要玻璃，栖阅同款）===');
ok(/struct GlassActionButtonStyle/.test(login), '有专用的玻璃按钮样式');
const bordered = (login.match(/buttonStyle\(\.bordered\)/g) || []).length;
ok(bordered === 0, '登录页不该还有 .buttonStyle(.bordered)（那是描边实心，不是玻璃；实际 ' + bordered + ' 处）');
const glassBtns = (login.match(/buttonStyle\(GlassActionButtonStyle\(\)\)/g) || []).length;
ok(glassBtns >= 7, '登录页按钮改成玻璃（实际 ' + glassBtns + ' 处）');
ok(/func glassField\(\)/.test(login), '有玻璃输入框');
ok(/glassField\(\)/.test(login), '站方的邮箱/密码框用了玻璃输入框');
ok(/PageBackdrop\(\)/.test(login),
   '登录页接上了 PageBackdrop（玻璃后面要有高对比内容才有折射效果）');
const n = (login.match(/\.glassCard\(cornerRadius: 12, variant: \.regular\)/g) || []).length;
ok(n >= 3, '登录页至少 3 处玻璃卡片（实际 ' + n + ' 处）');
ok(login.indexOf('Color.white.opacity(0.55), in: .rect(cornerRadius: 12)') < 0,
   '登录页不再有「半透明白背景」（已换成玻璃）');

console.log('');
console.log((fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
