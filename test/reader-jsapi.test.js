/**
 * Swift → JS 调用名 **跨语言边界**门禁。
 *
 * 血的教训（两回）：
 *
 * ① ReaderHost.callJS 无条件调 `window.QiReader.<fn>`，
 *    而当时的分页模块挂在 `window.QiReaderPaginate` 上。
 *    于是 setPageTurn 发出去的是 `window.QiReader.enable(...)` ——
 *    undefined 不是函数 → 抛异常 → **分页从来没启用过**，
 *    界面表现就是"翻页那个就是摆设"，而且**不报任何错**。
 *
 * ② 后来分页改成原生（CoreText），CSS 多列那套整个删掉了。
 *    这个门禁要保证：Swift 调用的每一个 JS 方法，在 reader.js 里都得真的存在。
 *
 * 之前所有门禁都只测 JS 内部或 Swift 内部，从来没把两边对过表。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, l, e) => { if (c) { pass++; console.log(`  ✓ ${l}`); } else { fail++; console.log(`  ✗ ${l}${e ? '  → ' + e : ''}`); } };

const readerJs = fs.readFileSync(path.join(ROOT, 'Resources/reader/reader.js'), 'utf8');
const host     = fs.readFileSync(path.join(ROOT, 'Core/ReaderHost.swift'), 'utf8');

/** 从 `window.X = { ... }` 里抽出**顶层**方法名。
 *  必须括号深度感知：不然函数体里的 if / catch / String 全被当成方法名。
 *  最后一个方法常常没有尾逗号，也要能取到。
 */
function apiOf(src, objName) {
  const i = src.indexOf(`window.${objName} = {`);
  if (i < 0) return null;
  const open = src.indexOf('{', i);
  let depth = 0, end = -1;
  for (let k = open; k < src.length; k++) {
    const c = src[k];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { end = k; break; } }
  }
  if (end < 0) return null;
  const body = src.slice(open + 1, end);
  const names = new Set();
  let d = 0, i2 = 0;
  while (i2 < body.length) {
    const c = body[i2];
    if (c === '{' || c === '(' || c === '[') { d++; i2++; continue; }
    if (c === '}' || c === ')' || c === ']') { d--; i2++; continue; }
    if (d === 0) {
      const m = /^([A-Za-z_$][\w$]*)\s*(:|,|$)/.exec(body.slice(i2));
      if (m) {
        names.add(m[1]);
        i2 += m[0].length;
        continue;
      }
    }
    i2++;
  }
  for (const kw of ['if', 'for', 'while', 'return', 'function', 'catch', 'var', 'let', 'const', 'new', 'typeof', 'else', 'try']) names.delete(kw);
  return names;
}

console.log('\n── reader.js 暴露的 API ──');
const qiReader = apiOf(readerJs, 'QiReader');
ok(qiReader && qiReader.size > 0, `window.QiReader: ${qiReader ? [...qiReader].join(', ') : '没找到'}`);

console.log('\n── 没有第二个 JS 模块了（分页改原生）──');
ok(!fs.existsSync(path.join(ROOT, 'Resources/reader/reader-paginate.js')),
   'reader-paginate.js 已删（CSS 多列那套不要了）');
ok(!/QiReaderPaginate/.test(host), 'ReaderHost 里没有 QiReaderPaginate 的残留');
ok(!/installPaginate|callPaginateJS/.test(host), '没有残留的注入/调用');

console.log('\n── 每个 callJS 的方法名，window.QiReader 里必须真的存在 ──');
const called = [...host.matchAll(/callJS\(\s*"(\w+)"/g)].map(x => x[1]);
ok(called.length > 0, `Swift 侧一共调了 ${called.length} 个 JS 方法`);
for (const m of new Set(called)) {
  ok(qiReader && qiReader.has(m), `QiReader.${m} 存在`, `实际有: ${qiReader ? [...qiReader].join(', ') : '?'}`);
}

console.log('\n── 关键方法不能缺席 ──');
for (const m of ['applySettings', 'setInitial', 'upsertChapter', 'refreshChapters', 'markChapterRequestFinished']) {
  ok(qiReader && qiReader.has(m), `主模块提供 ${m}`);
}

console.log('\n── 踩过的坑不能再踩 ──');
ok(!/window\.QiReader\.enable/.test(host), '别再把分页方法打到 window.QiReader 上');
ok(/window\.QiReader && window\.QiReader\./.test(host), 'callJS 打的还是 window.QiReader');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
