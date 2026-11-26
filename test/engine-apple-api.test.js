// 门禁：⭐⭐⭐⭐⭐ **Apple-only 文件里的「平台 API 陷阱」静态兜底**（2026-11-19 CI build296/457/460 实证）
//
// 跑法：node test/engine-apple-api.test.js
//
// ⚠️ **为什么必须有这条门禁**：
//   柴阅的 `LegadoEngine/Sources/ChaiyueEngine/` 里有一部分代码**只在 Apple 平台编译**
//   （`#if canImport(JavaScriptCore) && !os(Linux)`）
//   ⇒ ⇒ **沙盒 Linux 门禁永远绿** ⇒ 这类错**只有 CI 能暴露** ⇒ 每次 4~5 分钟一轮 ⭐⭐⭐
//   ⇒ 必须有静态门禁提前抓 ⭐⭐⭐
//
// ⚠️⚠️⚠️ **这条门禁自己踩过的坑（2026-11-19 实证 ⇒ 别再犯）**：
//   ① 上一版门禁**断言了三条错误结论**（禁 `ccPKCS7Padding` / 断言 CCCryptorCreateWithMode 是 11 个参数
//      / 要求「Compression 直接传 UInt32 数值不包类型」）⇒ 于是**门禁一直绿、CI 一直红**⭐⭐⭐
//      ⇒ **门禁绿 ≠ 代码对** ⇒ 门禁的结论必须来自【CI 的编译器亲口说的】，不能来自推测 ⭐⭐⭐
//   ② **探针输出要看全**：上一轮探针有 4 行报错，只看了前 3 行就断言「ccNoPadding 不存在」
//      ⇒ 其实第 14 行 `CCPadding(ccNoPadding)` **根本没报错** ⇒ 名字一直都在 ⭐⭐⭐
//
// 本门禁抓的**已实证**陷阱（每条都有 CI 编译器报错作证）：
//   ① `COMPRESSION_*` 裸常量 —— Apple 上不在作用域 ⇒ 一律走 `rawValue:` 通道
//   ② Compression 枚举的 **rawValue 是 UInt32** ⇒ `Int32(...)` 编不过
//   ③ `compression_stream` 是 C struct ⇒ Swift 导入成**成员构造器要 5 个参数** ⇒ **没有零参 init**
//      ⇒ 症状：编译器转挑 `compression_decode_buffer` 重载 ⇒ 报「missing arguments for parameters dst_ptr…」
//   ④ Compression 枚举**必须包成 `compression_*` 类型**传给 `compression_stream_init`
//      ⇒ 直接传 UInt32 ⇒ 类型不匹配 ⇒ 同样报那个误导性的错
//   ⑤ `COMPRESSION_ZLIB = 0x205`（不是 0！！）⇒ 写 0 会静默用错算法
//   ⑥ padding 的权威名是 `ccPKCS7Padding` / `ccNoPadding`（`kCCPaddingPKCS7` 这些**不存在**）
//   ⑦ `CCCryptorCreateWithMode` = **12 个参数**（Apple 官方 CommonCryptor.h）
//   ⑧ `Data.withUnsafeBytes` **有两个重载** ⇒ 闭包**必须显式标注参数类型**
//      ⇒ 否则报「generic parameter 'ContentType' could not be inferred」
//   ⑨ `.rsaEncryptionOAEP` —— SDK 里没有这个成员（只有 OAEPSHA1/SHA256/SHA384/SHA512）
//   ⑩ CommonCrypto 的 `kCC*` 常量是 `Int`（typedef 是 uint32_t）⇒ 必须显式转换
//   ⑪ `NSRegularExpression.stringByReplacingMatches` 的参数标签**两个平台不同** ⇒ 必须走统一封装 helper
//
// ⇒ 变异对照：把任一条改回原样 ⇒ **必须红**

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
// ⭐⭐⭐⭐⭐ **扫描目录改成【全部引擎源码】**（2026-11-21 移植柴阅）⭐⭐⭐
//   旧引擎的 `Sources/LegadoEngine` 已被柴阅的 `Sources/ChaiyueEngine` + `ChaiyueModels` 取代 ⭐⭐⭐
const SRC = path.join(ROOT, 'LegadoEngine', 'Sources');

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

