// Android StrResponse (+ okhttp Response via raw()). Missing okhttp parts are synthesised:
// priorResponse() is a 302 to the final url when the request url differs (redirect), else null.
var __hdrs = function(h){ h = h || {}; var out = {};
  for (var n in h) out[n] = h[n];
  var find = function(k){ k = String(k).toLowerCase(); for (var n in h) { if (n.toLowerCase() == k) return h[n]; } return null; };
  var def = function(name, fn){ try { Object.defineProperty(out, name, { value: fn, enumerable: false }); } catch (e) { out[name] = fn; } };
  def('get', find);
  def('names', function(){ var a = []; for (var n in h) a.push(n); return a; });
  def('values', function(k){ var v = find(k); return v == null ? [] : String(v).split('\n'); });
  def('toMultimap', function(){ var m = {}; for (var n in h) m[n] = String(h[n]).split('\n'); return m; });
  def('size', function(){ var c = 0; for (var n in h) c++; return c; });
  def('toString', function(){ var a = []; for (var n in h) a.push(n + ': ' + h[n]); return a.join('\n'); });
  return out; };
var __urlObj = function(u){ u = String(u == null ? '' : u); return {
  toString: function(){ return u; }, url: function(){ return u; },
  host: function(){ var m = /^[a-z]+:\/\/([^\/:?#]+)/i.exec(u); return m ? m[1] : ''; },
  encodedPath: function(){ var m = /^[a-z]+:\/\/[^\/?#]*([^?#]*)/i.exec(u); return m && m[1] ? m[1] : '/'; },
  query: function(){ var i = u.indexOf('?'); return i < 0 ? null : u.substring(i + 1).split('#')[0]; } }; };
var __rawResp = function(o, isPrior){
  var code = Number(o.code || 0);
  var reqUrl = String(o.reqUrl || o.url || '');
  var finalUrl = String(o.url || '');
  var self = {
    code: function(){ return code; }, message: function(){ return code >= 200 && code < 300 ? 'OK' : ''; },
    isSuccessful: function(){ return code >= 200 && code < 300; },
    isRedirect: function(){ return [300,301,302,303,307,308].indexOf(code) >= 0; },
    headers: function(){ return __hdrs(o.headers); },
    header: function(k, d){ var v = __hdrs(o.headers).get(k); return v == null ? (d === undefined ? null : d) : v; },
    request: function(){ return { url: function(){ return __urlObj(isPrior ? reqUrl : finalUrl); }, method: function(){ return String(o.method || 'GET'); },
                                 headers: function(){ return __hdrs(o.reqHeaders); }, header: function(k){ return __hdrs(o.reqHeaders).get(k); } }; },
    body: function(){ var b = String(o.body == null ? '' : o.body); return { string: function(){ return b; }, toString: function(){ return b; } }; },
    priorResponse: function(){
      if (isPrior || !reqUrl || reqUrl == finalUrl) return null;
      return __rawResp({ code: 302, url: reqUrl, reqUrl: reqUrl, headers: { Location: finalUrl }, body: '', method: o.method }, true); },
    networkResponse: function(){ return self; }, cacheResponse: function(){ return null; },
    toString: function(){ return 'Response{code=' + code + ', url=' + finalUrl + '}'; } };
  return self; };
var __respWrap = function(o){ o = o || {}; if (typeof o.body === 'function' && typeof o.raw === 'function') return o; return {
  body: function(){ return o.body; }, code: function(){ return o.code; }, statusCode: function(){ return o.code; },
  url: function(){ return o.url; }, headers: function(){ return __hdrs(o.headers); }, raw: function(){ return __rawResp(o, false); },
  message: function(){ return __rawResp(o, false).message(); }, isSuccessful: function(){ return Number(o.code) >= 200 && Number(o.code) < 300; },
  header: function(k){ return __hdrs(o.headers).get(k); },
  cookies: function(){ return o.cookies || {}; }, cookie: function(k){ var c = o.cookies || {}; return c[String(k)] == null ? null : c[String(k)]; },
  hasCookie: function(k){ return (o.cookies || {})[String(k)] != null; },
  toString: function(){ return o.body; } }; };
var __hdrArg = function(h){ if (h == null) return {}; if (h.__obj) return h.__obj; if (typeof h === 'string') { try { return JSON.parse(h); } catch (e) { return {}; } } return h; };
java.connect = function(u, h){ return __respWrap(java.__connect(String(u), h == null ? null : (typeof h === 'string' ? h : JSON.stringify(__hdrArg(h))))); };
java.get = function(a, h){ if (arguments.length >= 2 || /^https?:/.test(String(a))) return __respWrap(java.__http('GET', String(a), null, __hdrArg(h))); return java.__get(String(a)); };
java.post = function(u, b, h){ return __respWrap(java.__http('POST', String(u), b == null ? null : String(b), __hdrArg(h))); };
java.head = function(u, h){ return __respWrap(java.__http('HEAD', String(u), null, __hdrArg(h))); };
java.put = function(k, v){ return java.__put(String(k), v); };
java.ajaxAll = function(us){ var r = []; for (var i = 0; i < us.length; i++) r.push(java.connect(us[i])); return r; };
java.importScript = function(u){ u = String(u);
  // Legado importScript only returns the text (callers eval it themselves): http -> cacheFile, else readTxtFile.
  var s = /^http/.test(u) ? java.cacheFile(u) : java.readTxtFile(u);
  if (s == null || String(s).trim() == '') throw new Error(u + ' 内容获取失败或者为空');
  return String(s); };
java.createSymmetricCrypto = function(t, key, iv){ return {
  encrypt: function(d){ return java.__crypto('enc', t, key, iv, d, 'bytes'); },
  encryptBase64: function(d){ return java.__crypto('enc', t, key, iv, d, 'base64'); },
  encryptHex: function(d){ return java.__crypto('enc', t, key, iv, d, 'hex'); },
  decrypt: function(d){ return java.__crypto('dec', t, key, iv, d, 'bytes'); },
  decryptStr: function(d){ return java.__crypto('dec', t, key, iv, d, 'str'); },
  setIv: function(v){ iv = v; return this; } }; };
java.aesDecodeToString = function(d, k, t, iv){ return java.createSymmetricCrypto(t, k, iv).decryptStr(d); };
java.aesBase64DecodeToString = java.aesDecodeToString;
// Android JsEncodeUtils.aesEncodeToString really calls decryptStr (kept for parity).
java.aesEncodeToString = function(d, k, t, iv){ return java.createSymmetricCrypto(t, k, iv).decryptStr(d); };
java.aesEncodeToBase64String = function(d, k, t, iv){ return java.createSymmetricCrypto(t, k, iv).encryptBase64(d); };
java.desDecodeToString = java.aesDecodeToString; java.desBase64DecodeToString = java.aesDecodeToString;
java.desEncodeToBase64String = java.aesEncodeToBase64String;
java.desEncodeToString = function(d, k, t, iv){ return java.__crypto('enc', t, k, iv, d, 'rawstr'); };
var __isBytes = function(v){ if (v == null || typeof v != 'object') return false;
  if (typeof Int8Array != 'undefined' && (v instanceof Int8Array || v instanceof Uint8Array)) return true;
  if (!Array.isArray(v) || v.length == 0) return false;
  for (var i = 0; i < v.length; i++) { var n = v[i]; if (typeof n != 'number' || n % 1 != 0 || n < -128 || n > 255) return false; }
  return true; };
var cache = { // Android CacheManager
  put: function(k, v, t){ k = String(k); t = Number(t || 0);
    if (__isBytes(v)) __native.xcPutBytes(k, v, t); else __native.xcPut(k, v, t); },
  get: function(k, onlyDisk){ return __native.xcGet(String(k), !!onlyDisk); },
  getInt: function(k){ var v = __native.xcGet(String(k), true); var n = parseInt(v, 10); return (v == null || isNaN(n)) ? null : n; },
  getLong: function(k){ return cache.getInt(k); },
  getDouble: function(k){ var v = __native.xcGet(String(k), true); var n = parseFloat(v); return (v == null || isNaN(n)) ? null : n; },
  getFloat: function(k){ return cache.getDouble(k); },
  getByteArray: function(k){ return __native.xcGetBytes(String(k)); },
  putFile: function(k, v, t){ __native.xcPutFile(String(k), v == null ? '' : String(v), Number(t || 0)); },
  getFile: function(k){ return __native.xcGetFile(String(k)); },
  putMemory: function(k, v){ __native.xcMemPut(String(k), v); },
  getFromMemory: function(k){ return __native.xcMemGet(String(k)); },
  deleteMemory: function(k){ __native.xcMemDel(String(k)); },
  delete: function(k){ __native.xcDel(String(k)); },
  getQueryTTF: function(k){ return null; } };
// [fix10] Android returns java.util.Map from getLoginInfoMap()/getLoginHeaderMap(): sources call
// .get('键') as well as ['键'] / for-in / JSON.stringify. Plain object + non-enumerable Map methods.
var __mapLike = function(o){ if (o == null || typeof o !== 'object') o = {};
  var d = function(n, f){ try { Object.defineProperty(o, n, { value: f, enumerable: false, configurable: true, writable: true }); } catch (e) {} };
  d('get', function(k){ var v = o[String(k)]; return v === undefined ? null : v; });
  d('getOrDefault', function(k, def){ var v = o[String(k)]; return v === undefined || v === null ? def : v; });
  d('put', function(k, v){ var old = o[String(k)]; o[String(k)] = v; return old === undefined ? null : old; });
  d('containsKey', function(k){ return Object.prototype.hasOwnProperty.call(o, String(k)); });
  d('remove', function(k){ var v = o[String(k)]; delete o[String(k)]; return v === undefined ? null : v; });
  d('keySet', function(){ return Object.keys(o); });
  d('values', function(){ return Object.keys(o).map(function(k){ return o[k]; }); });
  d('entrySet', function(){ return Object.keys(o).map(function(k){ return { key: k, value: o[k], getKey: function(){ return k; }, getValue: function(){ return o[k]; } }; }); });
  d('size', function(){ return Object.keys(o).length; });
  d('isEmpty', function(){ return Object.keys(o).length == 0; });
  return o; };
var __mkSource = function(o){ o.getKey = function(){ return o.bookSourceUrl; };
  o.getVariable = function(){ return __native.srcGet('__variable'); }; o.setVariable = function(v){ __native.srcPut('__variable', v == null ? '' : String(v)); };
  o.putVariable = o.setVariable; o.getTag = function(){ return o.bookSourceName; };
  o.evalJS = function(__s){ return eval(String(__s)); };
  o.refreshJSLib = function(){}; o.putConcurrent = function(v){}; o.refreshExplore = function(){ __native.exploreRefresh(); };
  o.getHeaderMap = function(hasLoginHeader){ var m = {}, h = o.header || '';
    try { if (/^@js:/i.test(h)) h = String(eval(h.substring(4)));
          else if (/^<js>/i.test(h)) h = String(eval(h.substring(4, h.lastIndexOf('<'))));
          if (h && String(h).trim()) { var j = JSON.parse(h); for (var k in j) m[k] = String(j[k]); } } catch(e) { java.log('执行请求头规则出错 ' + e); }
    var hasUA = false; for (var n in m) { if (n.toLowerCase() == 'user-agent') hasUA = true; }
    if (!hasUA) m['User-Agent'] = __native.webViewUA();
    if (hasLoginHeader) { var lh = o.getLoginHeaderMap(); if (lh) { for (var q in lh) m[q] = lh[q]; } }
    return m; };
  o.get = function(k){ return __native.srcGet(String(k)); }; o.put = function(k, v){ return __native.srcPut(String(k), v); };
  // ⭐⭐⭐ 一次导出整张书源变量 map（宿主回传用 ⇒ 解锁态要能落盘）⭐⭐⭐
  o.getAllVars = function(){ return __native.srcGetAll(); };
  o.getLoginInfo = function(){ return __native.loginInfoGet(); }; o.getLoginInfoMap = function(){ var m; try { m = JSON.parse(o.getLoginInfo()); } catch(e) { m = null; } return __mapLike(m); };
  o.putLoginInfo = function(v){ return __native.loginInfoPut(typeof v == 'string' ? v : JSON.stringify(v)); };
  o.removeLoginInfo = function(){ __native.loginInfoRemove(); };
  o.getLoginHeader = function(){ return __native.loginHeaderGet(); };
  o.getLoginHeaderMap = function(){ try { var m = JSON.parse(o.getLoginHeader()); return m && typeof m === 'object' ? __mapLike(m) : null; } catch(e) { return null; } };
  o.putLoginHeader = function(v){ __native.loginHeaderPut(typeof v == 'string' ? v : JSON.stringify(v)); };
  o.removeLoginHeader = function(){ __native.loginHeaderRemove(); };
  o.getLoginUi = function(){ return o.__loginUi; }; o.loginUi = o.__loginUi; /* [fix10] Android: a String field, not a method (sources test typeof source.loginUi == 'function' to detect a non-Legado host) */ o.key = o.bookSourceUrl;
  o.getLoginJs = function(){ return __native.loginJs(); };
  o.login = function(){ var __js = __native.loginJs(); if (!__js) return null; eval(__js);
    if (typeof login == 'function') { return login.apply(this); } else { throw('Function login not implements!!!'); } };
  source = o; };
var __mkBook = function(o, name){ o.getVariable = function(k){ return __native.varGet(k == null ? '__' + name + 'Var' : String(k)); };
  o.putVariable = function(k, v){ return __native.varPut(String(k), v); }; o.setVariable = function(v){ __native.varPut('__' + name + 'Var', v); };
  o.setUseReplaceRule = function(v){}; o.getUseReplaceRule = function(){ return true; }; o.setReverseToc = function(v){};
  this[name] = o; };
var source = {}; var book = null; var chapter = null; var result = null; var baseUrl = ''; var key = ''; var page = 1;
// MARK: - Legado 兼容层（Rhino/Java 语义 → 标准 ES）
// 1) Android 的 Elements / 集合有 toArray()，JS 原生数组没有。很多书源对列表结果调 toArray()，
//    直接报 "result.toArray is not a function"。补成返回浅拷贝（不改变原数组）。
if (!Array.prototype.toArray) {
  try { Object.defineProperty(Array.prototype, 'toArray', { value: function(){ return this.slice(); },
    enumerable: false, configurable: true, writable: true }); } catch (e) { Array.prototype.toArray = function(){ return this.slice(); }; }
}
// 同时补 toArrayList / getElements 的常见别称
if (!Array.prototype.toArrayList) {
  try { Object.defineProperty(Array.prototype, 'toArrayList', { value: function(){ return this.slice(); },
    enumerable: false, configurable: true, writable: true }); } catch (e) { Array.prototype.toArrayList = function(){ return this.slice(); }; }
}
// 列表规则的元素在本引擎里是 outerHtml 字符串（Legado 是 Jsoup Element 对象）。
// 书源常对元素调 a.attr(key)（如按 data-* 排序），给 String 补一个从 HTML 解析属性的实现。
if (!String.prototype.attr) {
  // 纯字符串查找，不用正则：避免 Swift 多行字符串与 JS 正则的双重转义。
  var __attrOf = function(html, name){
    var s = String(html), k = String(name), i = 0;
    var isSpace = function(c){ return c == 32 || c == 9 || c == 10 || c == 13; };
    var isNameChar = function(c){ return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 58 || c == 45; };
    var isEnd = function(c){ return isSpace(c) || c == 62; };
    while (true) {
      var p = s.indexOf(k, i);
      if (p < 0) return null;
      var before = p > 0 ? s.charCodeAt(p - 1) : 0;
      if (!isNameChar(before)) {
        var q = p + k.length;
        while (q < s.length && isSpace(s.charCodeAt(q))) q++;
        if (s.charCodeAt(q) == 61) {
          q++;
          while (q < s.length && isSpace(s.charCodeAt(q))) q++;
          var c = s.charCodeAt(q);
          if (c == 34 || c == 39) {   // 双引号或单引号
            var end = s.indexOf(String.fromCharCode(c), q + 1);
            if (end > q) return s.slice(q + 1, end);
          } else {
            var e2 = q;
            while (e2 < s.length && !isEnd(s.charCodeAt(e2))) e2++;
            if (e2 > q) return s.slice(q, e2);
          }
        }
      }
      i = p + 1;
    }
  };
  try { Object.defineProperty(String.prototype, 'attr', {
    value: function(k){ return __attrOf(this, k); }, enumerable: false, configurable: true, writable: true }); }
  catch (e) { try { String.prototype.attr = function(k){ return __attrOf(this, k); }; } catch (e2) {} }
}
// Java 的 String.getBytes()：书源按字节数组做异或/构造 SecretKeySpec。
// 返回有符号 byte 数组（-128..127），ASCII 场景下与 Java 一致。
if (!String.prototype.getBytes) {
  try { Object.defineProperty(String.prototype, 'getBytes', {
    value: function(){ var s = String(this), a = [], j, c;
      for (j = 0; j < s.length; j++) { c = s.charCodeAt(j) & 0xFF; a.push(c > 127 ? c - 256 : c); }
      return a; }, enumerable: false, configurable: true, writable: true }); }
    catch (e) { try { String.prototype.getBytes = function(){ var s = String(this), a = [];
      for (var j = 0; j < s.length; j++) { var c = s.charCodeAt(j) & 0xFF; a.push(c > 127 ? c - 256 : c); }
      return a; }; } catch (e2) {} }
}