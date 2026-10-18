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

  function ensureJsLib(source) {
    if (!source || !source.jsLib) return Promise.resolve();
    var key = source.bookSourceUrl || source.bookSourceName || 'anon';
    if (libLoaded[key]) return Promise.resolve();
    libLoaded[key] = true;
    var code = String(source.jsLib);
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
      g.source = source; g.book = undefined; g.chapter = undefined;
      try {
        fn(code);
      } finally {
        g.source = prevSource; g.book = prevBook; g.chapter = prevChapter;
        void addedCache; void addedCookie;
      }
    } catch (e) {
      QR.java.log('[jsLib 出错] ' + (source.bookSourceName || key) + ': ' + e.message);
    }
    return Promise.resolve();
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
      try { v = rule.evalExpr(code, scope); } catch (e) { v = ''; }
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
    var body = opt.body != null ? String(opt.body) : '';

    if (method === 'GET' && abs.indexOf('?') > 0) {
      // GET 的 query 走 analyzeQuery 重新编码（keyword 这类中文要变 %E6%96%97）
      var qi = abs.indexOf('?');
      abs = abs.slice(0, qi) + '?' + encodeFields(abs.slice(qi + 1));
      body = '';
    } else if (method === 'POST' && body && !/^[[{]/.test(body.trim())) {
      // Legado: 非 JSON/XML 的 form body 走 analyzeFields 编码
      body = encodeFields(body);
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
  function encField(v) {
    var s = String(v == null ? '' : v), out = '', i = 0;
    while (i < s.length) {
      if (s.charAt(i) === '%' && /^[0-9A-Fa-f]{2}$/.test(s.substr(i + 1, 2))) {
        out += s.substr(i, 3); i += 3; continue;
      }
      var c = s.charAt(i);
      if (/[A-Za-z0-9_.\-~!*'()]/.test(c)) out += c;
      else if (c === '+') out += '+';
      else out += encodeURIComponent(c);
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

  function fetchPage(target, ctx) {
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
        try { items = QR.jsonpath.select(JSON.parse(page.text), body) || []; } catch (e) { items = []; }
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

    /** 发现页的分类列表 */
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
            return { kinds: normalizeKinds(arr, ctx.baseUrl) };
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
          if (Array.isArray(jk)) return { kinds: normalizeKinds(jk, ctx.baseUrl) };
        }
        var kinds = raw.split(/(&&|\n)+/).map(function (l) { return String(l).trim(); }).filter(Boolean)
          .map(function (l) {
            var p2 = l.split('::');
            return { title: p2[0], url: dom.absolutize((p2[1] || '').trim(), ctx.baseUrl), style: '' };
          });
        return { kinds: kinds };
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
        var ctx = { baseUrl: baseUrlOf(src), source: src };
        var out = {};
        var raw = p.tocUrl || p.bookUrl || '';
        return buildUrl(raw, ctx).then(function (target) {
          out.请求URL = target.url || String(raw);
          if (!target.url) { out.结论 = '目录 URL 为空'; return out; }
          return QR.java.rawRequest(target.url, 'GET', target.headers || {}, '', 20000)
            .then(function (resp) {
              var body = resp._body || resp.body || '';
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
              var nodes = [];
              if (doc) {
                try { nodes = rule.resolveNodes(ruleText(tocRule.chapterList), doc, {}); }
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
              if (nodes.length === 0 && doc) {
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
              if (nodes.length === 0) out.结论 = '**chapterList 一个都没命中** —— 目录规则对不上';
              else out.结论 = '命中 ' + nodes.length + ' 条（看下面的章节名/URL 对不对）';
              return out;
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
          function f(rv) { return rule.getValue(ruleText(rv), page.doc, ctx); }
          // tocUrl 缺失时默认就是书籍页本身
          return Promise.all([
            f(bi.name), f(bi.author), f(bi.intro), f(bi.kind),
            f(bi.lastChapter), f(bi.coverUrl), f(bi.tocUrl), f(bi.wordCount)
          ]).then(function (v) {
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
        var ctx = { baseUrl: url, source: src, book: p.book };
        var maxPages = Math.max(1, p.maxPages || 3);

        /** 抓一页目录，返回 { list, nextUrl } */
        function one(u, offset) {
          return fetchPage({ url: u, headers: {} }, ctx).then(function (page) {
            markContent(ctx, page);
            var spec = ruleText(tr.chapterList);
            return rule.getElements(spec, page.doc, ctx).then(function () {
              // ⚠️ 必须走 resolveNodes（自己解析 || 兜底链），
              //    不能 dom.resolve(page.doc, spec) —— 后者把 || 各分支当并集，
              //    `a[rel=chapter] || li a[href*="/info/"]` 会吐出 63 个而不是 17 个。
              var nodes = rule.resolveNodes(spec, page.doc, ctx);
              var bases = nodes.length ? nodes : [page.doc];
              var idx = offset;
              return bases.reduce(function (acc, base) {
                return acc.then(function (out) {
                  return Promise.all([
                    rule.getValue(ruleText(tr.chapterName), base, ctx),
                    rule.getValue(ruleText(tr.chapterUrl), base, ctx)
                  ]).then(function (v) {
                    var title = (v[0] || '').trim();
                    // 标题和 URL 都必须有才算一章。
                    // ⚠️ 原来只查 title：站方在 <li> 里插纯文本（没 <a>）时，
                    //    chapterUrl 拿到空串，absolutizeMaybe('', page.url)
                    //    会**回落到详情页 URL** —— 于是凭空多出一堆"章节"，
                    //    点进去全是同一本书的详情页。实测 m.powenxue15.com 的
                    //    PC 版 15 个 <li> 里 7 个是纯文本 `<li>标题</li>`。
                    var url = absolutizeMaybe(v[1], '');
                    if (!title || !url) return out;
                    out.push({
                      url: url,
                      title: title,
                      index: idx++,
                      isVolume: /卷|部|篇/.test(title) && !/第\s*\d+/.test(title),
                      tag: ''
                    });
                    return out;
                  });
                });
              }, Promise.resolve([]));
            }).then(function (list) {
              // 站方给了 nextTocUrl 就用它，否则自己找「下一页」链接
              var explicit = '';
              if (tr.nextTocUrl && ruleText(tr.nextTocUrl).trim()) {
                try { explicit = dom.value(page.doc, ruleText(tr.nextTocUrl), page.url); } catch (e) {}
              }
              var nextUrl = absolutizeMaybe(explicit || findNextPage(page.doc, page.url), page.url);
              // 下一跳 URL 必须真的变了，否则会死循环
              if (nextUrl && nextUrl === u) nextUrl = '';
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
          return { chapters: chapters };
        });
      }).catch(function (e) {
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
        var ctx = { baseUrl: url, source: src, chapter: p.chapter };
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
    return (arr || []).map(function (k) {
      if (typeof k === 'string') {
        var p = k.split('::');
        return { title: p[0], url: dom.absolutize((p[1] || '').trim(), base), style: '' };
      }
      return {
        title: String(k.title || k.name || k.text || ''),
        url: dom.absolutize(String(k.url || k.link || ''), base),
        style: (k.style && typeof k.style === 'object') ? JSON.stringify(k.style) : String(k.style || '')
      };
    }).filter(function (k) { return k.title; });
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
    return Promise.resolve()
      .then(function () { return fn(payload || {}); })
      .catch(function (e) {
        return { error: String(e && e.message || e) };
      });
  };
  g.__qrOps = Object.keys(OPS);
})(typeof globalThis !== 'undefined' ? globalThis : self);
