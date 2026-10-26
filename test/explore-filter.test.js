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
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  const { win } = createSandbox({ nativeMock: async () => ({ ok: true, value: '' }) });

  console.log('=== ① 站方的筛选栏项必须分流到 filters，不能混进 kinds ===');
  const kinds = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
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
  })})`);

  const ks = kinds.kinds || [];
  const fs2 = kinds.filters || [];
  console.log('  kinds  :', ks.map(k => k.title).join(' , ') || '(空)');
  console.log('  filters:', fs2.map(f => `${f.title}(${f.chars.length}项→${f.paramKey})`).join(' , ') || '(空)');

  ok(ks.length === 1, `只有 1 个真分类进了 kinds（实际 ${ks.length}）`);
  ok(ks[0] && ks[0].title === '我的书架', '真分类「我的书架」在 kinds 里');
  ok(fs2.length === 2, `两个筛选项进了 filters（实际 ${fs2.length}）`);

  console.log('\n=== ② 筛选项的内容（选项 / 当前值 / 变量名）===');
  const pf = fs2.find(f => f.title === '平台');
  ok(!!pf, '找得到「平台」筛选项');
  ok(pf && pf.chars.length === 4, `「平台」有 4 个选项（实际 ${pf && pf.chars.length}）`);
  ok(pf && pf.chars.indexOf('七猫') >= 0, '选项里有「七猫」');
  ok(pf && pf.default === '番茄', `默认值是「番茄」（实际 ${pf && pf.default}）`);
  ok(pf && pf.paramKey === 'find_source',
     `变量名从 action 里抠出来了 = find_source（实际 ${pf && pf.paramKey}）`);

  const mf = fs2.find(f => f.title === '模式');
  ok(mf && mf.paramKey === 'find_tab', `「模式」→ find_tab（实际 ${mf && mf.paramKey}）`);

  console.log('\n=== ③ url 为空的普通项（不是 select）要过滤掉 ===');
  const kinds2 = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
    source: {
      bookSourceUrl: 'https://example.com',
      exploreUrl: JSON.stringify([{ title: '纯动作项' }])
    }
  })})`);
  // ⚠️ 2026-10-22 改：**url 为空的项要过滤掉**
  //   站方 style_list 里混着一堆 `title:"--"`、url 为空串的项
  //   （番茄 14 个 / QQ阅读 1 个）⇒ 界面上就是一排没意义的「--」❗
  //   （跟 Legado 行为一致：空 url 的 kind 不能请求，直接不显示）
  ok((kinds2.kinds || []).length === 0,
     'url 为空的普通项被过滤掉了（站方数据里的「--」不该显示）');
  ok((kinds2.filters || []).length === 0, '它不是 select ⇒ 不进 filters');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
