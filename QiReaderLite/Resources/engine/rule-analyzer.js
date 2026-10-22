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

    // 内容类型决定：JSON 响应 → JSONPath。
    // ⚠️ 但**必须同时要求规则本身长得像 JSONPath**（以 $ 开头）：
    //    否则 JSON 响应里的 `{{$.grade}}分`（插值成 "85分"）、`{{java.put(...)}}`
    //    这些**值类型**规则会被硬塞进 JSONPath 解析器 → 一律返回空。
    //    实测「免费追书」书源整个详情页字段全空，就是这一条引起的。
    if (ctx && ctx.isJSON && /^\s*\$/.test(s)) return T.JSONPATH;
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
      // 搜索词 —— 站方的 jsLib/规则里经常直接用 `key`
      // （🍅大灰狼的 explore 规则就用了 → 不给就是 "key is not defined"）
      key: '',
      // 常用快捷方式，真实 Legado 里有些是宿主注入的
      JSON: JSON, Math: Math, Date: Date, RegExp: RegExp,
      String: String, Number: Number, Array: Array, Object: Object,
      parseInt: parseInt, parseFloat: parseFloat, isNaN: isNaN,
      encodeURI: g.encodeURI, encodeURIComponent: g.encodeURIComponent,
      decodeURI: g.decodeURI, decodeURIComponent: g.decodeURIComponent,
      btoa: g.btoa, atob: g.atob, console: { log: function () { QR.java.log.apply(null, arguments); } }
    };
    for (var k in (extra || {})) scope[k] = extra[k];
    // ⚠️ source 必须**包一层**（补上 Legado 的 source.getVariable / setVariable 等 API）。
    //    裸对象上没这些方法 → 站方 JS 一调就 TypeError；
    //    而 URL 里的 JS 异常会被 analyzeJsInUrl 吞掉 → URL 变成空串
    //    → 0 请求 0 结果，界面上一点报错都看不到（聚合源最常见的"静默失效"）。
    if (scope.source && QR.wrapSource) scope.source = QR.wrapSource(scope.source);
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
    // ⚠️⚠️ jsLib 里的函数是**全局作用域**的（间接 eval 定义的），
    //    所以它们体里的自由变量（`source` / `result` / `book`）解析到的是
    //    **全局对象**，不是规则 scope。
    //    站方 login()/setArguments() 就是这么写的：
    //        const { source } = this;  let open_argument = source.getVariable();
    //        result = JSON.parse(source.getLoginInfo());
    //    → 全局对象上必须**同时**有 source 和 result，否则：
    //        "Cannot read properties of undefined (reading 'getVariable')"
    //        "result is not defined"
    if (scope && typeof g !== 'undefined') {
      try {
        if (scope.source !== undefined) g.source = scope.source;
        if (scope.result !== undefined) g.result = scope.result;
        if (scope.book !== undefined) g.book = scope.book;
      } catch (e) { /* 忽略 */ }
    }
    var names = Object.keys(scope);
    var args = names.map(function (k) { return scope[k]; });
    var key = names.join(',') + '\u0001' + code;
    var fn = evalCache[key];
    var fnExpr = null;
    if (!fn) {
      try {
        /* jshint evil:true */
        fn = new Function(names.concat(['__qrCode']).join(','),
          'return eval(__qrCode);');
        // ⚠️ 栖阅语义（AnalyseRule+JavaScript 的 cstring 原文）：
        //   语法错时**再试一次「整段当表达式」**：
        //     Function("return (" + __script + ");")
        //   ⇒ 像 `@js:{a:1}` 这种**对象字面量**规则（当脚本跑是语法错）
        //     第二次就能拿到值。轻阅原来直接失败 ❌
        fnExpr = new Function(names.concat(['__qrCode']).join(','),
          'return eval("(" + __qrCode + ")");');
      } catch (e) {
        return Promise.reject(new Error('JS 作用域非法: ' + e.message));
      }
      evalCache[key] = fn;
    }
    var fixed = fixRhinoLenient(code);

    function once() {
      try {
        return Promise.resolve(fn.apply(scope, args.concat([fixed])));
      } catch (e) {
        // 语法错 → 整段当表达式再试一次（栖阅语义）
        if (e && e.name === 'SyntaxError' && fnExpr) {
          try {
            return Promise.resolve(fnExpr.apply(scope, args.concat([fixed])));
          } catch (e2) {
            return Promise.reject(new Error('JS 执行失败: ' + (e2 && e2.message)));
          }
        }
        return Promise.reject(new Error('JS 执行失败: ' + (e && e.message)));
      }
    }

    // ⚠️⚠️ **两遍跑**：让 `java.ajax` 能同步返回正文。
    //
    // Legado 的 java.ajax 是**同步**的（`JSON.parse(java.ajax(url))` 到处都在用）；
    // 我们的原生桥是异步的（只能 postMessage，回调才异步）→
    // 直接返回 Promise → 站方 JSON.parse(Promise) 直接炸 →
    // 表现为「登录失败 / JSON Parse error: Unexpected EOF」这种**看不出原因**的错。
    //
    // 所以：
    //   ① 第一遍：java.ajax 只记录 URL（并把 toast 静音，免得报假错）
    //   ② 把记下来的 URL 抓回来（**认 URL 里的 ,{json} 后缀** —— method/headers/body）
    //   ③ 第二遍：java.ajax 命中缓存 → 同步返回正文 → 站方的 JSON.parse 就正常了
    //
    // 没用到 ajax 的规则只跑一遍，行为不变。
    var prevRecord = QR.__qrAjaxRecord;
    var prevCache = QR.__qrAjaxCache;
    var prevToast = QR.__qrSuppressToast;
    var cache = {};
    // ⚠️ 「本 op 里已经试挂过的线路」⇒ 换线兜底时跳过它们
    //    （两遍跑有 5 轮上限 ⇒ 最多覆盖 5 条不同线路，不会来回打同一条）
    //    ⚠️ 每个 op 开始时清（不能跨 op 记，否则下次 op 就不试那条线了）
    QR.__qrTriedHosts = {};

    function restore() {
      QR.__qrAjaxRecord = prevRecord;
      QR.__qrAjaxCache = prevCache;
      QR.__qrSuppressToast = prevToast;
    }

    // ⚠️⚠️ 必须是**循环**，不能只跑两遍。
    //
    // 站方的登录流程是「开浏览器 → 用户登 → 拿页面里的 token → 带着 token 交接给服务器」：
    //     let page = java.startBrowserAwait(url, '用户后台');
    //     let token = 从 page.body() 里抠;
    //     let res = java.ajax(`${base}/user_api,…token…`);   // ← 交接
    //     JSON.parse(res)
    //
    // 如果只跑两遍、或者把 ajax **并行**发出去：
    //   · 交接请求会在**用户还没登完**时就发出去 → 服务端返回空
    //     → "JSON Parse error: Unexpected EOF"
    //   · 而且交接 URL 里的 token 是从**空页面**算出来的 → URL 本身就是错的
    //
    // 所以要循环到「不再有新调用」为止，每一遍：
    //   ① 跑 JS（已缓存的调用同步返回真值，新调用被录下来）
    //   ② **按代码顺序**把录下来的调用依次抓回来（浏览器在前 → 等用户登完 → 再发交接）
    //   ③ 还有新调用 → 再跑一遍
    // ⚠️ 必须有**轮数上限** —— 有些请求 URL 每次都不一样（带随机码/时间戳），
    //    缓存永远命中不了 → 无限循环 → App 卡死。
    //    5 轮足够覆盖「开浏览器 → 拿 token → 交接 → 再开浏览器」这种链。
    var MAX_PASS = 5;
    var depth = 0;
    function loop() {
      var recorded = [];
      QR.__qrAjaxRecord = function (u, kind, title) {
        recorded.push({ url: String(u), kind: kind || 'ajax', title: String(title || '') });
        return '';
      };
      QR.__qrAjaxCache = cache;
      // ⚠️⚠️ **每一遍都静音** toast/log（装了 sink 的 op）：
      //    每一遍的 ajax 结果在**这一遍结束时**都还是假的（还没抓回来）→
      //    站方据此报的错也是假的 → 「未获取到登录凭据，登录失败」这种**假报错**就是这么来的。
      //    真实例子（🍅番茄登录 fq_login）：
      //        第 1 遍 弹浏览器 → 用户登录 → sessionid 合并回快照
      //        第 2 遍 ajax 的 URL 变了（带上了真 cookie）→ 又是假的 → 站方报「登录失败」❌
      //        第 3 遍 ajax 命中缓存 → 真结果 → 「欢迎 XXX 登录成功」✅
      //    现在统一**最后一遍才交消息**（原生 toast/log + sink）→ 用户只看到真结果。
      // ⚠️ 以前只静音第一遍 → 中间遍的假报错会**先弹出来**误导用户。
      //
      // ⚠️ 消息**每一遍都先暂存**，跑完这一遍再决定要不要交出去：
      //   · 这一遍录到了 ajax → 这一遍是假的 → 消息丢掉
      //   · 这一遍没录到 ajax → 这一遍是真的 → 消息交出去
      //
      //   以前是「第一遍一律静音」→ 副作用是**没用到 ajax 的真结果也被吃掉**：
      //   典型：站方 login() 发现邮箱密码为空 → toast「请先填写邮箱和密码」
      //   → 那一遍没有 ajax → 不会有第二遍 → 那句话永远不出现。
      //   （实测踩到：login op 什么原文都收不到，站方报啥用户都看不到）
      //
      // ⚠️ 没装 sink 的 op 行为完全不变（还是只静音第一遍）。
      var holding = null;
      var holdingAll = !!(QR.__qrMsgSink && QR.__qrHoldBegin);
      QR.__qrSuppressToast = holdingAll ? true : (depth === 0);
      if (holdingAll) { holding = QR.__qrHoldBegin(); }
      depth++;
      return once().then(function (r) {
        var real = (recorded.length === 0);
        if (holding) QR.__qrHoldEnd(real);
        if (!recorded.length) {
          try { QR.java.log('[两遍跑] 第' + depth + ' 遍：没有 ajax 调用 ⇒ 这一遍的结果是真的'); } catch (e) {}
          restore(); return r;
        }
        if (depth >= MAX_PASS) {
          // ⚠️⚠️ **轮数用尽 = 这一遍拿到的是空结果**（2026-10-21 真机「时好时坏」）：
          //   站方 `JSON.parse(java.ajax(url))` 会炸 → 整条规则静默失效。
          //   ⇒ 必须**喊出来**，否则日志里什么都看不出来。
          try {
            QR.java.log('[两遍跑] ⚠️ 轮数用尽（上限 ' + MAX_PASS + '）仍有 ' + recorded.length
              + ' 个调用没命中缓存 ⇒ **这一遍是空结果，详情/目录大概率失败**');
          } catch (e) {}
          restore(); return r;
        }
        try {
          QR.java.log('[两遍跑] 第' + depth + ' 遍录到 ' + recorded.length
            + ' 个调用 → 抓回来，下一遍重试（上限 ' + MAX_PASS + ' 遍）');
        } catch (e) {}
        return fetchRecorded(recorded, cache).then(function () { return loop(); });
      });
    }
    return loop().catch(function (e) {
      restore();
      throw e;
    });
  }

  /**
   * 把录下来的 URL 抓回来。
   * ⚠️ 必须用 analyzeUrl 拆 `,{json}` 后缀 ——
   *    否则 POST 的 method/headers/body 全丢，URL 里还粘着后缀 → 服务端返回空。
   */
  /**
   * 把录下来的调用**按代码顺序**依次抓回来。
   *
   * ⚠️ 必须**顺序**、不能并行：
   *    浏览器那一步要等用户登完，后面的「交接」请求才有意义。
   *    并行发 → 交接先到 → 服务端看到未登录 → 返回空 → "Unexpected EOF"。
   */
  function fetchRecorded(list, cache) {
    var out = cache || {};
    var chain = Promise.resolve();
    // ⚠️⚠️⚠️ **互斥候选归组：同 path+query+method、只有 host 不同 ⇒ 是站方 catch 循环的候选**
    //
    //   站方大灰狼的正文规则长这样：
    //       try { data = java.ajax(base_url + '/content' + op); JSON.parse(data); }
    //       catch { for (i in host) { data = java.ajax(host[i] + '/content' + op);
    //                                 JSON.parse(data); setArguments('server', host[i]); break; } }
    //   ⇒ 这 8 条线路是**互斥候选**（只会用一条），不是顺序链。
    //
    //   但「两遍跑」的第 1 遍里，所有 ajax 都返回 ''（录制）⇒ JSON.parse 全抛
    //   ⇒ **catch 循环把 8 条全录了下来** ⇒ 宿主以前把 8 条**全抓了**。
    //
    //   💥 后果（2026-10-21 真机）：一次正文操作向站方发了 **8 条**同 item_id 的请求
    //      ⇒ **番茄免登录访问次数上限(3 次)被打爆**
    //      ⇒ 缓存里躺着的全是「您今日免登录访问次数已达上限(3次)！」
    //      ⇒ 站方第 2 遍命中它 → JSON.parse 成功（合法 JSON！）→ **不换线**
    //      ⇒ content = "" ⇒ **正文是空的** ⭐
    //
    //   ⇒ 修：**同组只抓第一个**，剩下的留给站方自己换线
    //      （站方第 2 遍如果发现这条不行，catch 循环会录下一条 → 第 3 遍再抓）
    //      ⇒ 站方一次操作最多 1~2 次请求，限流打不爆 ✅
    //      ⇒ 而且站方那个「线路故障，已自动切换到」机制**真正生效了**
    //         （以前是被宿主一次全抓破坏了）
    // ⚠️⚠️ **每遍开始时重置「本遍候选计数」**
    //   （跨遍累加会误判：第 1 遍只录了 1 个 URL，第 2 遍累加成 2
    //    ⇒ 被当成「同组还有备选」⇒ 单候选失败也写空串 ⇒ 不再重试 ❗）
    var stAll = (out.__grp && out.__grp.st) ? out.__grp.st : null;
    if (stAll) {
      for (var gk in stAll) { if (stAll[gk]) stAll[gk].total = 0; }
    }
    list.forEach(function (rec) {
      var u = rec.url;
      chain = chain.then(function () {
        // 浏览器类：弹内嵌浏览器等用户关掉 → 拿页面 HTML
        if (rec.kind === 'browser') {
          return QR.java.openBrowser(u, rec.title)
            .then(function (page) {
              out[u] = page;
              // ⚠️ 浏览器里刚登录出来的 cookie **必须合并回快照** ——
              //    快照是 op 开头拍的，里面没有新 cookie →
              //    站方 cookie.getKey() 拿不到 sessionid。
              try {
                var ck = page && page.cookie;
                if (ck && QR.__qrMergeCookie) {
                  var host = '';
                  try { host = new URL(u).host; } catch (e) { host = String(u); }
                  QR.__qrMergeCookie(host, ck);
                }
              } catch (e) { /* 忽略 */ }
            })
            .catch(function () {
              // ⚠️⚠️ 同上：浏览器打不开**不写缓存** ⇒ 下一遍会重试
              //   （原来写空串 ⇒ 下一遍命中空页面 ⇒ 站方从空页面抠 token
              //     ⇒ 交接 URL 本身就是错的 ⇒ 必然失败）
              delete out[u];
            });
        }
        var t = null;
        try { t = (QR.analyzeUrl) ? QR.analyzeUrl(u, { baseUrl: '' }) : null; } catch (e) { t = null; }
        var url = (t && t.url) ? t.url : u;
        var method = (t && t.method) || 'GET';
        var headers = (t && t.headers) || {};
        var body = (t && t.body) || '';
        // ⚠️ 归组 key：**不含 host**（host 不同 = 不同线路 = 互斥候选）
        //    ⚠️⚠️ **但必须算上 headers！**（2026-10-21 真机门禁 fq-login 变红抓出来的）
        //      登录链是「browser 拿 sessionid → 交接 ajax 带 sessionid」，
        //      两次 ajax 的 path/query/method **完全一样**，只有 **cookie 不同**
        //      ⇒ 只按 path+query+method 归组 ⇒ 第二遍被判成「同一个候选、已试过」
        //      ⇒ 永远不重抓 ⇒ `sessionid=undefined` ⇒ **番茄登录直接废掉** ❗
        //      ⇒ 所以归组条件必须是：**path + query + method + headers 全一样，只有 host 不同**
        //      ⇒ 那才是真正的「同一个请求换一条线路」
        var gkey = '';
        try {
          var pu = new URL(url);
          var hk = [];
          try {
            var hobj = headers || {};
            for (var hn in hobj) {
              if (Object.prototype.hasOwnProperty.call(hobj, hn)) hk.push(hn + '=' + hobj[hn]);
            }
            hk.sort();
          } catch (he) { hk = []; }
          gkey = pu.pathname + '|' + pu.search + '|' + method + '|' + hk.join('&');
        } catch (e) {
          gkey = 'raw|' + u;
        }
        // ⭐ 组内状态：**哪些候选已经试过了** + **组里一共有几个候选**
        //    （跨遍保留 ⇒ 放在 cache 上，用不可枚举属性，`Object.keys` 不会把它算进缓存上限）
        var st = (out.__grp && out.__grp.st) ? out.__grp.st : null;
        if (!st) {
          st = {};
          try {
            Object.defineProperty(out, '__grp', {
              value: { st: st }, enumerable: false, writable: true, configurable: true
            });
          } catch (e) { out.__grp = { st: st }; }
        }
        var g = st[gkey];
        if (!g) { g = { tried: [], done: false, total: 0 }; st[gkey] = g; }
        g.total++;
        // ⚠️⚠️ **组内已有一条成功 ⇒ 后面的候选不用抓了**（站方只会用一条）
        if (g.done) {
          try {
            QR.java.log('[两遍跑] 同组已有可用线路 ⇒ 跳过候选：' + String(u).slice(0, 120));
          } catch (e3) {}
          return;
        }
        // ⚠️⚠️ **组内已经试过这个候选 ⇒ 不重复抓**
        //    （否则站方每遍都重录它 → 死循环抓同一条，永远换不到线）
        //
        // ⚠️⚠️ **但单候选（g.total === 1）必须允许重试！**
        //   没有备选线路时，失败只能重试同一个 URL ——
        //   写空串会让「命中缓存就不录了」⇒ 这一遍被当成「真的」⇒ **一次抖动就死定**
        //   （就是 ajax-retry.test.js 保护的那个老坑）
        if (g.total > 1 && g.tried.indexOf(u) >= 0) {
          try {
            QR.java.log('[两遍跑] 同组候选已试过 ⇒ 不重复抓：' + String(u).slice(0, 120));
          } catch (e3) {}
          return;
        }
        g.tried.push(u);
        return QR.java.rawRequest(url, method, headers, body)
          .then(function (resp) {
            var bodyText = (resp && resp._body) || '';
            var code = resp && resp._code;
            // ⚠️⚠️⚠️ **临时性故障不写缓存**（2026-10-21 真机「详情页时好时坏」的根因）：
            //   以前这里是 `out[u] = (resp && resp._body) || ''` —— **失败也写缓存**。
            //   ⇒ 网络抖一下（超时 / 502）⇒ 缓存里躺了个**空串**
            //   ⇒ 第 2 遍 `java.ajax` **命中了这个空串** ⇒ 返回 ''
            //   ⇒ 而且「命中缓存就不录了」⇒ `recorded.length === 0`
            //   ⇒ 被判定成「这一遍是真的」⇒ **直接返回空串，不再重试** ❗
            //   ⇒ 站方 `JSON.parse('')` 炸 ⇒ 详情页加载失败
            //   ⇒ **一次网络抖动 = 整条详情规则死定** ⭐ 这就是「时好时坏」
            //
            //   ⇒ 现在：**异常状态码不写缓存** ⇒ 下一遍会重新录、重新请求
            //      ⇒ 两遍跑天然带上了重试能力（MAX_PASS 5 轮兜底）✅
            //   ⇒ 而「200 + 正常响应」照常写缓存（服务器明确答了，重试也没用）
            var bad = !!(code && (code < 200 || code >= 400));
            if (bad) {
              delete out[u];
              // ⭐⭐⭐ **同组还有备选线路 ⇒ 把空串写进缓存**（2026-10-21 真机「正文是空的」）：
              //   站方的换线机制长这样：
              //       try { data = java.ajax(base + '/content' + op); JSON.parse(data); }
              //       catch { for (i in host) { data = java.ajax(host[i] + '/content' + op);
              //                                 JSON.parse(data); setArguments('server', host[i]); break; } }
              //   ⇒ 它**只在 JSON.parse 抛异常时才换线**。
              //   ⇒ 所以失败必须让站方拿到一个「JSON.parse 会抛」的值 ⇒ **空串**正好。
              //   ⇒ 下一遍：base 那条命中空串 ⇒ JSON.parse 抛 ⇒ **站方自己换到下一条线路** ✅
              //   ⇒ 而且换到的那条在缓存里有值 ⇒ 一次成功。
              //   ⚠️ 单候选（没有备选）时**不能**写空串 ——
              //     否则「命中缓存就不录了」⇒ 这一遍被当成「真的」⇒ **一次抖动就死定**
              //     （就是上面注释里记的那个「时好时坏」老坑）⇒ 那种情况保持不写、可重试 ✅
              if (g.total > 1) {
                out[u] = '';
                try {
                  QR.java.log('[ajax异常状态] ' + String(u).slice(0, 160) + '  状态=' + code
                    + '  ⇒ 同组还有 ' + (g.total - 1) + ' 条备选线路 ⇒ 写空串让站方自己换线');
                } catch (e3) {}
              }
            } else {
              out[u] = bodyText;
              // ⭐ 这组有可用线路了 ⇒ 同组后面的候选不用再抓
              if (bodyText) g.done = true;
            }
            // ⚠️⚠️ **失败/异常必须喊出来**（2026-10-21）：
            //   以前这里是 `.catch(function(){ out[u] = ''; })` —— 失败被**静默吞掉**，
            //   站方 JS 拿到空串 → 报出 `abstract.split` / `Unable to parse JSON string`
            //   这种**天书错**，谁也看不出是「服务器挂了」。
            //   ⇒ 现在把 URL / 状态 / 响应开头都打进引擎日志，一眼定位。
            if (resp && resp._body === '') {
              QR.java.log('[ajax空响应] ' + String(u).slice(0, 160)
                + '  状态=' + code);
            } else if (bad) {
              QR.java.log('[ajax异常状态] ' + String(u).slice(0, 160)
                + '  状态=' + code + '  响应开头='
                + String(bodyText).slice(0, 200)
                + '  ⇒ 不写缓存，下一遍重试');
            }
            // 缓存别无限长（URL 带随机码的请求会一直加新键）
            var keys = Object.keys(out);
            if (keys.length > 40) {
              keys.slice(0, keys.length - 40).forEach(function (k) { delete out[k]; });
            }
          })
          .catch(function (e) {
            // ⚠️⚠️ **请求异常（超时 / 网络错）同样不写缓存** ⇒ 下一遍能重试
            //    （原来是 `out[u] = ''` ⇒ 空串进缓存 ⇒ 再也不重试 ⇒ 一次抖动就死）
            delete out[u];
            // ⭐ 同组还有备选线路 ⇒ 写空串，让站方下一遍 JSON.parse 抛 ⇒ 自己换线
            if (g && g.total > 1) {
              out[u] = '';
              try {
                QR.java.log('[ajax失败] ' + String(u).slice(0, 160)
                  + '  ⇒ 同组还有 ' + (g.total - 1) + ' 条备选 ⇒ 写空串让站方自己换线');
              } catch (e4) {}
            }
            try {
              QR.__qrLastAjax = {
                url: String(u || ''), code: 0, body: '',
                error: String(e && e.message || e)
              };
            } catch (e2) { /* 忽略 */ }
            QR.java.log('[ajax失败] ' + String(u).slice(0, 160) + '  '
              + String(e && e.message || e)
              + '  ⇒ 不写缓存，下一遍重试');
          });
      });
    });
    return chain.then(function () { return out; });
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
  /**
   * 列表规则（书单/目录）专用入口：复合规则 `<js>…</js>$.data` → **返回 JSON 对象数组**
   *
   * ⚠️ 为什么不能直接用 `getElements`：
   *    它最后会 `flatten()` → 把 JSON **对象** `JSON.stringify` 成字符串 ❌
   *    → 章节/书单的字段（title/url/name）全毁 → **列表空**。
   *    （🍅大灰狼的 ruleToc.chapterList 就是这种复合规则：
   *      `<js>解 data: URL → ajax 拿 catalog JSON → data;</js>$.data`）
   *
   * ⚠️ 也不能用 `evalJsonPath`：它会把命中的**数组**当一个元素（Legado 语义要摊平）
   *    → 整本目录被当成一条 ❌
   */
  function getJsonList(rule, base, ctx) {
    ctx = ctx || {};
    try {
      var scope = makeScope(jsScope(base, base, ctx, rule));
      var r = interpolate(applyGetPut(String(rule == null ? '' : rule), scope), scope);
      var kind = classify(r, ctx);
      if (kind !== T.JS) return Promise.resolve([]);
      var body = stripModePrefix(r, kind);
      var jt = splitJsWithTail(body);
      if (!jt.sel) return Promise.resolve([]);
      return runJs(jt.code, makeScope(jsScope(base, base, ctx, body)))
        .then(function (res) { return selectFromJsResult(res, jt.sel, ctx, base); })
        .catch(function (e) {
          QR.java.log('[列表规则出错]', String(body).slice(0, 100), e && e.message, lastAjaxNote(), baseNote(base));
          return [];
        });
    } catch (e) {
      return Promise.resolve([]);
    }
  }

  /**
   * 诊断版 `getJsonList`：**把 JS 报错也带出来**
   *
   * 为什么要有它（2026-10-21）：
   *   目录诊断（engine.js 的 explainToc）以前**只按 HTML/CSS 路径**数节点 →
   *   对 🍅大灰狼这种**复合规则**（`<js>…</js>$.data`）**必然 0 命中** →
   *   结论恒为「chapterList 一个都没命中 —— 目录规则对不上」→ **纯误导**，
   *   白白让人以为规则写错了、其实规则是对的。
   *
   *   这里按**真实路径**（toc op 的做法：JS → 再走尾部选择器）跑一遍，
   *   把真实条数 + JS 报错摆出来，诊断才说真话。
   */
  function getJsonListDiag(rule, base, ctx) {
    ctx = ctx || {};
    try {
      var scope = makeScope(jsScope(base, base, ctx, rule));
      var r = interpolate(applyGetPut(String(rule == null ? '' : rule), scope), scope);
      var kind = classify(r, ctx);
      if (kind !== T.JS) return Promise.resolve({ items: [], error: '', kind: kind });
      var body = stripModePrefix(r, kind);
      var jt = splitJsWithTail(body);
      if (!jt.sel) return Promise.resolve({ items: [], error: '复合规则没有尾部选择器', kind: kind });
      return runJs(jt.code, makeScope(jsScope(base, base, ctx, body)))
        .then(function (res) {
          var items = selectFromJsResult(res, jt.sel, ctx, base);
          return { items: Array.isArray(items) ? items : (items ? [items] : []),
                   error: '', kind: kind };
        })
        .catch(function (e) {
          return { items: [], error: String(e && e.message || e), kind: kind };
        });
    } catch (e) {
      return Promise.resolve({ items: [], error: String(e && e.message || e), kind: 'error' });
    }
  }

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

    // ⚠️ 切掉 ##尾部## 之后必须**再判一次字面量**。
    //    上面第 ~346 行那次判定是针对整条规则的，而带尾部的规则里
    //    `##(^|X)##$1` 含 `|` `(` `[`，过不了那个判定；等切完尾部，
    //    body 就只剩插值出来的**值**（比如一整段简介），却还会被
    //    classify 判成 SELECTOR 去查选择器 → 直接返回空。
    //    表现：`{{$.introduction}}##(^|[。！？]+…)##$1<br>` 得到空简介。
    // 「含 {{ 的规则是模板产出一个值」这条约定要贯彻到底：
    // 只要插值真的发生过（rule !== rawRule），插值结果就是**值**，
    // 不能再当选择器去查 —— 否则带换行、带 `>`（<br>）、带 `.`（105.3万字）
    // 的简介/分类模板都会落到 CSS 解析路径上返回空。
    var headIsValue = (rule !== rawRule && kind === T.SELECTOR && !!body);

    var p;
    if (headIsValue) {
      p = Promise.resolve([body]);
    } else switch (kind) {
      case T.JS: {
        var jt = splitJsWithTail(body);
        p = runJs(jt.code, makeScope(jsScope(base, base, ctx, body)))
          .then(function (r) {
            // 复合规则 `<js>代码</js>选择器`：JS 算出个值，再从里面取字段
            return jt.sel ? selectFromJsResult(r, jt.sel, ctx, base) : r;
          });
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
      QR.java.log('[规则出错]', String(body).slice(0, 120), e && e.message, lastAjaxNote(), baseNote(base));
      return [];
    });
  }

  /**
   * 规则报错时补一句「最后一次响应是什么」
   *
   * ⚠️ 没有这句，日志只有 `abstract.split` 这种天书，
   *    根本看不出服务器到底返回了啥（502？「会员已过期」？空？）。
   */
  function lastAjaxNote() {
    try {
      var a = QR.__qrLastAjax;
      if (!a) return '';
      var s = '[最后响应] ' + String(a.url || '').slice(0, 160);
      if (a.error) s += '  错误=' + a.error;
      else s += '  状态=' + a.code;
      if (a.body) s += '  开头=' + String(a.body).slice(0, 200);
      return s;
    } catch (e) { return ''; }
  }

  /**
   * 规则报错时补一句「喂给规则的原文开头」
   *
   * ⚠️ 真机 2026-10-21：`init` 规则挂在 `JSON.parse(java.hexDecodeToString(result))`
   *    上，抛的是「Unable to parse JSON string」→ 不知道 result 到底是什么。
   *    把原文头 200 字打出来，一眼看出是「空」还是「被截断」还是「不是 base64」。
   */
  function baseNote(base) {
    try {
      var t = baseToText(base);
      if (!t) return '[基准] (空)';
      return '[基准] ' + String(t).slice(0, 200);
    } catch (e) { return ''; }
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

  /**
   * 规则里用的 java —— 在原生 java 之上给 get/getString 加一层回退。
   *
   * 书源里极常见 `{{java.getString('$.bookStatue')=='03'?'完结':'连载'}}`
   * 这种写法：把 `$.字段` 当**取值**用。
   * 而原生 `java.get(k)` 只查 @put/@get 的变量表，'$.bookStatue' 不是变量名 → 恒空
   * → 三元永远走另一支（完结的书会显示"连载"）。
   *
   * 所以：变量表里有就用变量表；没有且参数长得像 `$` 路径，就回退到**当前规则结果**上取。
   */
  function ruleJava(base, result) {
    if (!base) return base;
    var j = Object.create(base);
    function resolveArg(k) {
      var v = typeof base.get === 'function' ? base.get(k) : '';
      if (v != null && String(v) !== '') return v;
      var s = String(k == null ? '' : k).trim();
      if (s.charAt(0) !== '$' || result == null) return v == null ? '' : v;
      try { return evalJsonPath(result, s); } catch (e) { /* 继续手写路径 */ }
      var m = /^\$\.([\w.]+)$/.exec(s);
      if (m) {
        var cur = result;
        var parts = m[1].split('.');
        for (var i = 0; i < parts.length; i++) {
          if (cur == null) return '';
          cur = cur[parts[i]];
        }
        return cur == null ? '' : cur;
      }
      return v == null ? '' : v;
    }
    j.get = resolveArg;
    j.getString = function (k) { var r = resolveArg(k); return r == null ? '' : String(r); };
    j.getInt = function (k) { return parseInt(resolveArg(k), 10) || 0; };
    return j;
  }

  function jsScope(result, base, ctx, code) {
    return {
      // 多值规则的 result 必须是数组，书源里会写 result.length / result[0] / result.map
      result: Array.isArray(result) ? result
             : (result && result.nodeType ? dom.textOf(result) : result),
      $: asJsonish(result),
      resultNode: result,
      // 覆盖 makeScope 的默认 java：让 get/getString 能回退到「当前结果」
      // （书源里 `java.getString('$.字段')` 当取值用，非常常见）
      java: ruleJava(g.java, result),
      // 站方 @js: 里经常直接 document.querySelectorAll，
      // 得把它指向当前规则的基准文档，而不是引擎自己的空页面
      document: ownerDocOf(base),
      baseUrl: ctx.baseUrl || '',
      // ⚠️ 必须包一层：站方 JS 直接调 source.getVariable()，
      //    裸对象上没这方法 → TypeError → 整条规则静默失效。
      source: QR.wrapSource ? QR.wrapSource(ctx.source) : ctx.source,
      // ⚠️ book 也要包一层：站方会调 book.getVariable('custom')
      book: (ctx.book && QR.wrapBook) ? QR.wrapBook(ctx.book) : ctx.book,
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

  /**
   * 复合规则：`<js>代码</js>尾部选择器`
   *
   * Legado 允许 JS 块后面再跟一个选择器，意思是「JS 算出个值，再从里面取字段」。
   * 聚合源（🍅大灰狼）大量用这个形态：
   *     ruleToc.chapterList = "<js>…JSON.parse(…)…</js>$.data"
   *     ruleContent.content  = "<js>…content…</js>$.content"
   *
   * ⚠️ 以前只认「整条规则**就是** <js>…</js>」这一种形态，
   *    复合形态会把 `<js>` 原样丢进 eval → "Unexpected token '<'"
   *    → 这条规则**静默失效**（界面上一点报错都看不到）。
   *
   * `@js:` 是**贪婪到末尾**的（没有尾部），所以只对 `<js>…</js>` 做拆分。
   */
  function splitJsWithTail(s) {
    var t = String(s == null ? '' : s).trim();
    var m = /^<[jJ][sS]>([\s\S]*?)<\/[jJ][sS]>([\s\S]*)$/.exec(t);
    if (m) return { code: m[1], sel: String(m[2] || '').trim() };
    return { code: stripJsWrapper(t), sel: '' };
  }

  /** 把 JS 的结果当成「JSON / 页面」，再用选择器取字段 */
  function selectFromJsResult(res, sel, ctx, base) {
    var s = String(sel || '').trim();
    if (!s) return res;
    var baseUrl = ctx.baseUrl || '';
    // JSONPath（$.xxx / $[0]）—— 聚合源最常见的尾部形态
    if (s.charAt(0) === '$') {
      // ⚠️ 用 evalJsonPathList（不 stringify 对象、摊平一层数组）
      //    复合规则 `<js>…</js>$.data` 的尾巴走这里 —— 用 evalJsonPath 会把
      //    章节对象 stringify 成字符串 → 章节全毁 ❌
      var jp = evalJsonPathList(res, s);
      return jp && jp.length ? jp : [];
    }
    // 其余按 CSS/XPath：把结果当 HTML 解析
    try {
      var node = (res && res.nodeType) ? res : dom.parseHTML(String(res == null ? '' : res), baseUrl);
      var r = dom.resolve(node, s);
      return r.nodes.map(function (n) { return dom.valueOf(n, r.suffix, baseUrl); })
                    .filter(function (x) { return x !== ''; });
    } catch (e) {
      return [];
    }
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
    // 入参既可能是 **JSON 字符串**（响应正文），也可能是**已解析的对象**
    // （`{{$.tags..name}}` 里 scope.result 就是对象）。
    var data = text;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { return []; }
    } else if (data == null || typeof data !== 'object') {
      return [];
    }
    var r = QR.jsonpath.select(data, rule);
    return flatten(r, '');
  }

  /**
   * JSONPath 取**列表**（Legado 语义）
   *
   * ⚠️ 不能用 `evalJsonPath`：
   *   ① 它 flatten → 命中数组时返回 `[那个数组]`（数组本身，不是元素）
   *      → 整页书/章节被当成**一条** → 列表只剩 1 条 ❌
   *   ② flatten 对 JSON **对象**会 `JSON.stringify` 成字符串
   *      → 章节/书单的字段（title/url）全毁 ❌
   *
   * 这里：摊平**一层**数组，**对象原样保留** ✅
   */
  function evalJsonPathList(text, rule) {
    var data = text;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { return []; }
    } else if (data == null || typeof data !== 'object') {
      return [];
    }
    var r;
    try { r = QR.jsonpath.select(data, rule); } catch (e) { return []; }
    if (!Array.isArray(r)) return [];
    var out = [];
    for (var i = 0; i < r.length; i++) {
      var v = r[i];
      if (Array.isArray(v)) {
        for (var j = 0; j < v.length; j++) out.push(v[j]);   // 摊平一层
      } else {
        out.push(v);                                          // 对象原样保留
      }
    }
    return out;
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
    // Legado 的 `{{…}}` 里，`$.xxx` 走 **JSONPath**，其余走 JS。
    // 但我们这里只做裸 eval —— 于是 `$.tags..name` 这种**递归下降**
    // 在 JS 里是语法错误（`$..name` 不是合法 JS），求值失败被吞成空串。
    // `..`、`[*]`、`[?(…)]` 这些 JSONPath 特征词一律走 JSONPath 引擎。
    var e = String(expr == null ? '' : expr);
    if (/^\s*\$/.test(e) && /(\.\.|\[\s*\*|\[\s*\?\s*\(|\[\s*\d+\s*:\s*\d*\s*\])/.test(e)) {
      try {
        var jv = evalJsonPath(scope && scope.result, e.trim());
        return jv;
      } catch (err) { /* 落到下面的 eval */ }
    }
    try {
      var names = Object.keys(scope);
      var fn = new Function(names.concat(['__qrE']).join(','), 'return eval(__qrE);');
      return fn.apply(scope, names.map(function (k) { return scope[k]; }).concat([expr]));
    } catch (e2) {
      return '';
    }
  }

  /** {{…}} 里的 `##正则##替换`：按顶层 ## 切成三段（正则里可能含 ## 之外的 ##） */
  function splitRegexTailTop(expr) {
    var s = String(expr == null ? '' : expr);
    var i = s.indexOf('##');
    if (i <= 0) return null;
    var head = s.slice(0, i);
    // 正则里常见 {2,3} 这种量词；只在 ## 边界切，别被花括号骗了
    var j = s.indexOf('##', i + 2);
    if (j < 0) return { head: head, pattern: s.slice(i + 2), replace: null };
    return {
      head: head,
      pattern: s.slice(i + 2, j),
      replace: s.slice(j + 2)
    };
  }

  /** 对单个字符串做 `正则 → 替换`（替换串支持 $1 $2 反向引用） */
  function applyInlineRegex(str, pattern, replace) {
    if (!pattern) return str;
    var re;
    try { re = new RegExp(pattern, 'g'); } catch (e) { return str; }
    var rep = replace == null ? '' : String(replace);
    return String(str).replace(re, function () {
      return replaceAll(arguments[0], rep, arguments);
    });
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
        // Legado 允许 `{{值##正则##替换}}` —— 先求值 `值`，再对结果做正则替换。
        // 不拆的话整段 `$.tags..name##\s##，` 会原样进 eval，必炸。
        var seg = splitRegexTailTop(expr);
        var v;
        if (seg) {
          v = evalExpr(seg.head, scope);
          var sv = (v === null || v === undefined) ? '' : String(v);
          v = applyInlineRegex(sv, seg.pattern, seg.replace);
        } else {
          v = evalExpr(expr, scope);
        }
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

  /**
   * 这条规则是不是**一个不可分割的块**（不能按 `\n` 切）。
   *
   * ⚠️ 踩过的坑（🍅大灰狼聚合源）：
   *    ruleToc.chapterList = "<js>\n  …一堆代码…\n</js>$.data"
   *    —— `<js>` 块里**有换行**，而引擎原来按 `\n` 把规则切成多行兜底链，
   *    第一行就剩 "<js>" → eval("<js>") → "Unexpected token '<'"
   *    → 这条规则**静默失效**（界面上一点报错都看不到，只表现为"目录是空的"）。
   *
   * 跟「含 `{{` 的规则不按行切」是同一个道理：
   *    块里的 \n 是**代码/输出里的换行**，不是规则分隔符。
   */
  function isBlockRule(raw) {
    var t = String(raw == null ? '' : raw).trim();
    if (!t) return false;
    if (t.indexOf('{{') >= 0) return true;
    if (/^@js:/i.test(t)) return true;
    if (/^<[jJ][sS]>/.test(t)) {
      var close = t.toLowerCase().indexOf('</js>');
      if (close < 0) return true;                 // 没闭合的（被截断的）也别切
      var after = t.slice(close + 5);
      if (!after.trim()) return true;             // 整块就是这条规则
      if (after.indexOf('\n') < 0) return true;   // 同一行的尾巴 → 复合规则 <js>…</js>$.data
      return false;                               // 后面还有别的规则行
    }
    return false;
  }

  function getElements(rule, base, ctx) {
    // ⚠️ 含 `{{` 的规则**不按行切**：它是「一个模板产出一个值」，
    //    里面的 \n 是**输出里的换行**，不是规则分隔符。
    //    按行切的话，`{{$.status}}\n{{$.tag}}\n{{$.grade}}分` 这种
    //    多行 kind / intro 模板只会返回第一行的值，
    //    `<br>\n🏅 评分：…\n🎗 标签：…` 这种简介模板甚至因为第一行
    //    是 `<br>`（被当 CSS 标签名）直接查空。
    //    不含 `{{` 的规则才按 `\n` 当兜底链逐行试（老行为）。
    //    ⚠️ 同理 `<js>…</js>` 块也不能按行切（见 isBlockRule）。
    var rawText = String(rule == null ? '' : rule);
    var lines = isBlockRule(rawText) ? [rawText] : toLines(rule);
    if (!lines.length) return Promise.resolve({ values: [], rule: '' });

    function tryOr(line) {
      // ⚠️ `<js>…</js>` 整块**不能按 || / && 拆**：
      //    站方代码里本来就有 `result.tab || '小说'` 这种 **JS 运算符**，
      //    拆开等于把代码腰斩 → 碎片被当成规则 → eval("<js>…") →
      //    "Unexpected token '<'" → 这条规则静默失效。
      if (isBlockRule(line)) return tryAnd(line);
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
      if (isBlockRule(line)) {
        return evalOne(line, base, ctx).then(function (values) {
          return { values: values, rule: line };
        });
      }
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
    evalJsonPathList: evalJsonPathList,
    getJsonList: getJsonList,
    getJsonListDiag: getJsonListDiag,
    splitTop: splitTop,
    toLines: toLines,
    getElements: getElements,
    getValue: getValue,
    resolveNodes: resolveNodes,
    evalOne: evalOne,
    runJs: runJs,
    makeScope: makeScope,
    // ⚠️ 2026-10-22：**导出 jsScope**（引擎内部的标准 JS 作用域构造器）
    //   「bookList 是 @js:」这条通路要用它 —— 自己造 scope 会漏掉：
    //     · document（站方 JS 里的 querySelectorAll 要指向**当前页**的文档）
    //     · source / book（必须是**包过 API 的对象**，否则站方一调就 TypeError）
    //     · result / $ / java（java 要能回退到「当前结果」）
    //   ⇒ 少一样就表现为「站方 JS 抛 undefined.slice」这类看不懂的错 ⭐
    jsScope: jsScope,
    stripJsWrapper: stripJsWrapper,
    parseRegexRule: parseRegexRule,
    stringMatchAll: stringMatchAll,
    flatten: flatten
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
