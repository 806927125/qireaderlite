// 用 JS 原版（reader-scroll-core.js）跑一批用例，输出**期望值**。
// Swift 侧（ReaderScrollCore.swift）读同一份用例跑，逐条比对。
//
// 目的：Swift 翻译版必须跟 JS 原版**行为一致**。
//
// ⚠️ reader-scroll-core.js 是「与栖阅逐字节一致」的四件套之一，**不能改**。
//    所以这里只用它**导出的 5 个函数**；内部那几个
//    （finiteNumber / oppositeSide / directionPreferredRemovalSide /
//      distancePreferredRemovalSide）通过 chooseTrim 的行为**间接覆盖**。
//
// 用法：
//   node test/scroll-core-cases.js --emit  > test/fixtures/scroll-core-cases.json
//   node test/scroll-core-parity.test.js
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const CORE = require(path.join(ROOT, 'QiReaderLite/Resources/reader/reader-scroll-core.js'));

// ── 用例集（两边共用同一份输入）──
const CASES = [
  { name: 'chooseTrim: first=null → last', fn: 'chooseTrim',
    args: [null, 9, 4, null] },
  { name: 'chooseTrim: last=null → last',  fn: 'chooseTrim',
    args: [0, null, 4, null] },
  { name: 'chooseTrim: append → first',    fn: 'chooseTrim',
    args: [0, 9, 4, 'append'] },
  { name: 'chooseTrim: prepend → last',    fn: 'chooseTrim',
    args: [0, 9, 4, 'prepend'] },
  { name: 'chooseTrim: 未知 mode → 按距离', fn: 'chooseTrim',
    args: [0, 9, 4, 'weird'] },
  { name: 'chooseTrim: anchor==first → 翻转', fn: 'chooseTrim',
    args: [0, 9, 0, 'append'] },
  { name: 'chooseTrim: anchor==last → 翻转',  fn: 'chooseTrim',
    args: [0, 9, 9, 'append'] },
  { name: 'chooseTrim: 距离相等取 first',   fn: 'chooseTrim',
    args: [0, 8, 4, null] },
  { name: 'chooseTrim: 距离相等(append)',    fn: 'chooseTrim',
    args: [0, 8, 4, 'append'] },
  { name: 'chooseTrim: 靠近 last',          fn: 'chooseTrim',
    args: [0, 8, 7, null] },
  { name: 'chooseTrim: 负数坐标',           fn: 'chooseTrim',
    args: [-5, 3, -1, null] },
  // ⚠️ JS 的 Number(null) === 0 —— anchor 传 null 等价于 anchor=0，
  //    **不是**「无 anchor」。这几条专门钉死这个语义。
  { name: 'chooseTrim: anchor=null ≡ anchor=0', fn: 'chooseTrim',
    args: [0, 9, null, 'append'] },
  { name: 'chooseTrim: anchor=null 且 first=0 → 翻转', fn: 'chooseTrim',
    args: [0, 9, null, null] },
  { name: 'chooseTrim: 空串 first ≡ 0',     fn: 'chooseTrim',
    args: ['', 9, 4, null] },

  { name: 'trimWindow: 超限裁两端',        fn: 'trimWindow',
    args: [[1,2,3,4,5], 3, 3, 'append'] },
  { name: 'trimWindow: 不超限原样',        fn: 'trimWindow',
    args: [[1,2], 5, 1, null] },
  { name: 'trimWindow: limit=0 全清',      fn: 'trimWindow',
    args: [[1,2,3], 0, 2, null] },
  { name: 'trimWindow: prepend 方向',       fn: 'trimWindow',
    args: [[1,2,3,4,5], 3, 1, 'prepend'] },
  { name: 'trimWindow: anchor 保持',        fn: 'trimWindow',
    args: [[1,2,3,4,5], 3, 2, 'append'] },
  { name: 'trimWindow: 单章',               fn: 'trimWindow',
    args: [[7], 3, 7, null] },
  { name: 'trimWindow: 空数组',             fn: 'trimWindow',
    args: [[], 3, 0, null] },

  { name: 'shouldReport: includeProgress=false', fn: 'shouldReport',
    args: [false, false, false, 0, 1000] },
  { name: 'shouldReport: chapterChanged',        fn: 'shouldReport',
    args: [true, true, false, 1000, 1010] },
  { name: 'shouldReport: force',                fn: 'shouldReport',
    args: [true, false, true, 1000, 1010] },
  { name: 'shouldReport: 首次(last=0)',         fn: 'shouldReport',
    args: [true, false, false, 0, 1000] },
  { name: 'shouldReport: 节流内(差200<260)',    fn: 'shouldReport',
    args: [true, false, false, 1000, 1200] },
  { name: 'shouldReport: 节流外(差300>260)',    fn: 'shouldReport',
    args: [true, false, false, 1000, 1300] },
  { name: 'shouldReport: 差260 严格大于→false', fn: 'shouldReport',
    args: [true, false, false, 1000, 1260] },
  { name: 'shouldReport: 差261 → true',        fn: 'shouldReport',
    args: [true, false, false, 1000, 1261] },
  { name: 'shouldReport: last 负数',            fn: 'shouldReport',
    args: [true, false, false, -5, 1000] },

  { name: 'viewport: 全 null',                 fn: 'viewport', args: [null, null, null] },
  { name: 'viewport: anchor null',             fn: 'viewport', args: [null, 130, 500] },
  { name: 'viewport: 正常',                    fn: 'viewport', args: [100, 130, 500] },
  { name: 'viewport: 差 0.5 恰好 → restore',   fn: 'viewport', args: [100, 100.5, 500] },
  { name: 'viewport: 差 0.4 → 不 restore',     fn: 'viewport', args: [100, 100.4, 500] },
  { name: 'viewport: 负偏移',                  fn: 'viewport', args: [100, 80, 500] },
  { name: 'viewport: scroll null',             fn: 'viewport', args: [100, 130, null] },
  // ⚠️ Number(null) === 0 → scroll=null 等价于 scroll=0
  { name: 'viewport: anchor null ≡ 0',        fn: 'viewport', args: [null, 130, 500] },
  { name: 'viewport: scroll null ≡ 0',        fn: 'viewport', args: [100, 130, null] },

  { name: 'titleHeight: null → 0',            fn: 'titleHeight', args: [null] },
  { name: 'titleHeight: 负 → 0',              fn: 'titleHeight', args: [-5] },
  { name: 'titleHeight: 0 → 0',               fn: 'titleHeight', args: [0] },
  { name: 'titleHeight: 正常',                fn: 'titleHeight', args: [42.5] },
];

