// ---- asymmetric crypto / sign (hutool API) ----
var __keyTypePublic = function(u){ if (u == null) return true; if (typeof u == 'boolean') return u;
  var s = String(u && u.name ? u.name : u); return !/priv/i.test(s); };
var __rsaKeyObj = function(k, isPub){ return k == null ? null : {
  getEncoded: function(){ return __native.rsaKeyOut(k, isPub, 'bytes'); }, getAlgorithm: function(){ return 'RSA'; },
  getFormat: function(){ return isPub ? 'X.509' : 'PKCS#8'; }, toString: function(){ return __native.rsaKeyOut(k, isPub, 'base64'); } }; };
java.createAsymmetricCrypto = function(t){ t = String(t == null ? 'RSA' : t); var pub = null, pri = null;
  var gen = function(){ if (pub == null && pri == null) { var k = __native.rsaGen(); if (k) { pub = k.pub; pri = k.pri; } } };
  var run = function(enc, d, u, out){ gen(); var p = __keyTypePublic(u); return __native.rsa(enc, t, p ? pub : pri, p, d, out); };
  var o = {
    setPublicKey: function(k){ pub = k; return o; }, setPrivateKey: function(k){ pri = k; return o; },
    encrypt: function(d, u){ return run(true, d, u, 'bytes'); },
    encryptBase64: function(d, u){ return run(true, d, u, 'base64'); },
    encryptHex: function(d, u){ return run(true, d, u, 'hex'); },
    decrypt: function(d, u){ return run(false, d, u, 'bytes'); },
    decryptStr: function(d, u){ return run(false, d, u, 'str'); },
    getPublicKeyBase64: function(){ gen(); return pub == null ? null : __native.rsaKeyOut(pub, true, 'base64'); },
    getPrivateKeyBase64: function(){ gen(); return pri == null ? null : __native.rsaKeyOut(pri, false, 'base64'); },
    getPublicKey: function(){ gen(); return __rsaKeyObj(pub, true); },
    getPrivateKey: function(){ gen(); return __rsaKeyObj(pri, false); } };
  return o; };
java.createSign = function(alg){ alg = String(alg); var pub = null, pri = null;
  var gen = function(){ if (pub == null && pri == null) { var k = __native.rsaGen(); if (k) { pub = k.pub; pri = k.pri; } } };
  var o = {
    setPublicKey: function(k){ pub = k; return o; }, setPrivateKey: function(k){ pri = k; return o; },
    sign: function(d){ gen(); return __native.rsaSign(alg, pri, d, 'bytes'); },
    signHex: function(d){ gen(); return __native.rsaSign(alg, pri, d, 'hex'); },
    signBase64: function(d){ gen(); return __native.rsaSign(alg, pri, d, 'base64'); },
    verify: function(d, s){ gen(); return __native.rsaVerify(alg, pub, d, s); },
    getPublicKeyBase64: function(){ gen(); return pub == null ? null : __native.rsaKeyOut(pub, true, 'base64'); },
    getPrivateKeyBase64: function(){ gen(); return pri == null ? null : __native.rsaKeyOut(pri, false, 'base64'); },
    getPublicKey: function(){ gen(); return __rsaKeyObj(pub, true); },
    getPrivateKey: function(){ gen(); return __rsaKeyObj(pri, false); } };
  return o; };

// ---- symmetric (JsEncodeUtils deprecated helpers) ----
java.aesDecodeToByteArray = function(s, k, t, iv){ return java.createSymmetricCrypto(t, k, iv).decrypt(s); };
java.aesBase64DecodeToByteArray = java.aesDecodeToByteArray;
java.aesEncodeToByteArray = function(d, k, t, iv){ return java.createSymmetricCrypto(t, k, iv).encrypt(d); };
java.aesEncodeToBase64ByteArray = function(d, k, t, iv){ return java.strToBytes(java.createSymmetricCrypto(t, k, iv).encryptBase64(d)); };
java.aesDecodeArgsBase64Str = function(d, k, m, p, iv){
  return java.createSymmetricCrypto('AES/' + m + '/' + p, java.base64DecodeToByteArray(String(k)) || [], java.base64DecodeToByteArray(String(iv)) || []).decryptStr(d); };
java.aesEncodeArgsBase64Str = function(d, k, m, p, iv){ return java.createSymmetricCrypto('AES/' + m + '/' + p, k, iv).encryptBase64(d); };
java.tripleDESDecodeStr = function(d, k, m, p, iv){ return java.createSymmetricCrypto('DESede/' + m + '/' + p, k, iv).decryptStr(d); };
java.tripleDESEncodeBase64Str = function(d, k, m, p, iv){ return java.createSymmetricCrypto('DESede/' + m + '/' + p, k, iv).encryptBase64(d); };
java.tripleDESDecodeArgsBase64Str = function(d, k, m, p, iv){
  return java.createSymmetricCrypto('DESede/' + m + '/' + p, java.base64DecodeToByteArray(String(k)) || [], java.strToBytes(String(iv))).decryptStr(d); };
java.tripleDESEncodeArgsBase64Str = function(d, k, m, p, iv){
  return java.createSymmetricCrypto('DESede/' + m + '/' + p, java.base64DecodeToByteArray(String(k)) || [], java.strToBytes(String(iv))).encryptBase64(d); };

