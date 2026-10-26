#!/usr/bin/env node
/**
 * **发现页筛选栏：paramKey 为空时要执行站方 action**（2026-10-22 真机「平台切不了」）
 *
 * 跑法：node test/filter-action.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 站方有两种写法，宿主要分两条路：
 *
 *   ① 🍅大灰狼：`action: "show(infoMap['平台'],'find_source')"`
 *      ⇒ 引擎能抠出 paramKey（`find_source`）⇒ 宿主自己写这个源级变量 ✅
 *
 *   ② 🍒NovelHub 聚合源：action **自己读写源级变量、自己刷新发现页**
 *      (function(){var c={};try{c=JSON.parse(source.getVariable()||'{}');}catch(e){}
 *        var v=infoMap['平台'];if(v!==null&&v!==undefined){c['src']=v;
 *        try{source.setVariable(JSON.stringify(c));}catch(e1){}}
 *        try{java.refreshExplore();}catch(e2){}})()
 *      ⇒ 抠不出 paramKey（空）⇒ 宿主原来**直接 return** ⇒ **点了没反应** ⭐
 *
 * ⇒ 照栖阅的做法：把 `infoMap[标题] = 值` 喂给站方 action，让**站方自己**写变量
 *   （站方写完 `source.setVariable` ⇒ 标 dirty ⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘）
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

const root = path.join(__dirname, '..');
const engineSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Resources', 'engine', 'engine.js'), 'utf8');
const exploreSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Features', 'Explore', 'ExploreView.swift'), 'utf8');
const svcSrc = fs.readFileSync(
  path.join(root, 'QiReaderLite', 'Core', 'SourceService.swift'), 'utf8');

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
const PWD = 'nhub2026';

const nativeMock = async (fn, args) => {
  if (fn === 'request') {
    const url = String(args.url || '');
    const method = (args.method || 'GET').toUpperCase();
    try {
      const res = await fetch(url, {
        method,
        headers: Object.assign({ 'User-Agent': UA }, args.headers || {}),
        body: (args.body && method !== 'GET' && method !== 'HEAD') ? args.body : undefined,
        redirect: 'follow',
      });
      return { ok: true, code: res.status, url, headers: {}, body: await res.text() };
    } catch (e) { return { ok: false, error: String(e.message) }; }
  }
  if (fn === 'log' || fn === 'toast') return { ok: true };
  if (fn === 'deviceID') return { ok: true, value: '0o6q14mk3z3qmvi6dtvf' };
  if (fn === 'getWebViewUA') return { ok: true, value: UA };
  if (fn === 'md5Encode') {
    const crypto = require('crypto');
    return { ok: true, value: crypto.createHash('md5').update(String(args.text || args.str || '')).digest('hex') };
  }
  return { ok: true, value: '' };
};

(async () => {
console.log('=== 1. 源码：要有 filterAction op + 宿主两条路 ===');
ok(/filterAction: function \(p\) \{/.test(engineSrc), 'engine.js 里有 filterAction op');
ok(/infoMap\[title\] = value/.test(engineSrc), 'filterAction 把选中值塞进 infoMap[标题]');
ok(/applySourceFilter/.test(svcSrc), 'SourceService 有 applySourceFilter');
ok(/applyFilter\(f, c\)/.test(exploreSrc), '筛选按钮传的是整个筛选项（含 action）');
ok(/f\.paramKey\.isEmpty/.test(exploreSrc) && /applySourceFilter/.test(exploreSrc),
   'paramKey 为空时走「执行站方 action」那条路');
ok(/setFilterChoice/.test(exploreSrc) && /filterChoice/.test(svcSrc),
   '宿主自己记「用户选了什么」（paramKey 为空时读不到源级变量 ⇒ 胶囊要显示这个）');

console.log('\n=== 2. 活体：NovelHub 的「平台」筛选项能不能切 ===');
const NH = path.join(root, 'sources', 'NovelHub聚合小说-轻阅版.json');
if (!fs.existsSync(NH)) {
  console.log('  (跳过：本地没有 NovelHub 源文件)');
} else {
  const src = JSON.parse(fs.readFileSync(NH, 'utf8'))[0];
  const { win } = createSandbox({ nativeMock });

  // 已解锁的源级变量（否则 nhAuth() 恒 false ⇒ 一个分类都没有）
  const crypto = require('crypto');
  const authVars = JSON.stringify({
    nhAuthed: crypto.createHash('md5').update(PWD).digest('hex')
  });

  const ex = await win.eval("window.__qrInvoke('exploreKinds', " + JSON.stringify({
    source: Object.assign({}, src, { __variables: authVars, __loginInfo: {} }),
    cookieSnapshot: {},
  }) + ")");
  const filters = (ex && ex.filters) || [];
  console.log('  filters:', filters.length, '| kinds:', ((ex && ex.kinds) || []).length);
  ok(filters.length > 0, '筛选项能解析出来');
  const plat = filters.find(f => f.title === '平台');
  ok(!!plat, '有「平台」筛选项');
  if (plat) {
    console.log('  平台 paramKey =', JSON.stringify(plat.paramKey),
                '| chars', plat.chars.length, '| default =', plat.default);
    ok(plat.paramKey === '', 'NovelHub 的 paramKey 是空的（⇒ 必须执行 action 才能切）');

    // 选一个真存在的平台（不是第一个，避免跟默认值撞上）
    const target = plat.chars.find(c => c !== plat.default) || plat.chars[0];
    const act = await win.eval("window.__qrInvoke('filterAction', " + JSON.stringify({
      source: Object.assign({}, src, { __variables: authVars, __loginInfo: {} }),
      action: plat.action, title: plat.title, value: target,
      cookieSnapshot: {},
    }) + ")");
    const dirty = (act && act.__sourceVars) || '';
    ok(act && act.ok, '站方 action 跑通了', act && act.error);
    ok(dirty.indexOf('"src":"' + target + '"') >= 0,
       '**站方把选中的平台写进了源级变量**（src=' + target + '）', '实际 ' + dirty.slice(0, 200));

    // 端到端：把落盘的变量喂回去 ⇒ 站方重跑后**分类应该按新平台变了**
    //
    // ⚠️ 不能断言「站方给的 default 变了」—— 站方（🍒NovelHub）的 default 恒为
    //    `nhPlatChars()[0]`（第一个），**不是当前值** ⇒ 拿它当判据必假红
    //    （胶囊上的当前值由宿主自己记，见 SourceVariables.filterChoice）
    const merged = JSON.stringify(Object.assign({}, JSON.parse(authVars), JSON.parse(dirty || '{}')));
    const ex2 = await win.eval("window.__qrInvoke('exploreKinds', " + JSON.stringify({
      source: Object.assign({}, src, { __variables: merged, __loginInfo: {} }),
      cookieSnapshot: {},
    }) + ")");
    const before = ((ex && ex.kinds) || []).map(k => k.title).join('|');
    const after = ((ex2 && ex2.kinds) || []).map(k => k.title).join('|');
    ok(after.length > 0, '切完平台后分类还在');
    ok(after !== before,
       '**切平台真的生效了**（站方按新平台返回了不同的分类）',
       '切前 ' + before.length + ' 字 / 切后 ' + after.length + ' 字');
    ok(((ex2 && ex2.kinds) || []).length > 0 &&
       ((ex2 && ex2.kinds) || []).length !== ((ex && ex.kinds) || []).length,
       '切前后的分类数量不一样（书旗 799 → 番茄 280 这种）');
  }
}

console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
