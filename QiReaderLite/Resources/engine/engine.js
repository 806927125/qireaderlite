/* ============================================================
 * engine.js —— 对外的操作入口
 *
 * Swift 侧只调 window.__qrInvoke(op, payload)，全部逻辑在这。
 * 返回值一律是可 JSON 序列化的普通对象，Promise 会被 callAsyncJavaScript 自动 await。
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};
  var dom = QR.dom;
  var rule = QR.rule;

  // 每次调用带上当前书源，java.* 和规则里的 source 都靠它
  var runtime = { source: null, baseUrl: '', page: 1 };
  QR.runtime = runtime;

  /* ---------------------------------------------------------
   * jsLib：每个书源可能有自定义 JS 库，规则里能直接调它的函数
   * ------------------------------------------------------- */

  var libLoaded = {};
  // ⚠️⚠️⚠️ **全局态治理**（2026-10-22 用户反馈「用了大灰狼之后别的书源加载就有问题」）
  //   jsLib 是**间接 eval** 加载的 ⇒ 它的 `var` / `function` **全部进全局作用域**
  //   ⇒ 大灰狼的 `host` / `getArguments` / `getFanqieCookie` / `createFilter` / …
  //   **全都留在全局** ⇒ 别的书源一用同名标识符就串 ⭐
  //   （栖阅有 `restoreMutatedBaseGlobals` / `purgeUnexpectedGlobals` 防这个，轻阅以前没有）
  //
  //   ⇒ 记下「**本次 jsLib 新增了哪些全局**」⇒ 切书源时**删掉它们**
  //   ⇒ ⚠️ 只删「新增的」就够：**同名被覆盖的**不用管 ——
  //      新书源会自己再定义一遍（它要的就是自己的值），
  //      切回旧书源时 jsLib 会重新加载 ⇒ 也会重新定义 ⇒ 无残留 ✅
  var libGlobals = {};
  // ⚠️⚠️⚠️ **被站方 jsLib 改写的全局的【原值】**（2026-10-22 真机「导入另一个源后大灰狼目录 0 章」）
  //   站方 jsLib 是**间接 eval** ⇒ `var host = [...]` / `function getArguments(){}` 会**覆盖**
  //   **同名**的全局 ⇒ 两个源的 jsLib 都有 `host` / `getArguments` 时 ⇒ **后加载的赢**
  //   ⇒ 大灰狼的 `host`（线路数组）/ `getArguments`（取 server）被换成别的源的
  //   ⇒ `base_url` 取错 ⇒ `/catalog` 打到错的服务器 ⇒ **返回空 ⇒ 目录 0 章** ⭐
  //
  //   ⇒ 光「删掉新增的」**不够**（同名覆盖是**改值**不是新增）⇒ 必须**把原值还原** ✅
  //   （这就是栖阅的 `restoreMutatedBaseGlobals`）
  var libChanged = {};
  var libOwner = '';   // 当前全局属于哪个书源

  function globalNames() {
    try { return Object.getOwnPropertyNames(g); } catch (e) { return []; }
  }

  function purgeLibGlobals(key) {
    // ① 站方**新增**的全局 ⇒ 删掉
    var names = libGlobals[key] || [];
    for (var i = 0; i < names.length; i++) {
      var n = names[i];
      try { delete g[n]; } catch (e) { try { g[n] = undefined; } catch (e2) {} }
    }
    libGlobals[key] = [];
    // ② 站方**改写**的全局 ⇒ **把原值还原**（同名覆盖的真相）
    var ch = libChanged[key] || {};
    for (var cn in ch) {
      try { g[cn] = ch[cn]; } catch (e) { /* 忽略 */ }
    }
    libChanged[key] = {};
    // ③ ★ **删掉 libLoaded** ⇒ 切回这个源时 **jsLib 一定会重新加载**
    //   ⇒ 站方自己的 `var host = [...]` / `function getArguments(){}` 会**重新定义**
    //   ⇒ **同名污染一定被覆盖回去**（哪怕中途还有别的源插进来）✅
    delete libLoaded[key];
  }

  function ensureJsLib(source) {
    var key = (source && (source.bookSourceUrl || source.bookSourceName)) || 'anon';
    // ⚠️⚠️ **切书源 ⇒ 清掉上一个书源留下的全局**（防串台）
    if (libOwner && libOwner !== key) {
      try {
        QR.java.log('[全局治理] 切书源 ⇒ 清掉上一个源留下的 ' +
          ((libGlobals[libOwner] || []).length) + ' 个全局变量');
      } catch (e) {}
      purgeLibGlobals(libOwner);
      libOwner = '';
    }
    // ⚠️ 线路列表**每次重置**（换线兜底只能用**当次书源**的线路）
    QR.__qrStationHosts = [];
    if (!source || !source.jsLib) return Promise.resolve();
    if (libLoaded[key]) {
      // 已加载过（同一书源连续用）⇒ 不重复 eval，但线路列表要从全局再取一次
      try {
        if (typeof host !== 'undefined' && Array.isArray(host) && host.length) {
          QR.__qrStationHosts = host.slice();
        }
      } catch (e) {}
      return Promise.resolve();
    }
    libLoaded[key] = true;
    var code = String(source.jsLib);
    var namesBefore = globalNames();
    // ⚠️ 基线快照（名字 → 值）⇒ 站方改写了谁，切源时把谁还原回去
    var snapshotBefore = {};
    for (var sb = 0; sb < namesBefore.length; sb++) {
      try { snapshotBefore[namesBefore[sb]] = g[namesBefore[sb]]; } catch (e) {}
    }
    try {
      /* jshint evil:true */
      // ⚠️ 这里原来用的是
      //     new Function('java','org','cache','cookie','source','book','chapter', code).call(g, ...)
      //    —— jsLib 里的 `function foo(){}` 声明会落在**那个函数的局部作用域**里，
      //    规则 JS 根本看不到。于是「jsLib 定义签名/解密函数 → 规则里调用」
      //    这种最常见的书源写法直接失效（而且不报任何错，调用时才 ReferenceError）。
      //
      //    改成**间接 eval**（(0, eval)）：间接 eval 在**全局作用域**执行，
      //    函数声明进全局；规则 JS 同样是 new Function（作用域链挂在全局上），
      //    于是能直接调到 —— 跟 Legado/Rhino 的共享 scope 语义一致。
      //    实测：严格模式下 new Function + 间接 eval，声明照样进全局。
      //
      //    副作用：jsLib 里的 var 也会进全局（Rhino 共享 scope 也是这样，可接受）。
      var fn = new Function('__code', 'return (0, eval)(__code);');

      // 原来靠形参提供的宿主变量，改 eval 后得自己摆到全局上。
      // java / org 本来就是全局的；cache / cookie 没有就补个空壳
      // （跟 makeScope 里 `cache: g.cache` 的行为对齐，不会比原来更差）。
      var addedCache = false, addedCookie = false;
      if (typeof g.cache === 'undefined') { g.cache = {}; addedCache = true; }
      if (typeof g.cookie === 'undefined') { g.cookie = {}; addedCookie = true; }
      var prevSource = g.source, prevBook = g.book, prevChapter = g.chapter;
      // jsLib 里的 checkEnv() 会摸 this.source（要判是安卓还是改版），
      // 所以这里也得给**包过 API 的**那份。
      g.source = QR.wrapSource ? QR.wrapSource(source) : source;
      g.book = undefined; g.chapter = undefined;
      try {
        fn(code);
      } finally {
        g.source = prevSource; g.book = prevBook; g.chapter = prevChapter;
        void addedCache; void addedCookie;
      }
      // ⚠️⚠️ **把站方的线路列表存一份**（2026-10-22 真机「QQ 阅读目录出不来」）：
      //   站方 jsLib 里的 `var host = [...]`（8 条线路）是**换线兜底的唯一依据**
      //   ⇒ 引擎侧在「这条线路 5xx 了」时要能拿到它 ⇒ 换一条重试
      //   ⇒ 存一份到 `QR.__qrStationHosts`（**只属于当次书源** ⇒ 不会串台）
      try {
        if (typeof host !== 'undefined' && Array.isArray(host) && host.length) {
          QR.__qrStationHosts = host.slice();
        }
      } catch (e) { /* 忽略 */ }
    } catch (e) {
      QR.java.log('[jsLib 出错] ' + (source.bookSourceName || key) + ': ' + e.message);
    }
    // ⚠️⚠️⚠️ **记账要放在 try/catch【外面】**（2026-10-22 真机栽在这）：
    //   以前记账在 try 里 ⇒ **站方 jsLib 一旦抛异常** ⇒ 已定义的全局**没被记账**
    //   ⇒ 切书源时清不掉 ⇒ **污染永久留下** ⇒ 别的源一直坏 ⭐
    //   ⇒ 现在：无论成功失败都记账 ✅
    try {
      var after = globalNames();
      var added = [];
      var changed = {};
      for (var gi = 0; gi < after.length; gi++) {
        var gn = after[gi];
        if (namesBefore.indexOf(gn) < 0) {
          added.push(gn);
        } else {
          // ⚠️ 同名但**值变了** ⇒ 记下原值，切源时还原
          try {
            if (g[gn] !== snapshotBefore[gn]) changed[gn] = snapshotBefore[gn];
          } catch (e2) {}
        }
      }
      libGlobals[key] = added;
      libChanged[key] = changed;
      libOwner = key;
      try {
        if (added.length || Object.keys(changed).length) {
          QR.java.log('[全局治理] 载入「' + (source.bookSourceName || key) + '」新增 ' +
            added.length + ' 个全局变量' +
            (Object.keys(changed).length ? ('、改写 ' + Object.keys(changed).length + ' 个（切书源时会还原）') : '') +
            '（切书源时会清掉）');
        }
      } catch (e3) {}
    } catch (e4) { /* 忽略 */ }
    return Promise.resolve();
  }

  /* ---------------------------------------------------------
   * 登录：loginUrl + 表单值
   * ------------------------------------------------------- */

  var loginLoaded = {};

  /**
   * 把 loginUrl 当 jsLib 一样加载进**全局作用域**。
   * 里面是 `function login(flag){…}` / `register()` / `checkStatus()` 这种定义，
   * 不加载到全局，登录界面点按钮时就找不到函数。
   */
  function ensureLoginLib(source) {
    if (!source || !source.loginUrl) return Promise.resolve();
    var key = (source.bookSourceUrl || source.bookSourceName || 'anon') + '#login';
    if (loginLoaded[key]) return Promise.resolve();
    loginLoaded[key] = true;
    // ⚠️ loginUrl 依赖 jsLib 里的东西（比如 `host` 服务器列表）→
    //    **必须先把 jsLib 加载了**，否则 loginUrl 一加载就 "host is not defined"。
    return ensureJsLib(source).then(function () {
    var prevSource = g.source;
    try {
      var fn = new Function('__code', 'return (0, eval)(__code);');
      g.source = QR.wrapSource ? QR.wrapSource(source) : source;
      try { fn(String(source.loginUrl)); }
      catch (e) { QR.java.log('[loginUrl 出错] ' + (source.bookSourceName || key) + ': ' + e.message); }
      finally { g.source = prevSource; }
    } catch (e) {
      g.source = prevSource;
      QR.java.log('[loginUrl 出错] ' + e.message);
    }
    return Promise.resolve();
    });
  }

  /* ---------------------------------------------------------
   * URL 模板
   * ------------------------------------------------------- */

  /**
   * 生成请求地址。
   *   搜索:   "https://x.com/s?q={{keyword}}&p={{page}}"
   *   带头:   "https://x.com/a,{\"headers\":{\"Referer\":\"...\"}}"
   *   动态:   "@js:java.ajax(base).toString()"
   */
  /**
   * 构造请求 URL —— 严格按 Legado 的三步顺序：
   *   ① analyzeJs()        执行 URL 里内嵌的 @js: / <js></js>
   *   ② replaceKeyPageJs() 展开 {{表达式}}（当 JS 求值）+ <1,2,3> 页码占位
   *   ③ analyzeUrl()       切 ,{json} 后缀 → 拼 method/body/headers
   *
   * 顺序不能换：Legado 注释写明「先替换内嵌规则再替换页数规则，
   * 避免内嵌规则中存在大于小于号时，规则被切错」。
   */
  function buildUrl(ruleStr, ctx) {
    var s = String(ruleStr == null ? '' : ruleStr).trim();
    if (!s) return Promise.resolve({ url: '', method: 'GET', body: '', headers: {} });

    s = analyzeJsInUrl(s, ctx);
    s = replaceKeyPageJs(s, ctx);
    return Promise.resolve(analyzeUrl(s, ctx));
  }

  /**
   * **规则产出的 URL**（bookUrl / tocUrl / chapterUrl）也要走 analyzeUrl ⭐
   *
   * ⚠️⚠️⚠️ 2026-10-22 适配 125 源时挖出来的（**目录 0 章的大头**）：
   *   站方规则常把「本次请求的 method / body / headers」写在 URL 后面：
   *     ruleBookInfo.tocUrl = 'https://chuangshi.qq.com/chapter/26150754,{"headers":{"User-Agent":"…"}}'
   *     ruleToc.chapterList = '<js>…java.ajax(url + "," + JSON.stringify(op))…'
   *   ⇒ Legado 语义：**逗号后那段 JSON = 本次请求的选项**（不是 URL 的一部分）
   *   ⇒ 轻阅以前**详情/目录/正文三个 op 都没走 analyzeUrl**（只有 explore/search 走了）
   *      ⇒ 后缀**原样发出去** ⇒ 服务端 404 / 拿到错页面 ⇒ **目录 0 章 / 详情空** ⭐
   *
   * ⚠️⚠️ **`data:` 伪 URL 不能走这条路**（聚合源用它塞载荷）：
   *   `data:;base64,<载荷>,{"type":"qingtian"}` ⇒ 那个 `,{"type":…}` 是
   *   **站方的类型标记**，不是请求选项 ⇒ 由 dataUrlContent 自己剥 ⭐
   *   ⇒ 所以这里对非 http(s) 的 scheme **原样返回**
   */
  function analyzeRuleUrl(raw, ctx) {
    var s = String(raw == null ? '' : raw).trim();
    if (!s) return Promise.resolve({ url: '', method: 'GET', body: '', headers: {} });
    if (!/^https?:\/\//i.test(s)) {
      return Promise.resolve({ url: s, method: 'GET', body: '', headers: {} });
    }
    return buildUrl(s, ctx);
  }

  /** URL 里的 JS 作用域：key=搜索词，page=页码，baseUrl，source */
  function urlJsScope(ctx, result) {
    var scope = rule.makeScope({
      result: result == null ? '' : result,
      key: ctx.keyword || '',
      keyword: ctx.keyword || '',
      page: ctx.page || 1,
      baseUrl: ctx.baseUrl || '',
      source: ctx.source
    });
    return scope;
  }

  /** ① analyzeJs：执行 URL 里内嵌的 @js:（贪婪到末尾）/ <js></js> */
  function analyzeJsInUrl(url, ctx) {
    var re = /@js:([\s\S]*)|<js>([\s\S]*?)<\/js>/g;
    var m, last = 0, out = '', acc = url;
    while ((m = re.exec(url)) !== null) {
      var before = url.slice(last, m.index).trim();
      if (before) out += before.replace(/@result/g, acc);
      var code = (m[1] !== undefined) ? m[1] : m[2];
      var scope = urlJsScope(ctx, acc);
      var v;
      try {
        v = rule.evalExpr(code, scope);
      } catch (e) {
        // ⚠️ 别再**默默吞掉**了：吞掉的话站方 JS 一报错，
        //    URL 就变成空串 → 0 请求 0 结果，界面上毫无线索（聚合源最常见的"静默失效"）。
        //    至少要留一条日志，真机自检面板里能看见。
        try { QR.java.log('[URL 里的 JS 出错] ' + String(e && e.message || e)); } catch (e2) {}
        v = '';
      }
      if (v === null || v === undefined) v = '';
      acc = String(v);
      out += acc;
      last = m.index + m[0].length;
      if (m[1] !== undefined) { last = url.length; break; }   // @js: 贪婪到末尾
    }
    var tail = url.slice(last).trim();
    if (tail) out += tail.replace(/@result/g, acc);
    return out || acc;
  }

  /** ② replaceKeyPageJs：{{表达式}} 按 JS 求值，<1,2,3> 是页码占位 */
  function replaceKeyPageJs(url, ctx) {
    var out = url;
    if (out.indexOf('{{') >= 0 && out.indexOf('}}') > out.indexOf('{{')) {
      out = out.replace(/\{\{([\s\S]*?)\}\}/g, function (m, expr) {
        var scope = urlJsScope(ctx, out);
        var v;
        try { v = rule.evalExpr(expr, scope); } catch (e) { v = ''; }
        return (v === null || v === undefined) ? '' : String(v);
      });
    }
    // <1,2,3>：第 N 页用第 N 个，页数超了就用最后一个
    if (ctx.page != null) {
      out = out.replace(/<(\d+(?:\s*,\s*\d+)*)>/g, function (m, g) {
        var pages = g.split(',').map(function (x) { return x.trim(); });
        var i = Math.min(ctx.page, pages.length) - 1;
        if (i < 0) i = pages.length - 1;
        return pages[i];
      });
    }
    return out;
  }

  /** ③ analyzeUrl：切 ,{json} 后缀，解析 method/body/headers */
  function analyzeUrl(url, ctx) {
    // paramPattern: ,\s*(?=\{)
    var m = /,\s*(?=\{)/.exec(url);
    var urlNoOption = m ? url.slice(0, m.index) : url;
    var opt = {};
    if (m) {
      try { opt = JSON.parse(url.slice(m.index + 1)) || {}; } catch (e) { opt = {}; }
    }

    var abs = dom.absolutize(urlNoOption, ctx.baseUrl);
    var method = String(opt.method || 'GET').toUpperCase();
    var headers = {};
    for (var hk in (opt.headers || {})) headers[hk] = String(opt.headers[hk]);
    // ⚠️⚠️ body 可能是**对象**（站方 `url,{"method":"POST","body":{"html":""}}`）——
    //   原来直接 `String(opt.body)` → **"[object Object]"** 发出去 ❌
    //   栖阅（AnalyzeUrl+Request 的字面量）有 `application/json; charset=utf-8`
    //   + 正规 JSON 序列化 ⇒ **照搬它**。
    var body = '';
    var isJsonBody = false;
    if (opt.body != null) {
      if (typeof opt.body === 'object') {
        try { body = JSON.stringify(opt.body); isJsonBody = true; }
        catch (e) { body = String(opt.body); }
      } else {
        body = String(opt.body);
      }
    }
    // JSON body 补 Content-Type（URL 选项里的头**替换**源级头，所以这里说了算）
    if (isJsonBody && !headers['Content-Type'] && !headers['content-type']) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }

    // ⚠️⚠️ query 重新编码**对所有方法都要做**（原来只做 GET，真机栽在这）：
    //   站方 POST 请求的 query 里常有**裸中文**（`source=番茄`）和**裸 JSON**
    //   （`variable={"custom":""}`）→ iOS 的 `URL(string:)` 遇到 `{` `"` 裸中文
    //   **直接判非法返回 nil** → 请求**根本没发出去** → 引擎把失败吞成空串
    //   → 站方 `JSON.parse('')` → 「JSON Parse error: Unable to parse JSON string」
    //   → 详情数据为空 → 简介规则炸「undefined is not an object (evaluating 'abstract.split')」。
    //
    //   ⚠️ 沙盒用 Node 的 fetch，它**自己会编码** → 沙盒全绿、真机炸。
    //      这就是「沙盒能跑 ≠ 真机能跑」的典型，别再只看沙盒。
    if (abs.indexOf('?') > 0) {
      var qi = abs.indexOf('?');
      abs = abs.slice(0, qi) + '?' + encodeFields(abs.slice(qi + 1));
      if (method === 'GET') body = '';
    }
    if (method === 'POST' && body) {
      var bt = body.trim();
      if (!isJsonBody && (bt.charAt(0) === '{' || bt.charAt(0) === '[')) {
        // JSON **字符串** body → 也要 application/json（Legado 语义）
        if (!headers['Content-Type'] && !headers['content-type']) {
          headers['Content-Type'] = 'application/json; charset=utf-8';
        }
      } else if (!isJsonBody) {
        // Legado: 非 JSON/XML 的 form body 走 analyzeFields 编码
        body = encodeFields(body);
        if (!headers['Content-Type'] && !headers['content-type']) {
          headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
        }
      }
    }

    // Legado: 解析后用新 URL 的目录更新 baseUrl，后续相对路径才找得到
    var newBase = dirOf(abs);

    return {
      url: abs,
      method: method,
      body: body,
      headers: headers,
      baseUrl: newBase
    };
  }

  /**
   * query / form body 的字段编码 —— 对齐 Legado 的 analyzeFields / analyzeQuery。
   * 关键：已经有 %XX 的不重复编码，**字面量 + 要保留**（form 编码里 + 就是空格）。
   */
  /**
   * 查询串 / 表单体的字段编码 —— **跟 Core/AnalyzeUrl.swift 的 analyzeFields 逐字同语义**
   *
   * ⚠️⚠️ **'+' 必须编码成 %2B**（Legado 原样，栖阅有 formPercentEncodedComponent）：
   *   留着 '+' 的话，服务器按 form 解码 query 时会把它变成**空格** →
   *   🍅大灰狼的 book_id 是 base64，base64 里出现 '+' → book_id 被损坏 →
   *   **表现为「有的书能开、有的书开不了」**（不是 100% 复现，很难查）。
   *
   * 保留字符：字母数字 + `-._`；结构符 `=` `&` 原样；
   * 已有 `%XX` 不重复编码；其余按 UTF-8 字节 %XX。
   */
  function encField(v) {
    var s = String(v == null ? '' : v), out = '', i = 0;
    while (i < s.length) {
      if (s.charAt(i) === '%' && /^[0-9A-Fa-f]{2}$/.test(s.substr(i + 1, 2))) {
        out += s.substr(i, 3); i += 3; continue;
      }
      var c = s.charAt(i);
      if (c === '=' || c === '&') { out += c; i++; continue; }
      if (c === '+') { out += '%2B'; i++; continue; }
      if (/[A-Za-z0-9_.\-]/.test(c)) { out += c; i++; continue; }
      out += encodeURIComponent(c);
      i++;
    }
    return out;
  }

  /** 把 a=1&b=2 形式的串重新编码 */
  function encodeFields(text) {
    return String(text).split('&').map(function (part) {
      var i = part.indexOf('=');
      if (i < 0) return encField(part);
      return encField(part.slice(0, i)) + '=' + encField(part.slice(i + 1));
    }).join('&');
  }

  /** 取 URL 的目录部分：https://x.com/a/b.html → https://x.com/a/ */
  function dirOf(u) {
    try {
      var url = new URL(String(u));
      url.hash = ''; url.search = '';
      var p = url.pathname;
      url.pathname = p.replace(/[^/]*$/, '');
      return url.href;
    } catch (e) { return String(u || ''); }
  }

  /** 逗号后跟 { 才是头部的 JSON 分隔符，普通 URL 里的逗号不能误伤 */
  function findHeaderSeparator(s) {
    for (var i = 0; i < s.length; i++) {
      if (s[i] === ',') {
        var rest = s.slice(i + 1).trim();
        if (rest.startsWith('{')) return i;
      }
    }
    return -1;
  }

  function enc(s) { try { return encodeURIComponent(String(s)); } catch (e) { return s; } }

  /* ---------------------------------------------------------
   * 抓页面
   * ------------------------------------------------------- */

  /** 抓完响应后标记内容类型：Legado 的 isJSON 决定整条规则链用什么解析器 */
  function markContent(ctx, page) {
    if (ctx) {
      ctx.isJSON = QR.rule.isJSONText(page.text);
      ctx.baseUrl = page.url;
      // ⚠️⚠️ **raw = 当前页原始内容**（Legado 语义）
      //   站方规则里 `var s = String(raw)` 就是指它
      //   （🍒NovelHub 的列表规则就靠它拿 HTML 再用正则解析）
      //   ⇒ 以前没给 ⇒ String(undefined) = "undefined" ⇒ 列表页永远 0 本 ⭐
      ctx.raw = page.text;
    }
    return ctx;
  }

