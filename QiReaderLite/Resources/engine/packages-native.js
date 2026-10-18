// ============================================================================
// packages-native.js —— 给「栖阅 packages_stub.js」补齐它依赖的原生函数
// ============================================================================
//
// 背景：栖阅把书源规则引擎编在 29MB 的 Swift 二进制里，JS 侧只留了一层
// 兼容层 packages_stub.js，它把 `Packages.javax.crypto.Cipher` 这些 Java 类
// 映射到 8~10 个 `_native*` 原生函数上。栖阅那边是 Swift 实现，搬不过来。
//
// 这里用**纯 JS** 把这些原生函数补上，让 packages_stub.js 能在轻阅里跑。
// 全部实现都是同步的（栖阅的 native 也是同步语义）。
//
// 注入顺序：必须在 packages_stub.js **之前**加载 ——
//   packages_stub.js 顶层就会定义 String.prototype.getBytes，函数体里就用 _nativeStrToBytes。
//
// ── 编码支持现状 ──
//   UTF-8 / ISO-8859-1 / US-ASCII：完整支持
//   GBK / GB18030 / Big5：**降级按 UTF-8 处理**（原生实现是 Swift 的 String.Encoding，
//   完整支持需要几十 KB 的编码表）。书源里密钥几乎都用 UTF-8，GBK 只在少数老源出现。
//   传入 GBK 且实际不是 UTF-8 时结果会不对 —— 这是已知限制，不是 bug。
//
// ── gzip ──
//   用 Web 标准的 CompressionStream / DecompressionStream（Safari 16.4+ / iOS 17+）。
//   轻阅部署目标 iOS 17，够用。不引第三方库。
//
// ── cipher ──
//   支持：AES/ECB/PKCS5Padding、AES/CBC/PKCS5Padding、AES/ECB/NoPadding、AES/CBC/NoPadding
//   不支持：DES / 3DES / Blowfish / GCM / CTR —— 明确抛错，不静默出错结果。

