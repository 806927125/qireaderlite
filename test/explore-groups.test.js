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
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  x ' + m)); };

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

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';

async function nativeMock(fn, args) {
  if (fn === 'request') {
    const url = String(args.url || '');
    if (url.indexOf('/discovestyle') >= 0) {
      return { ok: true, code: 200, url, headers: {}, body: STYLE_RESPONSE };
    }
    return { ok: true, code: 200, url, headers: {}, body: '{"code":0,"data":[]}' };
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  if (fn === 'deviceID') return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
  if (fn === 'getWebViewUA') return { ok: true, value: UA };
  return { ok: true, value: '' };
}

(async () => {
  const { win } = createSandbox({ nativeMock });
  const VARS = JSON.stringify({
    tab: '小说', tone_id: '默认音色', shuqi_tone_id: 'multi_role',
    server: 'https://v5.langge.uk', sources: '全部', source_type: '男频',
    find_source: '番茄', find_tab: '小说', fqpara: 'on', fqcommunity: 'on', pstyle: '0',
  });
  const source = Object.assign({}, bookSource, { __variables: VARS, __loginInfo: {} });

  const r = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
    source, cookieSnapshot: {},
  })})`);
  const kinds = r.kinds || [];
  console.log('  分类数:', kinds.length);
  kinds.forEach(k => console.log('   ·', JSON.stringify({ t: k.title, g: k.group })));

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
  ok(rec && /☆/.test(rec.group || ''),
     '「推荐榜」带上了装饰行组名（实际 ' + JSON.stringify(rec && rec.group) + '）');
  const city = kinds.find(k => k.title === '都市');
  ok(city && /热门标签/.test(city.group || ''),
     '「都市」带上了「热门标签」组名（实际 ' + JSON.stringify(city && city.group) + '）');

  console.log('');
  console.log('=== 4. 组标题行的 title 直接当组名（栖阅同款）===');
  // 站方原始数据：[8] 的 title 就叫「分类」⇒ 栖阅那一组的组名就是「分类」
  const cityKind = kinds.find(k => k.title === '都市');
  ok(cityKind && /热门标签/.test(cityKind.group || ''),
     '组标题行的 title 原文当组名（不是 style 的原始 JSON）');

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

  console.log('');
  console.log(`${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
