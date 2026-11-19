// 门禁：⭐⭐⭐⭐⭐ **Apple-only 文件里的「平台 API 陷阱」静态兜底**（2026-11-19 CI build296/457 实证）
//
// 跑法：node test/engine-apple-api.test.js
//
// ⚠️ **为什么必须有这条门禁**：
//   `LegadoEngine/…/JS/JSNatives.swift`、`JSBridge.swift` 这些文件里，
//   有一部分代码**只在 Apple 平台编译**（`#if canImport(JavaScriptCore) && !os(Linux)`）
//   ⇒ ⇒ **沙盒 Linux 门禁永远绿** ⇒ 这类错**只有 CI 能暴露** ⇒ 每次 4~5 分钟一轮 ⭐⭐⭐
//   ⇒ 必须有静态门禁提前抓 ⭐⭐⭐
//
// 本门禁抓的**已实证**陷阱：
//   ① `COMPRESSION_STREAM_ENCODE/DECODE` —— **不是** Apple 的 API（Apple 是 `COMPRESSION_ENCODE/DECODE`）
//      ⇒ 症状：类型推不出来 ⇒ 编译器挑了别的重载 ⇒ 报「missing arguments for parameters dst_ptr…」
//   ② `COMPRESSION_STATUS` 当**类型**用 —— Apple 的类型名是 `compression_status`（小写）
//   ③ `.rsaEncryptionOAEP` —— **SDK 里没有这个成员**（只有 OAEPSHA1/SHA256/SHA384/SHA512）
//      ⇒ 症状：`cannot be resolved without a contextual type`
//   ④ CommonCrypto 的 `kCC*` 常量是 `Int`（typedef 是 uint32_t）⇒ 必须显式转换
//      ⇒ 症状：`cannot assign value of type 'Int' to type 'CCAlgorithm' (aka 'UInt32')`
//   ⑤ `NSRegularExpression.stringByReplacingMatches` 的参数标签**两个平台不同**
//      （Darwin `withTemplate:` / Linux `template:`）⇒ 必须走统一封装的 helper
//
// ⇒ 变异对照：把任一条改回原样 ⇒ **必须红**

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'LegadoEngine', 'Sources', 'LegadoEngine');

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

console.log('=== 0. 门禁不是空跑 ===');
const appleOnly = files.filter((f) => /canImport\(JavaScriptCore\)|canImport\(WebKit\)/.test(codeNoC.get(f)));
check(`有 Apple-only 文件（${appleOnly.length} 个）`, appleOnly.length > 0, '0 个 ⇒ 门禁失效');

