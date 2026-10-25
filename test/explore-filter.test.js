#!/usr/bin/env node
/**
 * **发现页筛选栏（站方 `type:"select"` 契约）**（2026-10-21）
 *
 * 跑法：node test/explore-filter.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景（用户原话：「分类不应该有 api 的吗」）
 *
 * 站方（🍅大灰狼）的 `exploreUrl` 返回的不是纯分类列表：
 *     `qtsj.concat(infoData, groupDatas, style_list)`
 * 其中 `qtsj` 是**发现页筛选栏**（栖阅契约）：
 *     createFilter("平台", ["番茄","七猫","书旗",…], sources, "find_source", 1)
 *     createFilter("模式", ["小说","听书","短剧","漫画"], tab, "find_tab", 0.33)
 * 形状：`{ title, type:"select", chars:[…], default:当前值, action:"show(infoMap['平台'],'find_source')" }`
 *
 * ⚠️ 这些项**没有 url** ⇒ 以前混进分类列表 ⇒ 点不动 ⇒ 用户看到「平台」没有 api。
 * ⇒ 现在引擎侧必须把它们**分流**到 `filters`，一个都不许混进 `kinds`。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：本门禁在 jsdom 里跑老引擎（`Resources/engine/*.js`）⇒ 那些文件已删 ⇒ 门禁的对象没了。
 * · 现在：**直接调新引擎**（`legado-engine` 的 `--op exploreKinds`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老写法的 JS 层 `nativeMock` 已作废 ⇒ 改**声明式 `routes`**（本门禁全程离线，不需要路由）。
 *
 * ⚠️ **「筛选项的选项 / 当前值 / 变量名」现在归谁管**（迁移时必须说清，否则覆盖悄悄丢了）：
 *   | 字段 | 现在在哪 | 本门禁怎么验 |
 *   |---|---|---|
 *   | `chars` / `default` / `action` | **引擎侧**（`SourceFilter` 模型 + `splitExploreItems`） | 静态断言【新引擎 Swift 源码】 |
 *   | `paramKey`（从 action 抠变量名） | **宿主侧**（`LegadoEngineBackend.paramKey`） | 静态断言【App Swift 源码】（另有 Swift 门禁 `test/engine-backend-test.swift` ④） |
 *   | 分流（select ⇒ filters） | **引擎侧** | ✅ 下面【真跑段】 |
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段** ⇒ 那是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

(async () => {
  // ⚠️ 引擎没编译 ⇒ **显式 SKIP**（「没验到」≠「通过」）
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  // ⭐ 本门禁**不联网**（exploreUrl 是静态 JSON ⇒ 引擎压根不发请求）⇒ 不配 routes
  const { win } = createSandbox({});

  console.log('=== ① 站方的筛选栏项必须分流到 filters，不能混进 kinds ===');
  const res = win.__qrInvoke('exploreKinds', {
    source: {
      bookSourceUrl: 'https://example.com',
      exploreUrl: JSON.stringify([
        { title: '平台', type: 'select', chars: ['番茄', '七猫', '书旗', 'QQ阅读'],
          default: '番茄', action: "show(infoMap['平台'],'find_source')" },
        { title: '模式', type: 'select', chars: ['小说', '听书', '短剧', '漫画'],
          default: '小说', action: "show(infoMap['模式'],'find_tab')" },
        { title: '我的书架', url: 'https://example.com/shelf' }
      ])
    }
  });
  const kinds = (res && res.kinds) || [];
  const fs2 = (res && res.filters) || [];
  console.log('  kinds  :', kinds.map(k => k.title).join(' , ') || '(空)');
  console.log('  filters:', fs2.map(f => f.title).join(' , ') || '(空)');
  if (res && res.error) console.log('  engine error:', res.error);

  ok(kinds.length === 1, `只有 1 个真分类进了 kinds（实际 ${kinds.length}）`);
  ok(!!(kinds[0] && kinds[0].title === '我的书架'), '真分类「我的书架」在 kinds 里');
  ok(!!(kinds[0] && kinds[0].url === 'https://example.com/shelf'),
     '真分类带上了 url（点得动）');
  ok(fs2.length === 2, `两个筛选项进了 filters（实际 ${fs2.length}）`);
  ok(!kinds.some(k => k.title === '平台' || k.title === '模式'),
     '筛选项**没有**混进 kinds（用户点不动的那几个就是它们）');

  console.log('\n=== ② 筛选项的【选项 / 当前值 / 变量名】归谁管（迁移后重新定位） ===');
  // ⭐⭐⭐ 老引擎把 `chars` / `default` / `paramKey` 直接挂在 filter 上。
  //   新引擎的 `--op exploreKinds` **只输出 title** ⇒ 这三条**没法真跑** ⇒
  //   改按【新引擎 / App 的源码】断言（等价语义在哪 ⇒ 见下）⭐⭐⭐
  const models = engineSwiftSrc('Pipeline/Models.swift');
  const engineSrc = engineSwiftSrc('Pipeline/SourceEngine.swift');

  // ②-1 引擎侧：筛选项模型必须带着「选项 / 当前值 / 动作」
  ok(/struct\s+SourceFilter/.test(models),
     '新引擎有【筛选项模型 SourceFilter】（站方 type:"select" 的载体）');
  ok(/var\s+chars:\s*\[String\]/.test(models),
     '⭐ 筛选项模型带着**选项列表 chars**（站方 createFilter 的第二个参数）');
  ok(/var\s+defaultValue:\s*String\?/.test(models),
     '⭐ 筛选项模型带着**当前值 default**（站方 createFilter 的第三个参数）');
  ok(/var\s+action:\s*String\?/.test(models),
     '⭐ 筛选项模型带着**动作 action**（站方 createFilter 的第四个参数）');

  // ②-2 引擎侧：分流时必须真的把 chars / default / action 取出来
  const split = engineSrc.slice(engineSrc.indexOf('public static func splitExploreItems'));
  ok(/o\["chars"\]/.test(split), '⭐ 分流时从站方对象里取 **chars**（选项列表）');
  ok(/o\["default"\]/.test(split), '⭐ 分流时从站方对象里取 **default**（当前值）');
  ok(/o\["action"\]/.test(split), '⭐ 分流时从站方对象里取 **action**（动作表达式）');
  ok(/SourceFilter\(title:\s*ftitle,\s*chars:\s*chars,[\s\S]{0,160}?action:\s*o\["action"\]/.test(split),
     '⭐⭐ 这些值真的进了 SourceFilter（不是取了不用）');

  // ②-3 宿主侧：**变量名 paramKey** 是宿主从 action 里抠的（不是引擎的活）
  const backend = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Core', 'LegadoEngineBackend.swift'), 'utf8');
  ok(/static func paramKey\(from action: String\?\) -> String/.test(backend),
     '⭐⭐ 宿主有 paramKey 的实现（从站方 action 抠源级变量名）');
  ok(/"paramKey"/.test(backend),
     '⭐⭐ 宿主把 paramKey 挂回筛选项（轻阅侧的语义：变量名要给到界面）');
  // ⭐ 等价覆盖在【Swift 原生层门禁】：`test/engine-backend-test.swift` ④（`paramKey(from:) == "find_source"`）

  console.log('\n=== ③ url 为空的普通项（不是 select）要过滤掉 ===');
  const res2 = win.__qrInvoke('exploreKinds', {
    source: {
      bookSourceUrl: 'https://example.com',
      exploreUrl: JSON.stringify([{ title: '纯动作项' }])
    }
  });
  // ⚠️ 2026-10-22 改：**url 为空的项要过滤掉**
  //   站方 style_list 里混着一堆 `title:"--"`、url 为空串的项
  //   （番茄 14 个 / QQ阅读 1 个）⇒ 界面上就是一排没意义的「--」❗
  //   （跟 Legado 行为一致：空 url 的 kind 不能请求，直接不显示）
  ok(((res2 && res2.kinds) || []).length === 0,
     'url 为空的普通项被过滤掉了（站方数据里的「--」不该显示）');
  ok(((res2 && res2.filters) || []).length === 0, '它不是 select ⇒ 不进 filters');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
