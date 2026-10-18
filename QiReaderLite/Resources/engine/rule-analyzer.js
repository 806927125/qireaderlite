/* ============================================================
 * rule-analyzer.js —— Legado 书源规则解释器
 *
 * 一条规则可能长这样：
 *   class.search@tag.li@tag.a@href      Jsoup 选择器
 *   <li>...<a href="{{...}}">           简化 HTML 模板
 *   ##(\d+)##第$1章                     正则替换
 *   $.data.list[*].bookName             JSONPath
 *   //div[@class="c"]/text()            XPath
 *   @js:java.ajax(url).select("a")      JS
 *   规则A || 规则B || 规则C             回退链
 *   规则A && 规则B && 规则C             依次尝试
 *   <js>result.replace(...)             规则后接的 JS 后处理
 *
 * 全部在这里统一处理，Swift 侧只负责把原始字符串送进来。
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};
  var dom = QR.dom;

  /* ---------------------------------------------------------
   * 运算符拆分（顶层 && / ||，括号与引号内不算）
   * ------------------------------------------------------- */

  function splitTop(str, seps) {
    var out = [], buf = '', depth = 0, q = null;
    for (var i = 0; i < str.length; i++) {
      var c = str[i];
      if (q) {
        buf += c;
        if (c === '\\') { buf += str[++i] || ''; continue; }
        if (c === q) q = null;
        continue;
      }
      if (c === '"' || c === "'") { q = c; buf += c; continue; }
      if (c === '(' || c === '[' || c === '{') { depth++; buf += c; continue; }
      if (c === ')' || c === ']' || c === '}') { depth--; buf += c; continue; }
      if (depth === 0) {
        var hit = null;
        for (var s = 0; s < seps.length; s++) {
          if (str.startsWith(seps[s], i)) { hit = seps[s]; break; }
        }
        if (hit) { out.push(buf); buf = ''; i += hit.length - 1; continue; }
      }
      buf += c;
    }
    out.push(buf);
    return out.map(function (s) { return s.trim(); });
  }

  /* ---------------------------------------------------------
   * 规则类型判定
   * ------------------------------------------------------- */

  var T = {
    JS: 'js', REGEX: 'regex', JSONPATH: 'jsonpath', XPATH: 'xpath',
    HTML: 'html', SELECTOR: 'selector', EMPTY: 'empty'
  };

  /**
   * 规则模式判定 —— 对齐 Legado 的 SourceRule.init。
   *
   * 最关键的一条：**响应是 JSON 时，整条规则链都切 JSONPath 模式**，
   * 不管规则长什么样。API 类书源全靠这条。我以前永远当 CSS 选择器解析，
   * 结果就是「搜不出东西」。
   *
   * ctx.isJSON 由调用方在抓到响应后设置。
   */
  function classify(raw, ctx) {
    var s = String(raw == null ? '' : raw).trim();
    if (!s) return T.EMPTY;
    if (s.startsWith('@js:') || s.startsWith('@JS:')) return T.JS;
    if (s.startsWith('<js>') || s.startsWith('<JS>')) return T.JS;
    if (s.startsWith('##')) return T.REGEX;

    // 显式前缀优先
    if (/^@CSS:/i.test(s)) return T.SELECTOR;
    if (s.startsWith('@@')) return T.SELECTOR;
    if (/^@XPath:/i.test(s)) return T.XPATH;
    if (/^@Json:/i.test(s)) return T.JSONPATH;

    // 内容类型决定：JSON 响应 → 整链 JSONPath
    if (ctx && ctx.isJSON) return T.JSONPATH;
    if (/^\$\s*[.\[]/.test(s)) return T.JSONPATH;
    // 规则以 / 开头 → XPath（Legado 原注释：XPath 特征很明显，无需识别标头）
    if (s.charAt(0) === '/') return T.XPATH;
    if (s.charAt(0) === '<') return T.HTML;
    return T.SELECTOR;
  }

  /** 剥掉模式前缀，把真正的规则体交回给解析器 */
  function stripModePrefix(rule, kind) {
    var s = String(rule == null ? '' : rule);
    if (kind === T.XPATH) return s.replace(/^@XPath:/i, '');
    if (kind === T.JSONPATH) return s.replace(/^@Json:/i, '');
    if (kind === T.SELECTOR) return s.replace(/^@CSS:/i, '').replace(/^@@/, '');
    return s;
  }

  /** 响应体是不是 JSON —— Legado: content.toString().isJson() */
  function isJSONText(text) {
    var t = String(text == null ? '' : text).trim();
    if (!t) return false;
    var c = t.charAt(0);
    if (c !== '{' && c !== '[') return false;
    try { JSON.parse(t); return true; } catch (e) { return false; }
  }

  /* ---------------------------------------------------------
   * 正则规则： ##pat##rep##rep2
   * 没有 ## 的部分在中间；`##` 后面依次是 模式、替换、替换…
   * 只有一组时表示纯提取（取第 1 个捕获组，没有就取整体）
   * ------------------------------------------------------- */

  function parseRegexRule(rule) {
    var body = String(rule);
    // 前面若带 `前缀##模式##替换`，前缀是可选的「作用于哪里」
    var parts = body.split('##');
    var ops = [];
    for (var i = 1; i < parts.length; i++) {
      if (parts[i] === '' && i === parts.length - 1) continue;
      ops.push(parts[i]);
    }
    return { pattern: ops[0] || '', replace: ops[1] !== undefined ? ops[1] : null, rest: ops.slice(2) };
  }

  /** 看着像地址才补全 —— 否则正则抓到一句正文也会被当 URL 编码掉 */
  function looksLikeURL(s) {
    return /^(https?:|ftps?:|file:|\/\/|\/|\.{1,2}\/)/i.test(String(s || ''));
  }

  function applyRegex(text, rule, baseUrl) {
    var p = parseRegexRule(rule);
    if (!p.pattern) return [];
    var re;
    try { re = new RegExp(p.pattern, 'g'); } catch (e) { return []; }
    var out = [];
    var m, guard = 0;
    while ((m = re.exec(text)) !== null && guard++ < 20000) {
      var piece = p.replace === null
        ? (m.length > 1 ? (m[1] !== undefined ? m[1] : m[0]) : m[0])
        : replaceAll(String(m[0]), p.replace, m);
      if (p.rest.length && /<js>|<js/i.test(p.rest.join(''))) break;
      out.push(looksLikeURL(piece) ? dom.absolutize(piece, baseUrl) : piece);
      if (m.index === re.lastIndex) re.lastIndex++;
    }
    return out;
  }

  function replaceAll(src, rep, m) {
    return String(rep).replace(/\$(\d+)/g, function (_, d) {
      return m[Number(d)] !== undefined ? m[Number(d)] : '';
    }).replace(/\\n/g, '\n');
  }

  /* ---------------------------------------------------------
   * 规则后处理：尾部的 ##正则##替换 和 <js>...</js>
   * ------------------------------------------------------- */

  function postProcess(value, tail, ctx) {
    if (!tail) return value;
    return tail;
  }

  /* ---------------------------------------------------------
   * JS 求值作用域
   * ------------------------------------------------------- */

  function makeScope(extra) {
    var scope = {
      result: undefined,
      // Legado 的 {{$.xxx}} = 对上一条规则结果做 JSONPath。
      // $ 是合法 JS 标识符，可以直接当形参传进去。
      $: undefined,
      java: g.java,
      cookie: g.cookie,
      cache: g.cache,
      source: undefined,
      baseUrl: '',
      book: undefined,
      chapter: undefined,
      page: 1,
      // 常用快捷方式，真实 Legado 里有些是宿主注入的
      JSON: JSON, Math: Math, Date: Date, RegExp: RegExp,
      String: String, Number: Number, Array: Array, Object: Object,
      parseInt: parseInt, parseFloat: parseFloat, isNaN: isNaN,
      encodeURI: g.encodeURI, encodeURIComponent: g.encodeURIComponent,
      decodeURI: g.decodeURI, decodeURIComponent: g.decodeURIComponent,
      btoa: g.btoa, atob: g.atob, console: { log: function () { QR.java.log.apply(null, arguments); } }
    };
    for (var k in (extra || {})) scope[k] = extra[k];
    return scope;
  }

  var evalCache = {};

  /**
   * 跑站方 JS。
   *
   * 关键点：书源写的是**表达式**，不是 `return expr`。
   * `new Function('...', 'return (function(){ expr })()')` 会把完成值丢掉（恒为 undefined），
   * 所以这里用直接 eval 取最后一个语句的完成值 —— 这样
   * `@js: java.ajax(u).select('a')` 和 `@js: return xxx` 两种写法都能用。
   *
   * 不用 strict：不少书源靠非严格模式的 var 提升跨语句共享变量。
   */
  /**
   * Rhino（Legado 的 JS 引擎）比 ES 规范宽松，JavaScriptCore 不认。
   * 最常见的就是**解构参数不带括号**：`map([t,a]=>{...})`
   * —— Rhino 收，JSC 报 "Malformed arrow function parameter list"。
   *
   * 只修「标识符列表」这种简单形态，避免误伤正则字面量里的 [=>]。
   */
  function fixRhinoLenient(code) {
    var s = String(code == null ? '' : code);
    // 数组解构 [a,b] =>   →  ([a,b]) =>
    s = s.replace(/(\W|^)(\[[A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*\])\s*=>/g,
      function (m, pre, g) { return pre + '(' + g + ')=>'; });
    // 对象解构 {a,b} =>   →  ({a,b}) =>
    s = s.replace(/(\W|^)(\{[A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*\})\s*=>/g,
      function (m, pre, g) { return pre + '(' + g + ')=>'; });
    return s;
  }

  function runJs(code, scope) {
    var names = Object.keys(scope);
    var args = names.map(function (k) { return scope[k]; });
    var key = names.join(',') + '\u0001' + code;
    var fn = evalCache[key];
    if (!fn) {
      try {
        /* jshint evil:true */
        fn = new Function(names.concat(['__qrCode']).join(','),
          'return eval(__qrCode);');
      } catch (e) {
        return Promise.reject(new Error('JS 作用域非法: ' + e.message));
      }
      evalCache[key] = fn;
    }
    var out;
    try {
      out = fn.apply(scope, args.concat([fixRhinoLenient(code)]));
    } catch (e) {
      return Promise.reject(new Error('JS 执行失败: ' + (e && e.message)));
    }
    return Promise.resolve(out);
  }

  /* ---------------------------------------------------------
   * 主入口
   * ------------------------------------------------------- */

  function baseToText(base) {
    if (base == null) return '';
    if (typeof base === 'string') return base;
    if (base.__raw != null) return base.__raw;
    if (base.nodeType) return dom.textOf(base);
    // JSON 模式的「当前项」是普通对象，要能还原成 JSON 文本再被 JSONPath 解析
    if (typeof base === 'object') {
      try { return JSON.stringify(base); } catch (e) { return String(base); }
    }
    return String(base);
  }

  function baseToNode(base, baseUrl) {
    if (base == null) return null;
    if (base.nodeType) return base;
    if (base.__node) return base.__node;
    if (typeof base === 'string') return dom.parseHTML(base, baseUrl);
    return null;
  }

  /** 把规则的执行结果拉平成字符串数组 */
  function flatten(v, baseUrl) {
    var out = [];
    if (v == null) return out;
    if (Array.isArray(v)) {
      for (var i = 0; i < v.length; i++) out = out.concat(flatten(v[i], baseUrl));
      return out;
    }
    if (v && v.nodeType) { var t = dom.textOf(v); if (t) out.push(t); return out; }
    if (v && typeof v === 'object' && v.__value !== undefined) { return flatten(v.__value, baseUrl); }
    if (typeof v === 'object') {
      // 常见的 {text, url} / {title, href} 形状
      if (v.text !== undefined || v.title !== undefined) {
        var s = v.text !== undefined ? v.text : v.title;
        if (v.url || v.href) {
          return [dom.textOf(s) + '\t' + dom.absolutize(String(v.url || v.href), baseUrl)];
        }
        return flatten(s, baseUrl);
      }
      try { return [JSON.stringify(v)]; } catch (e) { return []; }
    }
    var str = String(v);
    if (str === '') return out;
    return [str];
  }

  /**
   * 执行单条规则（不含回退链），返回字符串数组
   * @param rule  规则原文
   * @param base  基准节点 / 文本
   * @param ctx   { baseUrl, source, book, chapter, ... }
   */
  function evalOne(rule, base, ctx) {
    ctx = ctx || {};
    var baseUrl = ctx.baseUrl || '';
    var text = baseToText(base);
    var node = baseToNode(base, baseUrl);

    // 先做 {{}} 插值和 @get/@put，再判定规则类型
    var scope = makeScope(jsScope(base, base, ctx, rule));
    rule = applyGetPut(String(rule == null ? '' : rule), scope);
    var rawRule = rule;
    rule = interpolate(rule, scope);
    var kind = classify(rule, ctx);
    rule = stripModePrefix(rule, kind);

    // 整条规则就是一个 {{占位符}} → 结果就是这个值本身，不再往下走选择器。
    // 不这么判的话 {{source.u}} 展开成 "S" 会被当成 <s> 标签选择器，
    // 因为 s/b/i/p 这些单字母本来都是合法 HTML 标签名。
    if (rule !== rawRule && /^\s*\{\{[\s\S]*\}\}\s*$/.test(rawRule)) {
      var whole = String(rule).trim();
      return Promise.resolve(whole ? [whole] : []);
    }
    // 部分插值后不再是选择器的，也原样返回。
    // ⚠️ **必须要求插值真的发生过**（rule !== rawRule）：
    //    不加这个判断，`chapterName: 'a@text || text'` 里的兜底裸词 `text`
    //    会被当**字面量**返回，目录里就出现一排字面写着 "text" 的章节；
    //    同理 `href` 会变成字面量 "href"。实测 2026-10-18 肉文屋。
    //    这个分支的本意只是接住 `{{...}}` 展开后的结果，不是接住裸词。
    if (kind === 'selector' && rule !== rawRule && !/[.#:@>\s*+~\[\]()|]/.test(rule)) {
      var lit = String(rule).trim();
      return Promise.resolve(lit ? [lit] : []);
    }

    // 拆出尾部后处理：##正则##替换 / <js>...</js>
    var tail = '';
    var body = String(rule);
    var jsTailIdx = findJsTail(body);
    if (jsTailIdx >= 0) { tail = body.slice(jsTailIdx); body = body.slice(0, jsTailIdx).trim(); }
    var rgIdx = findRegexTail(body);
    if (rgIdx > 0) { tail = body.slice(rgIdx) + (tail || ''); body = body.slice(0, rgIdx).trim(); }
    kind = classify(body);
    if (!body && kind === T.EMPTY) return Promise.resolve([]);

    var p;
    switch (kind) {
      case T.JS: {
        p = runJs(stripJsWrapper(body), makeScope(jsScope(base, base, ctx, body)));
        break;
      }
      case T.REGEX: {
        p = Promise.resolve(applyRegex(text, body, baseUrl));
        break;
      }
      case T.JSONPATH: {
        p = Promise.resolve(evalJsonPath(text, body));
        break;
      }
      case T.XPATH: {
        p = Promise.resolve(evalXPath(node || dom.parseHTML(text, baseUrl), body));
        break;
      }
      case T.HTML: {
        p = Promise.resolve([dom.htmlToText(body)]);
        break;
      }
      default: {
        // 选择器
        if (!node) return Promise.resolve([]);
        var r = dom.resolve(node, body);
        p = Promise.resolve(r.nodes.map(function (n) {
          return dom.valueOf(n, r.suffix, baseUrl);
        }).filter(function (s) { return s !== ''; }));
      }
    }

    return p.then(function (res) {
      var list = flatten(res, baseUrl);
      if (tail) list = applyTail(list, tail, ctx, base);
      return list;
    }).catch(function (e) {
      QR.java.log('[规则出错]', String(body).slice(0, 120), e && e.message);
      return [];
    });
  }

  /** {{$.id}} 里的 $ 应该是「上一条规则的结果」；结果是 JSON 字符串就解析掉 */
  function asJsonish(v) {
    if (v && v.nodeType) v = dom.textOf(v);
    if (typeof v === 'string') {
      var t = v.trim();
      if (t.charAt(0) === '{' || t.charAt(0) === '[') {
        try { return JSON.parse(t); } catch (e) { /* 继续往下抠 */ }
      }
      // 结果里 JSON 后面还粘着别的文本时，抠出第一段完整的 JSON
      var open = t.search(/[{[]/);
      if (open >= 0) {
        var head = t.charAt(open), close = head === '{' ? '}' : ']';
        var depth = 0, end = -1;
        for (var i = open; i < t.length; i++) {
          if (t[i] === head) depth++;
          else if (t[i] === close) { depth--; if (depth === 0) { end = i; break; } }
        }
        if (end > open) {
          try { return JSON.parse(t.slice(open, end + 1)); } catch (e2) { /* 放弃 */ }
        }
      }
    }
    return v;
  }

  function jsScope(result, base, ctx, code) {
    return {
      // 多值规则的 result 必须是数组，书源里会写 result.length / result[0] / result.map
      result: Array.isArray(result) ? result
             : (result && result.nodeType ? dom.textOf(result) : result),
      $: asJsonish(result),
      resultNode: result,
      // 站方 @js: 里经常直接 document.querySelectorAll，
      // 得把它指向当前规则的基准文档，而不是引擎自己的空页面
      document: ownerDocOf(base),
      baseUrl: ctx.baseUrl || '',
      source: ctx.source,
      book: ctx.book,
      chapter: ctx.chapter,
      page: ctx.page,
      base: base,
      rule: code
    };
  }

  function ownerDocOf(base) {
    if (base && base.nodeType === 9) return base;
    if (base && base.ownerDocument) return base.ownerDocument;
    return g.document;
  }

  function stripJsWrapper(s) {
    var t = String(s).trim();
    if (t.startsWith('@js:')) return t.slice(4);
    if (t.startsWith('@JS:')) return t.slice(4);
    if (t.startsWith('<js>') && t.endsWith('</js>')) return t.slice(4, -5);
    if (t.startsWith('<JS>') && t.endsWith('</JS>')) return t.slice(4, -5);
    return t;
  }

  function findJsTail(s) {
    var low = s.toLowerCase();
    var i1 = low.indexOf('<js>', 4);   // 跳过开头自身的 <js>
    var i2 = low.indexOf('@js:', 4);
    var idx = -1;
    if (i1 >= 0) idx = i1;
    if (i2 >= 0 && (idx < 0 || i2 < idx)) idx = i2;
    return idx;
  }

  function findRegexTail(s) {
    // 找 ## 出现的位置；若 ## 出现在选择器内部（罕见）则不算 tail
    var i = s.indexOf('##');
    if (i <= 0) return -1;
    // 前面必须不含 < 或 | 这类明显不是选择器的东西
    var head = s.slice(0, i);
    if (head.indexOf('|') >= 0) return -1;
    return i;
  }

  function applyTail(list, tail, ctx, base) {
    if (!tail) return list;
    // <js> 结尾：对每个结果跑 JS
    var jsM = /^(<js>|<JS>|@js:)([\s\S]*?)(<\/js>|<\/JS>)?$/.exec(tail.trim());
    if (jsM && /<js>|<JS>/i.test(tail)) {
      var code = tail.trim().replace(/^<[jJ][sS]>/, '').replace(/<\/[jJ][sS]>$/, '');
      return list.length ? evalTailOn(code, list, ctx, base) : list;
    }
    // ##正则##替换##  —— 出现在**后缀**位置时，语义是「把匹配的部分替换掉」。
    // 没写替换串 = **删掉**匹配部分（正文清洗就是这个用法，
    // 比如 `id.content@html##一秒记住.*|www.*` 就是要抹掉广告行）。
    //
    // 注意别和「整条规则就是 ##正则##」搞混：那种是**提取**匹配内容，
    // 走的是 evalOne 里的 T.REGEX 分支。两处语义相反。
    if (tail.startsWith('##')) {
      var r = parseRegexRule(tail);
      if (!r.pattern) return list;
      var re;
      try { re = new RegExp(r.pattern, 'g'); } catch (e) { return list; }
      var rep = r.replace === null ? '' : r.replace;
      return list.map(function (s) {
        return s.replace(re, function () {
          return replaceAll(arguments[0], rep, arguments);
        });
      });
    }
    return list;
  }

  function evalTailOn(code, list, ctx, base) {
    var scope = makeScope(jsScope(list, base, ctx, code));
    return runJs(code, scope).then(function (r) {
      var out = flatten(r, ctx.baseUrl || '');
      return out.length ? out : list;
    }).catch(function () { return list; });
  }

  function evalJsonPath(text, rule) {
    var data;
    try { data = JSON.parse(text); } catch (e) { return []; }
    var r = QR.jsonpath.select(data, rule);
    return flatten(r, '');
  }

  function evalXPath(root, rule) {
    var expr = rule.replace(/^xpath:/i, '');
    if (!/^\.{0,2}\//.test(expr)) expr = '//' + expr.replace(/^\/+/, '');
    try {
      var it = document.evaluate(expr, root, null,
        XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      var out = [];
      for (var i = 0; i < it.snapshotLength; i++) {
        var n = it.snapshotItem(i);
        if (!n) continue;
        out.push(n.nodeType === 3 || n.nodeType === 2 ? n.nodeValue : dom.textOf(n));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /* ---------------------------------------------------------
   * 对外：带回退链的求值
   * ------------------------------------------------------- */

  /** 规则可能是数组（多行），也可能是带 || / && 的字符串 */
  function toLines(rule) {
    if (rule == null) return [];
    if (Array.isArray(rule)) return rule.map(function (r) { return String(r); }).filter(function (r) { return r.trim(); });
    if (typeof rule === 'string') {
      // Legado 允许用换行写多行规则
      return rule.split('\n').map(function (r) { return r.trim(); }).filter(Boolean);
    }
    return [String(rule)];
  }

  /**
   * 求值一条完整规则（含 || / && 回退链）
   * 返回 { values: string[], rule: 实际命中的规则原文 }
   */
  /* ---------------------------------------------------------
   * {{表达式}} 插值
   *
   * Legado 允许在任意规则文本里嵌 {{…}}，求值后替换掉再执行。
   * 语料里最常见的是 {{java.put/get}}、{{$.Id}}、{{book.name}}、
   * {{Math.round()}}、{{Date.now()}} —— 不做这一步这些规则全部失效。
   * --------------------------------------------------------- */

  /** URL 级别的占位符由 buildUrl 单独处理，不在这里求值 */
  var URL_PLACEHOLDER = /^(page|pageIndex)$/i;

  function evalExpr(expr, scope) {
    try {
      var names = Object.keys(scope);
      var fn = new Function(names.concat(['__qrE']).join(','), 'return eval(__qrE);');
      return fn.apply(scope, names.map(function (k) { return scope[k]; }).concat([expr]));
    } catch (e) {
      return '';
    }
  }

  /**
   * 把 {{…}} 替换成求值结果。
   * 用括号配对找结尾，不靠正则 —— 里面可能嵌套 {{java.put('a', {x:1})}}。
   */
  function interpolate(text, scope) {
    var s = String(text == null ? '' : text);
    if (s.indexOf('{{') < 0) return s;
    var out = '', i = 0, guard = 0;
    while (i < s.length && guard++ < 500) {
      var a = s.indexOf('{{', i);
      if (a < 0) { out += s.slice(i); break; }
      out += s.slice(i, a);
      var depth = 0, j = a, end = -1;
      for (; j < s.length; j++) {
        if (s[j] === '{') depth++;
        else if (s[j] === '}') { depth--; if (depth === 0) { end = j; break; } }
      }
      if (end < 0) { out += s.slice(a); break; }
      // end 指向 }} 的第二个 }，所以内容要减 1 个字符；
      // 少减这个 1，表达式会变成 "book.name}"，求值必然失败返回空。
      var expr = end - 1 > a + 2 ? s.slice(a + 2, end - 1).trim() : '';
      i = end + 1;
      if (!expr || URL_PLACEHOLDER.test(expr)) out += s.slice(a, end + 1);
      else {
        var v = evalExpr(expr, scope);
        out += (v === null || v === undefined) ? '' : String(v);
      }
    }
    return out;
  }

  /** `@get:{var}` / `@put:{var}` —— 读写前面规则存下来的变量 */
  function applyGetPut(ruleStr, scope) {
    var m = /^@(get|put|getString|getInt):\{(.*)\}$/i.exec(String(ruleStr).trim());
    if (!m) return ruleStr;
    var op = m[1].toLowerCase(), key = m[2].trim();
    var vars = QR.runtime && QR.runtime.vars ? QR.runtime.vars : (QR.runtime.vars = {});
    if (op === 'put') {
      vars[key] = (scope && scope.result != null) ? scope.result : '';
      return '';
    }
    var v = vars[key];
    if (v == null) return '';
    return op === 'getint' ? String(parseInt(v, 10) || 0) : String(v);
  }

  function getElements(rule, base, ctx) {
    var lines = toLines(rule);
    if (!lines.length) return Promise.resolve({ values: [], rule: '' });

    function tryOr(line) {
      // || 分支：任一有结果就用它
      var orParts = splitTop(line, ['||']);
      if (orParts.length === 1) return tryAnd(line);
      var idx = 0;
      function step() {
        if (idx >= orParts.length) return Promise.resolve({ values: [], rule: line });
        var p = orParts[idx++];
        return tryAnd(p).then(function (r) {
          return r.values.length ? { values: r.values, rule: p } : step();
        });
      }
      return step();
    }

    // && 分支：依次尝试，前一个有结果就停
    function tryAnd(line) {
      var andParts = splitTop(line, ['&&']);
      if (andParts.length === 1) return evalOne(line, base, ctx).then(function (values) {
        return { values: values, rule: line };
      });
      var i = 0;
      function step() {
        if (i >= andParts.length) return Promise.resolve({ values: [], rule: line });
        var p = andParts[i++];
        return evalOne(p, base, ctx).then(function (values) {
          return values.length ? { values: values, rule: p } : step();
        });
      }
      return step();
    }

    // 多行：逐行尝试
    function stepLines(k) {
      if (k >= lines.length) return Promise.resolve({ values: [], rule: '' });
      return tryOr(lines[k]).then(function (r) {
        return r.values.length ? r : stepLines(k + 1);
      });
    }
    return stepLines(0);
  }

  function getValue(rule, base, ctx) {
    return getElements(rule, base, ctx).then(function (r) {
      return r.values.length ? r.values[0] : '';
    });
  }

  /**
   * 按 Legado 的 多行 → `||` → `&&` 顺序找**第一个非空分支**，返回**节点**数组。
   *
   * ⚠️ 为什么不能直接 `dom.resolve(doc, rule)`：
   *    `dom.resolve` 只认逗号分组，**完全不认 `||`**。
   *    把 `#list dl dd||#list dd||#chapterlist dl dd` 这种带兜底链的
   *    chapterList 原样丢进去，等于把各分支**并集**处理——
   *    实测 `a[rel=chapter] || li a[href*="/info/"]` 在肉文屋详情页上
   *    本该 17 章，实际吐出 **63 个节点**（17 + 46 个推荐书/导航混在一起），
   *    目录直接废掉。而 book source 里 `||` 兜底链是**最常见**的写法。
   *
   *    getElements 的分支逻辑是对的，但它返回的是**字符串值**，
   *    DOM 相关的调用（bookList / chapterList）要的是节点，所以这里补一份。
   */
  function resolveNodes(rule, base, ctx) {
    // Legado 语义：规则前面加 `-` = 「站方列表是倒序，取出来反转成阅读顺序」。
    // 很多站的详情页把**最新章放在最前**（实测 m.powenxue15.com 肉文屋：
    // 17 章里 39483916 在最前，后面才是 39483902…），不加 `-` 目录就是倒的。
    var raw = String(rule == null ? '' : rule).trim();
    var reverse = false;
    while (raw.charAt(0) === '-') { reverse = !reverse; raw = raw.slice(1).trim(); }
    if (!raw) return [];

    var lines = toLines(raw);
    for (var i = 0; i < lines.length; i++) {
      var orParts = splitTop(lines[i], ['||']);
      for (var j = 0; j < orParts.length; j++) {
        var andParts = splitTop(orParts[j], ['&&']);
        for (var k = 0; k < andParts.length; k++) {
          var r = null;
          try { r = dom.resolve(base, andParts[k]); } catch (e) { continue; }
          if (r && r.nodes && r.nodes.length) {
            return reverse ? r.nodes.slice().reverse() : r.nodes;
          }
        }
      }
    }
    return [];
  }

  /** java.getStringMatch / java.getElements 的兼容入口 */
  function stringMatchAll(rule, text) {
    var k = classify(rule);
    if (k === T.REGEX) return applyRegex(String(text == null ? '' : text), rule, '');
    if (k === T.JS) {
      return runJs(stripJsWrapper(rule), makeScope({ result: String(text || '') }))
        .then(function (r) { return flatten(r, ''); })
        .catch(function () { return []; });
    }
    // 当成普通选择器，在包了 HTML 的文档里取
    var doc = dom.parseHTML(String(text || ''), '');
    return Promise.resolve(dom.selectAll(doc, rule).map(function (n) { return dom.textOf(n); }));
  }

  QR.rule = {
    T: T,
    interpolate: interpolate,
    evalExpr: evalExpr,
    fixRhinoLenient: fixRhinoLenient,
    classify: classify,
    stripModePrefix: stripModePrefix,
    isJSONText: isJSONText,
    splitTop: splitTop,
    toLines: toLines,
    getElements: getElements,
    getValue: getValue,
    resolveNodes: resolveNodes,
    evalOne: evalOne,
    runJs: runJs,
    makeScope: makeScope,
    stripJsWrapper: stripJsWrapper,
    parseRegexRule: parseRegexRule,
    stringMatchAll: stringMatchAll,
    flatten: flatten
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