// ---- misc ----
java.utf8ToGbk = function(s){ return __native.utf8ToGbk(String(s)); };
java.toNumChapter = function(s){ return s == null ? null : __native.toNumChapter(String(s)); };
java.toURL = function(u, base){ var r = __native.toURL(String(u), base == null ? null : String(base));
  if (r == null) throw new Error('MalformedURLException: ' + u);
  r.getHost = function(){ return r.host; }; r.getOrigin = function(){ return r.origin; };
  r.getPathname = function(){ return r.pathname; }; r.getSearchParams = function(){ return r.searchParams; };
  r.toString = function(){ return r.href; }; return r; };
java.getAppVersionName = function(){ return __native.appVersionName(); };
java.getAppVersionCode = function(){ return __native.appVersionCode(); };
java.getAppVariant = function(){ return 'ydr'; };
java.getSource = function(){ return source; };
java.getTag = function(){ return (source && source.bookSourceName) ? source.bookSourceName : null; };
java.getElement = function(r){ return __native.getElement(String(r)); };
java.logType = function(v){ java.log(v == null ? 'null' : (Array.isArray(v) ? 'Array' : (typeof v))); };
java.ajaxTestAll = function(us, t){ return java.ajaxAll(us); };
java.openVideoPlayer = function(u, t){ __native.startBrowser(String(u)); };
java.getVerificationCode = function(u){ throw new Error('iOS 暂不支持 getVerificationCode（验证码输入框）'); };
(function(){ var t0 = java.toast, t1 = java.longToast;
  java.toast = function(m){ return t0((java.getTag() || '源') + ': ' + (m == null ? 'null' : String(m))); };
  java.longToast = function(m){ return t1((java.getTag() || '源') + ': ' + (m == null ? 'null' : String(m))); }; })();

// ---- files / archives (relative to the js cache folder) ----
java.getFile = function(p){ p = String(p); var i = __native.fileInfo(p); var f = {
    exists: function(){ return !!__native.fileInfo(p).exists; },
    isDirectory: function(){ return !!__native.fileInfo(p).isDirectory; },
    isFile: function(){ var x = __native.fileInfo(p); return !!x.exists && !x.isDirectory; },
    length: function(){ return __native.fileInfo(p).length; },
    getName: function(){ return i.name; }, getPath: function(){ return i.path; }, getAbsolutePath: function(){ return i.path; },
    delete: function(){ return __native.deleteFile(p); },
    list: function(){ return __native.fileList(p).map(function(x){ return x.substring(x.lastIndexOf('/') + 1); }); },
    listFiles: function(){ return __native.fileList(p).map(function(x){ return java.getFile(x); }); },
    readText: function(){ return java.readTxtFile(p); }, readBytes: function(){ return java.readFile(p); },
    toString: function(){ return i.path; } };
  return f; };
java.readFile = function(p){ return __native.readFile(String(p)); };
java.readTxtFile = function(p, c){ return __native.readTxtFile(String(p), c == null ? null : String(c)); };
java.deleteFile = function(p){ return __native.deleteFile(String(p)); };
java.downloadFile = function(a, b){ if (arguments.length > 1 && b != null) return __native.downloadFile(String(a), String(b));
  return __native.downloadFile(String(a)); };
java.cacheFile = function(u, t){ u = String(u); var key = java.md5Encode16(u); var p = cache.get(key);
  if (!p || !java.getFile(p).exists()) { p = java.downloadFile(u); java.log('首次下载 ' + u + ' >> ' + p); cache.put(key, p, Number(t || 0)); }
  return java.readTxtFile(p); };
java.unArchiveFile = function(p){ return __native.unArchiveFile(String(p)); };
java.unzipFile = java.unArchiveFile; java.unrarFile = java.unArchiveFile; java.un7zFile = java.unArchiveFile;
java.getTxtInFolder = function(p){ return __native.getTxtInFolder(String(p)); };
java.getZipByteArrayContent = function(u, p){ return __native.zipBytes(String(u), String(p)); };
java.getZipStringContent = function(u, p, c){ var b = java.getZipByteArrayContent(u, p); if (b == null) return '';
  return __native.bytesToText(b, c == null ? null : String(c)); };
// rar / 7z: only zip payloads can be read on iOS (native throws for real rar / 7z data)
java.getRarByteArrayContent = java.getZipByteArrayContent; java.get7zByteArrayContent = java.getZipByteArrayContent;
java.getRarStringContent = java.getZipStringContent; java.get7zStringContent = java.getZipStringContent;

// ---- cookie (CookieStore) ----
cookie.cookieToMap = function(c){ return __native.cookieToMap(c == null ? '' : String(c)); };
cookie.mapToCookie = function(m){ if (m == null) return null; var o = m.__obj ? m.__obj : m, a = [];
  for (var k in o) { if (typeof o[k] != 'function') a.push(k + '=' + o[k]); } return a.length ? a.join('; ') : null; };
cookie.replaceCookie = function(u, c){ if (u == null || c == null) return; __native.cookieReplace(String(u), String(c)); };
cookie.setWebCookie = function(u, c){ __native.cookieSetWeb(String(u), String(c)); };
cookie.clear = function(){ __native.cookieClear(); };