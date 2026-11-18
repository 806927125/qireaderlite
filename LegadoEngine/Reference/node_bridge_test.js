// 验证 JS bootstrap 与原生分发契约（模拟 JSNatives.swift 的参数约定）
const fs = require('fs');
const crypto = require('crypto');
const zlib = require('zlib');
const path = require('path').join(__dirname, '..', 'Sources', 'LegadoEngine', 'JS', 'Resources') + '/';

const vars = {};
const memCache = {};
const infoMap = {};
let srcVar = {};
const logs = [];

function bytesOf(v) {
  if (v == null) return Buffer.alloc(0);
  if (typeof v === 'string') return Buffer.from(v, 'utf8');
  if (Array.isArray(v)) return Buffer.from(v.map(x => x & 0xFF));
  return Buffer.alloc(0);
}
function signed(buf) { return Array.from(buf).map(b => b > 127 ? b - 256 : b); }
function b64d(s) {
  let t = String(s).replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, '');
  while (t.length % 4) t += '=';
  return Buffer.from(t, 'base64');
}
function cipherOut(buf, mode) {
  switch (mode) {
    case 'base64': case 'rawstr': return buf.toString('base64');
    case 'hex': return buf.toString('hex');
    case 'str': return buf.toString('utf8');
    default: return signed(buf);
  }
}
function jCipher(a) {
  const isEnc = a[0] === 'enc' || a[0] === true;
  const t = String(a[1] || 'AES');
  const parts = t.toUpperCase().split('/');
  const alg = parts[0], mode = parts[1] || 'ECB', pad = parts[2] || 'PKCS5PADDING';
  const key = bytesOf(a[2]), iv = bytesOf(a[3]);
  let input;
  if (isEnc) input = bytesOf(a[4]);
  else input = typeof a[4] === 'string' ? b64d(a[4]) : bytesOf(a[4]);
  const outMode = a[5] || 'bytes';
  let nodeAlg;
  if (alg === 'DES') nodeAlg = 'des-' + mode.toLowerCase();
  else if (alg === 'DESEDE' || alg === '3DES') nodeAlg = 'des-ede3-' + mode.toLowerCase();
  else nodeAlg = alg.toLowerCase() + '-' + key.length * 8 + '-' + mode.toLowerCase();
  const noPad = pad.indexOf('NOPADDING') >= 0;
  const c = isEnc ? crypto.createCipheriv(nodeAlg, key, mode === 'ECB' ? null : iv)
                  : crypto.createDecipheriv(nodeAlg, key, mode === 'ECB' ? null : iv);
  c.setAutoPadding(!noPad && (mode === 'ECB' || mode === 'CBC'));
  const out = Buffer.concat([c.update(input), c.final()]);
  return cipherOut(out, outMode);
}
function digest(alg, buf) {
  const name = alg.toUpperCase().replace(/-/g, '');
  return crypto.createHash(name === 'SHA1' ? 'sha1' : name.toLowerCase()).update(buf).digest();
}
function elDict(tag, text, html, outer, attrs) {
  return { tag, text, html, outer, ownText: text, data: '', attrs: attrs || {} };
}

