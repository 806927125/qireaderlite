var __jsEl = function(d, frag, base){ var e = {};
  e.__d = d; e.__frag = frag; e.__base = base || '';
  e.__refresh = function(nd){ e.__d = nd; };
  e.text = function(){ return e.__d.text || ''; };
  e.html = function(){ return e.__d.html || ''; };
  e.outerHtml = function(){ return e.__d.outer || ''; };
  e.ownText = function(){ return e.__d.ownText || ''; };
  e.data = function(){ return e.__d.data || ''; };
  e.tagName = function(){ return e.__d.tag || ''; }; e.nodeName = e.tagName;
  e.attr = function(k, v){ k = String(k);
    if (arguments.length > 1) { e.__d.attrs[k] = String(v); return e; }
    if (k.indexOf('abs:') == 0) return __native.jsoupAbs(e.__base, String(e.__d.attrs[k.slice(4)] || ''));
    var a = e.__d.attrs || {}; return a[k] == null ? '' : a[k]; };
  e.absUrl = function(k){ return e.attr('abs:' + k); };
  e.hasAttr = function(k){ return (e.__d.attrs || {})[String(k)] != null; };
  e.id = function(){ return e.attr('id'); };
  e.className = function(){ return e.attr('class'); };
  e.hasClass = function(c){ return (' ' + e.attr('class') + ' ').indexOf(' ' + c + ' ') >= 0; };
  e.val = function(){ return e.attr('value'); };
  e.select = function(c){ c = String(c); return __jsEls(__native.jsoupSelect(e.__d.outer, c, e.__frag, e.__base), e, c); };
  e.selectFirst = function(c){ var r = e.select(c); return r.length ? r[0] : null; };
  e.getElementsByTag = function(t){ return e.select(String(t)); };
  e.getElementsByClass = function(c){ return e.select('.' + c); };
  e.getElementById = function(i){ return e.selectFirst('#' + i); };
  e.children = function(){ return __jsEls(__native.jsoupChildren(e.__d.outer, true), null, null); };
  e.child = function(i){ return e.children()[i]; };
  e.title = function(){ if (e.__d.title != null) return e.__d.title; var t = e.selectFirst('title'); return t ? t.text() : ''; };
  e.body = function(){ return e.selectFirst('body') || e; };
  e.head = function(){ return e.selectFirst('head'); };
  e.remove = function(){ return e; };
  e.toString = function(){ return e.__d.outer || ''; };
  return e; };
var __jsEls = function(list, parent, css){ var a = [];
  list = list || [];
  for (var i = 0; i < list.length; i++) a.push(__jsEl(list[i], true, parent ? parent.__base : ''));
  a.size = function(){ return a.length; };
  a.get = function(i){ return a[i]; };
  a.first = function(){ return a.length ? a[0] : null; };
  a.last = function(){ return a.length ? a[a.length - 1] : null; };
  a.isEmpty = function(){ return a.length == 0; };
  a.eq = function(i){ return __jsEls(a[i] ? [a[i].__d] : [], parent, null); };
  a.text = function(){ return a.map(function(x){ return x.text(); }).join(' '); };
  a.html = function(){ return a.map(function(x){ return x.html(); }).join('\n'); };
  a.outerHtml = function(){ return a.map(function(x){ return x.outerHtml(); }).join('\n'); };
  a.toString = a.outerHtml;
  a.eachText = function(){ return a.map(function(x){ return x.text(); }); };
  a.eachAttr = function(k){ return a.filter(function(x){ return x.hasAttr(k); }).map(function(x){ return x.attr(k); }); };
  a.attr = function(k){ for (var i = 0; i < a.length; i++) { if (a[i].hasAttr(String(k).replace(/^abs:/, ''))) return a[i].attr(k); } return ''; };
  a.hasAttr = function(k){ return a.some(function(x){ return x.hasAttr(k); }); };
  a.select = function(c){ var out = [], subs = [];
    a.forEach(function(x){ var r = x.select(c); subs.push(r); r.forEach(function(y){ out.push(y.__d); }); });
    var res = __jsEls(out, null, null);
    res.remove = function(){ subs.forEach(function(r){ r.remove(); }); return res; };
    return res; };
  a.remove = function(){ if (parent && css) parent.__refresh(__native.jsoupRemove(parent.__d.outer, css, parent.__frag, parent.__base)); return a; };
  return a; };
var org = { jsoup: { Jsoup: {
  parse: function(h, base){ h = h == null ? '' : String(h); base = base == null ? '' : String(base);
    return __jsEl(__native.jsoupDoc(h, base), false, base); },
  parseBodyFragment: function(h, base){ return __jsEl({ outer: String(h), html: String(h), text: '', attrs: {} }, true, base || ''); },
  clean: function(h){ return String(h); } } } };
var __HashMap = function(){ var m = { __obj: {} };
  m.put = function(k, v){ m.__obj[String(k)] = v; return v; };
  m.get = function(k){ return m.__obj[String(k)]; };
  m.containsKey = function(k){ return m.__obj.hasOwnProperty(String(k)); };
  m.remove = function(k){ var v = m.__obj[String(k)]; delete m.__obj[String(k)]; return v; };
  m.keySet = function(){ return Object.keys(m.__obj); };
  m.size = function(){ return Object.keys(m.__obj).length; };
  m.toString = function(){ return JSON.stringify(m.__obj); };
  return m; };
var __ArrayList = function(){ var a = []; a.add = function(v){ a.push(v); return true; }; a.size = function(){ return a.length; };
  a.get = function(i){ return a[i]; }; return a; };
var __StrResponse = function(url, body){ return { url: function(){ return String(url); }, body: function(){ return body == null ? '' : String(body); },
  code: function(){ return 200; }, statusCode: function(){ return 200; }, headers: function(){ return {}; }, toString: function(){ return body == null ? '' : String(body); } }; };
