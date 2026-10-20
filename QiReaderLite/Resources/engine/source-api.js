/* ============================================================
 * source-api.js —— Legado 的 source.* / cookie.* 兼容层
 *
 * 聚合源（🍅大灰狼这类）重度依赖两条 Legado 专有通道：
 *   · source.getVariable() / setVariable()  —— **书籍变量**（存在源上的键值对）
 *   · cookie.getCookie(url) / setCookie()   —— **cookie 罐**
 *
 * ⚠️ 这两个在 Legado 里都是**同步** API（直接调 Kotlin/Java），
 *    而我们的原生桥是异步的（webkit.messageHandlers 只能 postMessage，
 *    回调才是异步）→ 没法在 JS 里 await 一次同步调用。
 *
 * 所以做法是：
 *   读 → **原生侧在调 op 之前把快照塞进 payload**，引擎侧同步读快照
 *   写 → 先落引擎内存，op 结束时由引擎把脏值回传给原生侧落盘
 *
 * ── 踩过的坑 ──
 * · 以前 `scope.source` 就是**原始 JSON 对象**，
 *   站方 JS 一调 `source.getVariable()` 就是
 *   「TypeError: source.getVariable is not a function」→
 *   整条规则静默失效（0 本书、0 个请求，界面上看不出任何报错）。
 *   所以 source 必须**包一层**，不能把裸对象塞进 scope。
 * · 书籍变量读出来是**字符串**（站方自己 JSON.parse），
 *   读不到时返回**空串**——多数站方有默认值兜底
 *   （本例大灰狼：getArguments 解析失败就退回 host[0] 当服务器）。
 * · cookie 快照按**域**存（host → "k=v; k2=v2"），
 *   读的时候先精确匹配，再做后缀匹配（v5.langge.uk ← langge.uk）。
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};

  /* ---------------------------------------------------------
   * cookie 罐（同步读快照）
   * ------------------------------------------------------- */

  /** host → "k=v; k2=v2" */
  var cookieSnapshot = {};

  function hostOf(url) {
    var s = String(url == null ? '' : url);
    try { return new URL(s).host; } catch (e) {}
    var m = s.match(/^[a-zA-Z][\w+.-]*:\/\/([^\/:?#]+)/);
    return m ? m[1] : s;
  }

  function cookiesFor(url) {
    var host = hostOf(url);
    if (!host) return '';
    if (Object.prototype.hasOwnProperty.call(cookieSnapshot, host)) {
      return cookieSnapshot[host] || '';
    }
    // 后缀匹配：v5.langge.uk → langge.uk
    var keys = Object.keys(cookieSnapshot);
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      if (!k) continue;
      if (host.length > k.length && host.slice(-(k.length + 1)) === '.' + k) {
        return cookieSnapshot[k] || '';
      }
    }
    return '';
  }

  function installCookie() {
    g.cookie = {
      /** 同步取 cookie 串 */
      getCookie: function (url) { return cookiesFor(url); },
      /** 写 cookie：本地先记一份（同步可见），真正落盘交给原生（异步） */
      setCookie: function (url, cookie) {
        var host = hostOf(url);
        cookieSnapshot[host] = String(cookie == null ? '' : cookie);
        QR.__qrDirtyCookie = true;
        try { if (QR.java && QR.java.setCookie) QR.java.setCookie(url, cookie); } catch (e) {}
        return '';
      },
      /** 删 cookie：本地先删（同步可见） */
      removeCookie: function (url) {
        var host = hostOf(url);
        if (Object.prototype.hasOwnProperty.call(cookieSnapshot, host)) {
          delete cookieSnapshot[host];
        }
        QR.__qrDirtyCookie = true;
        return '';
      },
      /** 取某个域下某个 cookie 的值 */
      getKey: function (host, name) {
        var c = cookiesFor(host);
        if (!c) return '';
        var parts = String(c).split(';');
        for (var i = 0; i < parts.length; i++) {
          var p = parts[i].trim();
          var idx = p.indexOf('=');
          if (idx > 0 && p.slice(0, idx) === String(name)) return p.slice(idx + 1);
        }
        return '';
      }
    };
  }

  /* ---------------------------------------------------------
   * source.* （Legado BaseSource 的那套）
   * ------------------------------------------------------- */

  /**
   * 给书源对象补上 Legado 的 API。**不能把裸对象塞进 scope** ——
   * 站方 JS 直接调 source.getVariable()，裸对象上没这方法就 TypeError。
   */
  function wrapSource(src) {
    if (!src || typeof src !== 'object') return src;
    if (src.__qireaderWrapped) return src;

    var wrapped = {};
    for (var k in src) {
      if (Object.prototype.hasOwnProperty.call(src, k)) wrapped[k] = src[k];
    }
    wrapped.__qireaderWrapped = true;

    // 书籍变量：原生侧塞进来的原始字符串（站方自己 JSON.parse）
    var vars = (src.__variables == null) ? '' : String(src.__variables);
    // 登录信息：原生侧塞进来的 map
    var loginInfo = src.__loginInfo && typeof src.__loginInfo === 'object'
      ? src.__loginInfo : {};

    /** 书籍变量 → map（读出来是字符串，站方会自己 parse） */
    wrapped.getVariable = function () { return vars; };

    /** 写书籍变量。两种写法：
     *   setVariable(jsonString)      —— 整份替换
     *   setVariable(key, value)      —— 改一项
     */
    wrapped.setVariable = function (a, b) {
      if (a && typeof a === 'object') {
        vars = JSON.stringify(a);
      } else if (b === undefined) {
        vars = String(a == null ? '' : a);
      } else {
        var m = {};
        try { m = JSON.parse(vars || '{}'); } catch (e) { m = {}; }
        m[String(a)] = String(b);
        vars = JSON.stringify(m);
      }
      QR.__qrDirtyVars = vars;
      return '';
    };

    /** 登录信息（map） */
    wrapped.getLoginInfoMap = function () { return loginInfo; };
    /** 登录信息（JSON 串） */
    wrapped.getLoginInfo = function () {
      try { return JSON.stringify(loginInfo); } catch (e) { return '{}'; }
    };
    /** 写登录信息。两种写法：
     *   putLoginInfo(jsonString)   —— 整份替换
     *   putLoginInfo(key, value)   —— 改一项
     */
    wrapped.putLoginInfo = function (a, b) {
      if (a && typeof a === 'object') {
        loginInfo = a;
      } else if (b === undefined) {
        try { loginInfo = JSON.parse(String(a == null ? '' : a)); } catch (e) { loginInfo = {}; }
      } else {
        loginInfo[String(a)] = String(b);
      }
      QR.__qrDirtyLogin = JSON.stringify(loginInfo);
      return '';
    };

    /** Legado 的 source.getKey()：给缓存当 key 用，稳定的源标识即可 */
    wrapped.getKey = function () {
      return String(src.bookSourceUrl || src.bookSourceName || '');
    };

    return wrapped;
  }

  /**
   * 书（book）也要包一层 —— 站方会调 `book.getVariable('custom')` 读书籍变量
   * （🍅大灰狼的 init 规则就调了）。裸对象上没这方法 → TypeError → 规则静默失效。
   */
  function wrapBook(book) {
    if (!book || typeof book !== 'object') return book;
    if (book.__qireaderBookWrapped) return book;
    var wrapped = {};
    for (var k in book) {
      if (Object.prototype.hasOwnProperty.call(book, k)) wrapped[k] = book[k];
    }
    wrapped.__qireaderBookWrapped = true;
    var vars = (book.variables && typeof book.variables === 'object') ? book.variables : {};
    wrapped.getVariable = function (key) {
      var v = vars[String(key)];
      return (v === undefined || v === null) ? '' : String(v);
    };
    wrapped.setVariable = function (key, value) {
      vars[String(key)] = String(value);
      return '';
    };
    return wrapped;
  }

  /* ---------------------------------------------------------
   * 对外
   * ------------------------------------------------------- */

  /** 原生侧在每次 op 前调用：装 cookie 快照 */
  QR.__qrInstallCookieSnapshot = function (snap) {
    cookieSnapshot = {};
    if (snap && typeof snap === 'object') {
      for (var k in snap) {
        if (Object.prototype.hasOwnProperty.call(snap, k)) cookieSnapshot[k] = String(snap[k] || '');
      }
    }
  };

  /** op 开始前清脏标记 */
  QR.__qrResetDirty = function () {
    QR.__qrDirtyVars = undefined;
    QR.__qrDirtyLogin = undefined;
    QR.__qrDirtyCookie = false;
  };

  /** op 结束后取脏值（给原生侧落盘） */
  QR.__qrTakeDirty = function () {
    var out = {};
    if (QR.__qrDirtyVars !== undefined) out.vars = QR.__qrDirtyVars;
    if (QR.__qrDirtyLogin !== undefined) out.login = QR.__qrDirtyLogin;
    if (QR.__qrDirtyCookie) out.cookie = true;
    return out;
  };

  QR.wrapSource = wrapSource;
  QR.wrapBook = wrapBook;
  installCookie();
})(typeof globalThis !== 'undefined' ? globalThis : self);
