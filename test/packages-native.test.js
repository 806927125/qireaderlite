// packages-native.js 的门禁测试
// 跑法：node test/packages-native.test.js
//
// ⚠️ 测试向量**不手敲** —— 全部用 Node 的 crypto 现算，再跟纯 JS 实现交叉比对。
//    手抄的常量一定会抄错（上次纯 JS AES 就是栽在 S 盒上）。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const vm = require('vm');

const ENGINE = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

// ── 装载被测脚本 ──
const sandbox = {
  console, TextEncoder, TextDecoder, Uint8Array, ArrayBuffer, JSON, Math, Date,
  String, Number, Boolean, Object, Array, RegExp, Error, Promise, Symbol, Map, Set,
  parseInt, parseFloat, isNaN, decodeURIComponent, encodeURIComponent,
  setTimeout, clearTimeout, Response, CompressionStream, DecompressionStream,
};
sandbox.window = sandbox; sandbox.globalThis = sandbox; sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(ENGINE, 'packages-native.js'), 'utf8'), sandbox,
                { filename: 'packages-native.js' });

const N = sandbox;

// ────────────────────────────────────────────────────────────────────────
console.log('=== 1. base64 往返（跟 Node Buffer 交叉验证）===');
(function () {
  const cases = [
    Buffer.from(''),
    Buffer.from('a'),
    Buffer.from('ab'),
    Buffer.from('abc'),
    Buffer.from('hello world'),
    Buffer.from([0, 1, 2, 250, 251, 252, 253, 254, 255]),
    crypto.randomBytes(257),
  ];
  let ok = true, bad = '';
  for (const buf of cases) {
    const mine = N._nativeBase64Encode(Array.from(buf));
    const node = buf.toString('base64');
    if (mine !== node) { ok = false; bad = `${mine} != ${node}`; break; }
    const back = N._nativeBase64DecodeToBytes(node);
    if (Buffer.from(back).compare(buf) !== 0) { ok = false; bad = 'roundtrip mismatch'; break; }
  }
  check('base64 编码/解码与 Node 一致', ok, bad);
})();

// ────────────────────────────────────────────────────────────────────────
console.log('\n=== 2. 字符串 ↔ 字节（UTF-8）===');
(function () {
  const cases = ['', 'abc', '中文测试', 'emoji 🚀🔥', 'a\u0000b'];
  let ok = true, bad = '';
  for (const s of cases) {
    const bytes = N._nativeStrToBytes(s, 'UTF-8');
    const node = Buffer.from(s, 'utf8');
    if (Buffer.compare(Buffer.from(bytes), node) !== 0) { ok = false; bad = `bytes mismatch @${s}`; break; }
    if (N._nativeBytesToStr(bytes, 'UTF-8') !== s) { ok = false; bad = `decode mismatch @${s}`; break; }
  }
  check('UTF-8 往返与 Node 一致', ok, bad);
})();