function runJS(c) {
  switch (c.fn) {
    case 'chooseTrim':
      return CORE.chooseTrimRemovalSide({
        firstIndex: c.args[0], lastIndex: c.args[1],
        anchorIndex: c.args[2], mode: c.args[3],
      });
    case 'trimWindow': {
      const r = CORE.trimChapterWindow(c.args[0], c.args[1], c.args[2], c.args[3]);
      return { kept: r.kept, removed: r.removed };
    }
    case 'shouldReport':
      return CORE.shouldReportProgress({
        includeProgress: c.args[0], chapterChanged: c.args[1], force: c.args[2],
        lastProgressAt: c.args[3], now: c.args[4],
      });
    case 'viewport': {
      const r = CORE.viewportAnchorAdjustment({
        anchorTop: c.args[0], currentTop: c.args[1], scrollTop: c.args[2],
      });
      return { delta: r.delta, targetScrollTop: r.targetScrollTop, shouldRestore: r.shouldRestore };
    }
    case 'titleHeight':
      return CORE.normalizedTitleHeight(c.args[0]);
    default: throw new Error('未知用例函数: ' + c.fn);
  }
}

const out = CASES.map(c => ({
  name: c.name,
  fn: c.fn,
  args: c.args,
  expected: runJS(c),
}));

if (process.argv[2] === '--emit') {
  process.stdout.write(JSON.stringify(out, null, 2));
} else {
  let bad = 0;
  for (const c of out) {
    const got = runJS(c);
    const a = JSON.stringify(got), b = JSON.stringify(c.expected);
    if (a !== b) { bad++; console.log('✗', c.name, 'got', a, 'want', b); }
  }
  console.log(bad === 0 ? `✅ JS 原版自检 ${out.length} 条全过` : `❌ ${bad} 条不一致`);
  process.exit(bad === 0 ? 0 : 1);
}