/** ⭐⭐⭐⭐⭐ **剥注释再匹配**（2026-11-19 实证）
 *   ⇒ 注释里写「SDK 里**没有** `.rsaEncryptionOAEP`」不该被判成「用了这个成员」
 *   ⇒ 存在性/计数类断言**必须**对【剥注释后的代码】做 ⭐⭐⭐ */
function stripComments(code) {
  return code
    .replace(/\/\*[\s\S]*?\*\//g, ' ')        // 块注释
    .replace(/\/\/[^\n]*/g, ' ');                  // 行注释
}

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}
const files = walk(SRC, []);
const codeOf = new Map(files.map((f) => [f, fs.readFileSync(f, 'utf8')]));
// ⭐⭐⭐ **匹配一律用剥注释后的代码** ⭐⭐⭐
const codeNoC = new Map([...codeOf].map(([f, c]) => [f, stripComments(c)]));

/** ⭐ 提取某个函数调用的实参个数（按括号配平，忽略字符串里的括号） */
function callArgs(code, fnName) {
  const idx = code.indexOf(fnName + '(');
  if (idx < 0) return -1;
  const open = idx + fnName.length + 1;
  let depth = 1, i = open, args = 1, inStr = false;
  for (; i < code.length && depth > 0; i++) {
    const c = code[i];
    if (inStr) { if (c === '"') inStr = false; continue; }
    if (c === '"') { inStr = true; continue; }
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') { depth--; if (depth === 0) break; }
    else if (c === ',' && depth === 1) args++;
  }
  return args;
}

console.log('=== 0. 门禁不是空跑 ===');
const appleOnly = files.filter((f) => /canImport\(JavaScriptCore\)|canImport\(WebKit\)/.test(codeNoC.get(f)));
check(`有 Apple-only 文件（${appleOnly.length} 个）`, appleOnly.length > 0, '0 个 ⇒ 门禁失效');