(function (g) {
  'use strict';
  if (typeof g === 'undefined') g = (typeof globalThis !== 'undefined') ? globalThis : this;
  var W = g;

  // ────────────────────────────────────────────────────────────────────────
  // 字节工具
  // ────────────────────────────────────────────────────────────────────────

  function toArray(b) {
    if (!b) return [];
    if (typeof b === 'string') {
      var out = [], enc = utf8Encode(b);
      for (var i = 0; i < enc.length; i++) out.push(enc[i]);
      return out;
    }
    if (b instanceof Uint8Array) return Array.prototype.slice.call(b);
    if (typeof b.length === 'number') return Array.prototype.slice.call(b);
    return [];
  }

  function utf8Encode(str) {
    if (typeof TextEncoder !== 'undefined') return Array.from(new TextEncoder().encode(str));
    // 兜底手写 UTF-8
    var out = [], i, c;
    for (i = 0; i < str.length; i++) {
      c = str.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 63)); }
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        i++;
      } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
    }
    return out;
  }

  function utf8Decode(bytes) {
    if (typeof TextDecoder !== 'undefined') {
      return new TextDecoder('utf-8').decode(new Uint8Array(bytes));
    }
    var s = '', i = 0, b, c;
    while (i < bytes.length) {
      b = bytes[i++];
      if (b < 0x80) c = b;
      else if (b < 0xe0) c = ((b & 31) << 6) | (bytes[i++] & 63);
      else if (b < 0xf0) c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      else {
        c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
        c -= 0x10000;
        s += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023));
        continue;
      }
      s += String.fromCharCode(c);
    }
    return s;
  }

  // 单字节编码（ISO-8859-1 / ASCII）
  function latin1Encode(str) {
    var out = [], i;
    for (i = 0; i < str.length; i++) out.push(str.charCodeAt(i) & 0xff);
    return out;
  }
  function latin1Decode(bytes) {
    var s = '', i;
    for (i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 0xff);
    return s;
  }

  function encodeByCharset(str, charset) {
    var cs = String(charset || 'UTF-8').toUpperCase();
    if (cs === 'ISO-8859-1' || cs === 'ISO8859-1' || cs === 'LATIN1' || cs === 'US-ASCII' || cs === 'ASCII') {
      return latin1Encode(str);
    }
    return utf8Encode(str);   // UTF-8 及其它一律按 UTF-8
  }

  function decodeByCharset(bytes, charset) {
    var cs = String(charset || 'UTF-8').toUpperCase();
    if (cs === 'ISO-8859-1' || cs === 'ISO8859-1' || cs === 'LATIN1' || cs === 'US-ASCII' || cs === 'ASCII') {
      return latin1Decode(bytes);
    }
    return utf8Decode(bytes);
  }

  // ────────────────────────────────────────────────────────────────────────
  // Base64
  // ────────────────────────────────────────────────────────────────────────

  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function b64EncodeBytes(bytes) {
    var b = toArray(bytes), out = '', i;
    for (i = 0; i < b.length; i += 3) {
      var b0 = b[i] & 0xff, b1 = b[i + 1] & 0xff, b2 = b[i + 2] & 0xff;
      out += B64C.charAt(b0 >> 2);
      out += B64C.charAt(((b0 & 3) << 4) | (b1 >> 4));
      out += (i + 1 < b.length) ? B64C.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
      out += (i + 2 < b.length) ? B64C.charAt(b2 & 63) : '=';
    }
    return out;
  }

  function b64DecodeToBytes(str) {
    var s = String(str || '').replace(/[\r\n\s]/g, '').replace(/=+$/, '');
    var out = [], i;
    // ⚠️ 不能靠 indexOf 返回 -1 来判断"字符缺失"——
    //    String.indexOf('') 返回 **0**，会把空位当成合法的 'A'，多解出字节。
    //    所以这里用 i+n < length 显式判断每组还剩几个字符。
    for (i = 0; i + 1 < s.length; i += 4) {
      var e0 = B64C.indexOf(s.charAt(i));
      var e1 = B64C.indexOf(s.charAt(i + 1));
      if (e0 < 0 || e1 < 0) break;
      out.push(((e0 << 2) | (e1 >> 4)) & 0xff);
      if (i + 2 < s.length) {
        var e2 = B64C.indexOf(s.charAt(i + 2));
        if (e2 < 0) break;
        out.push((((e1 & 15) << 4) | (e2 >> 2)) & 0xff);
        if (i + 3 < s.length) {
          var e3 = B64C.indexOf(s.charAt(i + 3));
          if (e3 < 0) break;
          out.push((((e2 & 3) << 6) | e3) & 0xff);
        }
      }
    }
    return out;
  }

  // ────────────────────────────────────────────────────────────────────────
  // AES（纯 JS）
  // ────────────────────────────────────────────────────────────────────────

  var SBOX = new Uint8Array(256), INV_SBOX = new Uint8Array(256);
  (function () {
    // S 盒 = GF(2^8) 上的乘法逆元 + 仿射变换。
    // 逆元用**暴力求**（gmul 找乘积为 1 的那个 b），不建 exp/log 幂表 ——
    // 幂表那条路容易在约简多项式/移位上错，而且错了不报错、只出错误密文。
    var sbox = new Uint8Array(256);
    function rotl8(v, n) { return ((v << n) | (v >>> (8 - n))) & 0xff; }
    for (var a = 0; a < 256; a++) {
      var inv = 0;
      // a=0 的逆元按 AES 规定取 0（不是 1），再走仿射变换 → S[0] = 0x63
      if (a !== 0) {
        for (var b = 1; b < 256; b++) {
          if (gmul(a, b) === 1) { inv = b; break; }
        }
      }
      sbox[a] = (inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63) & 0xff;
    }
    SBOX = sbox;
    for (var z = 0; z < 256; z++) { INV_SBOX[SBOX[z]] = z; }
  })();

  var RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d];

  function xtime(a) { return ((a << 1) ^ ((a & 0x80) ? 0x1b : 0)) & 0xff; }
  function gmul(a, b) {
    var p = 0, i, x = a, y = b;
    for (i = 0; i < 8; i++) {
      if (y & 1) p ^= x;
      x = xtime(x);
      y >>= 1;
    }
    return p & 0xff;
  }

  function expandKey(key) {
    var nk = key.length / 4, nr = nk + 6, w = [];
    var i, j;
    for (i = 0; i < nk; i++) {
      w[i] = [(key[4 * i] & 0xff), (key[4 * i + 1] & 0xff), (key[4 * i + 2] & 0xff), (key[4 * i + 3] & 0xff)];
    }
    for (i = nk; i < 4 * (nr + 1); i++) {
      var temp = [w[i - 1][0], w[i - 1][1], w[i - 1][2], w[i - 1][3]];
      if (i % nk === 0) {
        // RotWord → SubWord → XOR Rcon
        var t = temp[0];
        temp = [temp[1], temp[2], temp[3], t];
        for (j = 0; j < 4; j++) temp[j] = SBOX[temp[j]];
        temp[0] ^= RCON[i / nk - 1];
      } else if (nk > 6 && i % nk === 4) {
        // AES-192/256 的额外 SubWord
        for (j = 0; j < 4; j++) temp[j] = SBOX[temp[j]];
      }
      // ⚠️ w[i-nk] 的 XOR **只在这里做一次** ——
      //    在 RotWord 分支里再 XOR 一遍会导致双重异或，密钥扩展整个错掉（且不报错）。
      // ⚠️ 同样必须先攒够 4 个字节再赋值 ——
      //    写成 w[i] = [w[i-nk][j] ^ temp[j]] 会在循环里把整个字覆盖成单元素数组。
      var nw = [];
      for (j = 0; j < 4; j++) nw[j] = (w[i - nk][j] ^ temp[j]) & 0xff;
      w[i] = nw;
    }
    return { w: w, nr: nr };
  }

  function addRoundKey(s, w, rnd) {
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) s[r][c] ^= w[rnd * 4 + c][r];
    }
  }

  function subBytes(s, box) {
    for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) s[r][c] = box[s[r][c]];
  }

  // s[r][c]：r = 行，c = 列；state[r][c] = block[r + 4c]
  function shiftRows(s) {
    var t;
    // 行1：左移 1
    t = s[1][0]; s[1][0] = s[1][1]; s[1][1] = s[1][2]; s[1][2] = s[1][3]; s[1][3] = t;
    // 行2：左移 2（两两对换，4 个都要换）
    t = s[2][0]; s[2][0] = s[2][2]; s[2][2] = t;
    t = s[2][1]; s[2][1] = s[2][3]; s[2][3] = t;
    // 行3：左移 3（= 右移 1）
    t = s[3][0]; s[3][0] = s[3][3]; s[3][3] = s[3][2]; s[3][2] = s[3][1]; s[3][1] = t;
  }

  function invShiftRows(s) {
    var t;
    // 行1：右移 1
    t = s[1][3]; s[1][3] = s[1][2]; s[1][2] = s[1][1]; s[1][1] = s[1][0]; s[1][0] = t;
    // 行2：右移 2
    t = s[2][0]; s[2][0] = s[2][2]; s[2][2] = t;
    t = s[2][1]; s[2][1] = s[2][3]; s[2][3] = t;
    // 行3：右移 3（= 左移 1）
    t = s[3][0]; s[3][0] = s[3][1]; s[3][1] = s[3][2]; s[3][2] = s[3][3]; s[3][3] = t;
  }

  function mixColumns(s) {
    for (var c = 0; c < 4; c++) {
      var a0 = s[0][c], a1 = s[1][c], a2 = s[2][c], a3 = s[3][c];
      s[0][c] = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3;
      s[1][c] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3;
      s[2][c] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3);
      s[3][c] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2);
    }
  }

  function invMixColumns(s) {
    for (var c = 0; c < 4; c++) {
      var a0 = s[0][c], a1 = s[1][c], a2 = s[2][c], a3 = s[3][c];
      s[0][c] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
      s[1][c] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
      s[2][c] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
      s[3][c] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
    }
  }

  function aesEncryptBlock(block, ks) {
    var s = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], r, c, i;
    for (r = 0; r < 4; r++) for (c = 0; c < 4; c++) s[r][c] = block[r + 4 * c] & 0xff;
    addRoundKey(s, ks.w, 0);
    for (i = 1; i < ks.nr; i++) {
      subBytes(s, SBOX); shiftRows(s); mixColumns(s); addRoundKey(s, ks.w, i);
    }
    subBytes(s, SBOX); shiftRows(s); addRoundKey(s, ks.w, ks.nr);
    var out = new Array(16);
    for (c = 0; c < 4; c++) for (r = 0; r < 4; r++) out[r + 4 * c] = s[r][c];
    return out;
  }

  function aesDecryptBlock(block, ks) {
    var s = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], r, c, i;
    for (r = 0; r < 4; r++) for (c = 0; c < 4; c++) s[r][c] = block[r + 4 * c] & 0xff;
    addRoundKey(s, ks.w, ks.nr);
    for (i = ks.nr - 1; i >= 1; i--) {
      invShiftRows(s); subBytes(s, INV_SBOX); addRoundKey(s, ks.w, i); invMixColumns(s);
    }
    invShiftRows(s); subBytes(s, INV_SBOX); addRoundKey(s, ks.w, 0);
    var out = new Array(16);
    for (c = 0; c < 4; c++) for (r = 0; r < 4; r++) out[r + 4 * c] = s[r][c];
    return out;
  }

  function pkcs5Pad(bytes, blockSize) {
    var pad = blockSize - (bytes.length % blockSize);
    var out = bytes.slice();
    for (var i = 0; i < pad; i++) out.push(pad);
    return out;
  }

  function pkcs5Unpad(bytes) {
    if (!bytes.length) return bytes;
    var pad = bytes[bytes.length - 1];
    if (pad < 1 || pad > 16 || pad > bytes.length) return bytes;   // 越界就不动（别静默吞数据）
    return bytes.slice(0, bytes.length - pad);
  }

  function aesCbcEncrypt(data, key, iv, pad) {
    var ks = expandKey(key), bs = 16, out = [];
    var d = pad ? pkcs5Pad(data, bs) : data;
    var prev = iv ? iv.slice(0) : new Array(bs).fill(0);
    for (var off = 0; off < d.length; off += bs) {
      var block = new Array(bs), i;
      for (i = 0; i < bs; i++) block[i] = (d[off + i] || 0) ^ (prev[i] || 0);
      var enc = aesEncryptBlock(block, ks);
      out = out.concat(enc);
      prev = enc;
    }
    return out;
  }

  function aesCbcDecrypt(data, key, iv, unpad) {
    var ks = expandKey(key), bs = 16, out = [];
    var prev = iv ? iv.slice(0) : new Array(bs).fill(0);
    for (var off = 0; off < data.length; off += bs) {
      var block = data.slice(off, off + bs), i, c;
      for (i = 0; i < bs; i++) block[i] = block[i] || 0;
      var dec = aesDecryptBlock(block, ks);
      for (i = 0; i < bs; i++) out.push((dec[i] ^ (prev[i] || 0)) & 0xff);
      prev = block;
    }
    return unpad ? pkcs5Unpad(out) : out;
  }

  function aesEcbEncrypt(data, key, pad) {
    var ks = expandKey(key), bs = 16, out = [];
    var d = pad ? pkcs5Pad(data, bs) : data;
    for (var off = 0; off < d.length; off += bs) {
      var block = d.slice(off, off + bs), i;
      for (i = 0; i < bs; i++) block[i] = block[i] || 0;
      out = out.concat(aesEncryptBlock(block, ks));
    }
    return out;
  }

  function aesEcbDecrypt(data, key, unpad) {
    var ks = expandKey(key), bs = 16, out = [];
    for (var off = 0; off < data.length; off += bs) {
      var block = data.slice(off, off + bs), i;
      for (i = 0; i < bs; i++) block[i] = block[i] || 0;
      out = out.concat(aesDecryptBlock(block, ks));
    }
    return unpad ? pkcs5Unpad(out) : out;
  }

  function cipherProcess(dataB64, keyB64, transform, ivB64, isDecrypt) {
    var t = String(transform || '').toUpperCase();
    var algo = t.split('/')[0];
    var mode = (t.split('/')[1] || 'ECB').toUpperCase();
    var padMode = (t.split('/')[2] || 'PKCS5PADDING').toUpperCase();

    if (algo !== 'AES') {
      throw new Error('cipherProcess: 不支持的算法 ' + algo + '（当前只支持 AES）');
    }
    if (mode !== 'ECB' && mode !== 'CBC') {
      throw new Error('cipherProcess: 不支持的模式 ' + mode + '（当前只支持 ECB/CBC）');
    }
    if (padMode !== 'PKCS5PADDING' && padMode !== 'NOPADDING') {
      throw new Error('cipherProcess: 不支持的填充 ' + padMode + '（当前只支持 PKCS5Padding/NoPadding）');
    }

    var data = b64DecodeToBytes(dataB64);
    var key = b64DecodeToBytes(keyB64);
    var iv = ivB64 ? b64DecodeToBytes(ivB64) : null;
    if (key.length !== 16 && key.length !== 24 && key.length !== 32) {
      throw new Error('cipherProcess: AES 密钥长度非法 ' + key.length + '（需 16/24/32）');
    }
    if (mode === 'CBC' && !iv) {
      throw new Error('cipherProcess: CBC 模式必须有 IV');
    }

    var usePad = padMode === 'PKCS5PADDING';
    var out;
    if (mode === 'CBC') {
      out = isDecrypt ? aesCbcDecrypt(data, key, iv, usePad)
                      : aesCbcEncrypt(data, key, iv, usePad);
    } else {
      out = isDecrypt ? aesEcbDecrypt(data, key, usePad)
                      : aesEcbEncrypt(data, key, usePad);
    }
    return b64EncodeBytes(out);
  }

  // ────────────────────────────────────────────────────────────────────────
  // gzip —— 同步纯 JS 实现
  // ────────────────────────────────────────────────────────────────────────
  //
  // 为什么不用 CompressionStream：它是 **异步** 的（返回 Promise），
  // 而栖阅的 _nativeGzip/_nativeGunzip 是**同步**契约 ——
  // packages_stub 里直接 `var decompressed = _nativeGunzip(rawBytes)` 就当字节数组用。
  // 返回 Promise 会直接把引擎搞坏。
  //
  // 解压：完整 inflate（stored / fixed / dynamic 三种块都支持）
  // 压缩：gzip 容器 + deflate **stored 块**（不压缩，但格式完全合法，
  //       Java GZIPInputStream / Node zlib / unzip 都能解）

  var CRC_TABLE = (function () {
    var t = new Uint32Array(256), c, n, k;
    for (n = 0; n < 256; n++) {
      c = n;
      for (k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })();

  function crc32(bytes) {
    var c = 0xffffffff;
    for (var i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }

  // ---- inflate ----

  var LEN_BASE = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
  var LEN_EXTRA = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
  var DIST_BASE = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
  var DIST_EXTRA = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
  var CLEN_ORDER = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];

  // 规范 Huffman：count[len] = 该长度的码字数，symbol[] 按码值升序
  function buildHuffman(lengths) {
    var MAXBITS = 15, count = [], symbol = [], i, len, left;
    count.length = MAXBITS + 1;
    for (i = 0; i < lengths.length; i++) count[lengths[i]] = (count[lengths[i]] || 0) + 1;
    count[0] = 0;
    var offs = [];
    offs.length = MAXBITS + 2;
    offs[1] = 0;
    // ⚠️ count 是稀疏数组，count[len] 可能是 **undefined** ——
    //    直接参与加法会得到 NaN，然后 NaN 污染所有后续 offs，
    //    最后 symbol[NaN] = i 写到无效键上，整个 symbol 数组全是 undefined，
    //    而且**不报任何错**，只是解出来的全是垃圾。
    for (len = 1; len <= MAXBITS; len++) offs[len + 1] = offs[len] + (count[len] || 0);
    symbol = new Array(lengths.length);
    for (i = 0; i < lengths.length; i++) {
      if (lengths[i]) symbol[offs[lengths[i]]++] = i;
    }
    return { count: count, symbol: symbol };
  }

  function BitReader(data, pos) {
    this.data = data;
    this.pos = pos || 0;
    this.bitBuf = 0;
    this.bitCnt = 0;
  }
  BitReader.prototype.readBit = function () {
    if (this.bitCnt === 0) {
      if (this.pos >= this.data.length) throw new Error('inflate: 数据意外结束');
      this.bitBuf = this.data[this.pos++] & 0xff;
      this.bitCnt = 8;
    }
    var b = this.bitBuf & 1;
    this.bitBuf >>= 1;
    this.bitCnt--;
    return b;
  };
  BitReader.prototype.readBits = function (n) {
    var v = 0, i;
    for (i = 0; i < n; i++) v |= this.readBit() << i;
    return v;
  };
  BitReader.prototype.decode = function (huff) {
    var code = 0, first = 0, index = 0, len, count = huff.count, symbol = huff.symbol;
    for (len = 1; len <= 15; len++) {
      code |= this.readBit();
      var cnt = count[len] || 0;
      if (code - cnt < first) return symbol[index + (code - first)];
      index += cnt;
      first += cnt;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('inflate: 无效的 Huffman 码');
  };
  BitReader.prototype.align = function () { this.bitCnt = 0; this.bitBuf = 0; };

  function fixedTables() {
    var lengths = new Array(288), i;
    for (i = 0; i < 144; i++) lengths[i] = 8;
    for (i = 144; i < 256; i++) lengths[i] = 9;
    for (i = 256; i < 280; i++) lengths[i] = 7;
    for (i = 280; i < 288; i++) lengths[i] = 8;
    var dist = new Array(30);
    for (i = 0; i < 30; i++) dist[i] = 5;
    return { lit: buildHuffman(lengths), dist: buildHuffman(dist) };
  }

  function inflateRaw(data, startPos) {
    var br = new BitReader(data, startPos);
    var out = [];
    var fixed = null;
    var last = 0;
    do {
      last = br.readBit();
      var type = br.readBits(2);
      if (type === 0) {
        // stored
        br.align();
        if (br.pos + 4 > data.length) throw new Error('inflate: stored 块头部不完整');
        var len = data[br.pos] | (data[br.pos + 1] << 8);
        var nlen = data[br.pos + 2] | (data[br.pos + 3] << 8);
        br.pos += 4;
        if ((len ^ 0xffff) !== nlen) throw new Error('inflate: stored 块长度校验失败');
        if (br.pos + len > data.length) throw new Error('inflate: stored 块数据不完整');
        for (var i = 0; i < len; i++) out.push(data[br.pos++] & 0xff);
      } else if (type === 1 || type === 2) {
        var lit, dist;
        if (type === 1) {
          if (!fixed) fixed = fixedTables();
          lit = fixed.lit; dist = fixed.dist;
        } else {
          var hlit = br.readBits(5) + 257;
          var hdist = br.readBits(5) + 1;
          var hclen = br.readBits(4) + 4;
          var clens = new Array(19);
          var k;
          for (k = 0; k < 19; k++) clens[k] = 0;
          for (k = 0; k < hclen; k++) clens[CLEN_ORDER[k]] = br.readBits(3);
          var clHuff = buildHuffman(clens);
          var lengths = new Array(hlit + hdist);
          var idx = 0;
          while (idx < hlit + hdist) {
            var sym = br.decode(clHuff);
            if (sym < 16) { lengths[idx++] = sym; }
            else if (sym === 16) {
              if (idx === 0) throw new Error('inflate: 重复码没有前值');
              var prev = lengths[idx - 1];
              var rep = 3 + br.readBits(2);
              while (rep-- > 0 && idx < lengths.length) lengths[idx++] = prev;
            } else if (sym === 17) {
              var rep17 = 3 + br.readBits(3);
              while (rep17-- > 0 && idx < lengths.length) lengths[idx++] = 0;
            } else {
              var rep18 = 11 + br.readBits(7);
              while (rep18-- > 0 && idx < lengths.length) lengths[idx++] = 0;
            }
          }
          var litLengths = lengths.slice(0, hlit);
          var distLengths = lengths.slice(hlit);
          lit = buildHuffman(litLengths);
          dist = buildHuffman(distLengths);
        }
        // 解码符号
        for (;;) {
          var sym = br.decode(lit);
          if (sym < 256) { out.push(sym); continue; }
          if (sym === 256) break;
          sym -= 257;
          if (sym >= 29) throw new Error('inflate: 无效的长度码 ' + sym);
          var length = LEN_BASE[sym] + br.readBits(LEN_EXTRA[sym]);
          var dsym = br.decode(dist);
          if (dsym >= 30) throw new Error('inflate: 无效的距离码 ' + dsym);
          var distance = DIST_BASE[dsym] + br.readBits(DIST_EXTRA[dsym]);
          if (distance > out.length) throw new Error('inflate: 距离超出已解压数据');
          var start = out.length - distance;
          for (var j = 0; j < length; j++) out.push(out[start + j]);
        }
      } else {
        throw new Error('inflate: 保留的块类型 3');
      }
    } while (!last);
    return { bytes: out, pos: br.pos };
  }

  function gunzipBytes(bytes) {
    var d = toArray(bytes);
    if (d.length < 18) throw new Error('gunzip: 数据太短');
    if ((d[0] & 0xff) !== 0x1f || (d[1] & 0xff) !== 0x8b) throw new Error('gunzip: 不是 gzip 数据');
    if ((d[2] & 0xff) !== 8) throw new Error('gunzip: 不支持的压缩方法 ' + (d[2] & 0xff));
    var flg = d[3] & 0xff;
    var p = 10;
    if (flg & 0x04) {                                   // FEXTRA
      var xlen = d[p] | (d[p + 1] << 8); p += 2 + xlen;
    }
    if (flg & 0x08) {                                   // FNAME
      while (p < d.length && d[p] !== 0) p++;
      p++;
    }
    if (flg & 0x10) {                                   // FCOMMENT
      while (p < d.length && d[p] !== 0) p++;
      p++;
    }
    if (flg & 0x02) { p += 2; }                         // FHCRC
    var r = inflateRaw(d, p);
    // 尾部 8 字节：CRC32 + ISIZE
    var tail = d.length - 8;
    if (tail >= 0) {
      var isize = (d[d.length - 4] | (d[d.length - 3] << 8) | (d[d.length - 2] << 16) | (d[d.length - 1] << 24)) >>> 0;
      if (isize !== (r.bytes.length >>> 0)) {
        throw new Error('gunzip: 长度校验失败（期望 ' + isize + '，实际 ' + r.bytes.length + '）');
      }
    }
    return r.bytes;
  }

  function gzipBytes(bytes) {
    var d = toArray(bytes);
    var out = [];
    var i;
    // gzip header
    out.push(0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff);
    // deflate stored 块（最大 65535 一块）
    var off = 0;
    do {
      var len = Math.min(65535, d.length - off);
      var last = (off + len >= d.length) ? 1 : 0;
      out.push(last);                                   // BFINAL + BTYPE=00
      out.push(len & 0xff, (len >> 8) & 0xff);
      out.push((len ^ 0xffff) & 0xff, ((len ^ 0xffff) >> 8) & 0xff);
      for (i = 0; i < len; i++) out.push(d[off + i]);
      off += len;
    } while (off < d.length);
    // CRC32 + ISIZE
    var c = crc32(d);
    out.push(c & 0xff, (c >>> 8) & 0xff, (c >>> 16) & 0xff, (c >>> 24) & 0xff);
    var n = d.length >>> 0;
    out.push(n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff);
    return out;
  }

  // ────────────────────────────────────────────────────────────────────────
  // JSONPath —— 委托给轻阅自带的 jsonpath.js
  // ────────────────────────────────────────────────────────────────────────

  function jsonPathRead(json, path, suppress) {
    try {
      if (W.JSONPath && typeof W.JSONPath.read === 'function') {
        return W.JSONPath.read(json, path);
      }
      if (W.jsonpath && typeof W.jsonpath.read === 'function') {
        return W.jsonpath.read(json, path);
      }
    } catch (e) {
      if (!suppress) throw e;
    }
    if (suppress) return null;
    throw new Error('jsonPathRead: 找不到 JSONPath 实现');
  }

  // ────────────────────────────────────────────────────────────────────────
  // 注册到 global
  // ────────────────────────────────────────────────────────────────────────

  W._nativeStrToBytes = function (str, charset) {
    return encodeByCharset(str == null ? '' : String(str), charset);
  };

  W._nativeBytesToStr = function (bytes, charset) {
    return decodeByCharset(toArray(bytes), charset || 'UTF-8');
  };

  W._nativeBase64Encode = function (bytes) {
    return b64EncodeBytes(toArray(bytes));
  };

  W._nativeBase64DecodeToBytes = function (str) {
    return b64DecodeToBytes(str);
  };

  W._nativeCipherProcess = cipherProcess;

  W._nativeGzip = function (bytes) { return gzipBytes(bytes); };
  W._nativeGunzip = function (bytes) { return gunzipBytes(bytes); };

  W._nativeJsonPathRead = jsonPathRead;

  W._nativeSleepMillis = function (ms) {
    // JS 单线程没有同步 sleep。栖阅那边是真阻塞。
    // 书源里极少调用，这里用忙等兜底（小数值），大数值直接返回。
    var n = Number(ms) || 0;
    if (n <= 0) return;
    if (n > 50) return;             // 太长不阻塞主线程
    var end = Date.now() + n;
    while (Date.now() < end) { /* 忙等 */ }
  };

  W._nativeBase = function (bytes, from, to) {
    // 编码转换：from → to
    var s = decodeByCharset(toArray(bytes), from || 'UTF-8');
    return encodeByCharset(s, to || 'UTF-8');
  };

  // ────────────────────────────────────────────────────────────────────────
  // java.digestHex —— MessageDigest 依赖它
  // ────────────────────────────────────────────────────────────────────────
  //
  // packages_stub 的 MessageDigest 是这么算摘要的：
  //     if (typeof java !== 'undefined' && java.digestHex) return java.digestHex(text, algorithmName);
  //     if (algorithmName === 'MD5' && ... java.md5Encode) return java.md5Encode(text);
  //     return '';
  //
  // 轻阅的 java-api.js 只有 md5Encode / sha1Encode，**没有 digestHex**：
  //   → MD5 走 md5Encode 能出结果
  //   → SHA-1 / SHA-256 全部落到 `return ''` → digest() 返回**空数组**，
  //     书源拿到的是空字符串，而且**不报任何错**。栖阅原生是有 digestHex 的。
  //
  // 所以这里补上，算法支持 MD5 / SHA-1 / SHA-256（SHA-512 及其以上未实现）。
  // 未知算法返回 ''，与 packages_stub 自身的兜底行为一致 —— 不打断书源执行。

  function sha256hex(bytes) {
    var K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    function rotr(x, n) { return ((x >>> n) | (x << (32 - n))) | 0; }
    var len = bytes.length;
    var withPad = new Uint8Array((((len + 8) >> 6) + 1) * 64);
    withPad.set(bytes);
    withPad[len] = 0x80;
    // ⚠️ SHA-256 的长度字段是**整个 64 位大端**（高 32 位在前，且低 32 位自己也大端）。
    //    MD5 用的是 64 位小端。两种都写错的话：
    //      - 全小端 → 空输入对、非空全错（长度=0 时大小端一样）
    //      - 拆成两个 32 位各自大端 → 低 32 位变成 18 00 00 00，还是错
    var bitsHi = Math.floor(len / 0x20000000), bitsLo = (len << 3) >>> 0;
    var dp = withPad.length - 8;
    withPad[dp]     = (bitsHi >>> 24) & 0xff;
    withPad[dp + 1] = (bitsHi >>> 16) & 0xff;
    withPad[dp + 2] = (bitsHi >>> 8) & 0xff;
    withPad[dp + 3] = bitsHi & 0xff;
    withPad[dp + 4] = (bitsLo >>> 24) & 0xff;
    withPad[dp + 5] = (bitsLo >>> 16) & 0xff;
    withPad[dp + 6] = (bitsLo >>> 8) & 0xff;
    withPad[dp + 7] = bitsLo & 0xff;

    var w = new Int32Array(64), off, i, j;
    for (off = 0; off < withPad.length; off += 64) {
      for (i = 0; i < 16; i++) {
        j = off + i * 4;
        w[i] = (withPad[j] << 24) | (withPad[j + 1] << 16) | (withPad[j + 2] << 8) | withPad[j + 3];
      }
      for (i = 16; i < 64; i++) {
        var x = w[i - 15], y = w[i - 2];
        var s0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >>> 3);
        var s1 = rotr(y, 17) ^ rotr(y, 19) ^ (y >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (i = 0; i < 64; i++) {
        var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        var ch = (e & f) ^ ((~e) & g);
        var t1 = (h + S1 + ch + K[i] + w[i]) | 0;
        var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
      H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    var out = '';
    for (i = 0; i < 8; i++) out += ('00000000' + (H[i] >>> 0).toString(16)).slice(-8);
    return out;
  }

  if (!W.java) W.java = {};
  if (typeof W.java.digestHex !== 'function') {
    W.java.digestHex = function (text, algo) {
      var s = String(text == null ? '' : text);
      var name = String(algo || 'MD5').toUpperCase().replace(/_/g, '-');
      if (name === 'MD5') return typeof W.java.md5Encode === 'function' ? W.java.md5Encode(s) : '';
      if (name === 'SHA-1' || name === 'SHA1') return typeof W.java.sha1Encode === 'function' ? W.java.sha1Encode(s) : '';
      if (name === 'SHA-256' || name === 'SHA256') return sha256hex(utf8Encode(s));
      return '';   // SHA-512 等未实现 —— 与 packages_stub 自身兜底一致，不打断书源
    };
  }

  // 调试/自检出口：让门禁能单独验证 S 盒、密钥扩展、轮函数这些内部件。
  // 定位 AES 出错时，逐层对比 FIPS-197 中间值比黑盒试快得多。
  W.__packagesNativeInternals = {
    SBOX: SBOX, INV_SBOX: INV_SBOX,
    gmul: gmul, xtime: xtime,
    expandKey: expandKey,
    aesEncryptBlock: aesEncryptBlock, aesDecryptBlock: aesDecryptBlock,
    addRoundKey: addRoundKey, subBytes: subBytes,
    shiftRows: shiftRows, invShiftRows: invShiftRows,
    mixColumns: mixColumns, invMixColumns: invMixColumns,
    b64EncodeBytes: b64EncodeBytes, b64DecodeToBytes: b64DecodeToBytes,
    sha256hex: sha256hex,
  };

})(typeof globalThis !== 'undefined' ? globalThis : this);
