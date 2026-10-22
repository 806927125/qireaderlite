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
  var libOwner = '';   // 当前全局属于哪个书源

  function globalNames() {
    try { return Object.getOwnPropertyNames(g); } catch (e) { return []; }
  }

  function purgeLibGlobals(key) {
    var names = libGlobals[key] || [];
    for (var i = 0; i < names.length; i++) {
      var n = names[i];
      try { delete g[n]; } catch (e) { try { g[n] = undefined; } catch (e2) {} }
    }
    libGlobals[key] = [];
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
      // ⚠️ 记下本次 jsLib **新增**的全局 ⇒ 切书源时删掉
      try {
        var after = globalNames();
        var added = [];
        for (var gi = 0; gi < after.length; gi++) {
          if (namesBefore.indexOf(after[gi]) < 0) added.push(after[gi]);
        }
        libGlobals[key] = added;
        libOwner = key;
        try {
          if (added.length) {
            QR.java.log('[全局治理] 载入「' + (source.bookSourceName || key) + '」新增 ' +
              added.length + ' 个全局变量（切书源时会清掉）');
          }
        } catch (e) {}
      } catch (e) { /* 忽略 */ }
    } catch (e) {
      QR.java.log('[jsLib 出错] ' + (source.bookSourceName || key) + ': ' + e.message);
    }
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
        return Promise.all([
          rule.getValue(ruleText(tocRule.chapterName), base, tocCtx),
          rule.getValue(ruleText(tocRule.chapterUrl), base, tocCtx)
        ]).then(function (v) {
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

  function dataUrlContent(u) {
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
    } catch (e) {}
    return data;
  }

  function fetchPage(target, ctx) {
    var u = String((target && target.url) || '');
    // ⚠️ `data:` 伪 URL **不能真去 fetch**（原生会失败）：
    //    聚合源用它把参数塞进「URL」里（data:;base64,<载荷>,{选项}）。
    //    载荷直接当**页面内容**交给后面的规则（init 规则会自己解）。
    if (u.indexOf('data:') === 0) {
      var content = dataUrlContent(u);
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

  function extractBooks(page, listRule, ctx, opts) {
    opts = opts || {};
    var listRuleStr = ruleText(listRule.bookList);
    if (!listRuleStr) return Promise.resolve({ books: [], nextUrl: '' });

    // ★ JSON 响应：列表项是 JSON 对象，字段规则要针对每个对象单独求值
    if (ctx && ctx.isJSON) {
      var kind = rule.classify(listRuleStr, ctx);
      var body = rule.stripModePrefix(listRuleStr, kind);
      var items = [];
      if (kind === 'jsonpath') {
        try { items = jsonListOf(QR.jsonpath.select(JSON.parse(page.text), body)); } catch (e) { items = []; }
      } else {
        try { items = rule.getElements(listRuleStr, page.doc, ctx).values || []; } catch (e) { items = []; }
      }
      var jbooks = [];
      var jchain = items.reduce(function (acc, item) {
        return acc.then(function (list) {
          return extractOneBook(item, listRule, ctx, page.url, {}).then(function (b) {
            if (b && b.name) list.push(b);
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
    return Promise.all([
      f(listRule.name),
      f(listRule.author),
      f(listRule.intro),
      f(listRule.kind),
      f(listRule.lastChapter),
      f(listRule.coverUrl),
      f(listRule.bookUrl),
      f(listRule.wordCount)
    ]).then(function (v) {
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
    });
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
    login: function (p) {
      var src = p.source || {};
      runtime.source = src;
      return ensureLoginLib(src).then(function () {
        var action = String(p.action || '').trim();
        if (!action) return { ok: false, error: '没有登录动作' };
        var formValues = (p.formValues && typeof p.formValues === 'object') ? p.formValues : {};
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
          // JS 里常内嵌 {{$.xxx}} / {{page}}，要先展开再跑
          var jsCode = rule.interpolate(rule.stripJsWrapper(spec), scope);
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
        var url = absolutizeMaybe(p.bookUrl, baseUrlOf(src));
        if (!url) return { book: null, error: '书籍 URL 为空' };
        return fetchPage({ url: url, headers: {} }, { baseUrl: url }).then(function (page) {
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
          function f(rv) { return rule.getValue(ruleText(rv), initBase, ctx); }
          // tocUrl 缺失时默认就是书籍页本身
          return Promise.all([
            f(bi.name), f(bi.author), f(bi.intro), f(bi.kind),
            f(bi.lastChapter), f(bi.coverUrl), f(bi.tocUrl), f(bi.wordCount)
          ]).then(function (v) {
            // 👁️ 观测：详情页最终给出的 tocUrl 是什么形状（2026-10-21 真机 0 章排查）
            //   站方 ruleBookInfo.tocUrl 为空时回退成 `url`（书籍页），
            //   而 🍅大灰狼的 tocUrl 应该是 `data:;base64,…` ⇒ 两者行为完全不同。
            try {
              QR.java.log('[详情] 入参 bookUrl=' + brief(p.bookUrl) +
                ' ‖ 站方tocUrl字段=' + brief(v[6]) +
                ' ‖ 实际tocUrl=' + brief(absolutizeMaybe(v[6] || url, page.url)) +
                ' ‖ 书名=' + brief(v[0], 40));
            } catch (e) {}
            return {
              book: {
                name: v[0] || (p.book && p.book.name) || '',
                author: v[1] || '',
                intro: v[2] || '',
                kind: v[3] || '',
                lastChapter: v[4] || '',
                coverUrl: absolutizeMaybe(v[5], page.url),
                tocUrl: absolutizeMaybe(v[6] || url, page.url),
                wordCount: v[7] || ''
              }
            };
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
        var url = absolutizeMaybe(p.tocUrl || p.bookUrl, baseUrlOf(src));
        if (!url) return { chapters: [], error: '目录 URL 为空' };
        // 👁️ 观测：目录 URL 是怎么算出来的（2026-10-21 真机 0 章排查）
        try {
          QR.java.log('[目录] 入参 tocUrl=' + brief(p.tocUrl) +
            ' ‖ bookUrl=' + brief(p.bookUrl) +
            ' ‖ book.tocUrl=' + brief(p.book && p.book.tocUrl) +
            ' ‖ 实际用=' + brief(url));
        } catch (e) {}
        var ctx = { baseUrl: url, source: src, book: p.book };
        var maxPages = Math.max(1, p.maxPages || 3);

        /** 抓一页目录，返回 { list, nextUrl } */
        function one(u, offset) {
          try { QR.java.log('[目录] 请求 url=' + brief(u)); } catch (e) {}
          return fetchPage({ url: u, headers: {} }, ctx).then(function (page) {
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
                    jItems = jsonListOf(QR.jsonpath.select(JSON.parse(page.text),
                      rule.stripModePrefix(spec, jKind)));
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
              if (tr.nextTocUrl && ruleText(tr.nextTocUrl).trim()) {
                try { explicit = dom.value(page.doc, ruleText(tr.nextTocUrl), page.url); } catch (e) {}
              }
              var nextUrl = absolutizeMaybe(explicit || findNextPage(page.doc, page.url), page.url);
              // 下一跳 URL 必须真的变了，否则会死循环
              if (nextUrl && nextUrl === u) nextUrl = '';
              try {
                QR.java.log('[目录] 本页命中=' + (list ? list.length : 0) +
                  ' 条 ‖ nextUrl=' + brief(nextUrl, 160));
              } catch (e) {}
              return { list: list, nextUrl: nextUrl };
            });
          });
        }

        // 部分站目录要串行翻多页；下标跨页累计，别每页都从 0 开始
        function loop(u, n, acc) {
          if (!u || n >= maxPages) return Promise.resolve(acc);
          return one(u, acc.length).then(function (r) {
            var merged = acc.concat(r.list);
            if (!r.list.length || !r.nextUrl) return merged;
            return loop(r.nextUrl, n + 1, merged);
          });
        }

        return loop(url, 0, []).then(function (chapters) {
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
        var url = absolutizeMaybe(p.chapterUrl, baseUrlOf(src));
        if (!url) return { content: '', error: '章节 URL 为空' };
        // ⚠️⚠️ **必须带 book**！
        //    站方正文 JS 会调 `book.getVariable('custom')`（🍅大灰狼的 ruleContent.content）
        //    → ctx 里没有 book → 站方 JS 报
        //    「Cannot read properties of undefined (reading 'getVariable')」
        //    → 整条规则静默失效 → **正文是空的**（标题倒是对的，因为那条规则不用 book）
        var ctx = { baseUrl: url, source: src, chapter: p.chapter, book: p.book };
        return fetchPage({ url: url, headers: {} }, ctx).then(function (page) {
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
      out.push({
        title: String(k.title || k.name || k.text || ''),
        url: dom.absolutize(String(k.url || k.link || ''), base),
        style: (k.style && typeof k.style === 'object') ? JSON.stringify(k.style) : String(k.style || ''),
        group: String(k.group || '')
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