var __JURL = function(u){ var m = String(u).match(/^([a-zA-Z][\w+.-]*):\/\/([^\/:?#]*)(?::(\d+))?([^?#]*)(?:\?([^#]*))?/) || [];
  return { getProtocol: function(){ return m[1] || ''; }, getHost: function(){ return m[2] || ''; },
    getPort: function(){ return m[3] ? parseInt(m[3]) : -1; }, getPath: function(){ return m[4] || ''; },
    getQuery: function(){ return m[5] == null ? null : m[5]; }, toString: function(){ return String(u); } }; };
__JURL.__name = 'URL';
var __Base64 = { __name: 'Base64', DEFAULT: 0, NO_WRAP: 2, URL_SAFE: 8, NO_PADDING: 1,
  encodeToString: function(b, f){ var s = (typeof b == 'string') ? java.base64Encode(b) : __native.b64Bytes(b);
    if (f & 8) s = s.replace(/\+/g, '-').replace(/\//g, '_'); if (f & 1) s = s.replace(/=+$/, ''); return s; },
  encode: function(b, f){ return java.strToBytes(__Base64.encodeToString(b, f)); },
  decode: function(s, f){ return java.base64DecodeToByteArray(String(s)); } };
var __JString = function(s, c){ return (typeof s == 'string') ? s : java.bytesToStr(s, c || 'utf-8'); };
__JString.__name = 'String'; __JString.valueOf = function(v){ return String(v); }; __JString.format = function(f){ return String(f); };
var __JUUID = { __name: 'UUID',
  randomUUID: function(){ var u = String(java.randomUUID ? java.randomUUID() : '').toLowerCase();
    if (!u) u = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c){ var r = Math.random() * 16 | 0; return (c == 'x' ? r : (r & 3 | 8)).toString(16); });
    return { toString: function(){ return u; }, valueOf: function(){ return u; } }; },
  fromString: function(x){ var u = String(x).toLowerCase(); return { toString: function(){ return u; } }; },
  nameUUIDFromBytes: function(b){ var h = java.md5Encode(typeof b == 'string' ? b : java.bytesToStr(b, 'utf-8'));
    var c = h.split(''); c[12] = '3'; c[16] = ((parseInt(c[16], 16) & 3) | 8).toString(16); h = c.join('');
    var u = h.substr(0,8)+'-'+h.substr(8,4)+'-'+h.substr(12,4)+'-'+h.substr(16,4)+'-'+h.substr(20,12); return { toString: function(){ return u; } }; } };
var Packages = { org: org, android: { util: { Base64: __Base64 } },
  java: { util: { HashMap: __HashMap, LinkedHashMap: __HashMap, ArrayList: __ArrayList, UUID: __JUUID,
                  Date: function(t){ return t === undefined ? new Date() : new Date(Number(t)); },
                  Random: function(){ return { nextInt: function(n){ return n === undefined ? ((Math.random() * 4294967296) | 0) : Math.floor(Math.random() * n); },
                                               nextDouble: function(){ return Math.random(); }, nextBoolean: function(){ return Math.random() < 0.5; },
                                               nextLong: function(){ return Math.floor((Math.random() - 0.5) * 9007199254740991); } }; },
                  Arrays: { asList: function(){ return Array.prototype.slice.call(arguments.length == 1 && Array.isArray(arguments[0]) ? arguments[0] : arguments); } } },
          lang: { String: __JString, Math: Math, Integer: { parseInt: function(v, r){ return parseInt(String(v), r || 10); }, valueOf: function(v){ return parseInt(String(v), 10); }, toString: function(v, r){ return Number(v).toString(r || 10); }, MAX_VALUE: 2147483647, MIN_VALUE: -2147483648 },
                  Long: { parseLong: function(v){ return parseInt(String(v), 10); }, valueOf: function(v){ return parseInt(String(v), 10); } }, Double: { parseDouble: function(v){ return parseFloat(String(v)); } }, Boolean: { parseBoolean: function(v){ return String(v).toLowerCase() == 'true'; } }, Thread: { sleep: function(ms){ __native.sleep(Number(ms)); } },
                  System: { currentTimeMillis: function(){ return Date.now(); } } },
          net: { URL: __JURL, URLEncoder: { encode: function(s, c){ return java.encodeURI(String(s), c || 'UTF-8'); } },
                 URLDecoder: { decode: function(s){ return decodeURIComponent(String(s).replace(/\+/g, ' ')); } } } },
  io: { legado: { app: { help: { http: { StrResponse: __StrResponse } } } } } };
var JavaImporter = function(){ var imp = {};
  imp.importClass = function(c){ if (c && c.__name) imp[c.__name] = c; };
  imp.importPackage = function(){};
  for (var i = 0; i < arguments.length; i++) imp.importClass(arguments[i]);
  return imp; };
var importClass = function(c){ if (c && c.__name) this[c.__name] = c; };
var importPackage = function(){};
java.refreshExplore = function(){ __native.exploreRefresh(); }; java.refreshBookInfo = function(){}; java.refreshToc = function(){}; java.refreshContent = function(){};
// 阅读R SourceLoginJsExtensions.showBrowser(url, html, preloadJs, config): html (when given) is shown with url as base.
java.showBrowser = function(u, h, p, c){ __native.showBrowserHtml(String(u), h == null ? null : String(h), p == null ? null : String(p), c == null ? null : (typeof c == 'string' ? c : JSON.stringify(c))); };
// 阅读R SourceLoginJsExtensions.reLoginView(): redraw the login form. Sources also feature-detect 阅读R with it.
java.reLoginView = function(d){ __native.reLoginView(); };
// [fix11] 阅读R RssJsExtensions.open(name, url, title, origin): "login" opens the source login form.
java.open = function(n, u, t, o){ __native.openUi(String(n), u == null ? null : String(u), t == null ? null : String(t), o == null ? null : String(o)); };
// Legado java.searchBook(key, searchScope): scope "name::sourceUrl", a group, or a source object.
java.searchBook = function(k, s){ var sc = null;
  if (s != null) { sc = (typeof s == 'object' && s.bookSourceUrl) ? (String(s.bookSourceName || '') + '::' + String(s.bookSourceUrl)) : String(s); }
  __native.searchBook(k == null ? '' : String(k), sc); };
// Legado discover infoMap (InfoMap: a MutableMap read with infoMap['k'] / infoMap.get('k')).
if (typeof Proxy == 'function') {
  this.infoMap = new Proxy({}, {
    get: function(t, k){
      if (typeof k != 'string') return undefined;
      if (k == 'get') return function(x){ var v = __native.infoMapGet(String(x)); return v == null ? null : v; };
      if (k == 'put') return function(x, v){ return __native.infoMapPut(String(x), v == null ? null : String(v)); };
      if (k == 'remove') return function(x){ __native.infoMapPut(String(x), null); };
      if (k == 'containsKey') return function(x){ return __native.infoMapGet(String(x)) != null; };
      if (k == 'save' || k == 'saveNow') return function(){};
      if (k == 'toJSON') return function(){ return JSON.parse(__native.infoMapAll() || '{}'); };
      if (k == 'toString') return function(){ return __native.infoMapAll() || '{}'; };
      var v = __native.infoMapGet(k); return v == null ? undefined : v;
    },
    set: function(t, k, v){ __native.infoMapPut(String(k), v == null ? null : String(v)); return true; },
    has: function(t, k){ return typeof k == 'string' && __native.infoMapGet(k) != null; },
    deleteProperty: function(t, k){ __native.infoMapPut(String(k), null); return true; },
    ownKeys: function(){ try { return Object.keys(JSON.parse(__native.infoMapAll() || '{}')); } catch (e) { return []; } },
    getOwnPropertyDescriptor: function(t, k){ var v = __native.infoMapGet(String(k)); return v == null ? undefined : { value: v, enumerable: true, configurable: true, writable: true }; }
  });
}
java.startBrowserDp = function(u){ __native.startBrowser(String(u)); };
java.showReadingBrowser = function(u){ __native.startBrowser(String(u)); };
java.openUrl = function(u){ __native.startBrowser(String(u)); };
java.getWebViewUA = function(){ return __native.webViewUA(); };
java.startBrowser = function(u, t){ __native.startBrowserTitled(String(u), t == null ? '' : String(t)); };
// Legado: only the ✓ button returns the page; closing / cancelling throws.
java.startBrowserAwait = function(u, t, refetch, html){ var h = __native.startBrowserAwait(String(u), t == null ? '' : String(t), html == null ? null : String(html));
  if (h == null) throw new Error('验证结果为空（未点击完成）');
  return __respWrap({ body: String(h), code: 200, url: String(u), headers: {} }); };
java.webView = function(h, u, js){ var s = js == null ? null : String(js); if (s != null && /^\d+$/.test(s)) s = null;
  var url = u == null ? null : String(u); if (url != null && !/^https?:/i.test(url)) url = null;
  return __native.webView(h == null ? null : String(h), url || (source && source.bookSourceUrl) || null, s, arguments.length > 3 && typeof arguments[3] == 'string' ? arguments[3] : null); };
// webViewGetSource(html, url, js, sourceRegex[, cacheFirst]): first loaded resource url matching sourceRegex.
java.webViewGetSource = function(h, u, js, re){ return java.webView(h, u, js, re == null ? null : String(re)); };
// iOS approximation: WKWebView navigation overrides are not observed; sniffs loaded resource urls instead.
java.webViewGetOverrideUrl = java.webViewGetSource;
java.getElements = function(r){ return __native.getElements(String(r)); };
java.upLoginData = function(m){ var o = source.getLoginInfoMap ? source.getLoginInfoMap() : {}; var obj = (m && m.__obj) ? m.__obj : (m || {});
  for (var k in obj) o[k] = obj[k]; if (source.putLoginInfo) source.putLoginInfo(o); };
java.hexDecodeToByteArray = function(s){ return __native.hexBytes(String(s)); };
// ---- Rhino `Packages.*` Java class shims (JSExtJava.swift). Byte arrays are plain JS arrays of signed numbers.
var __jIsStr = function(v){ return v != null && typeof v == 'object' && v.__jstr === true; };
var __jText = function(v){ return v == null ? null : (__jIsStr(v) ? v.__t : String(v)); };
var __jArr = function(v){ if (v == null) return [];
  if (typeof v == 'string' || __jIsStr(v)) return java.strToBytes(__jText(v), 'UTF-8');
  if (Array.isArray(v)) return v;
  if (typeof v == 'object' && v.__bytes != null) return __jArr(v.__bytes);
  if (typeof v == 'object' && typeof v.length == 'number') return Array.prototype.slice.call(v);
  return []; };
// Java 的 new String(byte[]) / String(byte[]) 是按字节 UTF-8 解码，而 JS 的
// String(array) 只是逗号拼接数字。给字节数组挂不可枚举的 toString，使
// String(Arrays.copyOfRange(...)) 与 String(cipher.doFinal(...)) 得到原始文本。
var __jByteString = function(a){
  if (!Array.isArray(a) || a.length == 0 || a.length > 65536) return a;
  var i, n;
  for (i = 0; i < a.length; i++) { n = a[i];
    if (typeof n != 'number' || n % 1 != 0 || n < -128 || n > 255) return a; }
  var s = '', j = 0, b, b2, b3;
  while (j < a.length) {
    b = ((Number(a[j]) % 256) + 256) % 256;
    if (b < 0x80) { s += String.fromCharCode(b); j++; }
    else if (b >= 0xC0 && b < 0xE0 && j + 1 < a.length) {
      b2 = ((Number(a[j+1]) % 256) + 256) % 256;
      s += String.fromCharCode(((b & 0x1F) << 6) | (b2 & 0x3F)); j += 2; }
    else if (b >= 0xE0 && b < 0xF0 && j + 2 < a.length) {
      b2 = ((Number(a[j+1]) % 256) + 256) % 256;
      b3 = ((Number(a[j+2]) % 256) + 256) % 256;
      s += String.fromCharCode(((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)); j += 3; }
    else { s += String.fromCharCode(b); j++; }
  }
  Object.defineProperty(a, 'toString', { value: function(){ return s; }, enumerable: false, configurable: true });
  return a;
};
var __jSlice = function(b, off, len){ b = __jArr(b); if (off == null) return b; off = Number(off);
  return b.slice(off, len == null ? b.length : off + Number(len)); };
var __jS8 = function(x){ return (Number(x) << 24) >> 24; };
var __jThrow = function(cls, msg){ var e = new Error(cls + (msg ? ': ' + msg : '')); e.javaException = cls; throw e; };
var __jDef = function(o, name, fn){ Object.defineProperty(o, name, { value: fn, writable: true, configurable: true, enumerable: false }); };
var __jCs = function(c){ return c == null ? 'UTF-8' : String(__jText(c)); };
// Java regex replacement ("$1", "\\$") -> JS replacement ("$1", "$$")
var __jRepl = function(r){ r = String(__jText(r)); var o = '';
  for (var i = 0; i < r.length; i++) { var ch = r.charAt(i);
    if (ch == '\\' && i + 1 < r.length) { var nx = r.charAt(++i); o += nx == '$' ? '$$' : nx; }
    else if (ch == '$' && r.charAt(i + 1) == '{') { var j = r.indexOf('}', i); o += '$<' + r.substring(i + 2, j) + '>'; i = j; }
    else o += ch; }
  return o; };
var __jSplit = function(t, re, limit){ limit = limit == null ? 0 : Number(limit); var out = [];
  if (t.length == 0) return [''];
  var rx = new RegExp(String(__jText(re)), 'g'), last = 0, m;
  while ((limit <= 0 || out.length < limit - 1) && (m = rx.exec(t)) != null) {
    if (m[0].length == 0) { if (m.index >= t.length) break; if (m.index == 0) { rx.lastIndex++; continue; } }
    out.push(t.substring(last, m.index)); last = m.index + m[0].length;
    if (m[0].length == 0) rx.lastIndex++; }
  out.push(t.substring(last));
  if (limit == 0) while (out.length > 1 && out[out.length - 1] == '') out.pop();
  if (limit == 0 && out.length == 1 && out[0] == '' && t.length > 0) return [];
  return out; };
var __jFormat = function(fmt, args){ var idx = 0;
  return String(__jText(fmt)).replace(/%(\d+\$)?([-#+ 0,(]*)(\d+)?(?:\.(\d+))?([a-zA-Z%])/g, function(m, pos, flags, w, prec, conv){
    if (conv == '%') return '%'; if (conv == 'n') return '\n';
    var v = pos ? args[parseInt(pos, 10) - 1] : args[idx++]; var s, neg = false, num = false, lc = conv.toLowerCase();
    if (lc == 's') { s = v == null ? 'null' : String(__jIsStr(v) ? v.__t : v); if (prec != null) s = s.substring(0, Number(prec)); }
    else if (lc == 'd') { num = true; var n = Math.trunc(Number(v)); neg = n < 0; s = String(Math.abs(n));
      if (flags.indexOf(',') >= 0) s = s.replace(/\B(?=(\d{3})+(?!\d))/g, ','); }
    else if (lc == 'f') { num = true; var f = Number(v); neg = f < 0; s = Math.abs(f).toFixed(prec == null ? 6 : Number(prec));
      if (flags.indexOf(',') >= 0) { var p = s.split('.'); p[0] = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ','); s = p.join('.'); } }
    else if (lc == 'e') { num = true; var e = Number(v); neg = e < 0; s = Math.abs(e).toExponential(prec == null ? 6 : Number(prec)).replace(/e([+-])(\d)$/, 'e$10$2'); }
    else if (lc == 'x' || lc == 'o') { num = true; var xv = Number(v); s = (xv < 0 ? (xv >>> 0) : xv).toString(lc == 'x' ? 16 : 8); }
    else if (lc == 'c') s = typeof v == 'number' ? String.fromCharCode(v) : String(v).charAt(0);
    else if (lc == 'b') s = String(v == null ? false : (typeof v == 'boolean' ? v : true));
    else s = String(v);
    if (num) { if (neg) s = '-' + s; else if (flags.indexOf('+') >= 0) s = '+' + s; else if (flags.indexOf(' ') >= 0) s = ' ' + s; }
    if (conv != lc) s = s.toUpperCase();
    if (w != null) { w = Number(w);
      if (flags.indexOf('-') >= 0) { while (s.length < w) s += ' '; }
      else if (num && flags.indexOf('0') >= 0) { var sign = /^[-+ ]/.test(s) ? s.charAt(0) : ''; var body = sign ? s.substring(1) : s;
        while (body.length + sign.length < w) body = '0' + body; s = sign + body; }
      else { while (s.length < w) s = ' ' + s; } }
    return s; }); };

// java.lang.String: `new` gives an object whose toString/valueOf is the text (String(x), x + '', ==);
// a call without `new` gives the primitive. Methods are non-enumerable so a returned object stringifies.
var __NativeString = String;
var __JStr = function(a, b, c, d){ var t;
  // plain call with one argument (also when importPackage(java.lang) shadows the global String): JS String()
  if (!(this instanceof __JStr) && arguments.length <= 1) return arguments.length == 0 ? '' : (__jIsStr(a) ? a.__t : __NativeString(a));
  if (arguments.length == 0) t = '';
  else if (a == null) t = 'null';
  else if (typeof a != 'object' || __jIsStr(a)) t = __jText(a);
  else { var arr = __jArr(a), cs = 'UTF-8';
    if (typeof b == 'number') { arr = arr.slice(b, b + (typeof c == 'number' ? c : arr.length - b)); if (d != null) cs = __jCs(d); }
    else if (b != null) cs = __jCs(b);
    if (arr.length && typeof arr[0] == 'string') t = arr.join('');
    else t = arr.length ? String(java.bytesToStr(arr, cs)) : ''; }
  if (!(this instanceof __JStr)) return t;
  Object.defineProperty(this, '__t', { value: t, enumerable: false });
  Object.defineProperty(this, '__jstr', { value: true, enumerable: false }); };
(function(P){
  var m = {
    toString: function(){ return this.__t; }, valueOf: function(){ return this.__t; }, toJSON: function(){ return this.__t; },
    length: function(){ return this.__t.length; },
    getBytes: function(cs){ return java.strToBytes(this.__t, __jCs(cs)); },
    equals: function(o){ return o != null && this.__t === __jText(o); },
    equalsIgnoreCase: function(o){ return o != null && this.__t.toLowerCase() === String(__jText(o)).toLowerCase(); },
    compareTo: function(o){ var x = this.__t, y = String(__jText(o)), n = Math.min(x.length, y.length);
      for (var i = 0; i < n; i++) { if (x.charCodeAt(i) != y.charCodeAt(i)) return x.charCodeAt(i) - y.charCodeAt(i); } return x.length - y.length; },
    compareToIgnoreCase: function(o){ return new __JStr(this.__t.toLowerCase()).compareTo(String(__jText(o)).toLowerCase()); },
    isEmpty: function(){ return this.__t.length == 0; }, isBlank: function(){ return /^\s*$/.test(this.__t); },
    contains: function(s){ return this.__t.indexOf(String(__jText(s))) >= 0; },
    startsWith: function(s, off){ return this.__t.substring(off || 0).indexOf(String(__jText(s))) == 0; },
    endsWith: function(s){ s = String(__jText(s)); return s.length <= this.__t.length && this.__t.substring(this.__t.length - s.length) == s; },
    indexOf: function(s, f){ return typeof s == 'number' ? this.__t.indexOf(String.fromCharCode(s), f || 0) : this.__t.indexOf(String(__jText(s)), f || 0); },
    lastIndexOf: function(s, f){ s = typeof s == 'number' ? String.fromCharCode(s) : String(__jText(s)); return f == null ? this.__t.lastIndexOf(s) : this.__t.lastIndexOf(s, f); },
    charAt: function(i){ return this.__t.charAt(i); }, codePointAt: function(i){ return this.__t.codePointAt(i); },
    substring: function(a, b){ return b == null ? this.__t.substring(a) : this.__t.substring(a, b); },
    subSequence: function(a, b){ return this.__t.substring(a, b); },
    trim: function(){ return this.__t.trim(); }, strip: function(){ return this.__t.trim(); },
    toLowerCase: function(){ return this.__t.toLowerCase(); }, toUpperCase: function(){ return this.__t.toUpperCase(); },
    concat: function(s){ return this.__t + String(__jText(s)); },
    replace: function(a, b){ if (a instanceof RegExp) return this.__t.replace(a, b);
      a = typeof a == 'number' ? String.fromCharCode(a) : String(__jText(a)); b = typeof b == 'number' ? String.fromCharCode(b) : String(__jText(b));
      return this.__t.split(a).join(b); },
    replaceAll: function(re, r){ return this.__t.replace(new RegExp(String(__jText(re)), 'g'), __jRepl(r)); },
    replaceFirst: function(re, r){ return this.__t.replace(new RegExp(String(__jText(re))), __jRepl(r)); },
    matches: function(re){ return new RegExp('^(?:' + String(__jText(re)) + ')$').test(this.__t); },
    split: function(re, limit){ if (re instanceof RegExp) return this.__t.split(re, limit); return __jSplit(this.__t, re, limit); },
    hashCode: function(){ var h = 0; for (var i = 0; i < this.__t.length; i++) h = (31 * h + this.__t.charCodeAt(i)) | 0; return h; },
    toCharArray: function(){ return this.__t.split(''); }, chars: function(){ return this.__t.split('').map(function(c){ return c.charCodeAt(0); }); },
    intern: function(){ return this.__t; }, repeat: function(n){ return this.__t.repeat(n); },
    getClass: function(){ return { getName: function(){ return 'java.lang.String'; }, getSimpleName: function(){ return 'String'; } }; } };
  for (var k in m) __jDef(P, k, m[k]);
  // every other JS string method delegates to the primitive
  Object.getOwnPropertyNames(String.prototype).forEach(function(n){
    if (n == 'constructor' || n == 'length' || P.hasOwnProperty(n) || typeof String.prototype[n] != 'function') return;
    __jDef(P, n, function(){ return String.prototype[n].apply(this.__t, arguments); }); });
})(__JStr.prototype);
__JStr.__name = 'String';
['fromCharCode', 'fromCodePoint', 'raw'].forEach(function(n){ if (__NativeString[n]) __JStr[n] = __NativeString[n]; });
__JStr.valueOf = function(v, off, cnt){ if (v == null) return 'null';
  if (Array.isArray(v)) { var a = off == null ? v : v.slice(off, off + cnt); return a.every(function(x){ return typeof x == 'string'; }) ? a.join('') : String(v); }
  return String(__jIsStr(v) ? v.__t : v); };
__JStr.copyValueOf = __JStr.valueOf;
__JStr.format = function(f){ var a = Array.prototype.slice.call(arguments, 1);
  if (f != null && typeof f == 'object' && !__jIsStr(f)) { f = a.shift(); }   // format(Locale, fmt, ...)
  return __jFormat(f, a); };
__JStr.join = function(sep){ var a = Array.prototype.slice.call(arguments, 1); if (a.length == 1 && a[0] != null && typeof a[0] == 'object' && !__jIsStr(a[0])) a = Array.prototype.slice.call(a[0]);
  return a.map(function(x){ return __jText(x); }).join(String(__jText(sep))); };
__JString = __JStr;
// Rhino hands rules java.lang.String (result.body(), java.ajax ...), so sources call Java methods on
// plain JS strings too (body.contains("Just a moment...")). Add the missing ones to String.prototype.
['contains','equals','equalsIgnoreCase','compareTo','compareToIgnoreCase','isEmpty','isBlank','matches','replaceFirst',
 'subSequence','strip','hashCode','toCharArray','chars','intern','getClass'].forEach(function(n){
  if (n in String.prototype) return; var f = __JStr.prototype[n]; if (typeof f != 'function') return;
  __jDef(String.prototype, n, function(){ return f.apply(new __JStr(String(this)), arguments); }); });

var __JStrBuilder = function(s){ var b = { __s: (s == null || typeof s == 'number') ? '' : String(__jText(s)) };
  b.append = function(v, off, len){ if (Array.isArray(v)) v = v.slice(off || 0, len == null ? v.length : (off || 0) + len).join('');
    else if (off != null) v = String(__jText(v)).substring(off, len); b.__s += v == null ? 'null' : String(__jIsStr(v) ? v.__t : v); return b; };
  b.toString = function(){ return b.__s; }; b.valueOf = b.toString; b.length = function(){ return b.__s.length; };
  b.charAt = function(i){ return b.__s.charAt(i); }; b.indexOf = function(x, f){ return b.__s.indexOf(String(x), f || 0); };
  b.lastIndexOf = function(x){ return b.__s.lastIndexOf(String(x)); };
  b.insert = function(i, v){ b.__s = b.__s.substring(0, i) + String(__jText(v)) + b.__s.substring(i); return b; };
  b.reverse = function(){ b.__s = b.__s.split('').reverse().join(''); return b; };
  b.setLength = function(n){ b.__s = n <= b.__s.length ? b.__s.substring(0, n) : b.__s + new Array(n - b.__s.length + 1).join('\u0000'); };
  b.deleteCharAt = function(i){ b.__s = b.__s.substring(0, i) + b.__s.substring(i + 1); return b; };
  b['delete'] = function(a, e){ b.__s = b.__s.substring(0, a) + b.__s.substring(e); return b; };
  b.replace = function(a, e, v){ b.__s = b.__s.substring(0, a) + String(__jText(v)) + b.__s.substring(e); return b; };
  b.setCharAt = function(i, c){ b.__s = b.__s.substring(0, i) + String(c) + b.__s.substring(i + 1); };
  b.substring = function(a, e){ return e == null ? b.__s.substring(a) : b.__s.substring(a, e); };
  b.isEmpty = function(){ return b.__s.length == 0; };
  return b; };
__JStrBuilder.__name = 'StringBuilder';

// java.math.BigInteger (BigInt-backed): new BigInteger(1, md5Bytes).toString(16), new BigInteger("ff", 16),
// new BigInteger(numBits, rnd): uniform in [0, 2^numBits) from rnd.nextBytes (Random / SecureRandom).
var __JBigInt = function(a, b){ var v;
  if (typeof a == 'number' && b != null && typeof b == 'object' && (typeof b.nextBytes == 'function' || b.__rnd === true)) {
    var nb = Math.floor(a); if (!(nb >= 0)) __jThrow('java.lang.IllegalArgumentException', 'numBits must be non-negative');
    var nbytes = Math.ceil(nb / 8), rb = []; for (var ri = 0; ri < nbytes; ri++) rb.push(0);
    if (nbytes > 0) { if (typeof b.nextBytes == 'function') b.nextBytes(rb); else rb = __jRandBytes(nbytes);
      rb[0] = rb[0] & ((1 << (8 - (8 * nbytes - nb))) - 1); }
    var rh = ''; for (var rj = 0; rj < nbytes; rj++) { var rx = (rb[rj] & 0xff).toString(16); rh += rx.length < 2 ? '0' + rx : rx; }
    v = rh ? BigInt('0x' + rh) : BigInt(0); }
  else if (typeof a == 'number' && b != null && typeof b == 'object') { var bytes = __jArr(b), h = '';
    for (var i = 0; i < bytes.length; i++) { var x = (bytes[i] & 0xff).toString(16); h += x.length < 2 ? '0' + x : x; }
    v = h ? BigInt('0x' + h) : BigInt(0); if (a < 0) v = -v; }
  else if (a != null && typeof a == 'object' && !__jIsStr(a)) { var by = __jArr(a), hx = '';
    for (var j = 0; j < by.length; j++) { var y = (by[j] & 0xff).toString(16); hx += y.length < 2 ? '0' + y : y; }
    v = hx ? BigInt('0x' + hx) : BigInt(0); if (by.length && by[0] < 0) v -= BigInt(1) << BigInt(by.length * 8); }
  else if (typeof a == 'bigint') v = a;
  else { var s = String(__jText(a)).trim(), r = b == null ? 10 : Number(b), ng = false;
    if (s.charAt(0) == '-') { ng = true; s = s.substring(1); } else if (s.charAt(0) == '+') s = s.substring(1);
    v = BigInt(0); var R = BigInt(r);
    for (var k = 0; k < s.length; k++) { var dg = parseInt(s.charAt(k), r); if (isNaN(dg)) __jThrow('java.lang.NumberFormatException', s); v = v * R + BigInt(dg); }
    if (ng) v = -v; }
  return __JBigWrap(v); };
var __JBigWrap = function(v){ var w = function(o){ return o != null && o.__big != null ? o.__big : BigInt(typeof o == 'number' ? Math.trunc(o) : String(o)); };
  return { __big: v, toString: function(r){ return v.toString(r || 10); }, valueOf: function(){ return Number(v); },
    add: function(o){ return __JBigWrap(v + w(o)); }, subtract: function(o){ return __JBigWrap(v - w(o)); },
    multiply: function(o){ return __JBigWrap(v * w(o)); }, divide: function(o){ return __JBigWrap(v / w(o)); },
    mod: function(o){ var mm = w(o), r = v % mm; return __JBigWrap(r < 0 ? r + mm : r); }, remainder: function(o){ return __JBigWrap(v % w(o)); },
    pow: function(e){ return __JBigWrap(v ** BigInt(e)); }, negate: function(){ return __JBigWrap(-v); }, abs: function(){ return __JBigWrap(v < 0 ? -v : v); },
    modPow: function(e, mo){ var base = v % w(mo), ex = w(e), M = w(mo), r = BigInt(1); if (base < 0) base += M;
      while (ex > 0) { if (ex & BigInt(1)) r = r * base % M; base = base * base % M; ex >>= BigInt(1); } return __JBigWrap(r); },
    compareTo: function(o){ var x = w(o); return v < x ? -1 : (v > x ? 1 : 0); }, equals: function(o){ return o != null && v == w(o); },
    signum: function(){ return v < 0 ? -1 : (v > 0 ? 1 : 0); },
    bitLength: function(){ var x = v < 0 ? -v - BigInt(1) : v; return x == 0 ? 0 : x.toString(2).length; },
    testBit: function(n){ return ((v >> BigInt(n)) & BigInt(1)) == 1; },
    shiftLeft: function(n){ return __JBigWrap(v << BigInt(n)); }, shiftRight: function(n){ return __JBigWrap(v >> BigInt(n)); },
    and: function(o){ return __JBigWrap(v & w(o)); }, or: function(o){ return __JBigWrap(v | w(o)); }, xor: function(o){ return __JBigWrap(v ^ w(o)); },
    min: function(o){ var x = w(o); return __JBigWrap(v < x ? v : x); }, max: function(o){ var x = w(o); return __JBigWrap(v > x ? v : x); },
    gcd: function(o){ var x = v < 0 ? -v : v, y = w(o); if (y < 0) y = -y; while (y != 0) { var t = x % y; x = y; y = t; } return __JBigWrap(x); },
    modInverse: function(mo){ var M = w(mo), r0 = M, r1 = ((v % M) + M) % M, t0 = BigInt(0), t1 = BigInt(1);
      while (r1 != 0) { var q = r0 / r1, tr = r0 - q * r1; r0 = r1; r1 = tr; var tt = t0 - q * t1; t0 = t1; t1 = tt; }
      if (r0 != 1) __jThrow('java.lang.ArithmeticException', 'BigInteger not invertible.'); return __JBigWrap(t0 < 0 ? t0 + M : t0); },
    intValue: function(){ return Number(BigInt.asIntN(32, v)); }, longValue: function(){ return Number(BigInt.asIntN(64, v)); },
    toByteArray: function(){ var n = v, out = []; do { out.unshift(Number(BigInt.asIntN(8, n))); n >>= BigInt(8); }
      while (!((n == 0 && out[0] >= 0) || (n == -1 && out[0] < 0))); return out; } }; };
__JBigInt.__name = 'BigInteger';
__JBigInt.valueOf = function(n){ return __JBigWrap(BigInt(Math.trunc(Number(n)))); };
if (typeof BigInt != 'undefined') { __JBigInt.ZERO = __JBigInt.valueOf(0); __JBigInt.ONE = __JBigInt.valueOf(1); __JBigInt.TEN = __JBigInt.valueOf(10); }

// java.util.Random / java.security.SecureRandom. Random(seed) is Java's 48-bit LCG (same sequence as the JDK);
// SecureRandom and unseeded draws use __native.jRandomBytes (SecRandomCopyBytes). Derived methods follow java.util.Random.
var __jRandBytes = function(n){ n = Math.max(0, Math.floor(Number(n) || 0)); if (n == 0) return [];
  var r = null; try { r = __native.jRandomBytes(n); } catch (e) { r = null; }
  if (r == null || r.length != n) { r = []; for (var i = 0; i < n; i++) r.push(__jS8(Math.floor(Math.random() * 256))); }
  return __jArr(r); };
var __jRandU32 = function(){ var b = __jRandBytes(4); return (((b[0] & 0xff) << 24) | ((b[1] & 0xff) << 16) | ((b[2] & 0xff) << 8) | (b[3] & 0xff)) >>> 0; };
var __jBigOf = function(x){ if (typeof x == 'bigint') return x; if (x != null && x.__big != null) return x.__big;
  if (typeof x == 'number') return BigInt(Math.trunc(x)); return BigInt(String(__jText(x)).trim()); };
var __jLcg = function(seed){ var M = (BigInt(1) << BigInt(48)) - BigInt(1), A = BigInt('0x5DEECE66D'), C = BigInt(11), st = { s: BigInt(0) };
  var next = function(bits){ st.s = (st.s * A + C) & M; return Number(BigInt.asIntN(32, st.s >> BigInt(48 - bits))); };
  next.setSeed = function(x){ st.s = (BigInt.asIntN(64, __jBigOf(x)) ^ A) & M; };
  next.setSeed(seed); return next; };
var __jSecNext = function(bits){ return (__jRandU32() >>> (32 - bits)) | 0; };
var __jRandObj = function(next, alg, secure){ var r = { __rnd: true }, gauss = { has: false, v: 0 };
  __jDef(r, '__next', next);
  r.nextInt = function(a, b){ if (a == null) return next(32);
    if (b != null) { var o = Number(a), hb = Number(b); if (!(hb > o)) __jThrow('java.lang.IllegalArgumentException', 'bound must be greater than origin');
      if (hb - o <= 2147483647) return o + r.nextInt(hb - o); var x; do { x = next(32); } while (x < o || x >= hb); return x; }
    var bound = Number(a); if (!(bound > 0)) __jThrow('java.lang.IllegalArgumentException', 'bound must be positive');
    bound = Math.min(Math.floor(bound), 2147483647);
    if ((bound & -bound) == bound) return Math.floor(bound * next(31) / 2147483648);
    var bits, val; do { bits = next(31); val = bits % bound; } while (((bits - val + (bound - 1)) | 0) < 0);
    return val; };
  r.nextLong = function(){ var h = next(32), l = next(32); return h * 4294967296 + l; };
  r.nextDouble = function(){ return (next(26) * 134217728 + next(27)) / 9007199254740992; };
  r.nextFloat = function(){ return next(24) / 16777216; };
  r.nextBoolean = function(){ return next(1) != 0; };
  r.nextGaussian = function(){ if (gauss.has) { gauss.has = false; return gauss.v; } var v1, v2, s;
    do { v1 = 2 * r.nextDouble() - 1; v2 = 2 * r.nextDouble() - 1; s = v1 * v1 + v2 * v2; } while (s >= 1 || s == 0);
    var m = Math.sqrt(-2 * Math.log(s) / s); gauss.v = v2 * m; gauss.has = true; return v1 * m; };
  r.nextBytes = function(arr){ if (arr == null) return; var n = arr.length, i = 0;
    if (secure) { var b = __jRandBytes(n); for (; i < n; i++) arr[i] = b[i]; return; }
    while (i < n) { var rnd = r.nextInt(), k = Math.min(n - i, 4); for (; k-- > 0; rnd >>= 8) arr[i++] = __jS8(rnd); } };
  r.generateSeed = function(n){ return __jRandBytes(n); };
  r.setSeed = function(s){ if (!secure && next.setSeed && s != null && typeof s != 'object') next.setSeed(s); };
  r.getAlgorithm = function(){ return alg; };
  r.toString = function(){ return (secure ? 'java.security.SecureRandom' : 'java.util.Random') + '@' + alg; };
  return r; };
var __JRandom = function(seed){ var hasBig = typeof BigInt != 'undefined';
  if (!hasBig) return __jRandObj(__jSecNext, 'Random', true);
  if (seed == null) { var b = __jRandBytes(6), s = BigInt(0); for (var i = 0; i < 6; i++) s = (s << BigInt(8)) | BigInt(b[i] & 0xff); return __jRandObj(__jLcg(s), 'Random', false); }
  return __jRandObj(__jLcg(seed), 'Random', false); };
__JRandom.__name = 'Random';
// new SecureRandom() / new SecureRandom(seedBytes): the seed only supplements the system source, as on Android.
var __JSecureRandom = function(seed){ return __jRandObj(__jSecNext, 'SHA1PRNG', true); };
__JSecureRandom.__name = 'SecureRandom';
__JSecureRandom.getInstance = function(alg){ return __jRandObj(__jSecNext, alg == null ? 'SHA1PRNG' : String(__jText(alg)), true); };
__JSecureRandom.getInstanceStrong = function(){ return __jRandObj(__jSecNext, 'NativePRNGBlocking', true); };
__JSecureRandom.getSeed = function(n){ return __jRandBytes(n); };

// java.net.URL(spec | context, spec | protocol, host[, port], file) with openConnection() / openStream().
var __JURLBase = __JURL;
__JURL = function(a, b, c, d){ var s;
  if (arguments.length >= 3) { var four = arguments.length >= 4, port = four ? Number(c) : -1, file = String(__jText(four ? d : c));
    s = String(__jText(a)) + '://' + String(__jText(b)) + (port >= 0 ? ':' + port : '') + file; }
  else if (arguments.length == 2 && b != null) s = a == null ? String(__jText(b)) : String(__native.jsoupAbs(String(a), String(__jText(b))));
  else s = String(__jText(a));
  var o = __JURLBase(s);
  var ref = s.indexOf('#') >= 0 ? s.substring(s.indexOf('#') + 1) : null;
  o.openConnection = function(){ return __JHttpConn(o); };
  o.openStream = function(){ return o.openConnection().getInputStream(); };
  o.toExternalForm = function(){ return s; };
  o.getFile = function(){ var q = o.getQuery(); return o.getPath() + (q == null ? '' : '?' + q); };
  o.getRef = function(){ return ref; };
  o.getAuthority = function(){ return o.getHost() + (o.getPort() >= 0 ? ':' + o.getPort() : ''); };
  o.getDefaultPort = function(){ var p = o.getProtocol().toLowerCase(); return p == 'https' ? 443 : (p == 'http' ? 80 : -1); };
  o.equals = function(x){ return x != null && String(x) == s; };
  o.toJSON = function(){ return s; };
  return o; };
__JURL.__name = 'URL';

// java.net.HttpURLConnection. The request goes out (synchronously, through __native.jHttp) on the first call
// that needs the response, so the body written to getOutputStream() is complete by then.
var __JHttpConst = { __name: 'HttpURLConnection', HTTP_OK: 200, HTTP_CREATED: 201, HTTP_ACCEPTED: 202, HTTP_NO_CONTENT: 204,
  HTTP_PARTIAL: 206, HTTP_MULT_CHOICE: 300, HTTP_MOVED_PERM: 301, HTTP_MOVED_TEMP: 302, HTTP_SEE_OTHER: 303, HTTP_NOT_MODIFIED: 304,
  HTTP_BAD_REQUEST: 400, HTTP_UNAUTHORIZED: 401, HTTP_FORBIDDEN: 403, HTTP_NOT_FOUND: 404, HTTP_BAD_METHOD: 405,
  HTTP_CLIENT_TIMEOUT: 408, HTTP_CONFLICT: 409, HTTP_GONE: 410, HTTP_INTERNAL_ERROR: 500, HTTP_NOT_IMPLEMENTED: 501,
  HTTP_BAD_GATEWAY: 502, HTTP_UNAVAILABLE: 503, HTTP_GATEWAY_TIMEOUT: 504, __follow: true,
  setFollowRedirects: function(b){ __JHttpConst.__follow = !!b; }, getFollowRedirects: function(){ return __JHttpConst.__follow; } };
var __jHeaderMap = function(h){ var o = {}, keys = [];
  for (var n in h) { o[n] = __jList([String(h[n])]); keys.push(n); }
  var find = function(k){ if (k == null) return null; k = String(__jText(k)).toLowerCase(); for (var i = 0; i < keys.length; i++) if (keys[i].toLowerCase() == k) return keys[i]; return null; };
  __jDef(o, 'get', function(k){ var n = find(k); return n == null ? null : o[n]; });
  __jDef(o, 'containsKey', function(k){ return find(k) != null; });
  __jDef(o, 'keySet', function(){ return __jList(keys.slice()); });
  __jDef(o, 'entrySet', function(){ return __jList(keys.map(function(n){ return { getKey: function(){ return n; }, getValue: function(){ return o[n]; } }; })); });
  __jDef(o, 'size', function(){ return keys.length; }); __jDef(o, 'isEmpty', function(){ return keys.length == 0; });
  return o; };
var __JHttpConn = function(urlObj){ var u = String(urlObj);
  var c = { __m: 'GET', __h: [], __out: null, __res: null, __ct: 0, __rt: 0, __follow: __JHttpConst.__follow, __doOut: false, __doIn: true, __caches: true };
  var hIdx = function(k){ k = String(k).toLowerCase(); for (var i = 0; i < c.__h.length; i++) { if (c.__h[i][0].toLowerCase() == k) return i; } return -1; };
  var chk = function(){ if (c.__res) __jThrow('java.lang.IllegalStateException', 'Already connected'); };
  var sval = function(v){ return v == null ? '' : String(__jText(v)); };
  c.setRequestMethod = function(m){ chk(); m = String(__jText(m)).toUpperCase();
    if (!/^(GET|POST|HEAD|OPTIONS|PUT|DELETE|TRACE|PATCH)$/.test(m)) __jThrow('java.net.ProtocolException', 'Invalid HTTP method: ' + m);
    c.__m = m; };
  c.getRequestMethod = function(){ return c.__m; };
  c.setDoOutput = function(b){ chk(); c.__doOut = !!b; }; c.getDoOutput = function(){ return c.__doOut; };
  c.setDoInput = function(b){ chk(); c.__doIn = !!b; }; c.getDoInput = function(){ return c.__doIn; };
  c.setRequestProperty = function(k, v){ chk(); if (k == null) __jThrow('java.lang.NullPointerException', 'key is null'); k = String(__jText(k));
    var i = hIdx(k); if (i >= 0) c.__h[i] = [k, sval(v)]; else c.__h.push([k, sval(v)]); };
  c.addRequestProperty = function(k, v){ chk(); if (k == null) __jThrow('java.lang.NullPointerException', 'key is null'); k = String(__jText(k));
    var i = hIdx(k); if (i < 0) { c.__h.push([k, sval(v)]); return; }
    c.__h[i][1] += (k.toLowerCase() == 'cookie' ? '; ' : ', ') + sval(v); };
  c.getRequestProperty = function(k){ if (k == null) return null; var i = hIdx(String(__jText(k))); return i < 0 ? null : c.__h[i][1]; };
  c.getRequestProperties = function(){ var o = {}; c.__h.forEach(function(p){ o[p[0]] = p[1]; }); return __jHeaderMap(o); };
  c.setConnectTimeout = function(n){ c.__ct = Math.max(0, Number(n) || 0); }; c.getConnectTimeout = function(){ return c.__ct; };
  c.setReadTimeout = function(n){ c.__rt = Math.max(0, Number(n) || 0); }; c.getReadTimeout = function(){ return c.__rt; };
  c.setInstanceFollowRedirects = function(b){ c.__follow = !!b; }; c.getInstanceFollowRedirects = function(){ return c.__follow; };
  c.setUseCaches = function(b){ c.__caches = !!b; }; c.getUseCaches = function(){ return c.__caches; };
  c.setDefaultUseCaches = function(){}; c.setAllowUserInteraction = function(){};
  c.setChunkedStreamingMode = function(){}; c.setFixedLengthStreamingMode = function(){};
  c.setIfModifiedSince = function(t){ chk(); if (Number(t) > 0) c.setRequestProperty('If-Modified-Since', new Date(Number(t)).toUTCString()); };
  c.getOutputStream = function(){
    if (c.__res) __jThrow('java.net.ProtocolException', 'cannot write request body after response has been read');
    if (!c.__doOut) __jThrow('java.net.ProtocolException', 'cannot write to a URLConnection if doOutput=false - call setDoOutput(true)');
    if (c.__m == 'GET') c.__m = 'POST';   // JDK: doOutput turns a GET into a POST
    if (!c.__out) { var o = { __buf: [], __closed: false };
      o.write = function(b, off, len){ if (o.__closed) __jThrow('java.io.IOException', 'stream is closed');
        if (typeof b == 'number') { o.__buf.push(__jS8(b)); return; }
        var a = __jSlice(b, off, len); for (var i = 0; i < a.length; i++) o.__buf.push(__jS8(a[i])); };
      o.flush = function(){}; o.close = function(){ o.__closed = true; };
      c.__out = o; }
    return c.__out; };
  c.connect = function(){};
  c.__send = function(){ if (c.__res) return c.__res;
    var hdr = {}; c.__h.forEach(function(p){ hdr[p[0]] = p[1]; });
    var body = c.__out ? c.__out.__buf : null;
    var r = __native.jHttp(u, c.__m, hdr, body, (c.__ct || 0) + (c.__rt || 0), c.__follow);
    if (r == null || r.error != null) __jThrow(r && r.exception ? String(r.exception) : 'java.io.IOException', r && r.error != null ? String(r.error) : u);
    c.__res = { code: Number(r.code), message: r.message == null ? null : String(r.message), headers: r.headers || {},
      body: __jArr(r.body), url: r.url ? String(r.url) : u };
    return c.__res; };
  var hkeys = function(){ return Object.keys(c.__send().headers); };
  var hget = function(k){ if (k == null) return null; var h = c.__send().headers; k = String(__jText(k)).toLowerCase();
    for (var n in h) { if (n.toLowerCase() == k) return String(h[n]); } return null; };
  c.getResponseCode = function(){ return c.__send().code; };
  c.getResponseMessage = function(){ return c.__send().message; };
  c.getInputStream = function(){
    if (!c.__doIn) __jThrow('java.net.ProtocolException', 'Cannot read from URLConnection if doInput=false (call setDoInput(true))');
    var res = c.__send();
    if (res.code >= 400) { if (res.code == 404 || res.code == 410) __jThrow('java.io.FileNotFoundException', res.url);
      __jThrow('java.io.IOException', 'Server returned HTTP response code: ' + res.code + ' for URL: ' + res.url); }
    return __JBAIS(res.body.slice()); };
  c.getErrorStream = function(){ var res = c.__res; return (res && res.code >= 400 && res.body.length) ? __JBAIS(res.body.slice()) : null; };
  c.getHeaderField = function(k){ if (typeof k == 'number') { var res = c.__send();
      if (k == 0) return 'HTTP/1.1 ' + res.code + (res.message ? ' ' + res.message : '');
      var ks = hkeys(); return k > 0 && k <= ks.length ? String(res.headers[ks[k - 1]]) : null; }
    return hget(k); };
  c.getHeaderFieldKey = function(n){ var ks = hkeys(); return n > 0 && n <= ks.length ? ks[n - 1] : null; };
  c.getHeaderFields = function(){ return __jHeaderMap(c.__send().headers); };
  c.getHeaderFieldInt = function(k, dflt){ var v = parseInt(hget(k), 10); return isNaN(v) ? dflt : v; };
  c.getHeaderFieldLong = c.getHeaderFieldInt;
  c.getHeaderFieldDate = function(k, dflt){ var v = hget(k), t = v == null ? NaN : Date.parse(v); return isNaN(t) ? dflt : t; };
  c.getContentType = function(){ return hget('Content-Type'); };
  c.getContentEncoding = function(){ return hget('Content-Encoding'); };
  c.getContentLengthLong = function(){ var v = parseInt(hget('Content-Length'), 10); return isNaN(v) ? -1 : v; };
  c.getContentLength = function(){ var v = c.getContentLengthLong(); return v > 2147483647 ? -1 : v; };
  c.getDate = function(){ return c.getHeaderFieldDate('Date', 0); };
  c.getLastModified = function(){ return c.getHeaderFieldDate('Last-Modified', 0); };
  c.getExpiration = function(){ return c.getHeaderFieldDate('Expires', 0); };
  c.getURL = function(){ return c.__res ? new __JURL(c.__res.url) : urlObj; };
  c.usingProxy = function(){ return false; };
  c.disconnect = function(){};
  c.toString = function(){ return 'HttpURLConnection:' + u; };
  return c; };

// java.security.MessageDigest / javax.crypto.Mac
var __JDigest = { __name: 'MessageDigest', getInstance: function(alg){ alg = String(__jText(alg)); __native.jDigest(alg, []);
  var d = { __buf: [] };
  d.update = function(b, off, len){ if (typeof b == 'number') d.__buf.push(__jS8(b)); else d.__buf = d.__buf.concat(__jSlice(b, off, len)); };
  d.digest = function(b, off, len){ if (b != null) d.update(b, off, len); var r = __native.jDigest(alg, d.__buf); d.__buf = []; return r; };
  d.reset = function(){ d.__buf = []; }; d.getAlgorithm = function(){ return alg; };
  d.getDigestLength = function(){ return __native.jDigest(alg, []).length; };
  return d; }, isEqual: function(a, b){ return __JArrays.equals(__jArr(a), __jArr(b)); } };
var __JMac = { __name: 'Mac', getInstance: function(alg){ alg = String(__jText(alg)); var m = { __buf: [], __key: [] };
  m.init = function(k){ m.__key = (k && typeof k.getEncoded == 'function') ? __jArr(k.getEncoded()) : __jArr(k); m.__buf = []; };
  m.update = function(b, off, len){ if (typeof b == 'number') m.__buf.push(__jS8(b)); else m.__buf = m.__buf.concat(__jSlice(b, off, len)); };
  m.doFinal = function(b){ if (b != null) m.update(b); var r = __native.jHmac(alg, m.__key, m.__buf); m.__buf = []; return r; };
  m.reset = function(){ m.__buf = []; }; m.getAlgorithm = function(){ return alg; };
  m.getMacLength = function(){ return __native.jHmac(alg, [0], []).length; };
  return m; } };

// javax.crypto.spec.* / java.security.spec.* / KeyFactory
var __JKeySpec = function(k, a, b, c){ var key = typeof a == 'number' ? __jSlice(k, a, b) : __jArr(k); var alg = String(__jText(typeof a == 'number' ? c : a));
  return { __key: key, getEncoded: function(){ return key.slice(); }, getAlgorithm: function(){ return alg; }, getFormat: function(){ return 'RAW'; } }; };
__JKeySpec.__name = 'SecretKeySpec';
var __JIvSpec = function(iv, off, len){ var v = __jSlice(iv, off, len); return { getIV: function(){ return v.slice(); } }; };
__JIvSpec.__name = 'IvParameterSpec';
var __JGcmSpec = function(tLen, iv, off, len){ var v = __jSlice(iv, off, len); return { getIV: function(){ return v.slice(); }, getTLen: function(){ return Number(tLen); } }; };
__JGcmSpec.__name = 'GCMParameterSpec';
var __JX509Spec = function(b){ var v = __jArr(b); return { getEncoded: function(){ return v.slice(); }, getFormat: function(){ return 'X.509'; } }; };
__JX509Spec.__name = 'X509EncodedKeySpec';
var __JPkcs8Spec = function(b){ var v = __jArr(b); return { getEncoded: function(){ return v.slice(); }, getFormat: function(){ return 'PKCS#8'; } }; };
__JPkcs8Spec.__name = 'PKCS8EncodedKeySpec';
var __JKeyFactory = { __name: 'KeyFactory', getInstance: function(alg){ alg = String(__jText(alg)); var mk = function(spec, pub){ var v = spec.getEncoded();
    return { __pub: pub, getEncoded: function(){ return v.slice(); }, getAlgorithm: function(){ return alg; }, getFormat: function(){ return pub ? 'X.509' : 'PKCS#8'; } }; };
  return { generatePublic: function(s){ return mk(s, true); }, generatePrivate: function(s){ return mk(s, false); } }; } };

// javax.crypto.Cipher: AES / DES / DESede, ECB / CBC (+ CTR/CFB/OFB, GCM), PKCS5/PKCS7/NoPadding; RSA via __native.rsa.
var __JCipher = { __name: 'Cipher', ENCRYPT_MODE: 1, DECRYPT_MODE: 2, WRAP_MODE: 3, UNWRAP_MODE: 4,
  getInstance: function(t){ t = String(__jText(t)); var p = t.split('/');
    var isRsa = /^RSA/i.test(p[0]);
    if (p.length == 1) t = isRsa ? 'RSA/ECB/PKCS1Padding' : p[0] + '/ECB/PKCS5Padding';
    var c = { __buf: [], __mode: 1, __key: [], __iv: null, __tag: 128, __aad: null, __pub: true };
    c.init = function(mode, key, params){ c.__mode = Number(mode); c.__buf = []; c.__aad = null;
      c.__key = (key && typeof key.getEncoded == 'function') ? __jArr(key.getEncoded()) : __jArr(key);
      c.__pub = !(key && key.__pub === false);
      c.__iv = (params && typeof params.getIV == 'function') ? params.getIV() : (params != null && typeof params == 'object' && params.length != null ? __jArr(params) : null);
      c.__tag = (params && typeof params.getTLen == 'function') ? params.getTLen() : 128; };
    c.updateAAD = function(b, off, len){ c.__aad = (c.__aad || []).concat(__jSlice(b, off, len)); };
    c.update = function(b, off, len){ c.__buf = c.__buf.concat(__jSlice(b, off, len)); return []; };
    c.doFinal = function(b, off, len){ if (b != null) c.__buf = c.__buf.concat(__jSlice(b, off, len));
      var data = c.__buf; c.__buf = []; var enc = c.__mode == 1 || c.__mode == 3;
      if (isRsa) return __jByteString(__native.rsa(enc, t, c.__key, c.__pub, data, 'bytes'));
      var out = __native.jCipher(enc, t, c.__key, c.__iv, data, c.__tag, c.__aad);
      // 只有解密结果通常是明文文本（书源会 String(...)/JSON.parse）；加密结果保持纯字节数组。
      return enc ? out : __jByteString(out); };
    c.getIV = function(){ return c.__iv ? c.__iv.slice() : null; };
    c.getAlgorithm = function(){ return t; };
    c.getBlockSize = function(){ return isRsa ? 0 : (/^DES/i.test(p[0]) ? 8 : 16); };
    c.getOutputSize = function(n){ var bs = c.getBlockSize() || 1; return (Math.floor((n + c.__buf.length) / bs) + 1) * bs; };
    return c; } };

// java.util.Base64
var __jAscii = function(b){ b = __jArr(b); var s = ''; for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i] & 0xff); return s; };
var __JB64Enc = function(url, pad, mime){ var e = {};
  e.encodeToString = function(b){ var s = String(__native.b64Bytes(__jArr(b)));
    if (url) s = s.replace(/\+/g, '-').replace(/\//g, '_'); if (!pad) s = s.replace(/=+$/, '');
    if (mime && s.length > 76) s = s.match(/.{1,76}/g).join('\r\n'); return s; };
  e.encode = function(b){ return java.strToBytes(e.encodeToString(b), 'ISO-8859-1'); };
  e.withoutPadding = function(){ return __JB64Enc(url, false, mime); };
  return e; };
var __JB64Dec = function(mime){ return { decode: function(s){ s = (s != null && typeof s == 'object' && !__jIsStr(s)) ? __jAscii(s) : String(__jText(s));
    if (mime) s = s.replace(/[^A-Za-z0-9+\/=_-]/g, ''); s = s.replace(/\s+/g, '');
    if (s.length == 0) return [];
    var r = java.base64DecodeToByteArray(s); if (r == null) __jThrow('java.lang.IllegalArgumentException', 'Illegal base64 character'); return r; } }; };
var __JBase64 = { __name: 'Base64',
  getEncoder: function(){ return __JB64Enc(false, true, false); }, getUrlEncoder: function(){ return __JB64Enc(true, true, false); },
  getMimeEncoder: function(){ return __JB64Enc(false, true, true); },
  getDecoder: function(){ return __JB64Dec(false); }, getUrlDecoder: function(){ return __JB64Dec(false); }, getMimeDecoder: function(){ return __JB64Dec(true); } };
// android.util.Base64: accept byte / java.lang.String input too
__Base64.encodeToString = function(b, f){ var s = (typeof b == 'string' || __jIsStr(b)) ? java.base64Encode(__jText(b)) : __native.b64Bytes(__jArr(b));
  if (f & 8) s = s.replace(/\+/g, '-').replace(/\//g, '_'); if (f & 1) s = s.replace(/=+$/, '');
  return s; };
__Base64.decode = function(s, f){ s = (s != null && typeof s == 'object' && !__jIsStr(s)) ? __jAscii(s) : String(__jText(s));
  s = s.replace(/\s+/g, ''); if (s.length == 0) return [];
  var r = java.base64DecodeToByteArray(s); if (r == null) __jThrow('java.lang.IllegalArgumentException', 'bad base-64'); return r; };
__Base64.CRLF = 4; __Base64.NO_CLOSE = 16;

// java.util.Arrays (merged with the earlier asList)
var __jList = function(a){ a.size = function(){ return a.length; }; a.get = function(i){ return a[i]; };
  a.set = function(i, v){ var o = a[i]; a[i] = v; return o; }; a.add = function(i, v){ if (arguments.length > 1) a.splice(i, 0, v); else a.push(i); return true; };
  a.contains = function(v){ return a.indexOf(v) >= 0; }; a.isEmpty = function(){ return a.length == 0; };
  a.toArray = function(){ return a.slice(); }; a.addAll = function(o){ for (var i = 0; i < o.length; i++) a.push(o[i]); return true; };
  return a; };
var __jPad = function(a){ for (var i = 0; i < a.length; i++) { if (a[i] != null) return typeof a[i] == 'number' ? 0 : (typeof a[i] == 'boolean' ? false : null); } return 0; };
var __JArrays = { __name: 'Arrays',
  asList: function(){ return __jList(Array.prototype.slice.call(arguments.length == 1 && arguments[0] != null && typeof arguments[0] == 'object' && arguments[0].length != null && !__jIsStr(arguments[0]) ? arguments[0] : arguments)); },
  copyOf: function(a, n){ a = __jArr(a); n = Number(n); var r = a.slice(0, n), p = __jPad(a); while (r.length < n) r.push(p); return r; },
  copyOfRange: function(a, from, to){ a = __jArr(a); from = Number(from); to = Number(to);
    if (from > a.length || from < 0) __jThrow('java.lang.ArrayIndexOutOfBoundsException', String(from));
    if (from > to) __jThrow('java.lang.IllegalArgumentException', from + ' > ' + to);
    var r = a.slice(from, to), p = __jPad(a); while (r.length < to - from) r.push(p); return __jByteString(r); },
  fill: function(a, x, y, v){ if (arguments.length >= 4) { for (var i = x; i < y; i++) a[i] = v; } else { for (var j = 0; j < a.length; j++) a[j] = x; } },
  equals: function(a, b){ if (a == b) return true; if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] !== b[i] && String(a[i]) !== String(b[i])) return false; } return true; },
  toString: function(a){ if (a == null) return 'null'; return '[' + Array.prototype.map.call(a, function(x){ return x == null ? 'null' : String(x); }).join(', ') + ']'; },
  deepToString: function(a){ if (a == null) return 'null'; return '[' + Array.prototype.map.call(a, function(x){ return (x != null && typeof x == 'object' && x.length != null && !__jIsStr(x)) ? __JArrays.deepToString(x) : (x == null ? 'null' : String(x)); }).join(', ') + ']'; },
  sort: function(a, x, y, cmp){ var f = typeof x == 'number' ? cmp : x; var fn = f == null ? function(p, q){ return (typeof p == 'number' && typeof q == 'number') ? p - q : (String(p) < String(q) ? -1 : (String(p) > String(q) ? 1 : 0)); }
      : (typeof f == 'function' ? f : function(p, q){ return f.compare(p, q); });
    var s = typeof x == 'number' ? x : 0, e = typeof x == 'number' ? y : a.length;
    var part = Array.prototype.slice.call(a, s, e).sort(fn); for (var i = 0; i < part.length; i++) a[s + i] = part[i]; },
  hashCode: function(a){ if (a == null) return 0; var h = 1; for (var i = 0; i < a.length; i++) h = (31 * h + (typeof a[i] == 'number' ? (a[i] | 0) : 0)) | 0; return h; } };

// java.util.zip: Inflater / Deflater / CRC32 / GZIP + Inflater streams (natives inflate the whole input at once).
var __JInflater = function(nowrap){ this.__nowrap = !!nowrap; this.reset(); };
__JInflater.__name = 'Inflater';
__JInflater.prototype = {
  reset: function(){ this.__in = []; this.__out = []; this.__pos = 0; this.__end = false; this.__used = 0; this.__dirty = false; },
  setInput: function(b, off, len){ this.__in = this.__in.concat(__jSlice(b, off, len)); this.__dirty = true; },
  __run: function(){ if (!this.__dirty) return; this.__dirty = false;
    var r = __native.jInflate(this.__in, this.__nowrap);
    if (r == null) __jThrow('java.util.zip.DataFormatException', 'invalid deflate data');
    this.__out = r.data || []; this.__end = !!r.end; this.__used = Number(r.used || 0); },
  inflate: function(out, off, len){ this.__run(); off = off || 0; if (out == null) return 0; if (len == null) len = out.length - off;
    var n = Math.max(0, Math.min(len, this.__out.length - this.__pos));
    for (var i = 0; i < n; i++) out[off + i] = this.__out[this.__pos + i];
    this.__pos += n; return n; },
  finished: function(){ this.__run(); return this.__end && this.__pos >= this.__out.length; },
  needsInput: function(){ this.__run(); return !this.__end && this.__pos >= this.__out.length; },
  needsDictionary: function(){ return false; },
  getRemaining: function(){ this.__run(); return this.__end ? Math.max(0, this.__in.length - this.__used) : 0; },
  getTotalIn: function(){ this.__run(); return this.__end ? this.__used : this.__in.length; }, getBytesRead: function(){ return this.getTotalIn(); },
  getTotalOut: function(){ return this.__pos; }, getBytesWritten: function(){ return this.__pos; },
  end: function(){ this.__in = []; this.__out = []; } };
var __JDeflater = function(level, nowrap){ this.__nowrap = !!nowrap; this.reset(); };
__JDeflater.__name = 'Deflater';
__JDeflater.DEFAULT_COMPRESSION = -1; __JDeflater.BEST_COMPRESSION = 9; __JDeflater.BEST_SPEED = 1; __JDeflater.NO_COMPRESSION = 0;
__JDeflater.DEFLATED = 8; __JDeflater.NO_FLUSH = 0; __JDeflater.SYNC_FLUSH = 2; __JDeflater.FULL_FLUSH = 3;
__JDeflater.prototype = {
  reset: function(){ this.__in = []; this.__out = null; this.__pos = 0; this.__fin = false; },
  setInput: function(b, off, len){ this.__in = this.__in.concat(__jSlice(b, off, len)); },
  setLevel: function(){}, setStrategy: function(){},
  finish: function(){ this.__fin = true; },
  deflate: function(out, off, len){ if (!this.__fin) return 0; if (this.__out == null) this.__out = __native.jDeflate(this.__in, this.__nowrap) || [];
    off = off || 0; if (len == null || typeof len != 'number') len = out.length - off;
    var n = Math.max(0, Math.min(len, this.__out.length - this.__pos));
    for (var i = 0; i < n; i++) out[off + i] = this.__out[this.__pos + i]; this.__pos += n; return n; },
  finished: function(){ return this.__fin && this.__out != null && this.__pos >= this.__out.length; },
  needsInput: function(){ return !this.__fin; },
  getTotalIn: function(){ return this.__in.length; }, getTotalOut: function(){ return this.__pos; },
  end: function(){ this.__in = []; this.__out = null; } };
var __JCRC32 = function(){ var c = { __v: 0 };
  c.update = function(b, off, len){ c.__v = (typeof b == 'number') ? __native.jCrc32(c.__v, [b]) : __native.jCrc32(c.__v, __jSlice(b, off, len)); };
  c.getValue = function(){ return c.__v; }; c.reset = function(){ c.__v = 0; }; return c; };
__JCRC32.__name = 'CRC32';
// java.io.ByteArrayInputStream (superset of the bitmap shim's: keeps __bytes, adds read)
var __JBAIS = function(b, off, len){ var s = { __bytes: (off == null) ? b : __jSlice(b, off, len), __p: 0, __a: null };
  var arr = function(){ if (s.__a == null) s.__a = __jArr(s.__bytes); return s.__a; };
  s.read = function(buf, o, l){ var a = arr();
    if (buf == null) { return s.__p < a.length ? (a[s.__p++] & 0xff) : -1; }
    o = o || 0; if (l == null) l = buf.length - o; if (s.__p >= a.length) return l == 0 ? 0 : -1;
    var n = Math.min(l, a.length - s.__p); for (var i = 0; i < n; i++) buf[o + i] = a[s.__p + i]; s.__p += n; return n; };
  s.readAllBytes = function(){ var a = arr(), r = a.slice(s.__p); s.__p = a.length; return r; };
  s.readNBytes = function(n){ var a = arr(), r = a.slice(s.__p, s.__p + n); s.__p += r.length; return r; };
  s.available = function(){ return arr().length - s.__p; }; s.skip = function(n){ var k = Math.min(n, s.available()); s.__p += k; return k; };
  s.reset = function(){ s.__p = 0; }; s.mark = function(){}; s.markSupported = function(){ return false; };
  s.transferTo = function(out){ var r = s.readAllBytes(); out.write(r); return r.length; };
  s.close = function(){}; return s; };
__JBAIS.__name = 'ByteArrayInputStream';
var __jStreamBytes = function(inp){ if (inp == null) return [];
  if (typeof inp.readAllBytes == 'function') return __jArr(inp.readAllBytes());
  if (inp.__bytes != null) return __jArr(inp.__bytes);
  return __jArr(inp); };
var __JGZIPIn = function(inp){ var r = __native.jGunzip(__jStreamBytes(inp)); if (r == null) __jThrow('java.util.zip.ZipException', 'Not in GZIP format'); return __JBAIS(r); };
__JGZIPIn.__name = 'GZIPInputStream';
var __JInflaterIn = function(inp, inf){ var nw = !!(inf && inf.__nowrap); var r = __native.jInflate(__jStreamBytes(inp), nw);
  if (r == null) __jThrow('java.util.zip.ZipException', 'invalid deflate data'); return __JBAIS(r.data || []); };
__JInflaterIn.__name = 'InflaterInputStream';
var __jOutWrap = function(out, fin){ var s = { __buf: [] , __done: false };
  s.write = function(b, off, len){ if (typeof b == 'number') s.__buf.push(__jS8(b)); else s.__buf = s.__buf.concat(__jSlice(b, off, len)); };
  s.finish = function(){ if (s.__done) return; s.__done = true; var r = fin(s.__buf); if (out && out.write) out.write(r); };
  s.close = function(){ s.finish(); if (out && out.close) out.close(); }; s.flush = function(){}; return s; };
var __JGZIPOut = function(out){ return __jOutWrap(out, function(b){ return __native.jGzip(b); }); };
__JGZIPOut.__name = 'GZIPOutputStream';
var __JDeflaterOut = function(out, d){ var nw = !!(d && d.__nowrap); return __jOutWrap(out, function(b){ return __native.jDeflate(b, nw); }); };
__JDeflaterOut.__name = 'DeflaterOutputStream';
// java.io readers over a byte stream
var __JISR = function(inp, cs){ var t = String(java.bytesToStr(__jStreamBytes(inp), __jCs(cs))); var r = { __t: t, __p: 0 };
  r.read = function(buf, o, l){ if (buf == null) return r.__p < t.length ? t.charCodeAt(r.__p++) : -1;
    o = o || 0; if (l == null) l = buf.length - o; if (r.__p >= t.length) return -1; var n = Math.min(l, t.length - r.__p);
    for (var i = 0; i < n; i++) buf[o + i] = t.charAt(r.__p + i); r.__p += n; return n; };
  r.ready = function(){ return r.__p < t.length; }; r.close = function(){}; return r; };
__JISR.__name = 'InputStreamReader';
var __JBufReader = function(rd){ var t = rd && rd.__t != null ? rd.__t.substring(rd.__p || 0) : String(__jText(rd) || ''); var p = 0;
  var b = { readLine: function(){ if (p >= t.length) return null; var i = t.indexOf('\n', p), line;
      if (i < 0) { line = t.substring(p); p = t.length; } else { line = t.substring(p, i); p = i + 1; }
      return line.replace(/\r$/, ''); },
    read: function(){ return p < t.length ? t.charCodeAt(p++) : -1; }, ready: function(){ return p < t.length; },
    lines: function(){ var a = []; var l; while ((l = b.readLine()) != null) a.push(l); return a; }, close: function(){} };
  return b; };
__JBufReader.__name = 'BufferedReader';
var __JStrReader = function(s){ return { __t: String(__jText(s)), __p: 0, read: function(){ return -1; }, close: function(){} }; };
__JStrReader.__name = 'StringReader';
var __JCharset = { __name: 'Charset', forName: function(n){ n = String(__jText(n)); return { toString: function(){ return n; }, name: function(){ return n; }, displayName: function(){ return n; } }; },
  defaultCharset: function(){ return __JCharset.forName('UTF-8'); } };
var __JStdCs = { __name: 'StandardCharsets', UTF_8: __JCharset.forName('UTF-8'), US_ASCII: __JCharset.forName('US-ASCII'),
  ISO_8859_1: __JCharset.forName('ISO-8859-1'), UTF_16: __JCharset.forName('UTF-16'), UTF_16BE: __JCharset.forName('UTF-16BE'), UTF_16LE: __JCharset.forName('UTF-16LE') };

(function(P){
  var J = P.java, L = J.lang, U = J.util;
  L.String = __JStr; L.StringBuilder = __JStrBuilder; L.StringBuffer = __JStrBuilder;
  L.Integer.toHexString = function(n){ return (Number(n) >>> 0).toString(16); };
  L.Integer.toBinaryString = function(n){ return (Number(n) >>> 0).toString(2); };
  L.Integer.toOctalString = function(n){ return (Number(n) >>> 0).toString(8); };
  L.Integer.parseUnsignedInt = function(v, r){ return parseInt(String(__jText(v)), r || 10) | 0; };
  L.Integer.__name = 'Integer'; L.Long.__name = 'Long';
  L.Long.toString = function(v, r){ return Number(v).toString(r || 10); };
  L.Long.toHexString = function(n){ n = Number(n); return n < 0 && typeof BigInt != 'undefined' ? BigInt.asUintN(64, BigInt(Math.trunc(n))).toString(16) : n.toString(16); };
  L.Long.MAX_VALUE = 9223372036854775807; L.Long.MIN_VALUE = -9223372036854775808;
  L.Byte = { __name: 'Byte', MAX_VALUE: 127, MIN_VALUE: -128, parseByte: function(v, r){ return __jS8(parseInt(String(__jText(v)), r || 10)); }, toUnsignedInt: function(b){ return b & 0xff; } };
  L.Character = { __name: 'Character', isDigit: function(c){ return /\d/.test(String(c)); }, isLetter: function(c){ return /\p{L}/u.test(String(c)); },
    isWhitespace: function(c){ return /\s/.test(typeof c == 'number' ? String.fromCharCode(c) : String(c)); }, toChars: function(c){ return [String.fromCodePoint(c)]; } };
  L.System.arraycopy = function(src, sp, dst, dp, n){ var s = Array.prototype.slice.call(src, sp, sp + n); for (var i = 0; i < n; i++) dst[dp + i] = s[i]; };
  L.System.nanoTime = function(){ return Date.now() * 1000000; }; L.System.lineSeparator = function(){ return '\n'; };
  L.System.getProperty = function(k){ return null; };
  U.Arrays = __JArrays; U.Base64 = __JBase64;
  U.zip = { Inflater: __JInflater, Deflater: __JDeflater, CRC32: __JCRC32, GZIPInputStream: __JGZIPIn, GZIPOutputStream: __JGZIPOut,
            InflaterInputStream: __JInflaterIn, DeflaterOutputStream: __JDeflaterOut, ZipException: Error, DataFormatException: Error };
  J.math = { BigInteger: __JBigInt };
  J.security = { MessageDigest: __JDigest, KeyFactory: __JKeyFactory, SecureRandom: __JSecureRandom, spec: { X509EncodedKeySpec: __JX509Spec, PKCS8EncodedKeySpec: __JPkcs8Spec } };
  U.Random = __JRandom;
  J.net = J.net || {}; J.net.URL = __JURL; J.net.HttpURLConnection = __JHttpConst; J.net.URLConnection = __JHttpConst;
  J.nio = { charset: { StandardCharsets: __JStdCs, Charset: __JCharset } };
  P.javax = { crypto: { Cipher: __JCipher, Mac: __JMac, spec: { SecretKeySpec: __JKeySpec, IvParameterSpec: __JIvSpec, GCMParameterSpec: __JGcmSpec } },
              net: { ssl: { HttpsURLConnection: __JHttpConst } } };
  // java.io is replaced wholesale by later shims (bitmap): merge our extras into whatever gets assigned.
  var ioExtra = { ByteArrayInputStream: __JBAIS, InputStreamReader: __JISR, BufferedReader: __JBufReader, StringReader: __JStrReader };
  var io = J.io || {};
  var mergeIo = function(v){ io = v || {}; for (var k in ioExtra) { if (k == 'ByteArrayInputStream' || !(k in io)) io[k] = ioExtra[k]; } };
  mergeIo(io);
  try { Object.defineProperty(J, 'io', { configurable: true, enumerable: true, get: function(){ return io; }, set: mergeIo }); } catch (e) { J.io = io; }
})(Packages);
var javax = Packages.javax;