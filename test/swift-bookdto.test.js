/**
 * BookDTO 字段对齐门禁（纯静态检查，不跑 Swift）。
 *
 * 背景（2026-10-18）：引擎 bookInfo 明明返回了 tocUrl，Swift 的
 * `BookDTO` 结构体里却**根本没声明这个字段**，解码时直接丢掉，
 * toBook 再硬传 `tocUrl: ""` → 每本书 tocUrl 都是空 → 目录退回
 * 书籍页 → chapterList 打不中 → 0 章，且全程不报错。
 *
 * 沙盒那 38 项门禁全都直接调 `__qrInvoke`，**不经过 Swift 解码**，
 * 所以这个 bug 门禁一个都抓不到。只能静态比对字段。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

const svc = fs.readFileSync(path.join(ROOT, 'Core/SourceService.swift'), 'utf8');
const bsw = fs.readFileSync(path.join(ROOT, 'Core/BookSource.swift'), 'utf8');

// ⭐⭐⭐⭐⭐ **引擎 bookInfo 实际会返回哪些 key** —— 现在读【新引擎】（老 JS 引擎已物理删除）
//   ⇒ 新引擎的 `BookInfo` 字段（Swift）⇒ **验的是真正在跑的那份**⭐⭐⭐
const { engineSwiftSrc } = require('./engine-gate-helpers.js');
const engineInfoSrc = engineSwiftSrc('Pipeline/Models.swift');
const engineBiBlock = /public struct BookInfo[\s\S]*?public init\(/.exec(engineInfoSrc);
const engineKeys = (engineBiBlock ? (engineBiBlock[0].match(/public var (\w+):/g) || []) : [])
  .map(s => s.replace('public var ', '').replace(':', ''));

console.log('\n── 引擎 bookInfo 返回的字段 ──');
console.log('  ' + engineKeys.join(', '));

console.log('\n── BookDTO 必须声明这些字段（否则 Swift 解码会丢）──');
const dtoBlock = /struct BookDTO: Codable \{([\s\S]*?)\n    \}/.exec(svc);
ok(!!dtoBlock, '能定位到 BookDTO 结构体');
const dto = dtoBlock ? dtoBlock[1] : '';
for (const k of engineKeys) {
  // ⭐⭐⭐ `sourceName` 不在 BookDTO 里（它在 `Book` 上 ⇒ 由 `toBook` 单独填）
  //   ⇒ 引擎多返回的字段**不该**逼着 DTO 声明（否则「少字段」就会炸）⭐⭐⭐
  if (k === 'sourceName') {
    const bk = fs.readFileSync(path.join(ROOT, 'Core/Book.swift'), 'utf8');
    ok(/var sourceName: String/.test(bk), 'sourceName 在 Book 上（不在 BookDTO）');
    continue;
  }
  ok(new RegExp(`var ${k}\\s*:`).test(dto), `BookDTO 声明了 ${k}`);
}

console.log('\n── toBook 必须把 tocUrl 透传出去 ──');
const toBook = /func toBook\([\s\S]*?detailLoaded: false\)/.exec(svc);
ok(!!toBook, '能定位到 toBook');
ok(!!toBook && /tocUrl:\s*tocUrl/.test(toBook[0]),
   'toBook 传的是 tocUrl 而不是硬编码空串',
   toBook ? (toBook[0].match(/tocUrl:[^\n]*/) || [''])[0] : '');
ok(!!toBook && !/tocUrl:\s*""/.test(toBook[0]), 'toBook 里没有 tocUrl: "" 这种硬编码');

console.log('\n── ruleBookInfo.init 必须在 Swift 模型里（属性名避开保留字 init）──');
const biBlock = /struct BookInfoRule: Codable[\s\S]*?\n\}/.exec(bsw);
ok(!!biBlock && /var initRule:/.test(biBlock[0]), 'BookInfoRule 有 initRule 属性（不能叫 init）');
ok(!!biBlock && /case initRule = "init"/.test(biBlock[0]),
   'CodingKeys 把 initRule 映射回 JSON 键 "init"（引擎才认得）');

console.log('\n── BookInfoRule 的字段也要跟引擎对齐 ──');
const biKeys = ['name', 'author', 'intro', 'kind', 'lastChapter', 'coverUrl', 'tocUrl', 'wordCount'];
for (const k of biKeys) {
  ok(!!biBlock && new RegExp(`var ${k}\\s*:`).test(biBlock[0]), `BookInfoRule 声明了 ${k}`);
}

console.log('\n── 书单必须能扛住「少字段 / null」（build 20 回归）──');
ok(/decodeIfPresent\(String\.self, forKey: k\)/.test(dto),
   'BookDTO 逐列 decodeIfPresent（不依赖编译器合成的默认行为）');
ok(/tocUrl = g\(\.tocUrl\)/.test(dto), 'tocUrl 也走 decodeIfPresent（列表书没这列不会炸）');
const listBlock = /struct BookListDTO: Codable \{([\s\S]*?)\n    \}/.exec(svc);
ok(!!listBlock, '能定位到 BookListDTO');
ok(/static func lenient\(/.test(svc),
   'BookListDTO 有 lenient()：单本书解不出来只跳过它，不让整页书单消失');
ok(/for item in arr/.test(svc) && /continue/.test(svc), 'lenient 逐本单独解并跳过坏数据');
ok(/case \.keyNotFound/.test(svc) && /codingPath/.test(svc),
   '解码报错带上出错字段路径（下一轮不用再猜）');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