function nativeCall(name, a) {
  switch (name) {
    case 'b64Bytes': return bytesOf(a[0]).toString('base64');
    case 'hexBytes': return bytesOf(a[0]).toString('hex');
    case 'jDigest': return signed(digest(a[0], bytesOf(a[1])));
    case 'jHmac': {
      const alg = a[0].toUpperCase().replace('HMAC', '').replace(/-/g, '');
      return signed(crypto.createHmac(alg.toLowerCase(), bytesOf(a[1])).update(bytesOf(a[2])).digest());
    }
    case 'jCipher': return jCipher(a);
    case 'jGzip': return signed(zlib.gzipSync(bytesOf(a[0])));
    case 'jGunzip': return signed(zlib.gunzipSync(bytesOf(a[0])));
    case 'jDeflate': return signed(a[1] ? zlib.deflateRawSync(bytesOf(a[0])) : zlib.deflateSync(bytesOf(a[0])));
    case 'jInflate': return signed(a[1] ? zlib.inflateRawSync(bytesOf(a[0])) : zlib.inflateSync(bytesOf(a[0])));
    case 'jRandomBytes': return signed(crypto.randomBytes(a[0] | 0));
    case 'jCrc32': { const z = require('zlib'); return z.crc32 ? z.crc32(bytesOf(a[1]), a[0] | 0) : 0; }
    case 'xcPut': memCache[a[0]] = String(a[1]); return null;
    case 'xcGet': return memCache[a[0]] != null ? memCache[a[0]] : null;
    case 'xcDel': delete memCache[a[0]]; return null;
    case 'xcMemPut': memCache['@' + a[0]] = String(a[1]); return null;
    case 'xcMemGet': return memCache['@' + a[0]] != null ? memCache['@' + a[0]] : null;
    case 'xcMemDel': delete memCache['@' + a[0]]; return null;
    case 'varGet': return vars[a[0]] || '';
    case 'varPut': vars[a[0]] = String(a[1]); return null;
    case 'srcGet': return a[0] === '__variable' ? JSON.stringify(srcVar) : (srcVar[a[0]] || '');
    case 'srcPut': if (a[0] === '__variable') { try { srcVar = JSON.parse(a[1] || '{}'); } catch (e) {} } else srcVar[a[0]] = String(a[1]); return null;
    case 'loginInfoGet': return srcVar['loginInfo'] || '';
    case 'loginInfoPut': srcVar['loginInfo'] = String(a[0]); return null;
    case 'loginInfoRemove': delete srcVar['loginInfo']; return null;
    case 'loginHeaderGet': return srcVar['loginHeader'] || '';
    case 'loginHeaderPut': srcVar['loginHeader'] = String(a[0]); return null;
    case 'loginHeaderRemove': delete srcVar['loginHeader']; return null;
    case 'loginJs': return '';
    case 'infoMapGet': return infoMap[a[0]] != null ? infoMap[a[0]] : null;
    case 'infoMapPut': if (a[1] == null) delete infoMap[a[0]]; else infoMap[a[0]] = String(a[1]); return null;
    case 'infoMapAll': return JSON.stringify(infoMap);
    case 'cookieToMap': { const m = {}; String(a[0] || '').split(';').forEach(p => { const i = p.indexOf('='); if (i > 0) m[p.slice(0, i).trim()] = p.slice(i + 1).trim(); }); return m; }
    case 'cookieClear': case 'cookieReplace': case 'cookieSetWeb': return null;
    case 'webViewUA': return 'TestUA';
    case 'appVersionName': return '1.0.7';
    case 'appVersionCode': return 107;
    case 'sleep': return null;
    case 'utf8ToGbk': return signed(Buffer.from(String(a[0]), 'utf8'));
    case 'toNumChapter': return String(a[0]);
    case 'toURL': { const u = new URL(a[0], a[1] || undefined); return { href: u.href, host: u.host, origin: u.origin, pathname: u.pathname, searchParams: {}, protocol: u.protocol }; }
    case 'jsoupDoc': return elDict('#root', a[0].replace(/<[^>]+>/g, ''), a[0], a[0], {});
    case 'jsoupSelect': {
      // 极简 stub：只支持 'p' / '.x'，验证 __jsEl 包装链路
      const html = String(a[0]), css = String(a[1]);
      const out = [];
      const re = /<(\w+)([^>]*)>([\s\S]*?)<\/\1>/g; let m;
      while ((m = re.exec(html))) {
        const attrs = {}; const ar = /([\w-]+)\s*=\s*"([^"]*)"/g; let am;
        while ((am = ar.exec(m[2]))) attrs[am[1]] = am[2];
        if (css === m[1] || css === 'p') out.push(elDict(m[1], m[3].replace(/<[^>]+>/g, ''), m[3], m[0], attrs));
      }
      return out;
    }
    case 'jsoupChildren': return [];
    case 'jsoupRemove': return elDict('body', '', '', String(a[0]), {});
    case 'jsoupAbs': return String(a[1]);
    case 'getElement': return null;
    case 'getElements': return [];
    case 'fileInfo': return { exists: false, isDirectory: false, length: 0 };
    case 'fileList': return [];
    case 'readFile': case 'readTxtFile': case 'downloadFile': case 'deleteFile': return null;
    case 'getTxtInFolder': return null;
    case 'unArchiveFile': case 'zipBytes': return null;
    case 'rsaGen': return null;
    case 'rsa': case 'rsaSign': case 'rsaVerify': case 'rsaKeyOut': return null;
    default:
      if (/^(bmp|ttf)/.test(name)) return null;
      return null;
  }
}
function javaCall(name, a) {
  switch (name) {
    case 'log': logs.push(String(a[0])); return null;
    case 'toast': case 'longToast': logs.push(String(a[0])); return null;
    case 'base64Encode': return Buffer.from(String(a[0]), 'utf8').toString('base64');
    case 'base64DecodeToByteArray': return signed(b64d(a[0]));
    case 'base64Decode': case 'base64DecodeToString': return b64d(a[0]).toString('utf8');
    case 'md5Encode': return digest('MD5', Buffer.from(String(a[0]), 'utf8')).toString('hex');
    case 'md5Encode16': return digest('MD5', Buffer.from(String(a[0]), 'utf8')).toString('hex').slice(8, 24);
    case 'strToBytes': return signed(Buffer.from(String(a[0]), 'utf8'));
    case 'bytesToStr': case 'bytesToText': return bytesOf(a[0]).toString('utf8');
    case 'randomUUID': return crypto.randomUUID();
    case 'encodeURI': return encodeURIComponent(String(a[0])).replace(/%20/g, '+');
    case '__get': return vars[a[0]] || '';
    case '__put': vars[a[0]] = String(a[1]); return null;
    case '__crypto': return jCipher(a);
    case 'timeFormat': return '2026-11-18';
    case 'androidId': return '0123456789abcdef';
    default: return nativeCall(name, a);
  }
}