// ① ② Compression
console.log('\n=== 1. Compression 框架（Darwin 的名字）===');
for (const [f, code] of codeNoC) {
  const bad = [...code.matchAll(/COMPRESSION_STREAM_(ENCODE|DECODE)/g)].map((m) => m[0]);
  check(`${path.basename(f)}：没有 COMPRESSION_STREAM_ENCODE/DECODE`, bad.length === 0, bad.join(', '));
  // `COMPRESSION_STATUS` 当类型用（排除 COMPRESSION_STATUS_OK/END/ERROR 常量）
  const typeUse = [...code.matchAll(/\bCOMPRESSION_STATUS\b(?!_)/g)].map((m) => m[0]);
  check(`${path.basename(f)}：没有把 COMPRESSION_STATUS 当类型`, typeUse.length === 0, typeUse.join(', '));
  // ⭐⭐⭐⭐⭐ **CI build296 实证：Apple 平台上 `COMPRESSION_ENCODE` / `COMPRESSION_STATUS_OK` 等
  //   **全部不在作用域** ⇒ 一律走 `rawValue:` 通道 ⇒ 代码里**不允许出现任何裸的 COMPRESSION_ 常量** ⭐⭐⭐
  const bareConst = [...code.matchAll(/\bCOMPRESSION_[A-Z_]+\b/g)]
    .map((m) => m[0])
    .filter((n) => !['COMPRESSION_STREAM_ENCODE', 'COMPRESSION_STREAM_DECODE'].includes(n));
  check(`${path.basename(f)}：没有裸用 COMPRESSION_* 常量（全部走 rawValue 通道）`,
        bareConst.length === 0, [...new Set(bareConst)].join(', '));
  // ⭐⭐⭐⭐⭐ **CI 自省（读 SDK compression.h）拿到的事实**：
  //   · rawValue 是 **UInt32**（不是 Int32）⇒ `Int32(...)` 编不过 ⭐⭐⭐
  //   · **COMPRESSION_ZLIB = 0x205**（不是 0！！）⇒ 写 0 会静默用错算法 ⭐⭐⭐
  const badRaw = [...code.matchAll(/compression_(?:stream_operation|algorithm|status|stream_flags)\(rawValue:\s*Int32/g)];
  check(`${path.basename(f)}：Compression 的 rawValue 用 UInt32（SDK 事实）`, badRaw.length === 0,
        `第 ${badRaw[0] ? badRaw[0].index + 1 : 0} 字符处用了 Int32`);
  if (code.includes('compression_algorithm(rawValue:')) {
    check(`${path.basename(f)}：ZLIB 用 0x205（SDK 头文件实测值）`,
          /compression_algorithm\(rawValue:\s*UInt32\(0x205\)\)/.test(code),
          'COMPRESSION_ZLIB = 0x205 ⇒ 写 0 会静默用错算法');
  }
}

// ②-B CommonCrypto 的 padding：**Apple 上没有任何可用的 padding 常量名**
//   ⇒ CI 自省 + swiftc 探针实测：`kCCPaddingPKCS7` / `kCCPaddingNoPadding` / `kCCPKCS7Padding`
//      / `ccPKCS7Padding` **全部不在作用域** ⇒ 只能用 `CCPadding` 的 raw 数值（0=无 / 1=PKCS7）⭐⭐⭐
console.log('\n=== 2-B. CommonCrypto 的 padding（只能用 raw 数值）===');
const WRONG_PADDING = ['kCCPaddingPKCS7', 'kCCPaddingNoPadding', 'kCCPKCS7Padding', 'kCCNoPadding',
                        'ccPKCS7Padding', 'ccNoPadding', 'kCCPaddingNone'];
for (const [f, code] of codeNoC) {
  const used = WRONG_PADDING.filter((w) => code.includes(w));
  check(`${path.basename(f)}：padding 不用任何常量名（SDK 里都不存在）`, used.length === 0, used.join(', '));
  if (code.includes('CCPadding(')) {
    check(`${path.basename(f)}：padding 用 raw 数值（0=无填充 / 1=PKCS7）`,
          /CCPadding\(1\)/.test(code) && /CCPadding\(0\)/.test(code),
          '应当是 CCPadding(1) / CCPadding(0)');
  }
}

// ③ SecKeyAlgorithm
console.log('\n=== 2. Security 框架（SDK 里真实存在的成员）===');
for (const [f, code] of codeNoC) {
  const bad = [...code.matchAll(/\.rsaEncryptionOAEP\b(?!SHA)/g)].map((m) => m[0]);
  check(`${path.basename(f)}：没有 .rsaEncryptionOAEP（SDK 无此成员）`, bad.length === 0, bad.join(', '));
}

// ④ CommonCrypto 常量必须显式转换
console.log('\n=== 3. CommonCrypto 的 kCC* 常量必须显式转换（Int → uint32_t）===');
const CC_TYPED = ['kCCAlgorithmAES', 'kCCAlgorithmDES', 'kCCAlgorithm3DES', 'kCCAlgorithmBlowfish',
  'kCCModeECB', 'kCCModeCBC', 'kCCModeCFB', 'kCCModeCTR', 'kCCModeOFB', 'kCCModeOFB',
  'kCCEncrypt', 'kCCDecrypt', 'kCCModeOptionCTR_BE'];
for (const [f, code] of codeNoC) {
  for (const c of CC_TYPED) {
    const re = new RegExp('(?<!CC\\w+\\()\\b' + c + '\\b', 'g');
    const hits = [...code.matchAll(re)];
    if (hits.length === 0) continue;
    // 允许 `CCAlgorithm(kCCAlgorithmAES)` 这种：检查前面 30 字符里有没有 `XXX(`
    const unwrapped = hits.filter((m) => {
      const before = code.slice(Math.max(0, m.index - 40), m.index);
      return !/(CCAlgorithm|CCMode|CCOperation|CCPadding|CCModeOptions)\($/.test(before);
    });
    check(`${path.basename(f)}：${c} 已显式转换`, unwrapped.length === 0,
          unwrapped.length ? `第 ${unwrapped[0].index + 1} 字符处未转换` : '');
  }
}

// ⑤ NSRegularExpression 的平台差异必须走 helper
console.log('\n=== 4. NSRegularExpression 的平台差异（Darwin withTemplate: / Linux template:）===');
for (const [f, code] of codeNoC) {
  const direct = [...code.matchAll(/\.stringByReplacingMatches\(/g)].length;
  const helper = /func replacingMatches\(/.test(code) ? 2 : 0; // helper 里两个平台各一次
  if (direct === 0) continue;
  check(`${path.basename(f)}：${direct} 处 stringByReplacingMatches 全在 helper 里`,
        direct === helper, `直接调用 ${direct} 处，helper 里 ${helper} 处`);
}

// ⑥ CCCryptorCreateWithMode 的参数个数（Darwin = 11）
console.log('\n=== 5. CCCryptorCreateWithMode 的参数个数（Darwin = 11）===');
for (const [f, code] of codeNoC) {
  const idx = code.indexOf('CCCryptorCreateWithMode(');
  if (idx < 0) continue;
  const open = idx + 'CCCryptorCreateWithMode('.length;
  let depth = 1, i = open, args = 1, inStr = false;
  for (; i < code.length && depth > 0; i++) {
    const c = code[i];
    if (inStr) { if (c === '"') inStr = false; continue; }
    if (c === '"') { inStr = true; continue; }
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') { depth--; if (depth === 0) break; }
    else if (c === ',' && depth === 1) args++;
  }
  check(`${path.basename(f)}：CCCryptorCreateWithMode 传 11 个参数（Darwin 签名）`, args === 11,
        `实际 ${args} 个`);
}

console.log(`\n通过 ${passed} / 失败 ${failed}`);
process.exit(failed === 0 ? 0 : 1);
