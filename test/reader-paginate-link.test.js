/**
 * 分页 ↔ 原生 的**链路**门禁。
 *
 * 上一版栽在这：JS 里定义了 onPage / onEdge 回调，但 Swift 侧收消息是单向的，
 * 没法反过来调 JS 的 setter —— 回调**永远不触发**，
 * 于是「翻到章尾接下一章」整条链是死的，页码也永远不更新。
 * 而且二进制里搜不到 'paginatePage' 才发现。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
const ok = (c, l, e) => { if (c) { pass++; console.log(`  ✓ ${l}`); } else { fail++; console.log(`  ✗ ${l}${e ? '  → ' + e : ''}`); } };

const js   = fs.readFileSync(path.join(ROOT, 'Resources/reader/reader-paginate.js'), 'utf8');
const host = fs.readFileSync(path.join(ROOT, 'Core/ReaderHost.swift'), 'utf8');
const sess = fs.readFileSync(path.join(ROOT, 'Core/ReaderSession.swift'), 'utf8');
const web  = fs.readFileSync(path.join(ROOT, 'Features/Reader/ReaderWebView.swift'), 'utf8');

console.log('\n── JS 侧：必须主动 post（不能只留回调）──');
ok(/post\('paginatePage',\s*\{ page: p, count: state\.pageCount \}\)/.test(js),
   '翻页时 post paginatePage（页码/总页数）');
ok(/post\('paginateEdge',\s*\{ direction: -1, edge: 'head' \}\)/.test(js),
   '章首越界 post paginateEdge(head)');
ok(/post\('paginateEdge',\s*\{ direction: 1, edge: 'tail' \}\)/.test(js),
   '章尾越界 post paginateEdge(tail)');
ok(/post\('paginateFail'/.test(js), '分页失败 post paginateFail（要能退回滚动）');
ok(/post\('paginateReady'/.test(js), '注入完 post paginateReady');

console.log('\n── Swift 侧：三个消息都要处理 ──');
ok(/case "paginateReady"/.test(host), '处理 paginateReady');
ok(/case "paginatePage"/.test(host), '处理 paginatePage');
ok(/case "paginateEdge"/.test(host), '处理 paginateEdge');
ok(/case "paginateFail"/.test(host), '处理 paginateFail');
ok(/var onPaginateEdge: \(\(Int\) -> Void\)?/.test(host), '有 onPaginateEdge 回调');
ok(/var onPaginateFail: \(\(String\) -> Void\)?/.test(host), '有 onPaginateFail 回调');

console.log('\n── 接章：边缘事件要真的去切章 ──');
ok(/onPaginateEdge = \{ dir in\s*\n\s*session\.step\(dir\)/.test(web),
   'onPaginateEdge → session.step(dir)');
ok(/onPaginateFail = \{ reason in[\s\S]{0,200}?pageTurn = false/.test(web),
   '分页失败 → 关掉分页（退回上下滚动）');
ok(/onPaginateFail = \{ reason in[\s\S]{0,300}?edgeToast/.test(web),
   '分页失败要给用户一句提示，不是静默');

console.log('\n── 换章后要重排 ──');
ok(/var onChapterChanged: \(\(Int\) -> Void\)?/.test(sess), 'ReaderSession 有 onChapterChanged');
ok(/self\.onChapterChanged\?\(i\)/.test(sess), 'visibleChapter 时触发 onChapterChanged');
ok(/session\.onChapterChanged = \{ _ in repaginate\(\) \}/.test(web), 'ReaderWebView 接上 → repaginate()');
ok(/func repaginate\(\)[\s\S]{0,300}?refreshPageTurn/.test(web), 'repaginate 真的会重排');
ok(/func refreshPageTurn\(chapterIndex: Int\)/.test(host), 'ReaderHost 有 refreshPageTurn');

console.log('\n── 踩过的坑不能再踩 ──');
// step() 里立刻重排是错的：正文异步加载，那时 DOM 还没新章
ok(!/session\.step\(-1\); repaginate\(\)/.test(web) && !/session\.step\(1\); repaginate\(\)/.test(web),
   '不再在 step() 里立刻 repaginate（正文还没加载完）');
// 页数必须是 ceil
ok(/Math\.ceil\(totalW \/ m\.pageW - 0\.01\)/.test(js), '页数用 ceil（round 会吃掉最后一页）');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