// 与 JSBridge.installDispatchers 相同的 Proxy 结构
global.__nativeCall = (n, args) => nativeCall(n, args);
global.__javaCall = (n, args) => javaCall(n, args);
global.__cookieCall = (n, args) => nativeCall(n, args);
eval(`
var __native = new Proxy({}, { get: function(t, k){
    if (typeof k !== 'string') return undefined;
    return function(){ return __nativeCall(k, Array.prototype.slice.call(arguments)); }; } });
var java = new Proxy({}, {
  get: function(t, k){ if (k in t) return t[k];
    if (typeof k !== 'string') return undefined;
    return function(){ return __javaCall(k, Array.prototype.slice.call(arguments)); }; },
  set: function(t, k, v){ t[k] = v; return true; },
  has: function(t, k){ return k in t; } });
var cookie = new Proxy({}, {
  get: function(t, k){ if (k in t) return t[k];
    if (typeof k !== 'string') return undefined;
    return function(){ return __cookieCall(k, Array.prototype.slice.call(arguments)); }; },
  set: function(t, k, v){ t[k] = v; return true; } });
`);

for (const f of ['01_core.js', '02_graphics.js', '03_response.js', '04_crypto.js', '05_ttf.js']) {
  eval(fs.readFileSync(path + f, 'utf8'));
}
// loadBootstrap 的命名空间合并
eval(`(function(){ var have = Object.keys(java);
  for (var k in Packages.java) { if (have.indexOf(k) < 0) java[k] = Packages.java[k]; }
  if (typeof android === 'undefined') { android = Packages.android; }
})();`);

// Rhino 预处理（与 JSBridge.rhinoPreprocess 相同正则）
function rhinoPreprocess(s) {
  s = s.replace(/([\w$\]\)]+)\.length\(\)/g, '$1.length');
  s = s.replace(/((?:^|[(,=:?&|!;{}\n])\s*|\breturn\s+)(\[[\w$\s,]*\]|\{[\w$\s,:]*\})\s*=>/gm, '$1($2) =>');
  return s;
}
function E(s) { return eval(rhinoPreprocess(s)); }

let pass = 0, fail = 0;
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; }
  else { fail++; console.log('FAIL ' + name + ': got ' + g + ' want ' + w); }
}

