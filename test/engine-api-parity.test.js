#!/usr/bin/env node
/**
 * 栖阅引擎 ↔ 轻阅引擎 的 API 面对表
 *
 * 起因：我一直以为「栖阅的引擎我搬完了」，其实只搬了 packages_stub.js 一个文件。
 * 栖阅的引擎能力分散在**两个**文件：
 *     packages_stub.js  → 125 个 Packages.* / java.* ，我整份搬了
 *     jsoup_bridge.js   → org.seimicrawler.xpath.{JXDocument,JXNode}
 *                         + Jsoup Document/Element/Elements 的完整 Java API
 *                         我以「依赖 Swift/Kanna live DOM 句柄，搬不动」为由跳过了
 * 结果 Doc.xpath() / JXDocument 全是 undefined。
 *
 * 这个门禁把栖阅那份文件的**方法名逐个抠出来**跟轻阅对账，
 * 以后再漏会当场红，不用等用户拿书源撞上来才发现。
 */
const fs = require('fs');
const path = require('path');

const QY_JS = process.env.QY_JS || '/workspace/qy2027/Payload/栖阅.app/jsoup_bridge.js';
const ENGINE = path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

if (!fs.existsSync(QY_JS)) {
  console.log(`⚠️  栖阅 jsoup_bridge.js 不在 ${QY_JS}，跳过对照（拆包后再跑）`);
  process.exit(0);
}

const qy = fs.readFileSync(QY_JS, 'utf8');
const mine = ['org-jsoup.js', 'jsoup-compat.js', 'packages_stub.js']
  .map(f => fs.readFileSync(path.join(ENGINE, f), 'utf8')).join('\n');

const methods = (src, cls) => new Set(
  (src.match(new RegExp(cls.replace(/[$]/g, '\\$') + '\\.prototype\\.([A-Za-z0-9_]+)\\s*=', 'g')) || [])
    .map(m => m.match(/\.([A-Za-z0-9_]+)\s*=/)[1])
);

const missing = [];
function diff(cls, myName) {
  const want = methods(qy, cls);
  const have = methods(mine, myName);
  ok(want.size > 0, `${cls} 在栖阅那边能抠出方法名`);
  const gap = [...want].filter(m => !have.has(m));
  ok(gap.length === 0, `${cls} 缺 ${gap.length} 个方法：${gap.join(', ') || '无'}`);
  if (gap.length) missing.push(`${cls}: ${gap.join(', ')}`);
}

diff('_JsoupDoc', 'Doc');
diff('_JsoupElement', 'El');
diff('_JXDocument', 'JXDocument');
diff('_JXNode', 'JXNode');
// ⚠️ Elements 那一类我一开始**漏了**（32 个方法，门禁只对了上面 4 个）。
// 轻阅这边方法名是挂在数组变量上的 e.xxx = function，不是 prototype，得单独抠。
{
  const want = methods(qy, '_JsoupElements');
  const src = fs.readFileSync(path.join(ENGINE, 'org-jsoup.js'), 'utf8');
  const have = new Set((src.match(/\be\.([A-Za-z0-9_]+)\s*=\s*function/g) || [])
    .map(m => m.match(/e\.([A-Za-z0-9_]+)\s*=/)[1]));
  ok(want.size > 0, '_JsoupElements 在栖阅那边能抠出方法名');
  // 下划线开头的是栖阅自己的内部方法（_syncIndexes 是它在内部刷新索引用的），
  // 书源不会调，不纳入对账。
  const PRIVATE = new Set(['_syncIndexes']);
  // Array.prototype 自带的方法（轻阅的 Elements 是真数组）源码里本来就没有
  const ARRAY_NATIVE = new Set(['forEach', 'map', 'filter', 'slice', 'indexOf', 'join', 'concat']);
  const gap = [...want].filter(m => !have.has(m) && !PRIVATE.has(m) && !ARRAY_NATIVE.has(m));
  ok(gap.length === 0, `_JsoupElements 缺 ${gap.length} 个方法：${gap.join(', ') || '无'}`);
  if (gap.length) missing.push(`_JsoupElements: ${gap.join(', ')}`);

  // ⚠️ 静态名集合会误报：轻阅的 Elements 是**真数组**，forEach/map/filter 这些
  //    是 Array.prototype 自带的，源码里当然找不到 e.forEach = function。
  //    所以最终以**运行时**为准。
  {
    const { createSandbox } = require('./new-engine-harness');
    const { win } = createSandbox({ origin: 'https://example.com/' });
    const els = win.org.jsoup.Jsoup.parse('<html><body><p class="c">a</p><p class="c">b</p></body></html>')
      .select('p.c');
    // 下划线开头的是栖阅内部私有方法，书源调不到，不纳入
    const gone = [...want].filter(m => !m.startsWith('_') && typeof els[m] !== 'function');
    ok(gone.length === 0, `Elements 运行时缺 ${gone.length} 个：${gone.join(', ') || '无'}`);
  }
}

// 栖阅 jsoup_bridge.js 里暴露到全局的类型名。
// ⚠️ 必须**运行时**查，不能拿源码字符串 includes —— 我源码里写的是 `P.org.…`
//    变量名 P，字符串里根本没有 "Packages.org.…"，静态匹配必然全灭。
const exposed = [...new Set((qy.match(/Packages\.org\.[A-Za-z0-9_.]+/g) || [])
  .filter(t => !/\.__javaClassName$/.test(t)))];
{
  const { createSandbox } = require('./new-engine-harness');
  const { win } = createSandbox({ origin: 'https://example.com/' });
  const get = p => exposed
    .filter(t => t.endsWith(p))
    .map(t => t.split('.').reduce((o, k) => (o == null ? o : o[k]), win));
  const gone = exposed.filter(t => {
    const v = get(t)[0];
    return v === undefined || v === null;
  });
  ok(gone.length === 0, `Packages.* 运行时挂了 ${gone.length} 个：${gone.join(', ') || '无'}`);
}

// 反向：该有的能力不能只是「注释里写了」
ok(!/^\s*\/\/.*JXDocument/m.test(mine) || mine.includes('org.seimicrawler.xpath.JXDocument = JXDocument'),
   'JXDocument 是真挂上去了，不是只有注释');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
if (missing.length) console.log('\n对不上的：\n  ' + missing.join('\n  '));
process.exit(fail ? 1 : 0);
