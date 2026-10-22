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
  /**
   * 本次 op 里**从浏览器合并回来**的域。
   *
   * ⚠️⚠️ **必须在这里声明！**（踩过一次：用了没声明 → ReferenceError）
   *    `__qrInstallCookieSnapshot` 每个 op 开头都会执行 → 一执行就抛
   *    → **每个 op 都失败** → 引擎等于废了 → 用户看到「登录都点不了了」。
   *
   * 用途：站方 🍅番茄登录第一步是 `cookie.removeCookie("fanqienovel.com")`
   *（清旧会话），而两遍跑下这段会跑两遍 → 第二遍会把**刚从浏览器拿到的**
   * sessionid 删掉 → removeCookie 靠这个表跳过它们。
   */
  var mergedHosts = {};

  function hostOf(url) {
    var s = String(url == null ? '' : url);
    try { return new URL(s).host; } catch (e) {}
    var m = s.match(/^[a-zA-Z][\w+.-]*:\/\/([^\/:?#]+)/);
    return m ? m[1] : s;
  }

  function cookiesFor(url) {
    var host = hostOf(url);
    if (!host) return '';
    // ⚠️ 从 QR.__qrCookieSnapshot 读（不是模块内的闭包变量）——
    //    浏览器里刚登录出来的 cookie 是**中途**产生的，
    //    op 开头拍的那份快照里没有 → 站方 getKey 拿不到 → 「未获取到登录凭据」。
    var snap = QR.__qrCookieSnapshot || cookieSnapshot;
    if (Object.prototype.hasOwnProperty.call(snap, host)) {
      return snap[host] || '';
    }
    // 后缀匹配：v5.langge.uk → langge.uk
    var keys = Object.keys(snap);
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      if (!k) continue;
      if (host.length > k.length && host.slice(-(k.length + 1)) === '.' + k) {
        return snap[k] || '';
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
      /**
       * 删 cookie：本地先删（同步可见），**真罐也要删**（原生侧）
       *
       * ⚠️⚠️ **但刚从浏览器拿回来的域不能删！**
       *
       * 站方 🍅番茄登录（fq_login）的第一步就是：
       *     cookie.removeCookie("snssdk.com");
       *     cookie.removeCookie("fanqienovel.com")     // ← 清掉旧会话
       *     java.startBrowserAwait("https://fanqienovel.com/", "登录")
       *     ... cookie.getKey("fanqienovel.com", "sessionid")
       *
       * 在**两遍跑**下这段站方代码会跑两遍：
       *   第一遍：清旧 cookie → 录下浏览器 → （fetchRecorded 里）真的弹浏览器、
       *           用户登录完，**sessionid 合并回快照**
       *   第二遍：又执行一遍「清旧 cookie」→ **把刚合并进来的 sessionid 删了** ❌
       *            → 站方 getKey 拿不到 → 「未获取到登录凭据，登录失败」
       *
       * 所以：**本次 op 里从浏览器合并回来的域，removeCookie 一律跳过**。
       * （退出登录那种没有浏览器的 op 不受影响 —— 照样真删 ✅）
       */
      removeCookie: function (url) {
        var host = hostOf(url);
        if (mergedHosts[host]) {
          // 刚从浏览器拿到的登录凭据 → 不动它
          return '';
        }
        if (Object.prototype.hasOwnProperty.call(cookieSnapshot, host)) {
          delete cookieSnapshot[host];
        }
        if (QR.__qrCookieSnapshot && Object.prototype.hasOwnProperty.call(QR.__qrCookieSnapshot, host)) {
          delete QR.__qrCookieSnapshot[host];
        }
        QR.__qrDirtyCookie = true;
        // ⚠️ 以前只删了本地快照，**真 cookie 罐（原生 HTTPCookieStorage）没动**
        //    → 站方的「退出登录」是空操作 → 退出后 cookie 又在 → 看起来没退出。
        //    现在同步通知原生删掉。
        try { if (QR.java && QR.java.removeCookie) QR.java.removeCookie(url); } catch (e) {}
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

    /* ────────────────────────────────────────────────────────────
     * ⚠️⚠️⚠️ **Legado 风格：`source.get(key)` / `source.put(key, value)`**（2026-10-22 真机查出来的）
     *
     *   站方（🍒NovelHub 聚合源）**大量**用这两个 API（实测 jsLib+loginUrl 共 71 处 get / 58 处 put）：
     *     source.get("nhAuthed")   source.put("nhAuthed", hash)
     *     source.get("nhSafeMode") source.put("nhUaaToken", …)
     *
     *   轻阅以前**只实现了 `getVariable` / `setVariable`**（整份 JSON 串）
     *   ⇒ `source.get(...)` ⇒ **TypeError: not a function**
     *   ⇒ 站方把它包在 try/catch 里 ⇒ **静默失败**：
     *      ① `nhAuth()` 里 `source.get("nhAuthed")` 抛 ⇒ catch ⇒ return false
     *         ⇒ **所有规则字段都直接 return ""** ⇒ 发现页空白 / 搜索没结果 ⭐
     *      ② `unlockAll()` 里 `source.put("nhAuthed", hash)` 抛 ⇒ 被吞
     *         ⇒ **解锁状态压根没存下来** ⇒ 但站方照样弹「🔓 已解锁」⇒ **假成功** ⭐
     *
     *   ⇒ 语义：**读/写「书籍变量」里的某一项**（跟 getVariable/setVariable 同一份 `vars`）
     *      `get` 没有该项 ⇒ 返回空串（站方都按「空串 = 没设置」处理）
     *      `put` 改一项 ⇒ 标 dirty（`QR.__qrDirtyVars`）⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘 ✅
     *
     *   ⚠️ **不能把 `get` 实现成「返回整份 vars」** —— 站方是
     *      `String(source.get("nhAuthed") || "")` 这样比对的，
     *      拿到整份 JSON 的话哈希对不上 ⇒ 还是不解锁。
     * ──────────────────────────────────────────────────────────── */
    function varsMap() {
      var m = {};
      try { m = JSON.parse(vars || '{}') || {}; } catch (e) { m = {}; }
      if (!m || typeof m !== 'object') m = {};
      return m;
    }
    /** 读书籍变量的某一项（没有 ⇒ 空串） */
    wrapped.get = function (key) {
      var m = varsMap();
      var v = m[String(key)];
      return (v === undefined || v === null) ? '' : String(v);
    };
    /** 写书籍变量的某一项 */
    wrapped.put = function (key, value) {
      var m = varsMap();
      m[String(key)] = String(value == null ? '' : value);
      vars = JSON.stringify(m);
      QR.__qrDirtyVars = vars;
      return '';
    };

    /** 登录信息（map） */
    wrapped.getLoginInfoMap = function () { return loginInfo; };

    // ── loginHeader（栖阅机制，§9.2 🟢）──
    // 「存的是纯字符串，**会自动注入到每次请求头**」
    // 用途：番茄的 sessionid 之类「不来自 cookie 罐、但每个请求都要带」的凭据。
    // 聚合源（🍅大灰狼）要 sessionid 才能同步番茄数据，
    // 而它只能从 cookie 罐里翻 → 在 Safari 登录的读不到 → 一直提示「未登录番茄」。
    // 有了 loginHeader：填一次 → 之后每个请求自动带上 ✅
    var loginHeader = (src.__loginHeader == null) ? '' : String(src.__loginHeader);
    wrapped.getLoginHeader = function () { return loginHeader; };
    wrapped.putLoginHeader = function (v) {
      loginHeader = String(v == null ? '' : v);
      QR.__qrDirtyLoginHeader = loginHeader;
      return '';
    };
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
    // Legado 的 Book 上还有这几个方法，站方会调
    // （🍅大灰狼的 init 规则就调了 book.setUseReplaceRule / book.readConfig）
    wrapped.readConfig = wrapped.readConfig || {};
    ['setUseReplaceRule', 'setUseReplaceJs', 'setChapterUpdateMode',
     'setSearchTocUrl', 'setChapterUrl'].forEach(function (fn) {
      wrapped[fn] = function () { return ''; };
    });
    return wrapped;
  }

  /* ---------------------------------------------------------
   * 对外
   * ------------------------------------------------------- */

  /** 原生侧在每次 op 前调用：装 cookie 快照 */
  QR.__qrInstallCookieSnapshot = function (snap) {
    cookieSnapshot = {};
    QR.__qrCookieSnapshot = cookieSnapshot;
    // 本次 op 里**从浏览器合并回来的**域 —— 见下面 removeCookie 的注释
    mergedHosts = {};
    if (snap && typeof snap === 'object') {
      for (var k in snap) {
        if (Object.prototype.hasOwnProperty.call(snap, k)) cookieSnapshot[k] = String(snap[k] || '');
      }
    }
  };

  /**
   * 把浏览器里新产生的 cookie 合并进快照（登录后立刻要用）
   *
   * ⚠️ 同时记进 `mergedHosts`：这次 op 里**从这个浏览器拿到的**域。
   *    removeCookie 要靠它避免把「刚拿到的登录 cookie」又删掉（见下）。
   */
  QR.__qrMergeCookie = function (host, cookie) {
    if (!host || !cookie) return;
    var snap = QR.__qrCookieSnapshot || (QR.__qrCookieSnapshot = {});
    snap[host] = String(cookie);
    mergedHosts[host] = true;
  };

  /** op 开始前清脏标记 */
  QR.__qrResetDirty = function () {
    QR.__qrDirtyVars = undefined;
    QR.__qrDirtyLogin = undefined;
    QR.__qrDirtyLoginHeader = undefined;
    QR.__qrDirtyCookie = false;
  };

  /** op 结束后取脏值（给原生侧落盘） */
  QR.__qrTakeDirty = function () {
    var out = {};
    if (QR.__qrDirtyVars !== undefined) out.vars = QR.__qrDirtyVars;
    if (QR.__qrDirtyLogin !== undefined) out.login = QR.__qrDirtyLogin;
    if (QR.__qrDirtyLoginHeader !== undefined) out.loginHeader = QR.__qrDirtyLoginHeader;
    if (QR.__qrDirtyCookie) out.cookie = true;
    return out;
  };

  QR.wrapSource = wrapSource;
  QR.wrapBook = wrapBook;
  installCookie();
})(typeof globalThis !== 'undefined' ? globalThis : self);
