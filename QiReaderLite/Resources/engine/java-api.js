/* ============================================================
 * java-api.js —— 站方书源里 java.* 的实现
 *
 * 一切出网请求都走原生桥（沙盒里的 fetch 会被 CORS/ATS 卡死，
 * 也没法复用 WKWebView 的 Cookie 罐），所以 java.ajax 这类必须
 * 转发给 NativeBridge。
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};

  var seq = 0;
  var pending = {};

  function nativeCall(fn, args, timeoutMs) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      var h = g.webkit && g.webkit.messageHandlers && g.webkit.messageHandlers.qr;
      if (!h) { reject(new Error('原生桥不可用')); return; }
      var timer = setTimeout(function () {
        if (pending[id]) { delete pending[id]; reject(new Error('原生调用超时: ' + fn)); }
      }, timeoutMs || 40000);
      pending[id] = function (v) { clearTimeout(timer); resolve(v); };
      h.postMessage({ id: id, fn: fn, args: args || {} });
    });
  }
  g.__qrResolve = function (id, value) {
    var f = pending[id];
    if (!f) return;
    delete pending[id];
    f(value);
  };

  /* ---------------- base64：三级兜底 ---------------- */

  function b64decode(s) {
    s = String(s == null ? '' : s).replace(/\s/g, '');
    // 1) 原生
    if (QR.java && QR.java._b64Dec) {
      try { var r = QR.java._b64Dec(s); if (r != null) return r; } catch (e) {}
    }
    // 2) atob（WKWebView 有，老 WebView 可能没有）
    if (typeof g.atob === 'function') {
      try {
        var bin = g.atob(s), arr = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
        return utf8Decode(arr);
      } catch (e) {}
    }
    // 3) 纯 JS 查表 + 分块，避免大字符串爆栈
    return utf8Decode(manualB64ToBytes(s));
  }

  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function manualB64ToBytes(s) {
    s = s.replace(/=+$/, '');
    var out = new Uint8Array(Math.floor(s.length * 3 / 4));
    var o = 0, buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      var v = B64C.indexOf(s[i]);
      if (v < 0) continue;
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; out[o++] = (buf >> bits) & 0xFF; }
    }
    return out.subarray(0, o);
  }

  function b64encode(str) {
    var bytes = utf8Encode(String(str == null ? '' : str));
    var CH = 0x8000, parts = [];
    for (var i = 0; i < bytes.length; i += CH) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CH)));
    }
    var bin = parts.join('');
    if (typeof g.btoa === 'function') { try { return g.btoa(bin); } catch (e) {} }
    var out = '';
    for (var j = 0; j < bin.length; j += 3) {
      var n = (bin.charCodeAt(j) << 16) | ((bin.charCodeAt(j + 1) || 0) << 8) | (bin.charCodeAt(j + 2) || 0);
      out += B64C[(n >> 18) & 63] + B64C[(n >> 12) & 63] + (j + 1 < bin.length ? B64C[(n >> 6) & 63] : '=') + (j + 2 < bin.length ? B64C[n & 63] : '=');
    }
    return out;
  }

  function utf8Encode(s) {
    if (typeof TextEncoder === 'function') return new TextEncoder().encode(s);
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        var c2 = s.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3FF) << 10) + (c2 & 0x3FF);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }

  function utf8Decode(bytes) {
    if (typeof TextDecoder === 'function') { try { return new TextDecoder('utf-8').decode(bytes); } catch (e) {} }
    var s = '', CH = 0x8000, parts = [];
    for (var i = 0; i < bytes.length; i += CH) parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CH)));
    return decodeURIComponent(escape(parts.join('')));
  }

  /* ---------------- HTTP ---------------- */

  function rawRequest(url, method, headers, data, timeout) {
    return nativeCall('request', {
      url: String(url || ''),
      method: String(method || 'GET').toUpperCase(),
      headers: headers || {},
      body: data == null ? '' : String(data),
      timeout: timeout ? timeout / 1000 : 20
    }).then(function (r) {
      if (!r || r.ok === false) throw new Error((r && r.error) || '请求失败');
      return {
        _code: r.code,
        _url: r.url,
        _redirectUrl: r.redirectUrl,
        _headers: r.headers || {},
        _body: r.body || '',
        code: r.code,
        url: r.url,
        headers: r.headers || {},
        body: r.body || '',
        baseUrl: r.url,
        request: { url: String(url || ''), method: method },
        string: function () { return r.body || ''; },
        bytes: function () { return utf8Encode(r.body || ''); },
        byteStream: function () { return utf8Encode(r.body || ''); },
        charStream: function () { return r.body || ''; },
        contentType: function () { return (r.headers && (r.headers['Content-Type'] || r.headers['content-type'])) || ''; },
        cookie: function () { return (r.headers && (r.headers['Set-Cookie'] || r.headers['set-cookie'])) || ''; },
        header: function (n) { var h = r.headers || {}; return h[n] || h[n.toLowerCase()] || ''; },
        ok: function () { return r.code >= 200 && r.code < 400; }
      };
    });
  }

  /* ---------------- java.* ---------------- */

  function mkJsoupish(resp) {
    return QR.jsoup.Jsoup.parse(resp._body, resp._url || resp.url);
  }

  /* 本地变量存储：跨规则传递中间结果。
     {{java.put("cid",7)}} 必须同步返回，否则插值会变成 "[object Promise]"。
     注意 java.get(k) 取的是这里，跟发 HTTP 的 java.get(url) 是两个函数。 */
  function varStore() {
    if (!QR.runtime) QR.runtime = {};
    return QR.runtime.vars || (QR.runtime.vars = {});
  }

  var java = {
    // --- 网络 ---
    ajax: function (url) { return applyUrlArg(url, function (u) { return java.get(u); }); },
    get: function (url, headers) { return rawRequest(resolveUrl(url), 'GET', headers || {}, null, 20000).then(mkJsoupish); },
    post: function (url, body, headers) { return rawRequest(resolveUrl(url), 'POST', headers || {}, body, 20000).then(mkJsoupish); },
    put: function (url, body, headers) { return rawRequest(resolveUrl(url), 'PUT', headers || {}, body, 20000).then(mkJsoupish); },
    delete: function (url, headers) { return rawRequest(resolveUrl(url), 'DELETE', headers || {}, null, 20000).then(mkJsoupish); },
    head: function (url, headers) { return rawRequest(resolveUrl(url), 'HEAD', headers || {}, null, 20000).then(mkJsoupish); },
    ajaxAsync: function (url) { return applyUrlArg(url, function (u) { return java.getAsync(u); }); },
    getAsync: function (url) { return java.get(url); },
    postAsync: function (url, body, headers) { return java.post(url, body, headers); },
    getPromise: function (url) { return java.get(url); },
    postPromise: function (url, body, headers) { return java.post(url, body, headers); },
    ajaxPromise: function (url) { return java.get(url); },
    connect: function (url) { return new QR.jsoup.Connection(resolveUrl(url)); },
    connectAsync: function (url) { return java.connect(url).execute().then(mkJsoupish); },
    getStrResponse: function (url, headers) { return java.get(url, headers); },
    getSource: function (url) { return java.get(url).then(function (d) { return d.raw().documentElement.outerHTML; }); },
    webView: function (html, url) { return Promise.reject(new Error('当前版本未实现 webView 交互')); },
    startBrowser: function () { return Promise.reject(new Error('当前版本未实现交互式浏览器')); },
    openUrl: function (url) { return java.open(url); },
    open: function (url) { return java.open(url); },

    // --- 字符串 / 编码 ---
    base64Encode: function (s) { return b64encode(s); },
    base64Decode: function (s) { return b64decode(s); },
    base64DecodeToByteArray: function (s) {
      try { return manualB64ToBytes(String(s || '').replace(/\s/g, '')); } catch (e) { return new Uint8Array(0); }
    },
    md5Encode: function (s) { return hexDigest(String(s == null ? '' : s), 'md5'); },
    md5Encode16: function (s) { return hexDigest(String(s == null ? '' : s), 'md5').slice(0, 16); },
    sha1Encode: function (s) { return hexDigest(String(s == null ? '' : s), 'sha-1'); },
    encodeURI: function (s) { return g.encodeURI(String(s == null ? '' : s)); },
    encodeURIComponent: function (s) { return g.encodeURIComponent(String(s == null ? '' : s)); },
    escape: function (s) { return g.escape(String(s)); },
    unescape: function (s) { return g.unescape(String(s)); },
    htmlFormat: function (s) { return String(s == null ? '' : s); },
    regex: function (re, s) { try { return new RegExp(re).exec(String(s)); } catch (e) { return null; } },
    getString: function (arr) {
      if (Array.isArray(arr)) return java.getStringArray(arr);
      return nativeCall('getString', { str: String(arr == null ? '' : arr) }).then(function (r) { return b64decode(r.value); });
    },
    getStringArray: function (list) {
      var arr = list == null ? [] : (Array.isArray(list) ? list : [list]);
      return nativeCall('getStringArray', { list: arr.map(String) })
        .then(function (r) { return (r.value || []).map(b64decode); });
    },
    getStringWrapper: function (s) { return String(s == null ? '' : s); },
    /**
     * Legado 的 java.timeFormat：把日期字符串转成 epoch 毫秒。
     * 书源常写 `updateTime: "{{java.timeFormat(java.getString('$.updateDate'))}}"`
     * 来给章节标时间。站方给的多是 "2017-04-24 14:16:34" / "2017/04/24" /
     * "2017-04-24T14:16:34.000Z"，这里做纯 JS 解析，不碰原生。
     * 解析不了就返回 0（跟 Legado 一样，不抛）。
     */
    timeFormat: function (t) {
      var s = String(t == null ? '' : t).trim();
      if (!s) return 0;
      if (/^\d+$/.test(s)) { var n0 = parseInt(s, 10); return s.length <= 10 ? n0 * 1000 : n0; }
      var m = s.match(/(\d{4})[-\/年](\d{1,2})[-\/月](\d{1,2})日?(?:[T\s]+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
      if (m) {
        return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
      }
      var d = new Date(s);
      var ms = d.getTime();
      return isNaN(ms) ? 0 : ms;
    },

    // 本地变量：跨规则传递中间结果。语料里 java.put/java.get 有 800+ 条
    put: function (k, v) { varStore()[String(k)] = v; return v; },
    get: function (k) {
      var st = varStore(), key = String(k);
      return Object.prototype.hasOwnProperty.call(st, key) ? st[key] : '';
    },
    getString: function (k) { return String(java.get(k)); },
    getInt: function (k) { return parseInt(java.get(k), 10) || 0; },
    getFloat: function (k) { return parseFloat(java.get(k)) || 0; },
    getObject: function (k) { var v = java.get(k); try { return JSON.parse(v); } catch (e) { return v; } },
    getList: function (k) { var v = java.get(k); return Array.isArray(v) ? v : String(v).split(/\n/); },
    del: function (k) { delete varStore()[String(k)]; },
    containsKey: function (k) { return String(k) in varStore(); },
    clear: function () { QR.runtime.vars = {}; },
    importScript: function (path) { return nativeCall('importScript', { path: String(path) }); },
    getWebViewUA: function () { return nativeCall('getWebViewUA', {}).then(function (r) { return r.value; }); },

    // --- DOM ---
    getElements: function (rule, base) { return QR.rule.getElements(rule, base); },
    getElement: function (rule, base) {
      var a = QR.rule.getElements(rule, base);
      return (a && a.length) ? a[0] : null;
    },
    setContent: function (html) { return nativeCall('setContent', { html: String(html == null ? '' : html) }); },

    // --- 补齐：125 源聚合包里用到、轻阅原本没有的 ---
    // 依据：运行时逐个 typeof java.X === 'function' 点名出来的，不是 grep 源码
    // （源码里赋值形态五花八门，grep 会误判 —— java.io / java.util 这些包引用更会误报）
    ajaxAll: function (urlList) {
      var urls = Array.isArray(urlList) ? urlList : [urlList];
      // 返回带 body()/bodyStr()/headers()/code() 的 StrResponse 数组，跟 Legado 对齐
      return Promise.all(urls.map(function (u) {
        return java.ajax(u).then(function (r) {
          return {
            url: String(u),
            code: r && r.code != null ? r.code : 200,
            bodyStr: function () { return r && r.body != null ? String(r.body) : ''; },
            body: function () { return { string: function () { return this.bodyStr(); } }; },
            headers: function () { return {}; },
            toString: function () { return this.bodyStr(); }
          };
        });
      }));
    },
    getAbsoluteURL: function (u, base) {
      try { return new URL(String(u), String(base || java.getString('$.baseUrl') || '')).href; }
      catch (e) { return String(u); }
    },
    // 简繁转换：轻阅不做真实 OpenCC，靠词表兜底；至少不是 undefined
    t2s: function (t) { return String(t == null ? '' : t); },
    // UTC 版 timeFormat：轻阅统一按本地时区，这里保持签名不报错
    timeFormatUTC: function (t, f) { return java.timeFormat(t, f); },
    hexDecodeToString: function (hex) {
      var h = String(hex == null ? '' : hex).replace(/[^0-9a-fA-F]/g, '');
      var out = '';
      for (var i = 0; i + 1 < h.length; i += 2) out += String.fromCharCode(parseInt(h.substr(i, 2), 16));
      try { return decodeURIComponent(escape(out)); } catch (e) { return out; }
    },
    randomUUID: function () {
      // 必须是 v4 格式：书源常拿它当签名 nonce
      if (g.crypto && g.crypto.randomUUID) return g.crypto.randomUUID();
      var b = new Uint8Array(16);
      if (g.crypto && g.crypto.getRandomValues) g.crypto.getRandomValues(b);
      else for (var i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
      b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
      var h = [];
      for (var j = 0; j < 16; j++) h.push((b[j] + 0x100).toString(16).substr(1));
      return h.slice(0, 4).join('') + '-' + h.slice(4, 6).join('') + '-' +
             h.slice(6, 8).join('') + '-' + h.slice(8, 10).join('') + '-' + h.slice(10).join('');
    },
    // 触发宿主动作：沙盒里没有真 UI，返回「不可用」而不是静默 undefined
    refreshExplore: function () { return nativeCall('refreshExplore', {}); },
    refreshTocUrl: function () { return nativeCall('refreshTocUrl', {}); },
    showBrowser: function (url) { return nativeCall('showBrowser', { url: resolveUrl(url) }); },
    startBrowserAwait: function (url) {
      return nativeCall('showBrowser', { url: resolveUrl(url) }).then(function (r) { return r && r.value; });
    },
    reLoginView: function (a) { return nativeCall('reLoginView', { msg: String(a == null ? '' : a) }); },
    searchBook: function (key) { return nativeCall('searchBook', { key: String(key == null ? '' : key) }); },
    toNumChapter: function (name) {
      // 「第 123 章」→ 123；书源拿它排序用
      var m = String(name == null ? '' : name).match(/(\d+)/);
      return m ? parseInt(m[1], 10) : -1;
    },
    createSymmetricCrypto: function (key, iv, mode) {
      // 对齐 java.createSymmetricCrypto(key, iv, transformation) 的形状。
      // 轻阅没有真 Cipher 实例，这里给一个能用 java.encryptBase64/decryptBase64 的壳
      var K = String(key == null ? '' : key), I = iv == null ? '' : String(iv);
      var MODE = String(mode == null ? 'AES/CBC/PKCS5Padding' : mode).toUpperCase();
      function pad(s, n) {
        var padLen = n - (s.length % n);
        var r = '';
        for (var i = 0; i < padLen; i++) r += String.fromCharCode(padLen);
        return s + r;
      }
      return {
        encrypt: function (text) { return nativeCall('symmetricCrypto', { op: 'encrypt', key: K, iv: I, mode: MODE, text: String(text == null ? '' : text), pad: true }); },
        decrypt: function (b64) { return nativeCall('symmetricCrypto', { op: 'decrypt', key: K, iv: I, mode: MODE, text: String(b64 == null ? '' : b64) }); },
        encryptBase64: function (text) { return nativeCall('symmetricCrypto', { op: 'encrypt', key: K, iv: I, mode: MODE, text: String(text == null ? '' : text), b64: true, pad: true }); },
        decryptBase64: function (b64) { return nativeCall('symmetricCrypto', { op: 'decrypt', key: K, iv: I, mode: MODE, text: String(b64 == null ? '' : b64) }); },
        getKey: function () { return K; },
        getIv: function () { return I; }
      };
    },
    getStringMatch: function (rule, text) { return QR.rule.stringMatchAll(rule, text); },

    // --- 杂项 ---
    log: function () {
      var msg = Array.prototype.map.call(arguments, function (a) {
        try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); }
      }).join(' ');
      return nativeCall('log', { msg: msg });
    },
    longToast: function (s) { return nativeCall('toast', { msg: String(s) }); },
    toast: function (s) { return nativeCall('toast', { msg: String(s) }); },
    getCookie: function (url) { return nativeCall('getCookie', { url: resolveUrl(url) }).then(function (r) { return r.value; }); },
    setCookie: function (url, cookie) { return nativeCall('setCookie', { url: resolveUrl(url), cookie: String(cookie) }); },
    cacheFile: function (path, content) { return nativeCall('cacheFile', { path: String(path), text: String(content == null ? '' : content) }).then(function (r) { return r.value === '1'; }); },
    cacheText: function (path) { return nativeCall('readCache', { path: String(path) }).then(function (r) { return r.value; }); },
    readFile: function (path) { return nativeCall('readFile', { path: String(path) }).then(function (r) { return r.value; }); },
    deviceID: function () { return nativeCall('deviceID', {}).then(function (r) { return r.value; }); },
    androidId: function () { return java.deviceID(); },
    getLang: function () { return 'zh-CN'; },
    isWhiteList: function () { return true; },
    startBrowser_: null,
    lang: g.navigator ? g.navigator.language : 'zh-CN'
  };

  java.cacheFileRaw = rawRequest;
  java.rawRequest = rawRequest;
  java._b64Dec = null;   // 原生 base64 通道，预留给将来的注入

  function applyUrlArg(url, fn) {
    if (url && typeof url === 'object') {
      return fn(resolveUrl(url.url)).then(function (d) {
        return d;
      });
    }
    return fn(resolveUrl(url));
  }

  function resolveUrl(u) {
    if (!u) return '';
    if (typeof u !== 'string') u = u.url || '';
    if (/^https?:\/\//i.test(u)) return u;
    var base = (QR.runtime && QR.runtime.baseUrl) || g.location.href;
    try { return new URL(u, base).href; } catch (e) { return u; }
  }

  /* md5 / sha-1 纯 JS 实现（Crypto.subtle 在 file:// 下不可用，不能指望） */
  function hexDigest(str, algo) {
    var bytes = utf8Encode(str);
    // SHA-1 走内联的验证过实现（见 sha1.js），别再手写轮函数
    if (algo === 'sha-1' || algo === 'sha1') return QR.sha1(bytes);
    return md5hex(bytes);
  }

  function md5hex(bytes) {
    var K = [], i, j;
    // 64 步的移位量表：四轮分别是 7,12,17,22 / 5,9,14,20 / 4,11,16,23 / 6,10,15,21
    var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
             5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
             4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
             6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    function rr(n, s) { return (n << s) | (n >>> (32 - s)); }
    for (i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296);
    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    var len = bytes.length;
    var withPad = new Uint8Array(((len + 8) >> 6) * 64 + 64);
    withPad.set(bytes);
    withPad[len] = 0x80;
    var bitsLo = (len << 3) >>> 0, bitsHi = Math.floor(len / 0x20000000);
    var dp = withPad.length - 8;
    withPad[dp] = bitsLo & 0xFF; withPad[dp + 1] = (bitsLo >>> 8) & 0xFF;
    withPad[dp + 2] = (bitsLo >>> 16) & 0xFF; withPad[dp + 3] = (bitsLo >>> 24) & 0xFF;
    withPad[dp + 4] = bitsHi & 0xFF; withPad[dp + 5] = (bitsHi >>> 8) & 0xFF;
    withPad[dp + 6] = (bitsHi >>> 16) & 0xFF; withPad[dp + 7] = (bitsHi >>> 24) & 0xFF;

    for (i = 0; i < withPad.length; i += 64) {
      var M = new Int32Array(16);
      for (j = 0; j < 16; j++) M[j] = withPad[i + j * 4] | (withPad[i + j * 4 + 1] << 8) | (withPad[i + j * 4 + 2] << 16) | (withPad[i + j * 4 + 3] << 24);
      var A = a0, B = b0, C = c0, D = d0;
      for (j = 0; j < 64; j++) {
        var F, g;
        if (j < 16) { F = (B & C) | (~B & D); g = j; }
        else if (j < 32) { F = (D & B) | (~D & C); g = (5 * j + 1) % 16; }
        else if (j < 48) { F = B ^ C ^ D; g = (3 * j + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * j) % 16; }
        F = (F + A + K[j] + M[g]) | 0;
        A = D; D = C; C = B;
        B = (B + rr(F, S[j])) | 0;
      }
      a0 = (a0 + A) | 0; b0 = (b0 + B) | 0; c0 = (c0 + C) | 0; d0 = (d0 + D) | 0;
    }
    return le32(a0) + le32(b0) + le32(c0) + le32(d0);
  }
  function le32(n) {
    return [n & 0xFF, (n >>> 8) & 0xFF, (n >>> 16) & 0xFF, (n >>> 24) & 0xFF]
      .map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join('');
  }
  g.java = g.java || {};
  for (var k in java) { if (typeof java[k] === 'function') g.java[k] = java[k]; }
  g.java.lang = { String: function (s) { return String(s); } };

  QR.java = java;
})(typeof globalThis !== 'undefined' ? globalThis : self);