/**
   * JSONPath 的结果被 flatten 成**字符串**了，
   * 后面 `{{$.bookid}}` 这种字段模板打在字符串上必然取空 —— 复活成对象。
   */
  function reviveJsonNode(n) {
    if (typeof n !== 'string') return n;
    var t = n.replace(/^[\s]+|[\s]+$/g, '');
    if (t.charAt(0) !== '{' && t.charAt(0) !== '[') return n;
    try { return JSON.parse(t); } catch (e) { return n; }
  }

  /**
   * 章节条目 → {title,url} 列表。DOM 节点和 JSON 对象两条路共用，
   * 校验规则也只写一份（标题和 URL 都要有、URL 按 pageUrl 展开）。
   */
  function collectChapters(bases, offset, pageUrl, tocRule, tocCtx) {
    var idx = offset;
    return bases.reduce(function (acc, base) {
      return acc.then(function (out) {
        // ⚠️ 按顺序求值（@put/@get 场景：chapterName 存变量、chapterUrl 取变量）
        return evalFields([tocRule.chapterName, tocRule.chapterUrl], base, tocCtx).then(function (v) {
          var title = (v[0] || '').trim();
          // 标题和 URL 都必须有才算一章。
          // 原来只查 title：站方在 <li> 里插纯文本（没 <a>）时 chapterUrl 是空串，
          // absolutizeMaybe('', page.url) 会**回落到详情页 URL** → 一堆假章节。
          //
          // 判空必须在 absolutize **之前**，基准仍要是 pageUrl：
          // 写成 absolutizeMaybe(v[1], '') 的话，站方的**相对**章节地址
          // 不会被展开，WKWebView 直接甩「不支持的URL」（build 15 踩过）。
          var rawUrl = (v[1] || '').trim();
          if (!title || !rawUrl) return out;
          out.push({
            url: absolutizeMaybe(rawUrl, pageUrl),
            title: title,
            index: idx++,
            isVolume: /卷|部|篇/.test(title) && !/第\s*\d+/.test(title),
            tag: ''
          });
          return out;
        });
      });
    }, Promise.resolve([]));
  }

  // 暴露给 rule-analyzer 用（两遍跑时要用它把 URL 里的 ,{json} 后缀拆开）
  QR.analyzeUrl = analyzeUrl;

  /**
   * `data:` 伪 URL 的内容。
   *
   * 形如 `data:;base64,<载荷>,{"type":"qingtian"}`：
   *   · `;base64` 是元数据（RFC 2397）
   *   · `<载荷>` 是真正的内容
   *   · 逗号后面的 JSON 是 Legado 的 URL 选项（已由 analyzeUrl 拆走）
   *
   * ⚠️ 返回**原始载荷**不解码 —— 站方的 init 规则自己会解
   *    （`JSON.parse(java.hexDecodeToString(result))`）。
   */
  /**
   * 日志用：把可能很长的 URL / 载荷压成一行可读文本。
   * ⚠️ base64 载荷动辄几千字符 → 不截断的话 300 条日志窗口瞬间被一条撑爆。
   */
  function brief(v, max) {
    var s = String(v == null ? '' : v);
    var n = max || 200;
    if (s.length <= n) return s;
    return s.slice(0, n) + '…[全长' + s.length + ']';
  }

  /* ⚠️ 纯 JS 的 base64 编解码（**必须按 UTF-8**）
   *   atob/btoa 是 **Latin-1** ⇒ 「小说」会变「å°è¯´」（我自己的诊断日志就栽在这 ⭐）
   *   ⇒ 自己查表 + TextDecoder/TextEncoder
   */
  var B64TBL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64DecodeUtf8(str) {
    try {
      var s = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
      var bin = atob(s);
      var arr = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(arr);
      return decodeURIComponent(escape(bin));
    } catch (e) { return ''; }
  }
  function b64EncodeUtf8(str) {
    try {
      var s = String(str == null ? '' : str);
      var bytes;
      if (typeof TextEncoder !== 'undefined') {
        bytes = new TextEncoder().encode(s);
      } else {
        var bin = unescape(encodeURIComponent(s));
        bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      }
      var out = '';
      for (var j = 0; j < bytes.length; j += 3) {
        var b0 = bytes[j], b1 = bytes[j + 1], b2 = bytes[j + 2];
        out += B64TBL[b0 >> 2];
        out += B64TBL[((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4)];
        out += (b1 === undefined) ? '=' : B64TBL[((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6)];
        out += (b2 === undefined) ? '=' : B64TBL[b2 & 63];
      }
      return out;
    } catch (e) { return ''; }
  }

  function dataUrlContent(u, book) {
    var s = String(u == null ? '' : u);
    var i = s.indexOf(',');
    if (i < 0) return '';
    var data = s.slice(i + 1);
    // ⚠️ 还要去掉 Legado 的 URL 选项后缀 `,{"type":"…"}` ——
    //    bookInfo/toc 这条链**没有**先过 analyzeUrl，逗号后缀还粘在载荷后面，
    //    解出来就是 `{"a":1}{"type":"x"}` → JSON.parse 报
    //    "Unexpected non-whitespace character after JSON"。
    //
    // ⚠️⚠️ **后缀可能已经被百分号编码**（2026-10-21 真机栽在这）：
    //   宿主侧用 `URL(string:).absoluteString` 规范化过 →
    //   `,{"type":"x"}` 变成 `,%7B%22type%22%3A%22x%22%7D`
    //   ⇒ 只认 `,{` 的正则**剥不掉** → 载荷被污染 → 站方 JSON.parse 炸。
    //   ⇒ 这里**两种形态都认**（宿主侧已修，但引擎这边再兜一道）。
    var m = /,\s*(?=\{|%7B)/i.exec(data);
    if (m) data = data.slice(0, m.index);
    // ⭐⭐⭐ **把【书对象的原始字段】补进 data: 载荷**（2026-10-22 真机「book_id=undefined」）
    //   聚合源（🍅大灰狼）的 bookUrl / tocUrl 是 `data:;base64,<载荷>,{…}`，
    //   载荷里本来应该有 book_id / source / tab，站方的 init 规则直接从**载荷**里解构：
    //       let { book_id, source: sources, tab, … } = JSON.parse(java.hexDecodeToString(result));
    //   但载荷里**只有 tab 和 url** ⇒ book_id=undefined ⇒ 详情/目录请求全废
    //   ⇒ 而宿主手里**有** book_id（列表接口返回的原始字段）⇒
    //      **在这里把书对象的字段合并进载荷再重新编码**，站方就能解出来 ✅
    //   ⚠️ 站方用 `hexDecodeToString` 解（不是 hex 就按 base64 试）⇒ 我们重编成 base64 没问题
    if (book && typeof book === 'object') {
      try {
        var _dec = b64DecodeUtf8(data);
        if (_dec && _dec.indexOf('{') >= 0) {
          var _obj = JSON.parse(_dec);
          var _added = [];
          for (var _bk in book) {
            if (_bk === 'variables' || _bk === 'bookUrl' || _bk === 'tocUrl') continue;
            if (!(_bk in _obj)) { _obj[_bk] = book[_bk]; _added.push(_bk); }
          }
          if (_added.length) {
            data = b64EncodeUtf8(JSON.stringify(_obj));
            try {
              QR.java.log('[data:载荷] 已补上书对象的字段: ' + _added.join(',') +
                          '（新载荷长 ' + data.length + '）');
            } catch (e3) {}
          }
        }
      } catch (e) { /* 载荷不是 JSON 就别动 */ }
    }
    // 👁️ **只观测，不改行为**（2026-10-21 真机 0 章排查）：
    //   之前这里加过「在第一个 `&` 处截断」⇒ 实测是回归（2566 章 → 0 章）⇒ 已撤。
    //   现在只把载荷的真实形状打出来，让真机数据说话：
    //   · 长度 —— 载荷是不是被截短了
    //   · 有没有 `&` —— 真机上到底有没有 query 粘进来
    //   · 开头 120 字符 —— 长什么样
    try {
      QR.java.log('[data:载荷] 原始长=' + s.length + ' 剥后长=' + data.length +
        ' 含&=' + (data.indexOf('&') >= 0 ? '有' : '无') +
        ' 前120=' + brief(data, 120));
      // ⭐⭐⭐ **把载荷「解出来」看一眼**（2026-10-22 真机栽在这）
      //   症状：站方 init 规则解出 `book_id=undefined` ⇒ 请求 /detail?book_id=undefined
      //        ⇒ **服务器**回「illegal base64 data at input byte 9」⇒ 详情/目录全空
      //   而宿主这边只看到一串 base64 ⇒ 根本看不出缺了哪个字段 ⭐
      //   ⇒ 这里**只观测不改行为**：解一次（解不开就说解不开）并打出内容
      var _dec = null, _why = '';
      // ⚠️⚠️ **必须用宿主自己的解码器**（java.hexDecodeToString ⇒ 内含 UTF-8 修正）
      //   我以前直接用 `atob` ⇒ 返回 **Latin-1** ⇒ 「小说」变「å°è¯´」
      //   ⇒ **我自己的诊断日志骗了我两轮**（真机其实解出的是正确的「小说」）⭐
      try {
        _dec = b64DecodeUtf8(data);
        if (!_dec) { throw new Error('解不开'); }
      } catch (e2) {
        _why = '（解不开：' + String(e2 && e2.message || e2).slice(0, 60) + '）';
      }
      if (_dec !== null) {
        // ⭐ 站方载荷常是 **URL 编码过的** ⇒ 先还原再解
        try { _dec = decodeURIComponent(_dec); } catch (e3) {}
        QR.java.log('[data:载荷] 解出来 = ' + brief(_dec, 300) + _why);
      } else {
        QR.java.log('[data:载荷] 解不出来' + _why + '（载荷前 60 = ' + brief(data, 60) + '）');
      }
    } catch (e) {}
    return data;
  }

  function fetchPage(target, ctx) {
    var u = String((target && target.url) || '');
    // ⚠️ `data:` 伪 URL **不能真去 fetch**（原生会失败）：
    //    聚合源用它把参数塞进「URL」里（data:;base64,<载荷>,{选项}）。
    //    载荷直接当**页面内容**交给后面的规则（init 规则会自己解）。
    if (u.indexOf('data:') === 0) {
      // ⚠️ 传 ctx.book ⇒ 好把书对象的原始字段（book_id 等）补进载荷
      var content = dataUrlContent(u, ctx && ctx.book);
      runtime.baseUrl = u;
      return Promise.resolve({
        resp: { ok: true, code: 200, url: u, _body: content },
        doc: dom.parseHTML(content, u),
        text: content,
        url: u
      });
    }
    return QR.java.rawRequest(target.url, target.method || 'GET',
                              target.headers || {}, target.body || '',
                              target.timeout || 20000)
      .then(function (resp) {
        runtime.baseUrl = resp.url || target.url;
        return {
          resp: resp,
          doc: dom.parseHTML(resp._body, runtime.baseUrl),
          text: resp._body,
          url: runtime.baseUrl
        };
      });
  }

  /* ---------------------------------------------------------
   * 通用：从规则里取一批书
   * ------------------------------------------------------- */

  /**
   * 书源的 baseUrl。
   *
   * 语料里 193/8751 个源的 bookSourceUrl 带 "##" 后缀，
   * 形如 "https://m.dmxso.com##旅途" —— 那是站方自己标的分组/频道名，不是 URL 的一部分。
   * 整个当 baseUrl 用，相对路径拼出来就成了
   *   https://m.dmxso.com##旅途/search/?searchkey=xxx   ← 域名直接歪掉
   * 所以这里把 ## 之后的部分切掉。
   */
  function baseUrlOf(src) {
    var u = String((src && src.bookSourceUrl) || '');
    var i = u.indexOf('##');
    if (i >= 0) u = u.substring(0, i);
    // Legado 约定 `bookSourceUrl` 可以写成 `https://host@用户名:密码`
    // （HTTP Basic 认证）或 `https://host@用户名`。
    // `@` 之后不是 URL 的一部分 —— 不切掉的话基准变成
    // `https://host@遇知`，相对路径全拼歪（实测「免费追书」书源）。
    var at = u.indexOf('@', u.indexOf('://') > 0 ? u.indexOf('://') + 3 : 0);
    if (at > 0) u = u.substring(0, at);
    return u.replace(/\/+$/, '');
  }

  function ruleText(rv) {
    if (rv == null) return '';
    if (typeof rv === 'string') return rv;
    if (Array.isArray(rv)) return rv.filter(function (x) { return typeof x === 'string'; }).join('\n');
    if (rv.raw != null) return rv.raw || '';
    return '';
  }

  function firstValue(rv) {
    var t = ruleText(rv);
    if (!t) return '';
    return t.split('\n')[0];
  }

  /**
   * 这一页用哪份「书籍列表规则」—— 严格照 Legado 的 BookList.kt：
   *
   *   isSearch == true              → ruleSearch
   *   ruleExplore.bookList 为空     → ruleSearch   ★ 回退
   *   否则                          → ruleExplore
   *
   * 关键点：回退换的是**整份规则对象**，不是只换 bookList ——
   * name / author / coverUrl / bookUrl 全跟着换成 ruleSearch 的。
   * 只换 bookList 的话，列表能出来但书名书封全是空。
   *
   * 很多书源（玄幻、小说屋这类）ruleExplore 写的是 {}，
   * Legado 照样能在发现页出书，靠的就是这条回退。
   */
  function pickListRule(src, isSearch) {
    src = src || {};
    var search = src.ruleSearch || {};
    if (isSearch) return search;
    var explore = src.ruleExplore || {};
    if (!ruleText(explore.bookList).trim()) return search;
    return explore;
  }

  /**
   * Legado 的「正则式列表规则」：
   *   bookList: ":<tr…>(.*?)</a>…"
   *   name: "$2"          ← 引用 bookList 那个正则的第 2 个捕获组
   *   bookUrl: "$1"
   * 普通选择器写不出这种跨字段的组引用，必须单独处理。
   */
  function looksLikeRegexRule(s) {
    var t = String(s || '').trim();
    if (!t) return false;
    if (t.indexOf('@js:') === 0 || t.indexOf('<js>') === 0 || t.indexOf('##') === 0) return false;
    if (t.charAt(0) === ':') return true;                        // Legado 的正则标记
    return /\[\\s\\S\]|\\d|<\/|\(\?:/.test(t);
  }

  function regexMatches(text, ruleStr) {
    var pat = String(ruleStr).trim();
    if (pat.charAt(0) === ':') pat = pat.slice(1);   // 冒号是标记，不是正则的一部分
    var re;
    try { re = new RegExp(pat, 'g'); } catch (e) { return []; }
    var out = [], m, guard = 0;
    var src = String(text || '');
    while ((m = re.exec(src)) !== null && guard++ < 20000) {
      out.push(m);
      if (m.index === re.lastIndex) re.lastIndex++;
    }
    return out;
  }

  /** $N 取出来的组里常常裹着 <font color=…> 之类标签，抹掉 */
  function cleanGroup(v) {
    var t = String(v == null ? '' : v);
    if (t.indexOf('<') >= 0) return dom.htmlToText(t);
    return t.trim();
  }

  /**
   * 正则匹配出来的片段要放回合法的表格上下文里再解析，
   * 否则 <tr>/<td> 会被 HTML 解析器直接丢掉（它们不能是 body 的直接子元素）。
   */
  function fragmentFor(matchText, baseUrl) {
    var t = String(matchText || '');
    var head = t.replace(/^\s+/, '');
    var wrapped;
    if (/<tr[\s>]/i.test(head)) wrapped = '<table><tbody>' + t + '</tbody></table>';
    else if (/<t[dh][\s>]/i.test(head)) wrapped = '<table><tbody><tr>' + t + '</tr></tbody></table>';
    else if (/<(ul|ol)[\s>]/i.test(head)) wrapped = '<body>' + t + '</body>';
    else wrapped = '<body>' + t + '</body>';
    return dom.parseHTML(wrapped, baseUrl);
  }

  /**
   * JSON 列表 → **数组的元素**（Legado 语义）
   *
   * ⚠️⚠️ 这是「发现页/搜索页没有书」的真凶（用户真机报的）：
   *   站方的 ruleExplore.bookList = `$.data`，而 `$.data` 命中的是**一个数组**
   *   → jsonpath.select 返回 `[那个数组]`（数组本身，不是它的元素）
   *   → 引擎把**整个数组当成一本书** → `$.book_name` 取不到 → **书全被丢掉**
   *   → 列表页空。
   *
   * Legado 的行为：`$.data` 命中数组时，返回**数组的元素**（10 本就是 10 个条目）。
   *
   * ⚠️ 不能用 `QR.rule.flatten` —— 那个是给 DOM/标量用的，
   *    对 JSON **对象**会 `JSON.stringify` 成字符串 ❌
   */
  function jsonListOf(result) {
    if (!Array.isArray(result)) return [];
    if (result.length === 1 && Array.isArray(result[0])) return result[0];
    return result;
  }

  /**
   * JSONPath 取列表，**支持 `a||b` 兜底**（Legado 语义）
   *
   * ⚠️⚠️ 站方很爱这么写（纵横中文）：
   *     ruleExplore.bookList = 'result.resultList||result.bookList'
   *   ⇒ 轻阅以前**整条当一个路径**去查 ⇒ 第一段没命中就是 0 本 ⭐
   *   ⇒ 这里逐段试，**第一个非空的赢**
   */
  function jsonPathListOf(text, path) {
    var data;
    try { data = typeof text === 'string' ? JSON.parse(text) : text; } catch (e) { return []; }
    if (data == null) return [];
    var parts = String(path == null ? '' : path).split('||');
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].trim();
      if (!p) continue;
      try {
        var items = jsonListOf(QR.jsonpath.select(data, p));
        if (items && items.length) return items;
      } catch (e) { /* 试下一段 */ }
    }
    return [];
  }

  function extractBooks(page, listRule, ctx, opts) {
    opts = opts || {};
    var listRuleStr = ruleText(listRule.bookList);
    if (!listRuleStr) return Promise.resolve({ books: [], nextUrl: '' });

    // ⚠️⚠️⚠️ **bookList 是 `@js:`**（2026-10-22 真机「一个平台都出不了书」的根因）
    //
    //   站方（用户自己整合十几个源的那个聚合源）的 `ruleExplore.bookList` 是 **83KB 的 `@js:`**：
    //   站方 JS 自己抓列表页、把十几个平台的 HTML 统一成**同一行**的格式：
    //       url|||name|||author|||coverUrl|||intro|||kind|||tag
    //   然后 `name` / `author` / `bookUrl` / `coverUrl` / `intro` 这些**子规则**
    //   用 `##正则##` 从每一行里抠字段：
    //       name: ##^[^|]*\|\|\|([\s\S]*?)\|\|\|[\s\S]*$##$1
    //   ⇒ **Legado 的语义**：`bookList` 求值结果 = **字符串列表**（getStringList）：
    //     JS 返回数组 ⇒ 每项就是一行；JS 返回字符串 ⇒ **按行切**；
    //     然后**每一行**再各自套 name/author/… 子规则 ⇒ 一行一本书。
    //
    //   ⇒ 以前宿主**没有这条路**（只有 JSON / 正则 / DOM 选择器三条）
    //      ⇒ 站方那 83KB 的 JS 被当成 DOM 规则 ⇒ 整页文档当一本书
    //      ⇒ `name` 子规则抠不出来 ⇒ 全被 `if (b && b.name)` 过滤掉
    //      ⇒ **一个平台都出不了书**（分类是有的，所以现象是「能进列表、点进去空的」）⭐
    //
    //   ⚠️ 对象数组也能吃：baseToText 会把对象 JSON.stringify ⇒ JSONPath 子规则照常生效
    if (rule.classify(listRuleStr) === rule.T.JS) {
      // ⚠️⚠️ **scope 必须用引擎内部那套**（`rule.jsScope`）：
      //   自己造 scope ⇒ 漏掉 document / 包过 API 的 source ⇒ 站方 JS 抛
      //   「undefined.slice」这类看不懂的错 ⭐
      //   ⇒ base 传 page.doc ⇒ document 指向**当前列表页**（站方 @js: 里
      //      用 document.querySelectorAll 解析列表结构）
      var jsScope = rule.makeScope(rule.jsScope(page.doc, page.doc, ctx, listRuleStr));
      // ⚠️ `result` = **当前页原文**（站方的 `var s = String(raw)` 就是从 result 取的）
      //   轻阅默认给的是 dom.textOf(node)（纯文本）⇒ 正则匹配不上 ⇒ 0 本
      jsScope.result = page.text;
      // ⭐⭐⭐ **复合规则 `<js>代码</js>尾部选择器`**（2026-10-22 适配 125 源时挖出来的）
      //   站方的**列表规则**很常这么写：
      //     bookList = '<js>\n …自己抓数据… \n</js>$.data.books'
      //   ⇒ 以前**整串 eval**（stripJsWrapper 只在整串以 </js> 结尾时才剥）
      //      ⇒ eval("<js>…</js>$.data.books") ⇒ **"Unexpected token '<'"** ⇒ **列表 0 本** ⭐
      //      ⇒ 而**目录**那条路（getJsonList）早就支持复合规则了
      //         ⇒ 所以现象是「**目录能出、发现出不来**」⭐
      var jt = rule.splitJsWithTail(listRuleStr);
      var jsScope2 = rule.makeScope(rule.jsScope(page.doc, page.doc, ctx, jt.code));
      jsScope2.result = page.text;
      return rule.runJs(jt.code, jsScope2)
        .then(function (r) {
          var items = [];
          if (jt.sel) {
            // 复合规则：JS 算出个值，再用尾部选择器取字段
            var picked = rule.selectFromJsResult(r, jt.sel, ctx, page.doc);
            items = Array.isArray(picked) ? picked
                  : (picked == null ? [] : [picked]);
          } else if (Array.isArray(r)) {
            items = r.map(function (x) {
              return (x && typeof x === 'object') ? x : String(x == null ? '' : x);
            });
          } else if (r != null && typeof r === 'object') {
            items = [r];
          } else if (typeof r === 'string') {
            // Legado 的 getStringList：**按行切**（站方特意把字段里的 CR/LF 洗掉了）
            items = r.split(/\r?\n/).map(function (l) { return l.trim(); })
              .filter(function (l) { return !!l; });
          }

          var chain = items.reduce(function (acc, item) {
            return acc.then(function (list) {
              return extractOneBook(item, listRule, ctx, page.url, opts)
                .then(function (b) { if (b && b.name) list.push(b); return list; });
            });
          }, Promise.resolve([]));
          return chain.then(function (list) {
            return { books: list, nextUrl: extractNextUrl(page, listRule, page.url) };
          });
        })
        .catch(function (e) {

          QR.java.log('[发现页 bookList(JS) 出错]', String(e && e.message || e));
          return { books: [], nextUrl: '' };
        });
    }

    // ★ JSON 响应：列表项是 JSON 对象，字段规则要针对每个对象单独求值
    if (ctx && ctx.isJSON) {
      var kind = rule.classify(listRuleStr, ctx);
      var body = rule.stripModePrefix(listRuleStr, kind);
      var items = [];
      if (kind === 'jsonpath') {
        try { items = jsonPathListOf(page.text, body); } catch (e) { items = []; }
      } else {
        try { items = rule.getElements(listRuleStr, page.doc, ctx).values || []; } catch (e) { items = []; }
      }
      var jbooks = [];
      var jchain = items.reduce(function (acc, item) {
        return acc.then(function (list) {
          return extractOneBook(item, listRule, ctx, page.url, {}).then(function (b) {
            if (b && b.name) {
              // ⭐⭐⭐ **把列表项的【原始字段】并进 book 对象**（2026-10-22 真机栽在这）
              //   站方 jsLib 生成 `data:;base64,<载荷>` 时要用 **book_id / bid / item_id** 之类
              //   ⇒ 宿主原先只把 name/author/… 九个字段送给站方 ⇒ **book_id 压根没传过去**
              //   ⇒ 站方只生成了 `{"tab":"小说","url":""}` ⇒ 详情/目录请求全是 book_id=undefined
              //      ⇒ 服务器回「illegal base64 data at input byte 9」⇒ 整本书崩 ⭐
              //   ⇒ 这里把**原始 item 的所有键**都带上（站方要什么有什么）
              try {
                if (item && typeof item === 'object') {
                  for (var rk in item) {
                    if (!(rk in b)) b[rk] = item[rk];
                  }
                }
              } catch (e) {}
              list.push(b);
            }
            return list;
          });
        });
      }, Promise.resolve([]));
      return jchain.then(function (list) {
        return { books: list, nextUrl: extractNextUrl(page, listRule, page.url) };
      });
    }

    if (looksLikeRegexRule(listRuleStr)) {
      var ms = regexMatches(page.text, listRuleStr);
      var books = [];
      var chain = ms.reduce(function (p, mm) {
        return p.then(function (acc) {
          var frag = fragmentFor(mm[0], page.url);
          return extractOneBook(frag.body, listRule, ctx, page.url, { groups: mm })
            .then(function (b) { if (b && b.name) acc.push(b); return acc; });
        });
      }, Promise.resolve([]));
      return chain.then(function (list) {
        return { books: list, nextUrl: extractNextUrl(page, listRule, page.url) };
      });
    }

    var nodes = [];
    var bySelector = false;
    try {
      var parsed = dom.parseChain(listRuleStr);
      if (parsed.selector) { bySelector = true; nodes = rule.resolveNodes(listRuleStr, page.doc, ctx); }
    } catch (e) { bySelector = false; }

    var bases = bySelector && nodes.length ? nodes : [page.doc];
    var acc = bases.reduce(function (p, base) {
      return p.then(function (list) {
        return extractOneBook(base, listRule, ctx, page.url, opts)
          .then(function (b) { if (b && b.name) list.push(b); return list; });
      });
    }, Promise.resolve([]));
    return acc.then(function (list) {
      return { books: list, nextUrl: extractNextUrl(page, listRule, page.url) };
    });
  }

  /**
   * 求一组字段规则
   *
   * ⭐⭐⭐ **有 `@put:` / `@get:` 时必须【按顺序】求值**（Legado 语义，2026-10-22 适配 125 源时挖出来的）
   *   站方常这么串：
   *     name   = '$.catename@put:{bid:bid}'            ← 这里把 bid 存进变量
   *     tocUrl = 'https://x/chapterlist/bid/@get:{bid}' ← 这里再取出来
   *   ⇒ 以前**并行**求值 ⇒ tocUrl 可能在 name 之前跑 ⇒ 变量还没存 ⇒ 取到空串
   *      ⇒ 站方拿到的 URL 是 `.../bid//version/...` ⇒ **目录 0 章** ⭐
   *   （实测：红薯阅读 / 猪猪小说 / 七猫小说 / 咪咕阅读 / 宜搜小说…）
   *   ⇒ 没有 @put/@get 时仍走**并行**（保持性能）
   */
  function evalFields(rules, base, ctx) {
    var list = rules || [];
    var hasGetPut = list.some(function (rv) {
      return /@(get|put|getString|getInt):\{/i.test(ruleText(rv));
    });
    if (!hasGetPut) {
      return Promise.all(list.map(function (rv) { return rule.getValue(ruleText(rv), base, ctx); }));
    }
    var out = [];
    var chain = Promise.resolve();
    list.forEach(function (rv) {
      chain = chain.then(function () {
        return rule.getValue(ruleText(rv), base, ctx).then(function (v) { out.push(v); });
      });
    });
    return chain.then(function () { return out; });
  }

  function extractOneBook(base, listRule, ctx, pageUrl, opts) {
    opts = opts || {};
    function f(rv) {
      var t = ruleText(rv).trim();
      // "$1" / "$2" → 引用列表正则的捕获组
      var g = /^\$(\d+)$/.exec(t);
      if (g && opts.groups) {
        var v = opts.groups[Number(g[1])];
        return Promise.resolve(cleanGroup(v));
      }
      return rule.getValue(t, base, ctx);
    }
    var FIELDS = [
      ['name', listRule.name], ['author', listRule.author], ['intro', listRule.intro],
      ['kind', listRule.kind], ['lastChapter', listRule.lastChapter],
      ['coverUrl', listRule.coverUrl], ['bookUrl', listRule.bookUrl],
      ['wordCount', listRule.wordCount]
    ];
    var hasGetPut = FIELDS.some(function (x) {
      return /@(get|put|getString|getInt):\{/i.test(ruleText(x[1]));
    });
    if (hasGetPut) {
      var out = [];
      var chain = Promise.resolve();
      FIELDS.forEach(function (x) {
        chain = chain.then(function () {
          return f(x[1]).then(function (v) { out.push(v); });
        });
      });
      return chain.then(function () { return buildBook(out); });
    }
    return Promise.all(FIELDS.map(function (x) { return f(x[1]); })).then(buildBook);

    function buildBook(v) {
      var name = (v[0] || '').trim();
      if (!name && !(opts.requireUrl)) return null;
      var bookUrl = (v[6] || '').trim();
      // 列表页不直接给 bookUrl 时，用详情页 URL 兜底
      if (!bookUrl) bookUrl = (pageUrl || '').split('#')[0];
      return {
        name: name,
        author: v[1] || '',
        intro: v[2] || '',
        kind: v[3] || '',
        lastChapter: v[4] || '',
        coverUrl: absolutizeMaybe(v[5], pageUrl),
        bookUrl: absolutizeMaybe(bookUrl, pageUrl),
        wordCount: v[7] || ''
      };
    }
  }

  function absolutizeMaybe(u, base) {
    var s = String(u == null ? '' : u).trim();
    if (!s) return '';
    if (/^data:|^blob:|^qireaderlite:/i.test(s)) return s;
    return dom.absolutize(s, base);
  }

  function extractNextUrl(page, listRule, pageUrl) {
    var spec = ruleText(listRule.exploreUrl) || ruleText(listRule.searchUrl);
    if (!spec) return '';
    return findNextPage(page.doc, pageUrl);
  }

  function findNextPage(doc, base) {
    var cands = ['a.next@href', 'a:contains(下一页)@href', 'a:contains(下页)@href',
      'a:contains(next)@href', 'div.page a:last-child@href', 'a[rel=next]@href'];
    for (var i = 0; i < cands.length; i++) {
      var v = dom.value(doc, cands[i], base);
      if (v) return v;
    }
    return '';
  }

  /* ---------------------------------------------------------
   * OPS
   * ------------------------------------------------------- */

  var OPS = {

    ping: function () { return { ok: true, version: 1 }; },

    /** 搜索 */
    search: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        // searchUrl 在**顶层**（实测 7339 条顶层 / 0 条在 ruleSearch 里）
        var spec = ruleText(src.searchUrl) || ruleText(src.ruleSearch && src.ruleSearch.searchUrl);
        if (!spec) return { books: [], total: 0, error: '该书源没有搜索规则' };
        var ctx = { baseUrl: baseUrlOf(src), keyword: p.keyword || '', page: p.page || 1, source: src };
        return buildUrl(spec, ctx).then(function (target) {
          if (!target.url) return { books: [], total: 0, error: '搜索 URL 生成失败' };
          return fetchPage(target, ctx).then(function (page) {
            markContent(ctx, page);
            return extractBooks(page, pickListRule(src, true), ctx, { requireUrl: true });
          });
        });
      }).then(function (r) {
        return { books: r.books, total: r.books.length, nextUrl: r.nextUrl || '' };
      }).catch(function (e) {
        return { books: [], total: 0, error: String(e && e.message || e) };
      });
    },

    /**
     * 登录：跑 loginUrl 里的动作（login(true) / register() / checkStatus() …）
     *
     * ⚠️ 表单值挂在 **result** 上 —— Legado 就是这么给的，
     *    站方 login() 里读的是 `result['邮箱']` / `result['密码']`。
     */
    /**
     * ⚠️⚠️⚠️ **表单值必须合并进 `__loginInfo`**（2026-10-22 真机「解锁整个源」点了没反应）
     *
     *   站方（🍒NovelHub 聚合源）是从 **`source.getLoginInfoMap()`** 读**当前输入框的值**的：
     *     function nhAuthUiMap() { return source.getLoginInfoMap ? source.getLoginInfoMap() : {}; }
     *   ⇒ 轻阅以前**只把 formValues 挂到 `result`** ⇒ 站方读到的 `getLoginInfoMap()` 是**空的**
     *   ⇒ 站方提示「请在下面「整源解锁密码」输入框里填密码」⭐（用户明明填了！）
     *
     *   ⇒ **Legado / 栖阅的语义**：点 action 按钮时，**先把当前输入框的值写进 loginInfo**，
     *     再执行 action（站方的 `login(true)` 第一步也是 `putLoginInfo(JSON.stringify(result))`）
     *   ⇒ 这里照做：已存的 loginInfo + 当前输入框的值（**当前输入框优先**）
     *   ⚠️ 只是**内存里**合并 ⇒ 不会因为这个而把密码写进书源 JSON
     *      （轻阅的 loginInfo 存在 UserDefaults，不在书源文件里）
     */
    login: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureLoginLib(src).then(function () {
        var action = String(p.action || '').trim();
        if (!action) return { ok: false, error: '没有登录动作' };
        var formValues = (p.formValues && typeof p.formValues === 'object') ? p.formValues : {};
        // ⚠️ 表单值要先合并进 __loginInfo（长注释见本 op 上方）
        if (src && Object.keys(formValues).length) {
          var __li = (src.__loginInfo && typeof src.__loginInfo === 'object') ? src.__loginInfo : {};
          src.__loginInfo = Object.assign({}, __li, formValues);
        }
        var scope = rule.makeScope({
          result: formValues,
          source: src,
          book: p.book,
          baseUrl: baseUrlOf(src),
          key: p.key || ''
        });
        // jsLib 里的函数用 `this.source` 拿 source（this = 全局对象）→ op 期间挂上
        var prevSource = g.source;
        g.source = QR.wrapSource ? QR.wrapSource(src) : src;
        // ⚠️ 站方 **只**用 toast 报登录结果（"✅️登录成功" / "💔登录失败"），
        //    toast 弹一下就没了 → 用户根本不知道成没成。
        //    这里装个 sink 把原文收回来，原生侧显示给用户。
        var msgs = [];
        var prevSink = QR.__qrMsgSink;
        QR.__qrMsgSink = msgs;

        // ── 登录信息快照 ──
        //
        // 站方 `login(true)` 的**第一步**就是无条件 `putLoginInfo(表单值)`：
        //     putLoginInfo(JSON.stringify(result))   // result = {邮箱, 密码}
        // 而「密钥」是**登录成功**的标志（只有登录_api 返回 code==0 那步才写回去）。
        //
        // ⇒ 于是有两种情况会把密钥**抹掉且回不来**：
        //   ① 登录_api 失败（服务器 502 / 密码错）→ ④ 那步没跑到
        //   ② cookie 里已有 qttoken → 站方直接走
        //      「当前✅️已登录，请🚫退出登录后重新登录」分支 → **根本不重新登录**
        //
        // 两种情况的后果一样：**一次没成功的登录，把已有的登录态弄坏了**。
        // 所以跑完检查一下：密钥没了但原来有 → **恢复回去**。
        // ⚠️ 只对 login 动作生效（logout 要能真的清掉登录态）。
        var beforeLogin = (src.__loginInfo && typeof src.__loginInfo === 'object')
          ? JSON.stringify(src.__loginInfo) : '';
        var isLoginAction = /login\s*\(/i.test(action) && !/logout/i.test(action);

        function restoreLoginIfLost() {
          if (!isLoginAction || !beforeLogin) return;
          try {
            var b = JSON.parse(beforeLogin);
            var n = QR.__qrDirtyLogin ? JSON.parse(QR.__qrDirtyLogin) : {};
            if (b['密钥'] && !n['密钥']) {
              QR.__qrDirtyLogin = beforeLogin;   // ← 恢复旧的（登录态没被弄坏）
            }
          } catch (e) { /* 忽略 */ }
        }

        return rule.runJs(action, scope)
          .then(function (r) {
            g.source = prevSource;
            QR.__qrMsgSink = prevSink;
            restoreLoginIfLost();
            return { ok: true, result: (r == null ? '' : String(r)), messages: msgs };
          })
          .catch(function (e) {
            g.source = prevSource;
            QR.__qrMsgSink = prevSink;
            restoreLoginIfLost();
            return { ok: false, error: String(e && e.message || e), messages: msgs };
          });
      });
    },

    /**
     * 登录状态检测（轻阅自己加的，不是站方的）。
     *
     * 站方自己有个 `checkStatus()`，但它**只**把结果丢进 toast/log，
     * 用户看不到。所以这里做两件事：
     *   ① 把服务器地址解析出来（站方的 `getArgument('server')`，回退 jsLib 的 `host[0]`）
     *      —— 原生侧拿它**独立**打一次 /user_api，不经过站方 JS
     *   ② 跑一次站方的 checkStatus()，把它的原文（会员卡片）收回来
     */
    loginProbe: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        return ensureLoginLib(src);
      }).then(function () {
        var msgs = [];
        var prevSink = QR.__qrMsgSink;
        QR.__qrMsgSink = msgs;
        var prevSource = g.source;
        g.source = QR.wrapSource ? QR.wrapSource(src) : src;
        var base = '';
        // ① 站方自己的服务器设置（登录后会 setArgument('server', ...) 存进书籍变量）
        try {
          // ⚠️ 用 g.getArgument 而不是裸 getArgument：裸名在 typeof 检查里运行时安全，
          //    但 eslint no-undef 会误报（门禁 engine-lint 一直红在这行）。语义完全等价。
          if (typeof g.getArgument === 'function') base = String(g.getArgument('server') || '');
        } catch (e) { /* 没有这个函数就算了 */ }
        // ② 回退：jsLib 里的 `var host = [...]`（间接 eval → 全局变量）
        if (!base) {
          try {
            if (typeof host !== 'undefined' && host && host.length) base = String(host[0]);
          } catch (e) {}
        }
        // ③ 站方自己的检测（会员卡片走 java.log + java.longToast）
        //
        // ⚠️⚠️ **必须走 rule.runJs**，不能直接 checkStatus()：
        //    站方的 java.ajax 是**同步**的（`JSON.parse(java.ajax(url))`），
        //    直接调 → 拿到的是 Promise → JSON.parse(Promise) 炸 → 永远测不出登录态。
        //    runJs 里有「两遍跑」机制：第一遍录 URL、第二遍命中缓存同步返回真值。
        var scope = rule.makeScope({
          // ⚠️ `result` 必须给：站方 checkStatus 里会写 `result['邮箱'] = res.email`
          //    → 站方函数在**全局作用域**（间接 eval 定义的）→ 读的是全局的 result
          //    → 不给就是 "result is not defined"，卡片直接拼不出来。
          result: {},
          source: src,
          book: p.book,
          baseUrl: base || baseUrlOf(src),
          key: p.key || ''
        });
        var hasCheck = false;
        try { hasCheck = (typeof checkStatus === 'function'); } catch (e) {}
        var chain = hasCheck
          ? rule.runJs('checkStatus()', scope).then(function () { return null; },
                                                     function (e) { return String(e && e.message || e); })
          : Promise.resolve('这个书源没有 checkStatus()');
        return chain.then(function (errText) {
          g.source = prevSource;
          QR.__qrMsgSink = prevSink;
          if (errText) msgs.push('站方 checkStatus 失败：' + errText);
          var ck = '';
          try { ck = String(cookie.getCookie(base)); } catch (e) { ck = ''; }
          return {
            ok: true,
            baseUrl: base,
            messages: msgs,
            stationCheck: hasCheck && !errText,
            cookie: ck
          };
        });
      });
    },

    /** 发现页的分类列表 */
    /**
     * **站方的全部线路**（jsLib 里的 `host` 数组）
     *
     * 为什么要这个 op：🍅大灰狼把线路列表放在**站方 jsLib 的全局 `host`** 里
     *   （`['https://v5.langge.uk', 'http://219.154.201.122:5006', 'https://v4…', …]`），
     *   轻阅自己不知道有哪些线路 ⇒ 用户只能一个个手试。
     *   ⇒ 读出来交给 App **并发测速**，自动选一条通的写进书源变量 ✅
     */
    sourceHosts: function (p) {
      var h = (typeof g !== 'undefined') ? g.host : null;
      var arr = [];
      if (Array.isArray(h)) {
        for (var i = 0; i < h.length; i++) {
          var s = String(h[i] || '').trim();
          if (s && arr.indexOf(s) < 0) arr.push(s);
        }
      }
      return { hosts: arr };
    },

    /**
     * **站方的默认书籍变量**（jsLib 里 `getArguments` 的兜底默认值）
     *
     * ⭐⭐⭐ 为什么必须有这个 op（2026-10-21 真机「目录 0 章」查出来的根因）：
     *   站方的 `getArguments(open_argument, key)` **只有变量串解析失败时**
     *   （也就是空串）才返回它的默认变量表；一旦你写入**任何一项**
     *   （比如「测速选最快线路」写 `{"server":"…"}`），
     *   它就**不再给默认** ⇒ `tab / sources / source_type / proxy …` 全变 undefined
     *   ⇒ 源被改坏（实测：只写 `{"proxy":"本地"}` ⇒ `server` 没了 ⇒
     *     请求 URL 变成 `undefined/catalog` ⇒ 4 本书全部 0 章 ❗）
     *
     *   而且那份兜底默认表里**没有 `proxy`** ⇒ 站方 JS 里的
     *   `if (url != "" && proxy == "本地")` 永远不成立 ⇒
     *   **它不去抓番茄详情页** ⇒ 目录请求的 body 里 `html` 恒为空
     *   ⇒ 大灰狼服务器只能靠自己的缓存（响应 `"cache":true`）
     *   ⇒ **缓存里有的书能出目录，没有的就是 0 章** ⭐
     *
     * ⇒ 所以 App 写变量时必须**拿站方自己的默认值做底**，再盖上用户的改动 ✅
     */
    sourceVars: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var out = {};
        try {
          if (typeof g !== 'undefined' && typeof g.getArguments === 'function') {
            var d = g.getArguments('', '');
            if (d && typeof d === 'object') out = d;
          }
        } catch (e) { out = {}; }
        return { vars: out };
      });
    },

    /**
     * 发现页筛选栏：**执行站方的 action**（栖阅同款，2026-10-22）
     *
     * 站方（🍅大灰狼）的筛选 action 是「把值写进某个源级变量」那种简单形式：
     *     show(infoMap['平台'],'find_source')
     * ⇒ 轻阅从 action 里抠出 paramKey（`find_source`）⇒ 自己写这个变量 ✅
     *
     * ⚠️ 但站方（🍒NovelHub 聚合源）**不是这么写的** —— 它的 action
     * **自己读写源级变量、自己刷新发现页**：
     *     (function(){var c={};try{c=JSON.parse(source.getVariable()||'{}');}catch(e){}
     *       var v=infoMap['平台']; if(v!==null&&v!==undefined){c['src']=v;
     *       try{source.setVariable(JSON.stringify(c));}catch(e1){}}
     *       try{java.refreshExplore();}catch(e2){}})()
     * ⇒ 抠不出 paramKey（空）⇒ 轻阅原来**直接 return** ⇒ **点了没反应** ⭐
     *
     * ⇒ 照栖阅的做法：**把 `infoMap[标题] = 值` 喂给站方，让站方自己写变量**
     *   （站方写完 `source.setVariable` ⇒ 标 dirty ⇒ 引擎回传 `__sourceVars` ⇒ 原生落盘）
     */
    filterAction: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var action = String(p.action || '').trim();
        if (!action) return { ok: false, error: '没有筛选动作' };
        var title = String(p.title || '');
        var value = String(p.value == null ? '' : p.value);
        // 站方 action 里读的是 `infoMap['平台']` ⇒ 这里按【标题】塞进去
        var infoMap = {};
        if (title) infoMap[title] = value;
        var scope = rule.makeScope({
          result: {},
          source: src,
          book: p.book,
          baseUrl: baseUrlOf(src),
          key: p.key || '',
          infoMap: infoMap
        });
        // ⚠️ jsLib 里的函数在**全局作用域** ⇒ op 期间要把 g.source 挂上
        var prevSource = g.source;
        g.source = QR.wrapSource ? QR.wrapSource(src) : src;
        var msgs = [];
        var prevSink = QR.__qrMsgSink;
        QR.__qrMsgSink = msgs;
        return rule.runJs(action, scope)
          .then(function (r) {
            g.source = prevSource;
            QR.__qrMsgSink = prevSink;
            return { ok: true, result: (r == null ? '' : String(r)), messages: msgs };
          })
          .catch(function (e) {
            g.source = prevSource;
            QR.__qrMsgSink = prevSink;
            return { ok: false, error: String(e && e.message || e), messages: msgs };
          });
      });
    },

    exploreKinds: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        // exploreUrl 同样在顶层
        var spec = ruleText(src.exploreUrl) || ruleText(src.ruleExplore && src.ruleExplore.exploreUrl);
        if (!spec) return { kinds: [], error: '该书源没有发现规则' };
        var ctx = { baseUrl: baseUrlOf(src), source: src };
        // exploreUrl 常是 @js:，可能返回数组，也可能返回 JSON 字符串
        if (rule.classify(spec) === rule.T.JS) {
          var scope = rule.makeScope({ baseUrl: ctx.baseUrl, source: src });
          // ⚠️⚠️⚠️ **@js: 规则里不要做 `{{}}` 插值**（2026-10-22 实测 NovelHub 聚合源炸在这）
          //   Legado / 栖阅的语义：**`@js:` 是 JS 源码，里面的 `{{}}` 原样保留**
          //   （插值只发生在「URL 模板」规则上，比如 searchUrl 的 `https://x?q={{keyword}}`）
          //
          //   以前这里插值 ⇒ 踩了两个坑：
          //   ① `{{...}}`（**JS 对象展开语法**）被 evalExpr 求值失败 → 吃成空串
          //      ⇒ **整个 JS 语法坏掉** ⇒ 「Invalid or unexpected token」⭐
          //   ② `{{page+1}}` / `{{(page-1)*30}}` 被算成**固定数字**
          //      ⇒ 站方 JS 拼出来的分类 URL 的 page 写死 ⇒ **发现页翻页失效** ⭐
          //
          //   ⇒ 不插值的话：站方 JS 拼出的 URL 模板里 `{{page}}` 原样留着
          //      ⇒ 后面 `explore` op 的 buildUrl 才插值 ⇒ **翻页正常** ✅
          var jsCode = rule.stripJsWrapper(spec);
          return rule.runJs(jsCode, scope).then(function (r) {
            var arr = r;
            if (typeof arr === 'string') {
              var t = arr.trim();
              if (t.startsWith('[') || t.startsWith('{')) {
                try { arr = JSON.parse(t); } catch (e) { arr = []; }
              } else {
                // 纯文本分类："玄幻::/type/xh\n仙侠::/type/xx"（Legado 用 (&&|\n)+ 切）
                arr = t.split(/(&&|\n)+/).map(function (l) { return String(l).trim(); }).filter(Boolean)
                  .map(function (l) { var q = l.split('::'); return { title: q[0], url: q[1] || '' }; });
              }
            }
            if (!Array.isArray(arr)) arr = (arr && arr.exploreKind) ? arr.exploreKind : [];
            var nk = normalizeKinds(arr, ctx.baseUrl);
            return { kinds: nk.kinds, filters: nk.filters };
          }).catch(function (e) {
            return { kinds: [], error: String(e && e.message || e) };
          });
        }
        // 静态写法有两种（Legado BookSourceExtensions.exploreKinds 同款）：
        //   ① 整个 exploreUrl 是一段 JSON 数组  → [{title,url,style},…]
        //   ② 纯文本，每行 "分类名::url"（Legado 用 (&&|\n)+ 切）
        var raw = String(spec).trim();
        if (raw.charAt(0) === '[') {
          var jk = [];
          try { jk = JSON.parse(raw); } catch (e) { jk = []; }
          if (Array.isArray(jk)) {
            var nk2 = normalizeKinds(jk, ctx.baseUrl);
            return { kinds: nk2.kinds, filters: nk2.filters };
          }
        }
        var kinds = raw.split(/(&&|\n)+/).map(function (l) { return String(l).trim(); }).filter(Boolean)
          .map(function (l) {
            var p2 = l.split('::');
            return { title: p2[0], url: dom.absolutize((p2[1] || '').trim(), ctx.baseUrl), style: '' };
          });
        return { kinds: kinds, filters: [] };
      });
    },

    /** 发现页某一分类的书列表 */
    explore: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var ctx = { baseUrl: baseUrlOf(src), page: p.page || 1, source: src };
        return buildUrl(p.kindUrl || '', ctx).then(function (target) {
          if (!target.url) return { books: [], total: 0, error: '分类 URL 为空' };
          return fetchPage(target, ctx).then(function (page) {
            markContent(ctx, page);
            // 发现页：ruleExplore.bookList 为空时回退 ruleSearch（Legado BookList.kt 同款）
            return extractBooks(page, pickListRule(src, false), ctx, { requireUrl: true });
          });
        });
      }).then(function (r) {
        return { books: r.books, total: r.books.length, nextUrl: r.nextUrl || '' };
      }).catch(function (e) {
        return { books: [], total: 0, error: String(e && e.message || e) };
      });
    },

    /**
     * 诊断：把「发现页这一趟到底发生了什么」摊开。
     *
     * 沙盒里同一份规则能出 30 本、真机只有 1 本 —— 这种差异光看代码看不出来，
     * 必须把 请求URL / 状态码 / 响应字节 / 规则命中元素数 / 页面标题 一起摆出来。
     */
    explain: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var ctx = { baseUrl: baseUrlOf(src), page: p.page || 1, source: src };
        var out = {};
        return buildUrl(p.kindUrl || '', ctx).then(function (target) {
          out.请求URL = target.url || '';
          out.方式 = target.method || 'GET';
          if (!target.url) { out.结论 = '分类 URL 为空'; return out; }
          return QR.java.rawRequest(target.url, target.method || 'GET',
                                    target.headers || {}, target.body || '', 20000)
            .then(function (resp) {
              var body = resp._body || resp.body || '';
              out.最终URL = resp.url || resp._url || '';
              out.状态码 = resp._code || resp.code || 0;
              out.响应字节 = body.length;
              var listRule = pickListRule(src, false);
              out.用的规则 = (listRule === (src.ruleSearch || {}))
                ? 'ruleSearch（ruleExplore.bookList 为空，已回退）'
                : 'ruleExplore';
              out.bookList规则 = ruleText(listRule.bookList);
              var t = (body.match(/<title[^>]*>([\s\S]{0,100}?)<\/title>/i) || [])[1] || '';
              out.页面标题 = t.replace(/\s+/g, ' ').trim();
              try {
                var doc = dom.parseHTML(body, out.最终URL || target.url);
                var n = 0;
                try { n = rule.resolveNodes(ruleText(listRule.bookList), doc, {}).length; }
                catch (e) { out.选择器报错 = String(e && e.message || e); }
                out.规则命中元素 = n;
                // 规则没命中时，扫一遍页面里"重复出现多次"的 class 当候选列表容器。
                // 站方改版导致规则失效是常态，让 App 自己把候选摆出来，
                // 总比在沙盒里对着一个 503 的站瞎猜强。
                if (n <= 1) {
                  var counts = {}, tags = {};
                  try {
                    var all = doc.querySelectorAll('[class]');
                    for (var i = 0; i < all.length && i < 6000; i++) {
                      var el = all[i];
                      var cls = (el.getAttribute('class') || '').trim();
                      if (!cls) continue;
                      var parts = cls.split(/\s+/);
                      for (var j = 0; j < parts.length; j++) {
                        var c = parts[j];
                        if (!counts[c]) counts[c] = { n: 0, sample: '' };
                        counts[c].n++;
                        tags[c] = el.tagName;
                        if (!counts[c].sample && counts[c].n === 3) {
                          counts[c].sample = String(el.outerHTML || '')
                            .replace(/\s+/g, ' ').slice(0, 200);
                        }
                      }
                    }
                  } catch (e2) { /* 扫不动就算了，不影响主流程 */ }
                  var cand = Object.keys(counts)
                    .filter(function (c) { return counts[c].n >= 3; })
                    .sort(function (a, b) { return counts[b].n - counts[a].n; })
                    .slice(0, 6);
                  out.候选列表容器 = cand.map(function (c) {
                    return '.' + c + '  ×' + counts[c].n + ' <' + tags[c] + '>'
                      + (counts[c].sample ? '\n    ' + counts[c].sample : '');
                  }).join('\n');
                  if (!cand.length) out.候选列表容器 = '页面里没有重复出现的 class，可能不是书单页';
                  // 标签统计：像 #sitebox@tag.dl 这种靠 id+标签定位的，
                  // 光扫 class 扫不出来（元素自己没 class），得把常见容器标签数也摆出来
                  var tg = ['dl', 'li', 'tr', 'article', 'ul', 'section', 'h2', 'h3', 'table'];
                  var tstat = [];
                  for (var t = 0; t < tg.length; t++) {
                    var c2 = 0;
                    try { c2 = doc.querySelectorAll(tg[t]).length; } catch (e3) { continue; }
                    if (c2 > 2) tstat.push(tg[t] + '=' + c2);
                  }
                  out.元素统计 = '带class元素=' + (all ? all.length : 0)
                    + (tstat.length ? '  ' + tstat.join(' ') : '');

                  // ★ 最有用的一块：把「书单条目」的完整 HTML 摆出来。
                  // 光看候选 class 只能知道"哪个类重复多"，看不出书名藏在哪个标签，
                  // 改规则改不对。直接给一条完整条目，剩下的照着写就行。
                  var boxTags = ['dl', 'li', 'tr', 'article', 'section', 'ul'];
                  var samples = [];
                  for (var b = 0; b < boxTags.length && samples.length < 2; b++) {
                    var list = null;
                    try { list = doc.querySelectorAll(boxTags[b]); } catch (e4) { continue; }
                    if (!list || list.length < 3) continue;
                    samples.push('—— <' + boxTags[b] + '> ×' + list.length + ' 的第 1 条 ——\n'
                      + String(list[0].outerHTML || '').replace(/\s+/g, ' ').slice(0, 900));
                  }
                  out.书单条目样本 = samples.length ? samples.join('\n\n') : '没找到像书单容器的标签';
                }
              } catch (e) {
                out.解析报错 = String(e && e.message || e);
              }
              out.正文开头 = String(body).replace(/\s+/g, ' ').slice(0, 220);
              if (/验证|人机|cloudflare|captcha|请稍候|访问频繁/i.test(out.页面标题 + out.正文开头)) {
                out.结论 = '**站方给的是验证/拦截页**，不是书单页（多半是 IP 或 UA 被判）';
              } else if ((out.规则命中元素 || 0) <= 1) {
                out.结论 = '规则只命中 ' + (out.规则命中元素 || 0) + ' 个元素 —— 书单页结构跟规则对不上';
              } else {
                out.结论 = '规则命中 ' + out.规则命中元素 + ' 个元素，页面结构是对的';
              }
              return out;
            })
            .catch(function (e) {
              out.结论 = '请求失败：' + String(e && e.message || e);
              return out;
            });
        });
      });
    },

    /**
     * 诊断目录：跟 explain 一个路子，把目录页的真实结构摊开。
     * 目录不对基本就三种：URL 拿错、规则没命中、命中了但章节名/链接取错。
     */
    explainToc: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var tocRule = src.ruleToc || {};
        // ⚠️⚠️ **必须带 book** —— 站方的 chapterList 第一句就调
        //   `book.getVariable('custom')`（🍅大灰狼就是）→
        //   不给 book → 站方 JS 抛「Cannot read properties of undefined
        //   (reading 'getVariable')」→ 目录一条不剩 →
        //   而诊断会**误报**「chapterList 一个都没命中 —— 规则对不上」❌
        //   （用户会以为规则写错，其实只是诊断没喂 book）
        var ctx = { baseUrl: baseUrlOf(src), source: src, book: p.book };
        var out = {};
        var raw = p.tocUrl || p.bookUrl || '';
        return buildUrl(raw, ctx).then(function (target) {
          out.请求URL = target.url || String(raw);
          if (!target.url) { out.结论 = '目录 URL 为空'; return out; }
          // ⚠️ 必须走 fetchPage（不能 rawRequest）：
          //    聚合源的目录 URL 是 `data:;base64,…` 伪 URL —— **原生真去 fetch 会炸**
          //    （URLSession 去解 data: URL 的 base64 → 「illegal base64 data at input byte 9」）
          //    → 诊断里的「状态码 0 / 响应字节 21」全是这个废数据，
          //      让人误以为「规则没命中」。真实路径（toc op）走的是 fetchPage ✅
          return fetchPage(target, ctx)
            .then(function (page) {
              var resp = page.resp || {};
              var body = page.text || '';
              out.最终URL = resp.url || resp._url || '';
              out.状态码 = resp._code || resp.code || 0;
              out.响应字节 = body.length;
              out.页面标题 = ((body.match(/<title[^>]*>([\s\S]{0,100}?)<\/title>/i) || [])[1] || '')
                .replace(/\s+/g, ' ').trim();
              out.chapterList规则 = ruleText(tocRule.chapterList);
              out.chapterName规则 = ruleText(tocRule.chapterName);
              out.chapterUrl规则 = ruleText(tocRule.chapterUrl);
              var doc = null;
              try { doc = dom.parseHTML(body, out.最终URL || target.url); } catch (e) { out.解析报错 = String(e && e.message || e); }
              var specText = ruleText(tocRule.chapterList);
              // ⚠️⚠️ **先判规则类型**：复合/JS 规则（🍅大灰狼的 chapterList 就是
              //   `<js>…</js>$.data`）**CSS 路径对它没有意义** ——
              //   要么 0 命中，要么从「十六进制载荷」里瞎解析出几个假节点。
              //   ⇒ 以前诊断只跑 CSS 路径 → 结论恒为「chapterList 一个都没命中」
              //     （对复合规则是**假的**）→ 白白误导人以为规则写错了。
              var specKind = rule.classify(specText, ctx);
              var isJsRule = (specKind === rule.T.JS);
              var nodes = [];
              if (doc && !isJsRule) {
                try { nodes = rule.resolveNodes(specText, doc, {}); }
                catch (e2) { out.选择器报错 = String(e2 && e2.message || e2); }
              }
              out.规则命中元素 = nodes.length;
              // 命中的话，打印第一条命中项的完整 HTML —— 看章节名和链接到底在哪
              if (nodes.length) {
                out.命中条目样本 = String(nodes[0].outerHTML || '').replace(/\s+/g, ' ').slice(0, 900);
                try {
                  var nm = rule.getValue(ruleText(tocRule.chapterName), nodes[0], ctx);
                  var ur = rule.getValue(ruleText(tocRule.chapterUrl), nodes[0], ctx);
                  Promise.all([nm, ur]).then(function (v) {
                    out.取到的章节名 = String(v[0] || '').slice(0, 60);
                    out.取到的章节URL = String(v[1] || '').slice(0, 120);
                  });
                } catch (e3) { out.取值报错 = String(e3 && e3.message || e3); }
              }
              // 没命中 → 扫候选容器（跟 explain 一样）
              // ⚠️ 复合/JS 规则不用扫（扫的是十六进制载荷，纯噪音）
              if (nodes.length === 0 && doc && !isJsRule) {
                var counts = {}, tags = {};
                try {
                  var all = doc.querySelectorAll('[class]');
                  for (var i = 0; i < all.length && i < 6000; i++) {
                    var parts = (all[i].getAttribute('class') || '').trim().split(/\s+/);
                    for (var j = 0; j < parts.length; j++) {
                      var c = parts[j]; if (!c) continue;
                      if (!counts[c]) counts[c] = { n: 0, s: '' };
                      counts[c].n++; tags[c] = all[i].tagName;
                      if (!counts[c].s && counts[c].n === 3) {
                        counts[c].s = String(all[i].outerHTML || '').replace(/\s+/g, ' ').slice(0, 180);
                      }
                    }
                  }
                } catch (e4) {}
                var cand = Object.keys(counts).filter(function (c) { return counts[c].n >= 5; })
                  .sort(function (a, b) { return counts[b].n - counts[a].n; }).slice(0, 6);
                out.候选容器 = cand.map(function (c) {
                  return '.' + c + ' ×' + counts[c].n + ' <' + tags[c] + '>'
                    + (counts[c].s ? '\n    ' + counts[c].s : '');
                }).join('\n') || '页面里没有重复出现的 class';
                var tg = ['dl', 'dd', 'li', 'tr', 'article', 'section', 'div', 'table'];
                var ts = [];
                for (var t = 0; t < tg.length; t++) {
                  var n2 = 0; try { n2 = doc.querySelectorAll(tg[t]).length; } catch (e5) { continue; }
                  if (n2 > 5) ts.push(tg[t] + '=' + n2);
                }
                out.元素统计 = ts.join('  ') || '(没有明显容器标签)';
                var box = ['dl', 'dd', 'ul', 'ol', 'div', 'section'];
                var sm = [];
                for (var b = 0; b < box.length && sm.length < 2; b++) {
                  var lst = null; try { lst = doc.querySelectorAll(box[b]); } catch (e6) { continue; }
                  if (!lst || lst.length < 5) continue;
                  sm.push('—— <' + box[b] + '> ×' + lst.length + ' 的第 1 条 ——\n'
                    + String(lst[0].outerHTML || '').replace(/\s+/g, ' ').slice(0, 900));
                }
                out.目录容器样本 = sm.join('\n\n') || '没找到像目录容器的标签';
              }
              if (nodes.length > 0) {
                out.结论 = '命中 ' + nodes.length + ' 条（看下面的章节名/URL 对不对）';
                return out;
              }
              // ⚠️⚠️ CSS 路径 0 命中 **不等于**「规则没命中」：
              //   🍅大灰狼的 chapterList 是**复合规则**（`<js>…</js>$.data`），
              //   CSS 路径对它**必然 0 命中** → 以前这里恒报
              //   「chapterList 一个都没命中 —— 目录规则对不上」→ **纯误导**
              //   （用户会以为规则写错，其实规则是对的，锅在别处）。
              //   ⇒ 现在按**真实路径**（toc op 的做法：跑 JS → 再走尾部选择器）
              //     再跑一遍，把真实条数 / JS 报错摆出来，诊断才说真话。
              return rule.getJsonListDiag(ruleText(tocRule.chapterList), doc, ctx)
                .then(function (diag) {
                  out.JS路径命中 = diag.items.length;
                  if (diag.error) out.JS报错 = diag.error;
                  if (diag.items.length) {
                    var it0 = diag.items[0] || {};
                    out.取到的章节名 = String(it0.title || it0.name || '').slice(0, 60);
                    out.取到的章节URL = String(it0.url || it0.href || '').slice(0, 120);
                    out.结论 = '复合/JS 规则真实命中 ' + diag.items.length
                      + ' 条（CSS 路径对它不适用，**别当成规则没命中**）';
                  } else {
                    out.结论 = 'chapterList 真的一条都没解析出来'
                      + (diag.error ? '（JS 报错：' + diag.error + '）'
                                     : '（规则不是 JS，CSS 也没命中）');
                  }
                  return out;
                })
                .catch(function (e) {
                  out.结论 = 'chapterList 真的一条都没解析出来（诊断也炸了：'
                    + String(e && e.message || e) + '）';
                  return out;
                });
            })
            .catch(function (e) { out.结论 = '请求失败：' + String(e && e.message || e); return out; });
        });
      });
    },

    /** 书籍详情 */
    bookInfo: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var bi = src.ruleBookInfo || {};
        // ⚠️ 走 analyzeRuleUrl：站方 URL 后面可能带 `,{json}` 请求选项
        return analyzeRuleUrl(p.bookUrl, { baseUrl: baseUrlOf(src), page: 1, source: src })
        .then(function (tgt) {
        var url = tgt.url;
        if (!url) return { book: null, error: '书籍 URL 为空' };
        return fetchPage({ url: url, method: tgt.method, headers: tgt.headers || {}, body: tgt.body },
                         { baseUrl: url }).then(function (page) {
          var ctx = { baseUrl: page.url, source: src, book: p.book };
          markContent(ctx, page);
          // Legado 的 `ruleBookInfo.init`：在详情页结果上跑一次，
          // **把它的输出当成后面所有字段规则的基准节点**。
          // JSON 接口源几乎全靠它 —— 比如 `init: "$.data"` 把
          // `{code,msg,data:{...}}` 缩成 `{...}`，后面 `$.authorName` 才有值。
          // 不支持的话所有 $.xxx 都会打在 {code,msg,data} 这一层上 → 字段全空。
          // Swift 侧属性名不能叫 `init`（保留字），叫 initRule，
          // 但对 JSON 暴露的键应该还是 `init`。两个都认，
          // 免得哪边映射漏了整本书详情直接全空、目录也跟着废。
          var initText = ruleText(bi.init) || ruleText(bi.initRule);
          // ⚠️ getElements 返回的是 **Promise**，必须 await ——
          //    同步去读 .values 永远拿到 undefined（Promise 上没有这个属性），
          //    于是 base 一直停在整页，init 等于没跑。
          return rule.getElements(initText.trim() || '$$__no_init__$$', page.doc, ctx)
            .then(function (r) {
              var iv = r && r.values ? r.values : null;
              if (!initText.trim() || !iv || !iv.length) return page.doc;
              var b = iv[0];
              // getElements 给的是**字符串**值（JSONPath 结果会被序列化）。
              // `init: "$.data"` 拿到的是那段 JSON 文本，直接当基准的话
              // 后面 `{{$.bookId}}` 会在字符串上取字段 → 空。先 parse 回对象。
              if (typeof b === 'string') {
                var t = b.replace(/^[\s]+|[\s]+$/g, '');
                if (t.charAt(0) === '{' || t.charAt(0) === '[') {
                  try { b = JSON.parse(t); } catch (e) { /* 保持原样 */ }
                }
              }
              return b;
            })
            .catch(function () { return page.doc; })
            .then(function (initBase) {
          // ⚠️ 用 evalFields：有 @put/@get 时**按顺序**求值
          //   （站方常写 name='$.catename@put:{bid:bid}' + tocUrl='…/@get:{bid}'）
          //   ⇒ 并行的话 tocUrl 先跑 ⇒ 变量还没存 ⇒ 目录 URL 里是空的 ⭐
          // tocUrl 缺失时默认就是书籍页本身
          return evalFields([
            bi.name, bi.author, bi.intro, bi.kind,
            bi.lastChapter, bi.coverUrl, bi.tocUrl, bi.wordCount
          ], initBase, ctx).then(function (v) {
            // 👁️ 观测：详情页最终给出的 tocUrl 是什么形状（2026-10-21 真机 0 章排查）
            //   站方 ruleBookInfo.tocUrl 为空时回退成 `url`（书籍页），
            //   而 🍅大灰狼的 tocUrl 应该是 `data:;base64,…` ⇒ 两者行为完全不同。
            try {
              QR.java.log('[详情] 入参 bookUrl=' + brief(p.bookUrl) +
                ' ‖ 站方tocUrl字段=' + brief(v[6]) +
                ' ‖ 实际tocUrl=' + brief(absolutizeMaybe(v[6] || url, page.url)) +
                ' ‖ 书名=' + brief(v[0], 40));
            } catch (e) {}
            var _bk = {
              name: v[0] || (p.book && p.book.name) || '',
              author: v[1] || '',
              intro: v[2] || '',
              kind: v[3] || '',
              lastChapter: v[4] || '',
              coverUrl: absolutizeMaybe(v[5], page.url),
              tocUrl: absolutizeMaybe(v[6] || url, page.url),
              wordCount: v[7] || ''
            };
            // ⭐⭐⭐ **把 p.book 的【原始字段】也带上**（同上）
            //   站方 jsLib 拿 book_id 生成 data: 载荷 ⇒ 缺了就只有 {tab,url} ⇒ 全线崩
            try {
              if (p.book && typeof p.book === 'object') {
                for (var pk in p.book) {
                  if (!(pk in _bk) && pk !== 'variables') _bk[pk] = p.book[pk];
                }
              }
            } catch (e2) {}
            return { book: _bk };
          });
            });
        });
        });
      }).catch(function (e) {
        return { book: null, error: String(e && e.message || e) };
      });
    },

    /** 目录 */
    toc: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var tr = src.ruleToc || {};
        // ⚠️ 走 analyzeRuleUrl：站方 URL 后面可能带 `,{json}` 请求选项
        //   （创世中文网：'https://chuangshi.qq.com/chapter/26150754,{"headers":{…}}'
        //    ⇒ 以前后缀原样发出去 ⇒ 404 ⇒ **目录 0 章** ⭐）
        return analyzeRuleUrl(p.tocUrl || p.bookUrl, { baseUrl: baseUrlOf(src), page: 1, source: src })
        .then(function (tgt) {
        var url = tgt.url;
        if (!url) return { chapters: [], error: '目录 URL 为空' };
        // 👁️ 观测：目录 URL 是怎么算出来的（2026-10-21 真机 0 章排查）
        try {
          QR.java.log('[目录] 入参 tocUrl=' + brief(p.tocUrl) +
            ' ‖ bookUrl=' + brief(p.bookUrl) +
            ' ‖ book.tocUrl=' + brief(p.book && p.book.tocUrl) +
            ' ‖ 实际用=' + brief(url));
        } catch (e) {}
        var ctx = { baseUrl: url, source: src, book: p.book };
        var maxPages = Math.max(1, p.maxPages || 10);

        /**
         * 算出「下一跳」：站方的 nextTocUrl 可能给
         *   ① 一个 URL（字符串）② **一组 URL（数组）**（红薯小说一次给全所有剩余页）
         *   ③ 空 ⇒ 自己找「下一页」链接
         */
        function finishNext(list, u, v, page) {
          var explicit = '';
          var explicitList = [];
          if (Array.isArray(v)) {
            explicitList = v.map(function (x) { return String(x || '').trim(); })
                           .filter(Boolean);
            explicit = explicitList[0] || '';
          } else if (v != null && typeof v === 'object') {
            explicit = '';
          } else {
            explicit = String(v == null ? '' : v).trim();
          }
          var nextUrl = absolutizeMaybe(explicit || findNextPage(page.doc, page.url), page.url);
          // 下一跳 URL 必须真的变了，否则会死循环
          if (nextUrl && nextUrl === u) nextUrl = '';
          try {
            QR.java.log('[目录] 本页命中=' + (list ? list.length : 0) +
              ' 条 ‖ nextUrl=' + brief(nextUrl, 160) +
              (explicitList.length > 1 ? (' ‖ 站方一次给了 ' + explicitList.length + ' 页') : ''));
          } catch (e) {}
          return { list: list, nextUrl: nextUrl, nextUrls: explicitList };
        }

        /** 抓一页目录，返回 { list, nextUrl } */
        function one(u, offset) {
          try { QR.java.log('[目录] 请求 url=' + brief(u)); } catch (e) {}
          return fetchPage({
            url: u,
            method: (offset === 0 ? tgt.method : 'GET'),
            headers: (offset === 0 ? (tgt.headers || {}) : {}),
            body: (offset === 0 ? (tgt.body || '') : '')
          }, ctx).then(function (page) {
            try {
              QR.java.log('[目录] 返回 最终url=' + brief(page.url) +
                ' 状态=' + (page.resp && page.resp.code) +
                ' 正文长=' + (page.text ? page.text.length : 0) +
                ' isJSON=' + (ctx.isJSON ? 1 : 0));
            } catch (e) {}
            markContent(ctx, page);
            var spec = ruleText(tr.chapterList);
            return rule.getElements(spec, page.doc, ctx).then(function (jsRes) {
              // ★★★ 复合规则 `<js>…</js>$.data`（🍅大灰狼的目录就是这种）：
              //   先跑 JS（解 data: URL → ajax 拿 catalog JSON）→ 再用 `$.data` 取章节
              //   `getElements` **会**做这条链 ✅
              //   而 `resolveNodes` 只认 CSS → 复合规则的章节**全丢** → 目录空 ❌
              //   ⚠️ 以前这里把 getElements 的结果**丢掉了**，直接走 resolveNodes。
              var specKind = rule.classify(spec, ctx);
              if (specKind === rule.T.JS) {
                // ⚠️ 必须用 getJsonList：getElements 会把 JSON 对象 flatten 成字符串 ❌
                return rule.getJsonList(spec, page.doc, ctx).then(function (jsItems) {
                  return collectChapters(jsItems || [], offset, page.url, tr, ctx);
                });
              }
              // ★ JSON 响应的目录：章节是 JSON 对象（`$.list..bookChapters[*]`），
              //   不是 DOM 节点。必须直接 jsonpath 取**对象**，
              //   否则 resolveNodes 在 Document 上按 CSS 解析 → 0 节点 → 退回整页，
              //   结果目录为空。跟 extractBooks 的 JSON 分支是一对。
              if (ctx && ctx.isJSON) {
                var jItems = [];
                try {
                  var jKind = rule.classify(spec, ctx);
                  if (rule.T && rule.T.JSONPATH === jKind || jKind === 'jsonpath') {
                    jItems = jsonPathListOf(page.text, rule.stripModePrefix(spec, jKind));
                  }
                } catch (e) { jItems = []; }
                if (!jItems.length) {
                  try {
                    jItems = (rule.getElements(spec, page.text, ctx).values || [])
                      .map(reviveJsonNode);
                  } catch (e2) { jItems = []; }
                }
                return collectChapters(jItems, offset, page.url, tr, ctx);
              }
              // ⚠️ 必须走 resolveNodes（自己解析 || 兜底链），
              //    不能 dom.resolve(page.doc, spec) —— 后者把 || 各分支当并集，
              //    `a[rel=chapter] || li a[href*="/info/"]` 会吐出 63 个而不是 17 个。
              var nodes = rule.resolveNodes(spec, page.doc, ctx);
              return collectChapters(nodes.length ? nodes : [page.doc],
                                     offset, page.url, tr, ctx);
            }).then(function (list) {
              // 站方给了 nextTocUrl 就用它，否则自己找「下一页」链接
              var explicit = '';
              var explicitList = [];
              var ntxt = tr.nextTocUrl ? ruleText(tr.nextTocUrl).trim() : '';
              if (ntxt) {
                // ⚠️⚠️ **JSON 页面的 nextTocUrl 要拿【JSON 原文】**（2026-10-23 真机踩到）
                //   站方写法（🍅红薯小说）：
                //     nextTocUrl = '@js:\nvar n=JSON.parse(result); n=n.totalpage; …list'
                //   ⇒ 它要 `result` 是**JSON 字符串** ⇒ 以前在 HTML 文档上求值
                //      ⇒ `JSON.parse(result)` 炸 ⇒ nextUrl 空 ⇒ **不翻页 ⇒ 目录只有 50 章** ⭐
                //   ⇒ JSON 页面时用 `ctx.raw`（= page.text）作 result
                if (ctx && ctx.isJSON && rule.classify(ntxt) === rule.T.JS) {
                  try {
                    var ns = rule.makeScope(rule.jsScope(page.doc, page.doc, ctx, ntxt));
                    ns.result = (ctx.raw != null) ? ctx.raw : page.text;
                    return rule.runJs(rule.stripJsWrapper(ntxt), ns).then(function (v) {
                      return finishNext(list, u, v, page);
                    }).catch(function () { return finishNext(list, u, '', page); });
                  } catch (e) { /* 落回 HTML 路径 */ }
                }
                try { explicit = dom.value(page.doc, ntxt, page.url); } catch (e) {}
              }
              return finishNext(list, u, explicit, page);
            });
          });
        }

        // 部分站目录要串行翻多页；下标跨页累计，别每页都从 0 开始
        //
        // ⚠️⚠️ **队列 + 去重**（2026-10-23 真机「红薯目录只有 50 章」）
        //   站方（🍅红薯小说）的 nextTocUrl **一次返回所有剩余页的数组**：
        //     '@js: var n=JSON.parse(result); … for(i=2;i<=n;i++) list.push(baseUrl+i); list'
        //   ⇒ 以前只认**一个** URL ⇒ 只翻一页 ⇒ **目录只有 50 章**（一页 50 条）⭐
        //   ⇒ 现在：nextTocUrl 给数组 ⇒ **当队列** ⇒ 逐页抓
        //   ⇒ 且**去重**（站方每页都会再给一次同样的数组 ⇒ 不去重会重复抓 + 章节重复）
        var seen = {};
        function loop(queue, n, acc) {
          if (!queue || !queue.length || n >= maxPages) return Promise.resolve(acc);
          // 跳过已经抓过的页（站方每页都给全量数组 ⇒ 不去重会死循环 + 章节重复）
          while (queue.length && seen[queue[0]]) queue.shift();
          if (!queue.length || n >= maxPages) return Promise.resolve(acc);
          var u = queue.shift();
          seen[u] = 1;
          return one(u, acc.length).then(function (r) {
            var merged = acc.concat(r.list);
            if (!r.list.length) return merged;
            var q = (r.nextUrls && r.nextUrls.length) ? r.nextUrls.slice()
                    : (r.nextUrl ? [r.nextUrl] : []);
            return loop(q, n + 1, merged);
          });
        }

        return loop([url], 0, []).then(function (chapters) {
          var rawCount = chapters ? chapters.length : 0;
          // ⚠️⚠️⚠️ **过滤「书自己」那条占位**（2026-10-22 真机「QQ 阅读目录出不来」查出来的）
          //   大灰狼服务器的 `/catalog` 对**它没抓到章节的书**会返回**一条占位**：
          //     {"data":[{"title":"放开那个女巫",       ← 书名！不是章节名
          //                 "item_id":"7414308239…",  ← 等于 book_id
          //                 "first_pass_time":"第一卷：默认 | 2024-09-14 09:45:27",
          //                 "url":"", "toc_url":"", "is_volume":false}]}
          //   ⇒ 这**不是章节**（点进去必然失败）⇒ 以前被当成 1 个章节 ⇒ 用户看到「目录只有 1 章」
          //   ⇒ 现在按「title == 书名 && url 是 data: 载荷」判掉 ⭐
          var bookName = '';
          try { bookName = String((p.book && p.book.name) || '').trim(); } catch (e) {}
          var placeholder = false;
          var out = chapters || [];
          if (bookName && out.length) {
            // ⚠️⚠️ **零误伤**：只判「title == 书名」会误伤**第一章标题恰好等于书名**的书
            //   （很常见：很多书第一章就叫书名）⇒
            //   ⇒ **只有「滤完整个列表就空了」才真的滤掉** ⇒
            //   · 服务器只回了「书自己」那条 ⇒ 滤掉 ⇒ 0 章 + 明确提示 ✅
            //   · 正常章节里有一章叫书名 ⇒ 列表不空 ⇒ **一根都不动** ✅
            var kept = out.filter(function (c) {
              var t = String((c && c.title) || '').trim();
              var isPh = (t === bookName) && String((c && c.url) || '').indexOf('data:') === 0;
              return !isPh;
            });
            if (kept.length === 0) {
              placeholder = true;
              out = kept;
            }
          }
          try {
            QR.java.log('[目录] 完成 总章节=' + out.length + '（原始 ' + rawCount + ' 条）' +
              ' ‖ 抓了 ' + maxPages + ' 页上限'
              + (placeholder ? ' ‖ ⚠️ 过滤掉了「书自己」那条占位（站方服务器没这本书的章节）' : ''));
          } catch (e) {}
          // ⚠️ 把「原始条数 / 是否是占位」带回去 ⇒ Swift 侧能给出**准确**的提示
          //   （以前一律说「chapterList 规则没命中」⇒ 误导：规则命中了，是服务器没数据）
          return {
            chapters: out,
            rawCount: rawCount,
            placeholderFiltered: placeholder,
            bookName: bookName
          };
        });
        });
      }).catch(function (e) {
        try { QR.java.log('[目录] 抛错 ' + String(e && e.message || e)); } catch (e2) {}
        return { chapters: [], error: String(e && e.message || e) };
      });
    },

    /** 正文 */
    content: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureJsLib(src).then(function () {
        var cr = src.ruleContent || {};
        // ⚠️ 走 analyzeRuleUrl：站方 URL 后面可能带 `,{json}` 请求选项
        return analyzeRuleUrl(p.chapterUrl, { baseUrl: baseUrlOf(src), page: 1, source: src })
        .then(function (tgt) {
        var url = tgt.url;
        if (!url) return { content: '', error: '章节 URL 为空' };
        // ⚠️⚠️ **必须带 book**！
        //    站方正文 JS 会调 `book.getVariable('custom')`（🍅大灰狼的 ruleContent.content）
        //    → ctx 里没有 book → 站方 JS 报
        //    「Cannot read properties of undefined (reading 'getVariable')」
        //    → 整条规则静默失效 → **正文是空的**（标题倒是对的，因为那条规则不用 book）
        var ctx = { baseUrl: url, source: src, chapter: p.chapter, book: p.book };
        return fetchPage({ url: url, method: tgt.method, headers: tgt.headers || {}, body: tgt.body },
                         ctx).then(function (page) {
          markContent(ctx, page);
          // webJs：给站方解密/改写正文用，跑完拿它吐出的 HTML
          var htmlP = Promise.resolve(page.text);
          if (cr.webJs && String(cr.webJs).trim()) {
            htmlP = rule.runJs(String(cr.webJs), rule.makeScope({
              result: page.text, baseUrl: page.url, source: src, chapter: p.chapter,
              page: QR.jsoup.Jsoup.parse(page.text, page.url)
            })).then(function (r) {
              if (typeof r === 'string' && r) return r;
              if (r && r.html) return r.html;
              return page.text;
            }).catch(function (e) {
              QR.java.log('[webJs 出错] ' + e.message);
              return page.text;
            });
          }
          return htmlP.then(function (html) {
            var doc = dom.parseHTML(html, page.url);
            return Promise.all([
              rule.getValue(ruleText(cr.title), doc, ctx),
              rule.getValue(ruleText(cr.content), doc, ctx),
              rule.getValue(ruleText(cr.nextContentUrl), doc, ctx)
            ]).then(function (v) {
              var content = v[1] || '';
              // 阅读器是纯文本渲染，HTML 一律转成文本（br/p 会变成换行）。
              // 不少源的 content 规则写的是 `@html`，不转的话正文里会露出 <div id=...> 这种标签。
              if (/<[a-zA-Z][^>]*>/.test(content)) {
                content = dom.htmlToText(content);
              }
              content = cleanContent(content);
              return {
                title: v[0] || (p.chapter && p.chapter.title) || '',
                content: content,
                nextUrl: absolutizeMaybe(v[2], page.url)
              };
            });
          });
        });
        });
      }).catch(function (e) {
        return { content: '', error: String(e && e.message || e) };
      });
    }
  };

  function normalizeKinds(arr, base) {
    // ⚠️⚠️ **分组**（照抄栖阅 `ExploreCategorySplit.groups()` / `_splitExploreCategories(_)`）
    //
    //   站方（🍅大灰狼）把分类分成组，组标题是**装饰行**，形如
    //     `○ *。*☆ 排行榜 ☆*。* ○`  /  `○ *。*☆ 热门标签 ☆*。* ○`
    //   真正的分类是 `标题::URL` 两段式。
    //   ⇒ 栖阅：没有 "::" 的行 = **组标题**，后面的项归到这一组
    //      （界面上就是那个「分类筛选」面板：分类 / ☆排行榜☆ / ☆热门标签☆）
    //   ⇒ 轻阅原来把组标题也当成一个分类（URL 为空）→ 分组出不来、点不动 ❗
    var out = [];
    var filters = [];
    var group = '';
    (arr || []).forEach(function (k) {
      if (typeof k === 'string') {
        var raw = String(k).trim();
        if (!raw) return;
        if (raw.indexOf('::') < 0) {
          // 没有 "::" ⇒ 组标题（装饰符号剥掉，只留文字）
          group = raw.replace(/[*☆○●•·　\s]+/g, '').trim() || raw;
          return;
        }
        var p = raw.split('::');
        var title = p[0].trim();
        var url = dom.absolutize((p[1] || '').trim(), base);
        if (!title || !url) return;
        out.push({ title: title, url: url, style: '', group: group });
        return;
      }
      // ⭐⭐⭐ **发现页筛选栏**（栖阅契约，2026-10-21 补）
      //   站方（🍅大灰狼）的 exploreUrl 返回的是 `qtsj.concat(infoData, groupDatas, style_list)`，
      //   其中 `qtsj` 是**筛选栏**（不是分类）：
      //       createFilter('平台', ['番茄','七猫','书旗',…42个], sources, 'find_source', 1)
      //       createFilter('模式', ['小说','听书','短剧','漫画'], tab, 'find_tab', 0.33)
      //       createFilter('频道', ['男频','女频'], source_type, 'source_type', 0.33)
      //   契约：`{ title, type:'select', chars:[选项], default:当前值, action:"show(infoMap['平台'],'find_source')" }`
      //
      //   ⚠️ 这些项**没有 url 字段** ⇒ 以前被当成普通分类 ⇒ 出现在分类列表里但点不动
      //      ⇒ **用户看到「平台」这些项没有 api**（2026-10-21 用户原话）
      //   ⇒ 现在：单独分流成 `filters` ⇒ 宿主渲染成筛选栏 ⇒ 选中写源级变量 + 刷新
      var ktype = String((k && k.type) || '').toLowerCase();
      if (ktype === 'select') {
        var chars = [];
        if (Array.isArray(k.chars)) {
          chars = k.chars.map(function (c) { return String(c); });
        } else if (typeof k.chars === 'string') {
          chars = k.chars.split(/[,\n]/).map(function (c) { return c.trim(); }).filter(Boolean);
        }
        var ftitle = String(k.title || '');
        if (ftitle) {
          filters.push({
            title: ftitle,
            type: 'select',
            chars: chars,
            default: String(k.default || ''),
            // ⚠️ 参数名从 action 里抠：`show(infoMap['平台'],'find_source')` → 'find_source'
            paramKey: filterParamKey(k),
            action: String(k.action || '')
          });
        }
        return;
      }
      // ⚠️⚠️⚠️ **对象项也要认「装饰行」**（2026-10-22 对照栖阅截图才发现）
      //   站方（🍅大灰狼）的 `style_list = result.data || []` 是**对象数组**：
      //     { title:"°・*.☆ 排行榜 ☆.*・°", style:{layout_flexGrow:1, layout_flexBasisPercent:1} }
      //     { title:"推荐榜", url:"…", style:{…, layout_flexBasisPercent:0.25} }
      //   ⇒ 上面那段「无 `::` ⇒ 组标题」的解析**只对字符串项生效**（那是 `标题::URL` 两段式站源）
      //   ⇒ 对象项的**装饰行被当成了普通分类项** ⇒ `group` 全空
      //   ⇒ 宿主只好拿 `style`（原始 JSON）当组名 ⇒ 界面上出现
      //      `{"layout_flexGrow":1,"layout_flexBasisPercent":0.25}` 这种标题 ❗
      //   （栖阅那边是**正确分 4 组**的：分类 / ○ *。☆ 排行榜 ☆*。* ○ / …）
      var objTitle = String(k.title || k.name || k.text || '');
      var objStyle = (k.style && typeof k.style === 'object') ? k.style : null;
      var styleStr = objStyle ? JSON.stringify(objStyle) : String(k.style || '');
      // ⚠️⚠️⚠️ **判据只能是「url 空不空」，不能看 style！**
      //   站方的组标题行（不论是装饰行、「当前为: XX」还是「图书」）**style.pct 都是 1**
      //   ⇒ 之前我按 `pct == 1` 判「信息行」⇒ 把「当前为: XX」「图书」**误杀**了
      //   ⇒ 只剩装饰行（title 带 ☆）侥幸活下来 ⇒ 七猫/QQ阅读 看起来「还是一块」❗
      // ⚠️⚠️⚠️ **url 为空 ⇒ 这是站方的「组标题行」（栖阅同款）**（2026-10-22 对照栖阅截图）
      //   站方 style_list 的原始数据长这样（QQ阅读 实测 24 条）：
      //     [0] 点击登录可切换来源        url空 style=1   ← 站方自己 exclude 掉了
      //     [1] 切换后长按刷新即可        url空 style=1   ← 同上
      //     [2] 当前为: QQ阅读 [小说]频道：男频  url空  ← ⭐ **组标题**
      //     [3..7] 今日必读/会员榜/…      有 url         ← 归到 [2] 那组
      //     [8] 分类                      url空         ← ⭐ **组标题**（title 就叫「分类」）
      //     [9..22] 玄幻/奇幻/武侠…        有 url         ← 归到 [8] 那组
      //     [23] --                      url空         ← 垃圾行
      //   ⇒ **规则就一句：url 为空的项 = 组标题行，它自己成为一个组的标题，
      //      后面有 url 的项都归到最近的那个组标题下** ⭐
      //   ⇒ 番茄那边同样成立（装饰行「°・*.☆ 排行榜 ☆.*・°」的 url 也是空的）
      //   ⇒ 栖阅的界面就是这样：分类 / 当前为: XX / 分类 / 图书 …（几个组）
      //
      //   ⚠️ 之前我把它「丢掉」了 ⇒ 七猫/QQ阅读 的分组全没了 ⇒ **糊成一块**（用户反馈）
      var objUrl = dom.absolutize(String(k.url || k.link || ''), base);
      if (!objTitle) return;
      if (!objUrl) {
        // 「--」这种垃圾行不当组标题（它后面没内容 ⇒ 空组 ⇒ UI 也不显示）
        if (objTitle !== '--' && !/^[\s\-–—_]+$/.test(objTitle)) {
          group = objTitle;
        }
        return;   // 组标题行**不作为分类项输出**
      }
      out.push({
        title: objTitle,
        url: objUrl,
        style: styleStr,
        // ⚠️ 用**累积的 `group`**（装饰行设的），不是 `k.group`
        //    （站方对象数组里没有 group 字段 ⇒ 用 k.group 永远是空 ⇒ 宿主只能拿 style 当组名 ❗）
        group: String(k.group || '') || group
      });
    });
    return { kinds: out.filter(function (k) { return k.title; }), filters: filters };
  }

  /**
   * 从筛选栏的 `action` 里抠出**源级变量名**。
   *
   * 站方写法：`show(infoMap['平台'],'find_source')` ⇒ 第二个参数就是变量名。
   * 抠不出来就返回空串（宿主侧会把这一项标成「不可选」，而不是乱写变量）。
   */
  function filterParamKey(k) {
    var a = String((k && k.action) || '');
    var m = a.match(/infoMap\[['"]([^'"]+)['"]\]\s*,\s*['"]([^'"]+)['"]/);
    if (m && m[2]) return m[2];
    // 兜底：`show('平台','find_source')` 这种不带 infoMap 的写法
    var m2 = a.match(/\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*\)/);
    if (m2 && m2[2]) return m2[2];
    return '';
  }

  /* 正文清洗：去广告行、去首尾空行 */
  function cleanContent(s) {
    var lines = String(s || '').split('\n');
    var drop = /(上一章|下一章|返回目录|加入书架|推荐本书|txt下载|请记住本站|www\.|http:\/\/|请收藏本站|广告)/;
    var out = lines.filter(function (l) {
      var t = l.trim();
      if (!t) return true;
      if (drop.test(t) && t.length < 40) return false;
      return true;
    });
    return out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  /* ---------------------------------------------------------
   * 入口
   * ------------------------------------------------------- */

  g.__qrInvoke = function (op, payload) {
    var fn = OPS[op];
    if (!fn) return Promise.reject(new Error('未知操作: ' + op));
    var p = payload || {};
    // ① cookie 快照：原生侧在调用前塞进来（Legado 的 cookie.getCookie 是同步的，
    //    我们的原生桥是异步的，只能靠快照同步读）。
    if (QR.__qrInstallCookieSnapshot) QR.__qrInstallCookieSnapshot(p.cookieSnapshot);
    if (QR.__qrResetDirty) QR.__qrResetDirty();
    // ⚠️ jsLib 里的函数是用**间接 eval**定义的 → 活在**全局作用域**。
    //    所以 jsLib 函数体里写的 `source.getVariable()` 里的 `source`
    //    解析到的是**全局的 g.source**，不是规则 scope 里的那个。
    //    → 不在 op 期间把 g.source 挂上，jsLib 的函数一调就是
    //      "Cannot read properties of undefined (reading 'getVariable')"。
    var wrappedSrc = QR.wrapSource ? QR.wrapSource(p.source) : p.source;
    var prevSource = g.source, prevBook = g.book, prevChapter = g.chapter;
    g.source = wrappedSrc;
    g.book = p.book;
    g.chapter = p.chapter;
    return Promise.resolve()
      .then(function () { return fn(p); })
      .then(function (r) {
        // ② 站方 JS 改过的书籍变量/登录信息 → 回传给原生侧落盘
        if (QR.__qrTakeDirty && r && typeof r === 'object' && !Array.isArray(r)) {
          var dirty = QR.__qrTakeDirty();
          if (dirty.vars !== undefined) r.__sourceVars = dirty.vars;
          // ⭐⭐⭐ 站方变量（Legado 语义）⇒ 回传（原生落盘）⭐
          if (dirty.variable !== undefined) r.__sourceVariable = dirty.variable;
          if (dirty.login !== undefined) r.__loginInfo = dirty.login;
          if (dirty.loginHeader !== undefined) r.__loginHeader = dirty.loginHeader;
        }
        return r;
      })
      .catch(function (e) {
        return { error: String(e && e.message || e) };
      })
      .then(function (r) {
        g.source = prevSource; g.book = prevBook; g.chapter = prevChapter;
        return r;
      });
  };
  g.__qrOps = Object.keys(OPS);
})(typeof globalThis !== 'undefined' ? globalThis : self);