// ────────────────────────────────────────────────────────────────────────
console.log('\n=== 3a. AES 单块 —— FIPS-197 官方向量 ===');
(function () {
  // FIPS-197 附录 C / 附录 B 的 ECB 单块向量
  const pt = Buffer.from('00112233445566778899aabbccddeeff', 'hex');
  const vectors = [
    { keyLen: 16, key: '000102030405060708090a0b0c0d0e0f', ct: '69c4e0d86a7b0430d8cdb78070b4c55a' },
    { keyLen: 24, key: '000102030405060708090a0b0c0d0e0f1011121314151617', ct: 'dda97ca4864cdfe06eaf70a0ec0d7191' },
    { keyLen: 32, key: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', ct: '8ea2b7ca516745bfeafc49904b496089' },
  ];
  for (const v of vectors) {
    const key = Buffer.from(v.key, 'hex');
    const b64 = N._nativeCipherProcess(pt.toString('base64'), key.toString('base64'),
                                        'AES/ECB/NoPadding', '', false);
    const got = Buffer.from(b64, 'base64').toString('hex');
    check(`AES-${v.keyLen * 8} ECB 单块 = FIPS-197 官方值`, got === v.ct, `${got} != ${v.ct}`);
  }
})();

// ────────────────────────────────────────────────────────────────────────
console.log('\n=== 3b. AES —— 跟 Node crypto 交叉验证（多块 / 非零 IV / 多种 key 长）===');
(function () {
  const transforms = [
    { js: 'AES/CBC/PKCS5Padding', node: 'aes-128-cbc', keyLen: 16 },
    { js: 'AES/CBC/PKCS5Padding', node: 'aes-192-cbc', keyLen: 24 },
    { js: 'AES/CBC/PKCS5Padding', node: 'aes-256-cbc', keyLen: 32 },
    { js: 'AES/ECB/PKCS5Padding', node: 'aes-128-ecb', keyLen: 16 },
    { js: 'AES/ECB/PKCS5Padding', node: 'aes-256-ecb', keyLen: 32 },
    { js: 'AES/CBC/NoPadding', node: 'aes-128-cbc', keyLen: 16, noPad: true },
  ];
  let ok = true, bad = '';
  for (const t of transforms) {
    for (const plainLen of [0, 1, 15, 16, 17, 64, 200]) {
      const key = crypto.randomBytes(t.keyLen);
      // ⚠️ IV 必须非零：零 IV 会让 CBC 解密的第一块"恰好蒙对"，掩盖实现错误
      const iv = crypto.randomBytes(16);
      let plain = crypto.randomBytes(Math.max(plainLen, 1)).subarray(0, plainLen);
      if (t.noPad) {
        // NoPadding 要求 16 的倍数
        const n = Math.max(16, Math.ceil(plainLen / 16) * 16);
        const p2 = crypto.randomBytes(n);
        plain = p2.subarray(0, n);
      }
      const nodeCipher = crypto.createCipheriv(t.node, key, t.node.includes('ecb') ? null : iv);
      // ⚠️ 只在 NoPadding 时关掉 autoPadding。
      //    之前写成 `if (!ecb) setAutoPadding(false)` → 把 CBC 的 PKCS5 padding 也关了，
      //    于是 Node 输出 0 字节、我的实现输出 16 字节，误报成"实现不一致"。
      if (t.js.endsWith('NoPadding')) nodeCipher.setAutoPadding(false);
      const nodeEnc = Buffer.concat([nodeCipher.update(plain), nodeCipher.final()]);

      const mineB64 = N._nativeCipherProcess(
        plain.toString('base64'), key.toString('base64'), t.js, iv.toString('base64'), false);
      const mineEnc = Buffer.from(mineB64, 'base64');
      if (Buffer.compare(mineEnc, nodeEnc) !== 0) {
        ok = false; bad = `${t.js} key=${t.keyLen} len=${plainLen} 加密不一致`; break;
      }
      // 解密回来
      const backB64 = N._nativeCipherProcess(
        nodeEnc.toString('base64'), key.toString('base64'), t.js, iv.toString('base64'), true);
      const back = Buffer.from(backB64, 'base64');
      if (Buffer.compare(back, plain) !== 0) {
        ok = false; bad = `${t.js} key=${t.keyLen} len=${plainLen} 解密不一致`; break;
      }
    }
    if (!ok) break;
  }
  check('AES 加解密与 Node crypto 完全一致', ok, bad);
})();

// ────────────────────────────────────────────────────────────────────────
console.log('\n=== 4. 非法输入要明确报错（不能静默出错结果）===');
(function () {
  let threw = false;
  try { N._nativeCipherProcess('AAAA', 'AAAAAAAAAAAAAAAAAAAAAA==', 'DES/CBC/PKCS5Padding', 'AAAAAAAAAAAAAAAAAAAAAA==', false); }
  catch (e) { threw = /不支持的算法/.test(e.message); }
  check('不支持的算法（DES）明确抛错', threw);

  threw = false;
  try { N._nativeCipherProcess('AAAA', 'AAAA', 'AES/CBC/PKCS5Padding', 'AAAAAAAAAAAAAAAAAAAAAA==', false); }
  catch (e) { threw = /密钥长度/.test(e.message); }
  check('密钥长度非法明确抛错', threw);

  threw = false;
  try { N._nativeCipherProcess('AAAA', 'AAAAAAAAAAAAAAAAAAAAAA==', 'AES/GCM/NoPadding', '', false); }
  catch (e) { threw = /不支持的模式/.test(e.message); }
  check('不支持的模式（GCM）明确抛错', threw);
})();

// ────────────────────────────────────────────────────────────────────────
console.log('\n=== 5. gzip（同步）+ inflate 双向交叉验证 ===');
(function () {
  const zlib = require('zlib');
  let ok = true, bad = '';

  // 5a. 我的 gzip 输出 → Node gunzipSync 解开
  for (const len of [0, 1, 100, 5000, 70000]) {
    const data = crypto.randomBytes(len);
    const gz = N._nativeGzip(Array.from(data));
    if (!Array.isArray(gz)) { ok = false; bad = `gzip 返回的不是数组（是 ${typeof gz}）`; break; }
    let back;
    try { back = zlib.gunzipSync(Buffer.from(gz)); }
    catch (e) { ok = false; bad = `Node 解不开我的 gzip（len=${len}）: ${e.message}`; break; }
    if (Buffer.compare(back, data) !== 0) { ok = false; bad = `gzip 往返不一致 len=${len}`; break; }
  }
  check('我的 gzip 输出可被 Node zlib 解开（同步、合法 gzip）', ok, bad);

  // 5b. Node gzip 输出（真 deflate 压缩，含 dynamic huffman）→ 我的 gunzip 解开
  ok = true; bad = '';
  for (const level of [0, 1, 6, 9]) {
    for (const len of [0, 1, 50, 1000, 100000]) {
      // 用重复内容逼出 dynamic huffman
      const data = Buffer.alloc(len, 0x41);
      for (let i = 0; i < len; i += 7) data[i] = i & 0xff;
      const gz = zlib.gzipSync(data, { level });
      let back;
      try { back = Buffer.from(N._nativeGunzip(Array.from(gz))); }
      catch (e) { ok = false; bad = `我的 gunzip 解不开 Node 的 gzip（level=${level} len=${len}）: ${e.message}`; break; }
      if (Buffer.compare(back, data) !== 0) { ok = false; bad = `gunzip 结果不一致 level=${level} len=${len}`; break; }
    }
    if (!ok) break;
  }
  check('我的 inflate 能解开 Node 各压缩级别的 gzip（含动态 Huffman）', ok, bad);

  // 5c. 坏数据要明确报错，不能静默返回垃圾
  let threw = false;
  try { N._nativeGunzip([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]); }
  catch (e) { threw = true; }
  check('非法 gzip 数据明确抛错', threw);
})();

// ────────────────────────────────────────────────────────────────────────
console.log('\n=== 6. 集成：packages_stub.js + packages-native.js 端到端 ===');
(function () {
  const s2 = Object.assign({}, sandbox);
  s2.window = s2; s2.globalThis = s2; s2.self = s2;
  vm.createContext(s2);
  // 先 native，后 stub（顺序不能反）
  vm.runInContext(fs.readFileSync(path.join(ENGINE, 'packages-native.js'), 'utf8'), s2);
  vm.runInContext(fs.readFileSync(path.join(ENGINE, 'packages_stub.js'), 'utf8'), s2,
                  { filename: 'packages_stub.js' });
  const P = s2.Packages;
  check('Packages 命名空间存在', !!P);
  check('javax.crypto.Cipher 存在', !!(P && P.javax && P.javax.crypto && P.javax.crypto.Cipher));
  check('java.util.Base64 存在', !!(P && P.java && P.java.util && P.java.util.Base64));
  check('String.prototype.getBytes 存在', typeof ''.getBytes === 'function');
  check('JavaImporter 存在', typeof s2.JavaImporter === 'function');
  check('importPackage 存在', typeof s2.importPackage === 'function');

  // 真跑一次 AES 加密（书源里最常见的用法）
  try {
    const key = '1234567890123456';
    const iv = 'abcdefghijklmnop';
    const cipher = P.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
    const k = new P.javax.crypto.spec.SecretKeySpec(key.getBytes('UTF-8'), 'AES');
    const v = new P.javax.crypto.spec.IvParameterSpec(iv.getBytes('UTF-8'));
    cipher.init(1, k, v);
    const out = cipher.doFinal('hello 轻阅'.getBytes('UTF-8'));
    // ⚠️ doFinal 返回的**已经是 base64 字符串**（packages_stub 的 Cipher 约定：
    //    内部走 _nativeCipherProcess(…b64…)，返回 b64）。
    //    再套一层 _nativeBase64Encode 就变成双重编码，长度对不上。
    const encB64 = String(out);
    check('doFinal 返回的是 base64 字符串', /^[A-Za-z0-9+/]+={0,2}$/.test(encB64), encB64);
    check('密文长度是 16 的整数倍', Buffer.from(encB64, 'base64').length % 16 === 0,
          String(Buffer.from(encB64, 'base64').length));
    // 用 Node 独立解一次，验证结果正确
    const dec = crypto.createDecipheriv('aes-128-cbc', Buffer.from(key, 'utf8'), Buffer.from(iv, 'utf8'));
    const plain = Buffer.concat([dec.update(Buffer.from(encB64, 'base64')), dec.final()]);
    check('端到端 AES 加密结果可被 Node 解回原文', plain.toString('utf8') === 'hello 轻阅',
          plain.toString('utf8'));
  } catch (e) {
    check('端到端 AES 加密结果可被 Node 解回原文', false, e.message);
  }
})();

// ────────────────────────────────────────────────────────────────────────
setTimeout(() => {
  console.log('\n' + '═'.repeat(52));
  console.log(`  通过 ${passed}  失败 ${failed}`);
  console.log('═'.repeat(52));
  process.exit(failed === 0 ? 0 : 1);
}, 300);
