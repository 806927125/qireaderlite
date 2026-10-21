#!/usr/bin/env node
/**
 * **「测书源」功能的结构门禁**
 *
 * 背景（2026-10-21）：用户给了栖阅的「测书源」测试器截图 ⇒ 轻阅补了同款。
 * 这个门禁守住三件容易改坏的事：
 *   ① 四个阶段（发现/详情/目录/正文）**一个都不能漏**
 *   ② **某个阶段失败不许中断后面的阶段**（栖阅就是这种：目录挂了也照样测正文）
 *      —— 忘了包 do/catch 的话，目录一挂正文就不测了，用户还以为正文也坏了
 *   ③ 每个阶段都要**独立计时**（栖阅的「目录 2.32s / 正文 1.38s」）
 *
 * ⚠️ Swift 侧编不到沙盒（依赖 WebKit）⇒ 这里断言的是**源码结构**。
 *    真正的编译验证靠 CI（macOS runner）。
 */
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };
const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

(async () => {
  const runnerPath = 'QiReaderLite/Core/SourceTestRunner.swift';
  const timelinePath = 'QiReaderLite/Core/EngineLogTimeline.swift';
  const viewPath = 'QiReaderLite/Features/Sources/SourceTestView.swift';
  const listPath = 'QiReaderLite/Features/Sources/SourcesView.swift';

  console.log('=== ① 文件都在 ===');
  for (const p of [runnerPath, timelinePath, viewPath, listPath]) {
    ok(fs.existsSync(path.join(__dirname, '..', p)), p + ' 存在');
  }
  if (fail) { console.log(`\n❌ 通过 ${pass} / 失败 ${fail}`); process.exit(1); }

  const runner = read(runnerPath);
  const timeline = read(timelinePath);
  const view = read(viewPath);
  const list = read(listPath);

  console.log('\n=== ② 四个阶段一个都不能漏 ===');
  for (const [stage, call] of [
    ['发现', 'exploreKinds'],
    ['详情', 'bookInfo'],
    ['目录', 'toc'],
    ['正文', 'content'],
  ]) {
    ok(runner.includes(`.${call}(`), `编排器调了 ${call}（${stage}阶段）`);
  }
  ok(runner.includes('case .discover') && runner.includes('case .detail')
     && runner.includes('case .toc') && runner.includes('case .content'),
     '四个阶段的 Kind 都定义了');
  ok(/search\(source:/.test(runner), '发现失败时能回落搜索');

  console.log('\n=== ③ 失败不许中断后面的阶段 ===');
  // 每个阶段各自一个 do/catch ⇒ 目录挂了正文照样测
  const doCount = (runner.match(/\bdo \{/g) || []).length;
  const catchCount = (runner.match(/\} catch \{/g) || []).length;
  ok(doCount >= 4, `每个阶段都有独立 do（找到 ${doCount} 个）`);
  ok(catchCount >= 4, `每个阶段都有独立 catch（找到 ${catchCount} 个）`);
  // ⚠️ 阶段失败后不能 return —— 那样后面就不跑了
  const returnsInsideCatch = /\} catch \{[^}]*return report/s.test(runner);
  ok(!returnsInsideCatch, 'catch 里没有「直接 return」把后面的阶段掐掉');

  console.log('\n=== ④ 每步独立计时 ===');
  ok((runner.match(/Date\(\)/g) || []).length >= 4, '每个阶段各起了一次计时');
  ok(runner.includes('ms = Int(Date().timeIntervalSince'), '每阶段都记了耗时');

  console.log('\n=== ⑤ 时间线解析（栖阅同款）===');
  ok(timeline.includes('static func groups('), '有按步骤分组');
  ok(timeline.includes('static func timings('), '有分步耗时解析');
  ok(timeline.includes('op「') || timeline.includes('op「'), '耗时从「op「x」耗时 Nms」里取');
  ok(timeline.includes('isError'), '有错误判定');
  // 分组/耗时两处面板必须共用同一份解析（别各写一套）
  ok(view.includes('EngineLogTimeline.groups('), '测书源页用了共用的分组解析');
  ok(read('QiReaderLite/Features/Sources/EngineLogSheet.swift').includes('EngineLogTimeline.groups('),
     '引擎自检页也用了共用的分组解析');

  console.log('\n=== ⑥ 入口在书源页 ===');
  ok(list.includes('测书源'), '书源列表菜单里有「测书源」');
  ok(list.includes('SourceTestView(source:'), '点了能打开测书源页');
  ok(view.includes('复制报告'), '有「复制测试报告」');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