// ─────────────────────────────────────────────────────────────
// ① Compression 框架：枚举走 rawValue 通道 + 必须包类型 + struct init
// ─────────────────────────────────────────────────────────────
console.log('\n=== 1. Compression 框架（Apple 的真实形状）===');
for (const [f, code] of codeNoC) {
  const bare = [...code.matchAll(/\bCOMPRESSION_[A-Z_0-9]+\b/g)].map((m) => m[0]);
  check(`${path.basename(f)}：没有裸用 COMPRESSION_* 常量（全部走 rawValue 通道）`,
        bare.length === 0, [...new Set(bare)].join(', '));

  // ⭐ rawValue 必须是 **UInt32**（CI 实测：Int32 编不过）
  const int32Raw = /compression_\w+\(rawValue:\s*Int32/.test(code);
  check(`${path.basename(f)}：Compression 的 rawValue 不许用 Int32(...)（真值是 UInt32）`,
        !int32Raw, 'rawValue 是 UInt32 ⇒ Int32(...) 编不过');

  // ⭐ 四个枚举都要用 rawValue 通道构造
  for (const t of ['compression_stream_operation', 'compression_algorithm',
                   'compression_status', 'compression_stream_flags']) {
    if (!code.includes(t)) continue;
    check(`${path.basename(f)}：${t} 用 rawValue: 通道构造`,
          new RegExp(t + '\\(rawValue:').test(code), '必须走 rawValue: 通道');
  }

  // ⭐⭐⭐ ZLIB = 0x205（写 0 会静默用错算法）
  if (code.includes('compression_algorithm')) {
    check(`${path.basename(f)}：ZLIB 用 0x205（SDK 头文件实测值）`,
          /compression_algorithm\(rawValue:\s*UInt32\(0x205\)\)/.test(code),
          'COMPRESSION_ZLIB = 0x205 ⇒ 写 0 会静默用错算法');
  }

  // ⭐⭐⭐⭐⭐ compression_stream_init 的实参**必须包成 compression_* 类型**
  if (code.includes('compression_stream_init')) {
    const idx = code.indexOf('compression_stream_init(');
    const call = code.slice(idx, idx + 120);
    const rawUint = /compression_stream_init\([^)]*UInt32/.test(call);
    check(`${path.basename(f)}：compression_stream_init 的实参不许是裸 UInt32（必须包 compression_* 类型）`,
          !rawUint, call.slice(0, 90));
    check(`${path.basename(f)}：compression_stream_init 传的是 op/alg 变量`,
          /compression_stream_init\(&\w+,\s*op,\s*alg\)/.test(call), call.slice(0, 90));
  }

  // ⭐⭐⭐⭐⭐ compression_stream 是 C struct ⇒ 成员构造器要 5 个参数 ⇒ 没有零参 init
  if (code.includes('compression_stream(')) {
    check(`${path.basename(f)}：compression_stream 用 5 参成员构造器（没有零参 init）`,
          /compression_stream\(dst_ptr:/.test(code),
          'CI 编译器 note：init(dst_ptr:dst_size:src_ptr:src_size:state:)');
    check(`${path.basename(f)}：没有零参 compression_stream()`,
          !/compression_stream\(\s*\)/.test(code),
          '零参 ⇒ 编译器转挑 compression_decode_buffer 重载 ⇒ 报误导性的错');
    // ⭐⭐⭐⭐⭐ **dst_ptr / src_ptr 是【非可选指针】⇒ 不能传 nil**（CI build296 实测）
    check(`${path.basename(f)}：compression_stream 的 dst_ptr/src_ptr 不许传 nil`,
          !/dst_ptr:\s*nil/.test(code) && !/src_ptr:\s*nil/.test(code),
          "'nil' is not compatible with expected argument type 'UnsafeMutablePointer<UInt8>'");
    // ⭐⭐⭐ `src_ptr` 的实参必须是 `UnsafePointer(...)` **无标签**构造
    //   （`UnsafePointer(mutating:)` 这个标签在 Swift 里**不存在** ⇒ 报 extraneous argument label）⭐⭐⭐
    const srcArg = code.match(/src_ptr:\s*([^,\n]+)/);
    check(`${path.basename(f)}：src_ptr 用 UnsafePointer(...) 无标签构造`,
          !!srcArg && /UnsafePointer\(\s*\w+\s*\)/.test(srcArg[1]),
          srcArg ? `实际：${srcArg[1].trim()}` : '找不到 src_ptr 实参');
  }
}

// ─────────────────────────────────────────────────────────────
// ② CommonCrypto padding：用 Apple 权威名
// ─────────────────────────────────────────────────────────────
console.log('\n=== 2. CommonCrypto 的 padding（Apple 权威名 ccPKCS7Padding / ccNoPadding）===');
const WRONG_PADDING = ['kCCPaddingPKCS7', 'kCCPaddingNoPadding', 'kCCPKCS7Padding',
                        'kCCNoPadding', 'kCCPaddingNone', 'kCCPaddingPKCS5'];
for (const [f, code] of codeNoC) {
  const used = WRONG_PADDING.filter((w) => code.includes(w));
  check(`${path.basename(f)}：padding 不用不存在的常量名`, used.length === 0, used.join(', '));
  if (/ccPadding/.test(code)) {
    // ⭐⭐⭐⭐⭐ **CI build296 实测：`ccPKCS7Padding` / `ccNoPadding` 在 Swift 里是 `Int`**
    //   ⇒ 直接赋给 `CCPadding`（= UInt32）⇒ 报「cannot convert value of type 'Int' to
    //      specified type 'CCPadding' (aka 'UInt32')」⭐⭐⭐
    //   ⇒ 正解：用 Apple 头文件里的枚举**数值**（0=ccNoPadding / 1=ccPKCS7Padding）⭐⭐⭐
    // ⭐⭐⭐⭐⭐ **CI 探针实证**：`CCPadding(ccPKCS7Padding)` **编译通过**（常量折叠），
    //   但**不能隐式**赋给 CCPadding（cc* 是 Int ⇒ 三元表达式类型是 Int ⇒ 报「cannot convert」）⭐⭐⭐
    check(`${path.basename(f)}：padding 显式包 CCPadding(ccPKCS7Padding) / CCPadding(ccNoPadding)`,
          /CCPadding\(ccPKCS7Padding\)/.test(code) && /CCPadding\(ccNoPadding\)/.test(code),
          'cc* 是 Int ⇒ 必须显式包一层 CCPadding(...)');
    check(`${path.basename(f)}：padding 不许把 cc* 常量【隐式】赋给 CCPadding`,
          !/ccPadding\s*:\s*CCPadding\s*=\s*usePadding\s*\?\s*cc/.test(code),
          '三元里直接用 ccPKCS7Padding ⇒ 类型是 Int ⇒ 编不过');
    check(`${path.basename(f)}：padding 显式标注 CCPadding 类型`,
          /ccPadding\s*:\s*CCPadding\s*=/.test(code),
          '应当是 `let ccPadding: CCPadding = usePadding ? CCPadding(1) : CCPadding(0)`');
  }
}

// ─────────────────────────────────────────────────────────────
// ③ withUnsafeBytes 闭包必须显式标注参数类型（两个重载 ⇒ 歧义）
// ─────────────────────────────────────────────────────────────
console.log('\n=== 3. withUnsafeBytes 闭包必须显式标注参数类型（Data 有两个重载）===');
// ⭐⭐⭐ **只查【我们写的适配层】**（`Sources/LegadoEngine`）⭐⭐⭐
//   柴阅的源码是**权威实现** ⇒ 它的写法不该被我们的规则管 ⭐⭐⭐
//   ⇒ 而**我们要防的是「自己写的代码踩平台坑」** ⇒ 限定到适配层 ⇒ 规则不失效 ⭐⭐⭐
const OUR_CODE = [...codeNoC].filter(([f]) => f.includes(`${path.sep}Sources${path.sep}LegadoEngine${path.sep}`));
for (const [f, code] of OUR_CODE) {
  const bare = [];
  const re = /\.withUnsafe(?:Mutable)?Bytes\s*\{\s*([A-Za-z_][A-Za-z0-9_]*)?\s*(?:in\b|:)/g;
  let m;
  while ((m = re.exec(code)) !== null) bare.push(m[0].trim());
  check(`${path.basename(f)}：所有 withUnsafeBytes 闭包都显式标注了参数类型`,
        bare.length === 0, bare.join(' | '));
  const typed = /\.withUnsafe(?:Mutable)?Bytes\s*\{\s*\(\s*\w+\s*:\s*Unsafe(?:Mutable)?RawBufferPointer\s*\)/g;
  const typedCount = [...code.matchAll(typed)].length;
  const total = [...code.matchAll(/\.withUnsafe(?:Mutable)?Bytes\s*\{/g)].length;
  check(`${path.basename(f)}：withUnsafeBytes 总数与显式标注数一致（${total} 处）`,
        typedCount === total, `显式标注 ${typedCount} / 总数 ${total}`);
}

// ─────────────────────────────────────────────────────────────
// ④ Security 框架
// ─────────────────────────────────────────────────────────────
console.log('\n=== 4. Security 框架（SDK 里真实存在的成员）===');
for (const [f, code] of codeNoC) {
  const bad = [...code.matchAll(/\.rsaEncryptionOAEP\b(?!SHA)/g)].map((m) => m[0]);
  check(`${path.basename(f)}：没有 .rsaEncryptionOAEP（SDK 无此成员）`, bad.length === 0, bad.join(', '));
}

// ─────────────────────────────────────────────────────────────
// ⑤ CommonCrypto 常量必须显式转换
// ─────────────────────────────────────────────────────────────
console.log('\n=== 5. CommonCrypto 的 kCC* 常量必须显式转换（Int → uint32_t）===');
// ⭐⭐⭐ 同样**只查我们写的适配层**（柴阅源码是权威实现）⭐⭐⭐
const CC_TYPED = ['kCCAlgorithmAES', 'kCCAlgorithmDES', 'kCCAlgorithm3DES', 'kCCAlgorithmBlowfish',
  'kCCModeECB', 'kCCModeCBC', 'kCCModeCFB', 'kCCModeCTR', 'kCCModeOFB',
  'kCCEncrypt', 'kCCDecrypt', 'kCCModeOptionCTR_BE'];
for (const [f, code] of OUR_CODE) {
  for (const c of CC_TYPED) {
    const re = new RegExp('(?<!CC\\w+\\()\\b' + c + '\\b', 'g');
    const hits = [...code.matchAll(re)];
    if (hits.length === 0) continue;
    const unwrapped = hits.filter((m) => {
      const before = code.slice(Math.max(0, m.index - 40), m.index);
      return !/(CCAlgorithm|CCMode|CCOperation|CCPadding|CCModeOptions)\($/.test(before);
    });
    check(`${path.basename(f)}：${c} 已显式转换`, unwrapped.length === 0,
          unwrapped.length ? `第 ${unwrapped[0].index + 1} 字符处未转换` : '');
  }
}

// ─────────────────────────────────────────────────────────────
// ⑥ NSRegularExpression 的平台差异必须走 helper
// ─────────────────────────────────────────────────────────────
console.log('\n=== 6. NSRegularExpression 的平台差异（Darwin withTemplate: / Linux template:）===');
for (const [f, code] of OUR_CODE) {
  const direct = [...code.matchAll(/\.stringByReplacingMatches\(/g)].length;
  const helper = /func replacingMatches\(/.test(code) ? 2 : 0;
  if (direct === 0) continue;
  check(`${path.basename(f)}：${direct} 处 stringByReplacingMatches 全在 helper 里`,
        direct === helper, `直接调用 ${direct} 处，helper 里 ${helper} 处`);
}

// ─────────────────────────────────────────────────────────────
// ⑦ CCCryptorCreateWithMode 参数个数 = 12（Apple 官方 CommonCryptor.h）
// ─────────────────────────────────────────────────────────────
console.log('\n=== 7. CCCryptorCreateWithMode 的参数个数（Apple 官方签名 = 12）===');
for (const [f, code] of OUR_CODE) {
  const args = callArgs(code, 'CCCryptorCreateWithMode');
  if (args < 0) continue;
  check(`${path.basename(f)}：CCCryptorCreateWithMode 传 12 个参数（Apple 官方签名）`, args === 12,
        `实际 ${args} 个（官方签名含 tweak/tweakLength/numRounds 三个）`);
  // ⭐⭐⭐⭐⭐ **闭包体是多语句 ⇒ 没有隐式 return** ⇒ 返回值退化成 `()`
  //   ⇒ 外层 createStatus 变成 () ⇒ `createStatus == kCCSuccess` 编不过 ⭐⭐⭐
  const cIdx = code.indexOf('CCCryptorCreateWithMode(');
  const beforeCall = code.slice(Math.max(0, cIdx - 200), cIdx);
  check(`${path.basename(f)}：CCCryptorCreateWithMode 前有显式 return（多语句闭包无隐式返回）`,
        /return\s+$/.test(beforeCall) || /return\s+CCCryptorCreateWithMode\s*\(/.test(beforeCall),
        '闭包体多语句 ⇒ 必须写 return，否则 createStatus 退化成 ()');
}

console.log(`\n通过 ${passed} / 失败 ${failed}`);
process.exit(failed === 0 ? 0 : 1);
