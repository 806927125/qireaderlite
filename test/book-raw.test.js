#!/usr/bin/env node
/**
 * **书对象必须带【列表项的原始字段】**（2026-10-22 真机「详情页和目录都出不来」）
 *
 * 跑法：node test/book-raw.test.js
 *
 * ────────────────────────────────────────────────────────────
 * **真机日志**：
 * ```
 * [详情] https://v5.langge.uk/detail?book_id=undefined&source=undefined&tab=小说&...
 * [最后响应] 状态=200 开头={"code":-1,"msg":"illegal base64 data at input byte 9",...}
 * [data:载荷] 解出来 = {"tab":"小说","url":""}
 * ```
 * ⇒ 站方 jsLib 生成 `data:;base64,<载荷>` 时要读 **book.book_id** 之类
 * ⇒ 宿主原先只把 name/author/… 九个字段送给站方 ⇒ **book_id 压根没传过去**
 * ⇒ 载荷只有 `{tab,url}` ⇒ 详情/目录请求全是 **book_id=undefined**
 * ⇒ 服务器解 undefined 失败 ⇒ 回「illegal base64 data at input byte 9」⇒ 整本书崩 ⭐
 *
 * ⇒ **修法**：列表项的原始 item 字段一路带到站方（引擎 JSON 路径 + Swift 的 BookDTO/Book/rawJSON）
 *
 * 另外这一门禁还钉住 **base64 解码必须按 UTF-8**（我自己引入过的回归）：
 *   `atob` 返回的是 **Latin-1** ⇒ 直接返回就是「小说」变「å°è¯´」⭐
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-26 门禁迁移**（老 JS 引擎物理删除 ⇒ 改跑新引擎）
 *
 * · 以前：jsdom 里跑老引擎（`Resources/engine/*.js`）⇒ 已删 ⇒ 门禁的对象没了。
 * · 现在：**直接调新引擎**（`legado-engine --op explore` / `--js`）⇒ 验的是**真在跑的那份代码**。
 * · 假服务器：老的 JS 层 `nativeMock` 作废 ⇒ 改**声明式 `routes`**（列表页走路由 ⇒ 全程离线）。
 */
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { engineSwiftSrc } = require('./engine-gate-helpers');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓ ' + m); }
  else { fail++; console.log('  x ' + m + (extra ? ' — ' + extra : '')); }
};

// ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
//   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段** ⇒ 那是**实现细节**，不是语义
//   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
//   ⇒ **语义覆盖在下面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
//   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐

(async () => {
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log('\n⏭️ 通过 0 / 失败 0（环境跳过）');
    process.exit(0);
  }

  // ⭐⭐⭐ **假服务器 = 声明式 routes**（老写法的 JS 层 nativeMock 已作废）
  const { win } = createSandbox({
    routes: [{
      match: 'fake.example.com', status: 200,
      body: JSON.stringify({
        data: [
          { book_id: 'MTgzNTEy', name: '武炼巅峰', author: '莫默', bookUrl: 'https://x.example/1' },
          { book_id: 'OTk5OTk5', name: '第二本', author: '作者乙', bookUrl: 'https://x.example/2' }
        ]
      })
    }],
  });

  console.log('=== 1. 活体（离线）：列表项的【原始字段】一路带着（站方要 book_id） ===');
  const src = {
    bookSourceUrl: 'https://fake.example.com/',
    bookSourceName: '假源',
    enabled: true,
    exploreUrl: 'https://fake.example.com/list',
    ruleExplore: {
      bookList: '$.data[*]',
      name: '$.name',
      author: '$.author',
      bookUrl: '$.bookUrl',
      // ⭐⭐⭐ **直接拿原始字段当书名字段** ⇒ 就能看出「原始字段还在不在」
      wordCount: '$.book_id'
    },
    ruleBookInfo: { name: '$.name', author: '$.author' }
  };

  {
    const ex = win.__qrInvoke('explore', {
      source: src, kindUrl: 'https://fake.example.com/list', page: 1,
    });
    const books = (ex && ex.books) || [];
    console.log('  出书 =', books.length, '| 第一本 =', JSON.stringify(books[0] || {}).slice(0, 160));
    if (ex && ex.error) console.log('  engine error:', ex.error);
    ok(books.length === 2, '出书 2 本');
    ok(!!(books[0] && books[0].name === '武炼巅峰'), '书名对', books[0] && books[0].name);
    // ⭐⭐⭐ **原始字段（book_id）还在** ⇒ 站方生成 data: 载荷时读得到
    ok(!!(books[0] && books[0].wordCount === 'MTgzNTEy'),
       '⭐⭐ **列表项的原始字段 book_id 还在**（站方生成 data: 载荷靠它）',
       books[0] && books[0].wordCount);
    ok(!!(books[1] && books[1].wordCount === 'OTk5OTk5'),
       '⭐⭐ 第二本的原始字段也在（**每项**都带着自己的原始字段）',
       books[1] && books[1].wordCount);
  }

  console.log('\n=== 2. 源码（新引擎）：原始字段 ⇒ Book.raw ⇒ 站方 JS 的 book.book_id ===');
  {
    // ⚠️ **新引擎的 `--op explore` 不输出 raw 字典** ⇒ 「原始字段进了站方的 book 对象」这条
    //   只能按【新引擎 Swift 源码】验（老门禁验的是老引擎 JS 源码 ⇒ 同一件事，换成新引擎的等价描述）⭐⭐⭐
    const listItem = engineSwiftSrc('Pipeline/ListItem.swift');
    const engineSrc = engineSwiftSrc('Pipeline/SourceEngine.swift');

    ok(/var\s+rawFields:\s*\[String:\s*String\]/.test(listItem),
       '⭐ 引擎的列表项带着**原始字段 rawFields**（JSON 项的所有键）');
    ok(/raw:\s*item\.rawFields/.test(engineSrc),
       '⭐⭐ 列表项的原始字段进了 **Book.raw**（书对象带着它一路走）');
    ok(/for\s*\(k,\s*v\)\s*in\s+book\.raw\s*\{\s*properties\[k\]\s*=\s*\.string\(v\)/.test(engineSrc),
       '⭐⭐⭐ **原始字段挂上了站方的 book 对象**（站方 JS 读 `book.book_id` 读得到）');
    // ⭐ 等价覆盖：引擎仓 `Tests/LegadoCoreTests/JsonSourceSupportTests.swift`
    //   （原始字段保留 + 挂到 book 对象）+ App 侧 `test/engine-backend-test.swift` ③（宿主把 raw 带走）⭐⭐⭐
  }

  console.log('\n=== 3. 活体（离线）：base64 解码必须按 UTF-8（不能是 Latin-1） ===');
  {
    // 「小说」⇒ base64 ⇒ 解出来必须还是「小说」，不是「å°è¯´」
    const b64 = Buffer.from(JSON.stringify({ tab: '小说', url: '' }), 'utf8').toString('base64');
    const out = win.eval("java.hexDecodeToString('" + b64 + "')");
    console.log('  解出来 =', JSON.stringify(String(out)).slice(0, 120));
    ok(String(out).indexOf('小说') >= 0,
       '**中文按 UTF-8 解对了**（atob 返回 Latin-1 ⇒ 会变成「å°è¯´」）',
       JSON.stringify(String(out)).slice(0, 120));
    ok(String(out).indexOf('å°') < 0, '没有出现 Latin-1 乱码');
  }

  console.log('\n=== 4. 活体（离线）：解不了 base64 ⇒ 明确失败（空串），不能解出乱码 ===');
  {
    // ⚠️⚠️ 以前非法字符被 `manualB64ToBytes` **静默跳过** ⇒ 返回**乱码**
    //   ⇒ 站方 `JSON.parse(java.hexDecodeToString(result))` 拿到乱码 ⇒ 炸
    //   ⇒ 🍅大灰狼**目录 0 章** ⭐
    //   ⇒ 现在：不是合法 base64 ⇒ 明确失败（空串）⇒ 上层改走 hex 分支 ✅
    const bad = win.eval("java.hexDecodeToString('这不是base64!!!')");
    console.log('  非法 base64 解出 =', JSON.stringify(String(bad)).slice(0, 60));
    ok(typeof bad === 'string' && bad.length < 20,
       '**非法 base64 解出的是空/极短串**（不是乱码）',
       '实际 ' + JSON.stringify(String(bad)).slice(0, 60));

    const hex = Buffer.from('{"a":1}', 'utf8').toString('hex');
    const good = win.eval("java.hexDecodeToString('" + hex + "')");
    ok(String(good).indexOf('{"a":1}') >= 0,
       '合法 hex 仍能正确解出原文（别把好路也堵了）',
       '实际 ' + JSON.stringify(String(good)).slice(0, 60));
    // ⚠️ **hex 路径的沙盒/真机差异**（已上报）：沙盒的 Node 后端把 hex 路径实现成了 **Latin-1**
    //   ⇒ **非 ASCII** 的 hex 载荷在沙盒里会乱码（真机 JSC 走引擎 `Crypto` ⇒ UTF-8 ⇒ 正常）
    //   ⇒ 所以这里只用 **ASCII** 载荷验「别把好路堵了」（两边语义一致 ⇒ 门禁不假红）⭐⭐⭐
  }

  console.log('\n' + (fail === 0 ? '✅' : '❌') + ' 通过 ' + pass + ' / 失败 ' + fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
