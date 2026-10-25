#!/usr/bin/env node
/**
 * **发现页分类的分组解析**（2026-10-22 对照栖阅截图发现）
 *
 * 跑法：node test/explore-groups.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 站方（🍅大灰狼）的 exploreUrl 拿分类的方式：
 *     style_list = (JSON.parse(java.ajax(`${base}/discovestyle?...`))).data || []
 * ⇒ 那是**对象数组**：`{ title, url, style:{layout_flexGrow, layout_flexBasisPercent} }`
 *
 * 其中有三种：
 *   ① **装饰行**  title = 「°・*.☆ 排行榜 ☆.*・°」  style.flexBasisPercent = 1
 *      ⇒ **组标题**（栖阅的分组就来自这里）
 *   ② **信息行**  title = 「当前为: 番茄 [小说] 频道: 男频」  style.flexBasisPercent = 1
 *      ⇒ 既不是组也不是分类 ⇒ 丢掉
 *   ③ **分类项**  title = 「推荐榜」  style.flexBasisPercent = 0.25
 *
 * ⚠️⚠️ **原来的 bug**：引擎的「无 `::` ⇒ 组标题」解析**只对字符串项生效**
 *    （那是「标题::URL」两段式站源）⇒ **对象项的装饰行被当成了普通分类项**
 *    ⇒ `group` 全空 ⇒ 宿主只好拿 `style` 当组名
 *    ⇒ 界面上出现 `{"layout_flexGrow":1,"layout_flexBasisPercent":0.25}` 这种**原始 JSON 标题** ❗
 *
 * ⇒ 修：对象项也认装饰行（title 含 ☆ / ° / ○）⇒ 设为 group；信息行丢掉。
 *    修完后 group 分布实测（沙盒真跑站方）：
 *      "(空)": 2 / "°・*.☆ 排行榜 ☆.*・°": 9 / "°・*.☆ 热门标签 ☆.*・°": 48 / "°・*.☆ 主题 ☆.*・°": 90
 *    ⇒ 跟栖阅那页**完全一致**
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/*.js`）⇒ 已删 ⇒ 门禁的对象没了。
 * · 现在：**直接调新引擎**（`legado-engine --op exploreKinds`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（站方的 `/discovestyle` 走路由 ⇒ 全程离线）。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段** ⇒ 那是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

// ⭐⭐⭐ **已知回归清单**（迁移时实测出来的 ⇒ 新引擎**没有**这些语义）
//   ⇒ 下面相关断言钉的是【现状】⇒ 引擎修好后这些断言会红 ⇒ 那时改成断言「应有行为」⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **2026-10-26：R-分组 已修**（引擎 `b6d89e4`）⇒ 清单**已清空**
//   ⇒ 「对象数组里 url 为空的装饰行 = 组标题行」这条语义 ⇒ 新引擎**现在有了** ⭐⭐⭐
//   ⇒ 断言已升级成**钉真实语义**（见第 3 段）⇒ 引擎再退化会红 ⭐⭐⭐
const KNOWN_REGRESSIONS = [];

const SRC_FILE = path.join(__dirname, '..', 'sources', '🍅大灰狼聚合5.9.30-轻阅适配版v2.json');
const raw = JSON.parse(fs.readFileSync(SRC_FILE, 'utf8'));
const bookSource = (Array.isArray(raw) ? raw : [raw])[0];

/** 站方 discovestyle 的真实响应形状（照抄实测数据） */
const STYLE_RESPONSE = JSON.stringify({
  code: 0, msg: '', data: [
    { title: '大灰狼个人中心', url: 'https://v5.langge.uk/get_book_shelf', style: { layout_flexGrow: 1, layout_flexBasisPercent: 0.45 } },
    { title: '当前为: 番茄 [小说] 频道: 男频', style: { layout_flexGrow: 1, layout_flexBasisPercent: 1 } },
    { title: '°・*.☆ 排行榜 ☆.*・°', style: { layout_flexGrow: 1, layout_flexBasisPercent: 1 } },
    { title: '推荐榜', url: 'https://v5.langge.uk/get_discover?bdtype=推荐榜&page={{page}}', style: { layout_flexGrow: 1, layout_flexBasisPercent: 0.25 } },
    { title: '完本榜', url: 'https://v5.langge.uk/get_discover?bdtype=完本榜&page={{page}}', style: { layout_flexGrow: 1, layout_flexBasisPercent: 0.25 } },
    { title: '°・*.☆ 热门标签 ☆.*・°', style: { layout_flexGrow: 1, layout_flexBasisPercent: 1 } },
    // ⚠️ 站方 style_list 里混着的一堆 `title:"--"`、**url 为空串**的项
    //    （番茄 14 个 / QQ阅读 1 个 / 七猫 0 个）⇒ 界面上就是一排没意义的「--」❗
    { title: '--', url: '', style: { layout_flexGrow: 1, layout_flexBasisPercent: 0.25 } },
    { title: '都市', url: 'https://v5.langge.uk/discovedata?category_id=203&page={{page}}', style: { layout_flexGrow: 1, layout_flexBasisPercent: 0.25 } },
  ],
});

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  // ⭐⭐⭐ **假服务器 = 声明式 routes**（老写法的 JS 层 nativeMock 已作废）
  //   · `/discovestyle` ⇒ 站方拿分类列表的那条请求（实测真实 URL）
  //   · `langge.uk`   ⇒ 兜底（站方 JS 还会串几条别的请求）
  const { win } = createSandbox({
    routes: [
      { match: '/discovestyle', status: 200, body: STYLE_RESPONSE },
      { match: 'langge.uk', status: 200, body: '{"code":0,"data":[]}' },
    ],
  });

  // ⚠️⚠️ **payload 要走 argv** ⇒ 有 128KB 上限 ⇒ 源里只留【探索页要用的字段】
  //   （`jsLib` 单独放顶层：引擎的 `--op` 从顶层读它；源码里再放一份就是白占 32KB）
  const source = {
    bookSourceUrl: bookSource.bookSourceUrl,
    bookSourceName: bookSource.bookSourceName,
    exploreUrl: bookSource.exploreUrl,
  };
  const r = win.__qrInvoke('exploreKinds', { source, jsLib: bookSource.jsLib });
  const kinds = (r && r.kinds) || [];
  console.log('  分类数:', kinds.length);
  kinds.forEach(k => console.log('   ·', JSON.stringify({ t: k.title, g: k.group })));
  if (r && r.error) console.log('  engine error:', r.error);

  console.log('');
  console.log('=== 1. 装饰行 ⇒ 组标题（不再是分类项）===');
  const deco = kinds.filter(k => /[☆°○]/.test(k.title || ''));
  ok(deco.length === 0, '装饰行不该作为分类项出现（实际 ' + deco.length + ' 个）');

  console.log('');
  console.log('=== 2. 「当前为: XX」这类行是【组标题】，不是分类项（栖阅同款）===');
  // 栖阅的 QQ阅读 页有卡片「当前为: QQ阅读 [小说]频道：男频」⇒ 它是**组标题**
  // ⇒ 站方数据里 url 为空的行 = 组标题行（引擎把它解析进 kind.group）
  ok(!kinds.some(k => (k.title || '').indexOf('当前为') >= 0),
     '「当前为: XX」不作为分类项出现（它是组标题）');
  ok(kinds.every(k => (k.title || '').indexOf('当前为') < 0),
     '组标题行本身不会混进分类列表');

  console.log('');
  console.log('=== 3. 分类项带上正确的组名 ===');
  const rec = kinds.find(k => k.title === '推荐榜');
  ok(!!rec, '「推荐榜」在分类里');
  // ⭐⭐⭐⭐⭐ **对象项的组标题行**（2026-10-26 引擎已修 ⇒ 这里钉**真实语义**）
  //
  //   老引擎语义：**对象项**里「url 为空」的装饰行 ⇒ 设为**组标题**（后面的分类归它）
  //   ⇒ 站方（🍅大灰狼 / QQ阅读 / 七猫）的 style_list 就是这种形态 ⭐⭐⭐
  //   ⇒ 以前新引擎把它**直接丢掉** ⇒ **分组全没了** ⇒ 界面「糊成一块 / 未分组」⭐⭐⭐
  //
  //   ⚠️ 判据**只能是 url 空不空**（不能看 style！站方组标题行的 style.pct 也是 1）⭐⭐⭐
  ok(!!rec && rec.group,
     '对象项的组标题行生效 ⇒ 「推荐榜」拿到了组名（实际：' + (rec && rec.group) + '）');
  const city = kinds.find(k => k.title === '都市');
  ok(!!city, '「都市」在分类里');
  // ⭐ 「都市」前面最近的组标题行是「热门标签」⇒ 归到**它**，不是「推荐榜」那个组
  //   ⇒ 这才叫「最近的组标题行」⇒ 钉住「就近归属」这条语义
  ok(!!city && !!city.group && city.group.indexOf('热门标签') >= 0,
     '「都市」归到它**前面最近**的组标题（热门标签）⇒ 就近归属（实际：' + (city && city.group) + '）');
  const done = kinds.find(k => k.title === '完本榜');
  ok(!!done && done.group === (rec && rec.group),
     '「完本榜」与「推荐榜」同组（同一个组标题行下面的分类）');

  console.log('');
  console.log('=== 4. 字符串项的组标题（新引擎【有】这层解析 ⇒ 钉住它）===');
  // ⭐ 站方的另一种形态：「标题::URL」两段式（字符串项）
  //   ⇒ 无 `::` 的行 = 组标题（装饰符号要剥掉）⇒ 后面的项归它（引擎仓 §S-KIND-03）
  const r2 = win.__qrInvoke('exploreKinds', {
    source: {
      bookSourceUrl: 'https://x.example/',
      exploreUrl: '☆ 排行榜 ☆\n推荐榜::https://x.example/1\n完本榜::https://x.example/2',
    },
  });
  const kinds2 = (r2 && r2.kinds) || [];
  console.log('  字符串项的分类:', kinds2.map(k => `${k.title}→[${k.group}]`).join(' , ') || '(空)');
  ok(kinds2.length === 2, `字符串项解析出 2 个分类（实际 ${kinds2.length}）`);
  ok(kinds2.every(k => k.group === '排行榜'),
     '⭐ 字符串项的组标题生效（装饰符号剥掉 ⇒ 「排行榜」）');
  ok(!kinds2.some(k => /[☆°○]/.test(k.title || '')),
     '组标题行本身不作为分类项输出');

  console.log('');
  console.log('=== 5. url 为空的分类项（站方数据里的「--」）要过滤掉 ===');
  ok(!kinds.some(k => (k.title || '').trim() === '--'),
     '站方那个 title="--"、url 为空的项不该显示');
  ok(kinds.every(k => String(k.url || '').trim().length > 0),
     '所有显示出来的分类都有 url（空 url 没法请求）');

  console.log('');
  console.log('=== 6. 组名不是原始 JSON ===');
  ok(kinds.every(k => !/^\{.*\}$/.test((k.group || '').trim())),
     '组名不能是站方 style 的原始 JSON（那正是这次的 bug 症状）');
  ok(kinds.every(k => !/^\{.*\}$/.test((k.style || '').trim())),
     'style 是原始 JSON（老引擎把它当组名 ⇒ 界面上出现一串 JSON）');

  console.log('');
  console.log('=== 7. 站方的分类请求真的发出去了（假服务器接住了） ===');
  const reqs = (r && r.requests) || [];
  console.log('  引擎回传的请求:', reqs.join(' , ') || '(无)');
  ok(reqs.some(u => u.indexOf('/discovestyle') >= 0),
     '⭐ 引擎确实去站方拿了分类列表（/discovestyle）');

  console.log('');
  console.log('⚠️ 已知回归（新引擎没有 ⇒ 本门禁钉的是现状，已上报）：');
  KNOWN_REGRESSIONS.forEach((t, i) => console.log(`   ${i + 1}. ${t}`));

  console.log('');
  console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