eq('base64Encode', E("java.base64Encode('abc')"), 'YWJj');
eq('base64Decode', E("java.base64Decode('YWJj')"), 'abc');
eq('md5', E("java.md5Encode('abc')"), '900150983cd24fb0d6963f7d28e17f72');
eq('md516', E("java.md5Encode16('abc')"), '3cd24fb0d6963f7d');
eq('aes-ecb-roundtrip', E("java.aesDecodeToString(java.aesEncodeToBase64String('hello','1234567890123456','AES/ECB/PKCS5Padding',null),'1234567890123456','AES/ECB/PKCS5Padding',null)"), 'hello');
eq('aes-cbc-roundtrip', E("java.aesDecodeToString(java.aesEncodeToBase64String('你好世界','1234567890123456','AES/CBC/PKCS5Padding','6543210987654321'),'1234567890123456','AES/CBC/PKCS5Padding','6543210987654321')"), '你好世界');
eq('aes-createSymmetric', E("var c = java.createSymmetricCrypto('AES/ECB/PKCS5Padding','1234567890123456',null); c.decryptStr(c.encryptBase64('xyz'))"), 'xyz');
eq('des-roundtrip', E("java.desDecodeToString(java.desEncodeToBase64String('des测试','12345678','DES/ECB/PKCS5Padding',null),'12345678','DES/ECB/PKCS5Padding',null)"), 'des测试');
eq('hmac-sha256', E("java.bytesToStr(__native.jHmac('HmacSHA256', java.strToBytes('key'), java.strToBytes('msg')))").length > 0, true);
eq('digest-sha256', E("__native.jDigest('SHA-256', java.strToBytes('abc')).length"), 32);
eq('cache', E("cache.put('k1','v1'); cache.get('k1')"), 'v1');
eq('cache-memory', E("cache.putMemory('k2','v2'); cache.getFromMemory('k2')"), 'v2');
eq('put-get', E("java.put('kk','vv'); java.get('kk')"), 'vv');
eq('jsoup', E("org.jsoup.Jsoup.parse('<p>hi</p>').select('p').text()"), 'hi');
eq('jsoup-attr', E("org.jsoup.Jsoup.parse('<a href=\"/x\">l</a>').selectFirst('a').attr('href')"), '/x');
eq('length()', E("var s = 'abc'; s.length()"), 3);
eq('arrow', E("var f = x => x * 2; f(3)"), 6);
eq('base64-class', E("typeof android.util.Base64.encodeToString"), 'function');
eq('android-base64', E("android.util.Base64.encodeToString(java.strToBytes('abc'), 0)"), 'YWJj');
eq('BigInteger', E("new java.math.BigInteger('ff', 16).toString(10)"), '255');
eq('String-java', E("String(new java.lang.String('abc'))"), 'abc');
eq('URLEncoder', E("java.net.URLEncoder.encode('a b','UTF-8')"), 'a+b');
eq('UUID', E("String(java.util.UUID.randomUUID()).length"), 36);
eq('gzip-roundtrip', E("java.bytesToStr(__native.jGunzip(__native.jGzip(java.strToBytes('压缩测试abc'))))"), '压缩测试abc');
eq('deflate-roundtrip', E("java.bytesToStr(__native.jInflate(__native.jDeflate(java.strToBytes('deflate测试'), true), true))"), 'deflate测试');
eq('zlib-roundtrip', E("java.bytesToStr(__native.jInflate(__native.jDeflate(java.strToBytes('zlib测试'), false), false))"), 'zlib测试');
eq('strResponse', E("var r = __respWrap({body:'b',code:200,url:'https://x.com',headers:{},cookies:{}}); r.body()"), 'b');
eq('source-mk', E("__mkSource({bookSourceUrl:'https://s.com',bookSourceName:'S',header:'{\"A\":\"1\"}'}); source.getKey()"), 'https://s.com');
eq('source-headerMap', E("source.getHeaderMap(false)['A']"), '1');
eq('book-mk', E("var b = {name:'B',bookUrl:'https://b.com'}; __mkBook(b,'book'); b.putVariable('t','1'); b.getVariable('t')"), '1');
eq('cookieToMap', E("cookie.cookieToMap('a=1; b=2')['b']"), '2');
eq('infoMap', E("java.infoMapPut ? (java.infoMapPut('x','y'), java.infoMapGet('x')) : null"), 'y');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);