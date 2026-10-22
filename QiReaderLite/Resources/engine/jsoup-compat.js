/* ============================================================
 * jsoup-compat.js —— Legado/Jsoup 选择器 → WebKit DOM 选择器
 *
 * 栖阅是把 org.jsoup 桥回 Swift/Kanna 做的；这里换条路：
 * 直接用 WKWebView 自带的 DOM（DOMParser 解析 HTML），
 * 好处是零原生依赖，Swift 侧一行 HTML 解析代码都不用写。
 *
 * 要补的是 Jsoup 有、DOM 没有的那部分：
 *   :contains(t)  :containsOwn(t)  :matches(re)  :matchesOwn(re)
 *   [attr^=v] [attr$=v] [attr*=v] [attr~=v] [attr!=v]
 *   Legado 的 class.x / tag.x / id.x / text.x 前缀简写 + @ 链
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};

  /* ---------------------------------------------------------
   * DOM 解析
   * ------------------------------------------------------- */

  // DOMParser 对 <script>/<noscript> 里的内容有时会当文本，统一挖空
  function parseHTML(html, baseUrl) {
    var doc = new DOMParser().parseFromString(
      '<!doctype html><html><head><base href="' + (baseUrl || '') + '"></head><body>' +
      String(html == null ? '' : html) + '</body></html>', 'text/html');
    if (baseUrl) {
      // <base> 标签在部分 WebKit 版本里对 DOM 查询不生效，手动兜底
      doc.__baseUrl = baseUrl;
    }
    return doc;
  }

  function baseOf(node) {
    var b = node.ownerDocument && node.ownerDocument.__baseUrl;
    if (b) return b;
    var el = node.ownerDocument && node.ownerDocument.querySelector && node.ownerDocument.querySelector('base');
    if (el && el.href) return el.href;
    return '';
  }

  /* ---------------------------------------------------------
   * 绝对地址补全（书源里大量写相对 href/src）
   * ------------------------------------------------------- */

  function absolutize(url, baseUrl) {
    var u = String(url == null ? '' : url).trim();
    if (!u) return '';
    if (/^(https?|ftp|qireaderlite|data|blob|javascript|mailto):/i.test(u)) return protect(u);
    if (u.indexOf('//') === 0) return protect('https:' + u);
    if (!baseUrl) return u;
    try { return protect(new URL(u, baseUrl).href); } catch (e) { return u; }
  }

  /**
   * new URL() 会把 {{page}} 里的 { } 编码成 %7B%7B，后面就再也展开不了页码。
   * 先把占位符摘出来，URL 拼好再放回去。
   */
  function protect(u) {
    var holes = [];
    var s = String(u).replace(/\{\{[^{}]*\}\}/g, function (mm) {
      holes.push(mm); return '\u0001' + (holes.length - 1) + '\u0001';
    });
    s = s.replace(/%7B%7B/g, '{{').replace(/%7D%7D/g, '}}');
    s = s.replace(/\u0001(\d+)\u0001/g, function (mm, i) { return holes[Number(i)]; });
    return s;
  }

  /* ---------------------------------------------------------
   * Jsoup 伪类 / 运算符
   * ------------------------------------------------------- */

  // 把 :contains(...) :matches(...) 之类从选择器里摘出来，变成后置过滤条件
  var PSEUDO_RE = /:(containsOwn(?:Text)?|contains|matchesOwn|matches|hasText|textEquals)\(([^()]*(?:\([^()]*\)[^()]*)*)\)/gi;

  function splitPseudos(selector) {
    var pseudos = [];
    var clean = selector.replace(PSEUDO_RE, function (_, name, arg) {
      pseudos.push({ name: name.toLowerCase(), arg: arg });
      return '';
    });
    return { selector: clean, pseudos: pseudos };
  }

  function ownTextOf(el) {
    if (!el) return '';
    var out = '';
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3) out += n.nodeValue;
      else if (n.nodeType === 1 && ['BR', 'HR', 'IMG', 'INPUT'].indexOf(n.tagName) < 0) out += ' ';
    }
    return normalizeWS(out);
  }

  function textOf(el) {
    if (!el) return '';
    var t = el.textContent;
    // Document 节点按规范没有 textContent（返回 null），得走 documentElement
    if (t == null) t = el.documentElement ? el.documentElement.textContent : (el.body ? el.body.textContent : '');
    return normalizeWS(t);
  }

  function normalizeWS(s) {
    return String(s == null ? '' : s).replace(/[\u00a0\u3000\u200b]/g, ' ')
      .replace(/\s*\n\s*/g, '\n').replace(/[ \t]{2,}/g, ' ').trim();
  }

  function matchesPseudo(el, p) {
    var a = p.arg.replace(/^["']|["']$/g, '');   // 兼容 :contains("x")
    switch (p.name) {
      case 'contains': return textOf(el).indexOf(a) >= 0;
      case 'containstext': return textOf(el).toLowerCase().indexOf(a.toLowerCase()) >= 0;
      case 'containsown':
      case 'containsowntext': return ownTextOf(el).indexOf(a) >= 0;
      case 'matches': try { return new RegExp(a).test(textOf(el)); } catch (e) { return false; }
      case 'matchesown': try { return new RegExp(a).test(ownTextOf(el)); } catch (e) { return false; }
      case 'hastext': return textOf(el).indexOf(a) >= 0;
      // ⚠️ `text.` 前缀：**文本完全相等**（不是包含）—— 见 KW.text 的注释
      case 'textequals': return String(textOf(el)).trim() === a.trim();
      default: return true;
    }
  }

  // DOM 不支持 [attr!=v] / [attr!~=v]，改写成属性存在性过滤。
  // 注意运算符集合是 = ^= $= *= ~= 以及它们的 ! 否定形式，别漏掉 ^ 和 $。
  function applyNegatedOps(selector) {
    var negs = [];
    var clean = selector.replace(/\[([\w-]+)\s*(!)?([\^$*~]?=)\s*["']?([^"'\]]*)["']?\]/g,
      function (_, name, bang, op, val) {
        if (bang) {
          negs.push({ name: name, kind: op === '~=' ? 'notword' : 'not', val: val });
          return '[' + name + ']';
        }
        return '[' + name + op + '"' + val + '"]';
      });
    return { selector: clean, negs: negs };
  }

  function passesNeg(el, n) {
    var v = el.getAttribute(n.name);
    if (v == null) return false;
    if (n.kind === 'notword') return v.split(/\s+/).indexOf(n.val) < 0;
    return v !== n.val;
  }

  /* ---------------------------------------------------------
   * Legado 前缀简写
   *   class.foo  → .foo        tag.div → div
   *   id.foo     → #foo        text.关键 → :contains(关键)
   *   children   → *          出现在链里时表示直接子元素
   * ------------------------------------------------------- */

  var KW = {
    // ⚠️⚠️ **class 的值可以带空格**（2026-10-22 适配 125 源时挖出来的）
    //   站方写法：`class.clearfix chapter-list@tag.li`
    //   页面里是 `<ul class="clearfix chapter-list">` ⇒ **同一个元素上的两个 class**
    //   ⇒ 轻阅以前把空格当成了**后代选择器**（`.clearfix chapter-list`）⇒ **0 命中** ⭐
    //     （实测 125 源里有 **40 处**这种写法：啃书阁 / 安之原创 / 梧桐中文 / 神马小说…）
    //   ⇒ 空格一律当**并列的 class**（`.a.b`）
    //   ⚠️ 站方要写后代的话会用 `class.a@tag.b`（@ 链）⇒ 零误伤
    class: function (v) {
      return '.' + String(v).trim().split(/\s+/).filter(Boolean).join('.');
    },
    id: function (v) { return '#' + v; },
    tag: function (v) { return v; },
    // ⚠️⚠️ **`text.` 是【文本完全相等】，不是「包含」**（2026-10-22 适配 125 源时挖出来的）
    //   站方拿它挑**某一个确定的链接**：
    //     'text.查看目录@tag.a@href'   （啃书阁）
    //     'text.点击阅读@href'         （去读书）
    //     'text.目录@href'             （QQ 阅读）
    //   ⇒ 以前用 `:contains` ⇒ 连 `<title>`（标题里也含这四个字）都匹配上
    //      ⇒ 11 个元素 ⇒ `@tag.a` 挑到「首页」⇒ 目录页抓错 ⇒ **目录只有 1 章** ⭐
    //   ⇒ 改成「相等」⇒ 只匹配那一个 `<a>` ✔
    text: function (v) { return ':textEquals(' + v + ')'; },
    owntext: function (v) { return ':containsOwn(' + v + ')'; },
    children: function () { return '*'; }
  };

  /** 把 `class.book@tag.img@src` 拆成「选择器 + 链」 */
  function parseChain(raw) {
    var r = String(raw == null ? '' : raw).trim();
    // `@css:` 必须在按 @ 切链**之前**去掉，否则 @css 里的 @ 会被当成链分隔符
    if (/^@css:/i.test(r)) r = r.slice(5).trim();
    // 站方有时多写一个 @：@a.2@text / @class.book —— 前面这个 @ 只是习惯性前缀
    // 只放过「@text@」「@get:{k}」这种**带尾 @** 的别名/变量形式；
    // `@tag.p.1` 这种是正常的选择器前缀，必须剥掉前导 @。
    if (r.charAt(0) === '@' && r.charAt(1) !== '@' && !/^@(get|put|getString|getInt|text|html|ownText|href|src|tag|js)@/i.test(r)) {
      r = r.slice(1).trim();
    }
    // 有些站方写成 `@Text:` / `@html:` 这种取值的别名，统一去掉
    r = r.replace(/^@(text|html|ownText|tag|href|src)@/i, '$1@');

    var parts = r.split('@');
    var head = parts.shift() || '';
    var chain = [];
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (!p) continue;
      var dot = p.indexOf('.');
      var kw = (dot >= 0 ? p.slice(0, dot) : p).toLowerCase();
      var val = dot >= 0 ? p.slice(dot + 1) : '';

      // ⚠️⚠️ **Legado 的 `!N` 排除语法**（链尾这一段也能带）
      //   `id.list@tag.dd!0:1:2` ⇒ 取 dd，但**排除第 0/1/2 个**
      //   ⚠️ 轻阅以前完全不支持 ⇒ 这类规则一律 0 命中（125 源里 18 处 `!0`）
      var exMark = '';
      var exM = /!(.*)$/.exec(val);
      if (exM) {
        val = val.slice(0, exM.index).trim();
        var ids = [];
        exM[1].split(':').forEach(function (n) {
          var k = parseInt(n, 10);
          if (!isNaN(k)) ids.push(k);
        });
        if (ids.length) exMark = '__EXCL__' + ids.join(',') + '__';
      }

      if (dot >= 0 && (KW[kw] || isHtmlTag(kw))) {
        // tag.span.0 / a.1 / class.item.2 / dd.-1 → 选完之后再取第 N 个（负数从末尾算）
        var idx = -1, hasIndex = false;
        var im = /^(.*?)\.(-?\d+)$/.exec(val);
        if (im) { val = im[1]; idx = parseInt(im[2], 10); hasIndex = true; }
        if (KW[kw]) chain.push({ kind: 'sub', selector: exMark + KW[kw](val), child: true, index: idx, hasIndex: hasIndex });
        else chain.push({ kind: 'sub', selector: exMark + kw, child: true, index: idx, hasIndex: hasIndex });
      } else {
        // 光秃秃的 @tag / @text / @href 是取属性后缀，不是子选择器
        chain.push({ kind: 'attr', name: val || p });
      }
    }
    return { selector: prefixToCss(head), chain: chain };
  }

  function prefixToCss(head) {
    var h = String(head == null ? '' : head).trim();
    // ⚠️⚠️ **Legado 的 `!N` 排除语法**（2026-10-22 适配 125 源时挖出来的）
    //   `span!0` / `span!0:1` ⇒ 选完之后**排除第 0（/1）个**
    //   ⚠️ 头部**没有 `kw.` 前缀时**（如 `span!0`）也要处理
    //     ⇒ 以前完全不支持 ⇒ 这类规则一律 0 命中（125 源里 18 处 `!0`）
    var gExcl = [];
    var gExM = /!(.*)$/.exec(h);
    if (gExM) {
      h = h.slice(0, gExM.index).trim();
      gExM[1].split(':').forEach(function (n) {
        var k = parseInt(n, 10);
        if (!isNaN(k)) gExcl.push(k);
      });
    }
    var excl = gExcl.slice();
    if (!h) return '';
    // 找 `kw.` 的出现位置；值可以到下一个 kw. 或结尾为止 —— 这样中文类名不会被切碎
    var kwRe = /([a-zA-Z_][\w-]*)\./g, marks = [], m;
    while ((m = kwRe.exec(h)) !== null) {
      var k = m[1].toLowerCase();
      // 除元关键字外，真实 HTML 标签名也能当前缀：a.1 / span.0 / dd.-1
      if (KW[k]) marks.push({ kw: k, start: m.index, vStart: m.index + m[0].length });
      else if (isHtmlTag(k)) marks.push({ kw: 'tag', raw: k, start: m.index, vStart: m.index + m[0].length });
      // 注意：绝不能把 lastIndex 退回 m.index+1 —— 那会让 class. 里的 s.（合法标签 <s>）
      // 也被当成一个新前缀，切出一堆垃圾标记。值里带点由下面的 val 整体切分负责。
      if (marks.length > 8) break;     // 防御畸形规则
    }
    if (!marks.length) {
      // 没前缀简写，原样（div / .x / #y 都对）——但 `!N` 排除仍要生效
      return excl.length ? ('__EXCL__' + excl.join(',') + '__' + h) : h;
    }
    var out = [], lastIndex = 0, hasIdx = false, excl = [];
    var lead = h.slice(0, marks[0].start).trim();
    if (lead) out.push(lead);          // `div.class.a` 的 div 部分
    for (var i = 0; i < marks.length; i++) {
      var vEnd = i + 1 < marks.length ? marks[i + 1].start : h.length;
      var val = h.slice(marks[i].vStart, vEnd).trim();
      // ⚠️⚠️ **Legado 的 `!N` 排除语法**（2026-10-22 适配 125 源时挖出来的）
      //   `span!0` / `tag.dd!0:1:2:3` ⇒ 选完之后**排除第 0/1/2/3 个**
      //   （站方用它剔掉导航位 / 推荐位 / 表头行）
      //   ⚠️ 轻阅以前**完全不支持** ⇒ 这类规则一律 0 命中
      //   （实测 125 源里有 **18 处 `!0`** + 2 处 `!255`）
      var exM = /!(.*)$/.exec(val);
      if (exM) {
        val = val.slice(0, exM.index).trim();
        exM[1].split(':').forEach(function (n) {
          var k = parseInt(n, 10);
          if (!isNaN(k)) excl.push(k);
        });
      }
      // `p.1` / `li.-1`：值就是个下标，标签名自己当选择器
      var pure = /^(-?\d+)$/.exec(val);
      if (pure && marks[i].raw) {
        out.push(marks[i].raw);
        lastIndex = parseInt(pure[1], 10); hasIdx = true;
        continue;
      }
      // `tag.span.0` / `class.item.2` → 选完之后再取第 N 个
      var idxM = /^(.*?)(?:#|\.)(-?\d+)$/.exec(val);
      if (idxM && marks[i].kw !== 'id') {
        out.push(KW[marks[i].kw](idxM[1]));
        lastIndex = parseInt(idxM[2], 10); hasIdx = true;
        continue;
      }
      if (marks[i].raw) {
        // 真实标签当前缀时值是类名：`ul.chapter-list` → ul.chapter-list
        out.push(val ? marks[i].raw + '.' + val : marks[i].raw);
      } else {
        out.push(KW[marks[i].kw](val));
      }
    }
    var r = out.join('');
    if (excl.length) r = '__EXCL__' + excl.join(',') + '__' + r;
    return hasIdx ? '__IDX__' + lastIndex + '__' + r : r;
  }

  /* ---------------------------------------------------------
   * 主查询
   * ------------------------------------------------------- */

  /**
   * 解析整条规则：选择器 + @ 链 + 链尾属性后缀。
   * `class.book@tag.a@href` → { nodes: [<a>…], suffix: 'href' }
   */
  function resolve(root, rule) {
    var out = { nodes: [], suffix: '' };
    if (!root) return out;
    var sel = String(rule || '').trim();
    if (!sel) return out;

    // 逗号组合：各段独立走完整条链
    if (hasTopLevelComma(sel)) {
      var seen = new Set();
      sel.split(',').forEach(function (part) {
        var r = resolve(root, part);
        if (!out.suffix && r.suffix) out.suffix = r.suffix;
        r.nodes.forEach(function (e) { if (!seen.has(e)) { seen.add(e); out.nodes.push(e); } });
      });
      return out;
    }

    var parsed = parseChain(sel);
    var nodes = queryOne(root, parsed.selector);

    // `@text` / `@href` 单独作规则 = 取「当前元素」的对应值（语料里 2500+ 条）
    if (!parsed.selector && parsed.chain.length === 1 && parsed.chain[0].kind === 'attr' && root) {
      return { nodes: [root], suffix: parsed.chain[0].name };
    }
    // Legado 里 `chapterUrl: "href"` 这样的规则 = 取当前元素的 href 属性。
    // 裸词既可能是标签名也可能是属性名，这里用「按标签名查不到」来区分：
    // 真标签名查不到本来就毫无意义，当属性处理只会更对。
    if (!nodes.length && !parsed.chain.length && root && root.nodeType === 1
        && /^[A-Za-z_][\w-]*$/.test(parsed.selector) && !isHtmlTag(parsed.selector)) {
      return { nodes: [root], suffix: parsed.selector };
    }

    for (var i = 0; i < parsed.chain.length && nodes.length; i++) {
      var step = parsed.chain[i];
      var isLast = (i === parsed.chain.length - 1);
      var next = [];

      if (step.kind === 'sub') {
        nodes.forEach(function (n) {
          // Jsoup 的 select() **包含元素自身**：
          // `<div class="container searchresult">` 用 class.container@class.searchresult
          // 必须能命中它自己，所以这里不能排除自身。
          var found = queryOne(n, step.selector);
          if (step.index !== -1 || step.hasIndex) {
            var pick = step.index < 0 ? found[found.length + step.index] : found[step.index];
            found = pick ? [pick] : [];
          }
          next = next.concat(found);
        });
      } else if (isLast) {
        // 链尾属性：不是选择器了，交给 valueOf
        out.suffix = step.name;
        break;
      } else {
        // 中间的裸词是子选择器（tag.p.1@a@text → 先找 a，再取 text）
        nodes.forEach(function (n) {
          next = next.concat(queryOne(n, step.name).filter(function (e) { return e !== n; }));
        });
      }
      nodes = next;
    }
    out.nodes = nodes;
    return out;
  }

  /** 在 root 下按 Jsoup 风格选择器取元素数组 */
  function selectAll(root, rule) { return resolve(root, rule).nodes; }

  /** 一步到位：按规则取字符串值 */
  function value(root, rule, baseUrl) {
    var r = resolve(root, rule);
    if (!r.nodes.length) return '';
    return valueOf(r.nodes[0], r.suffix, baseUrl || baseOf(r.nodes[0]));
  }

  function queryOne(root, selector) {
    // prefixToCss 可能给选择器带上标记：
    //   __IDX__N__   （tag.span.0 这种索引语法）
    //   __EXCL__a,b__（Legado 的 `!N` 排除语法：排除第 a/b 个）
    var idx = -1, idxSet = false, excl = null;
    var sel0 = String(selector || '').trim();
    for (var mk = 0; mk < 3; mk++) {
      var em = /^__EXCL__([\d,\-]*)__(.*)$/.exec(sel0);
      if (em) {
        excl = em[1] ? em[1].split(',').map(function (n) { return parseInt(n, 10); })
                     .filter(function (n) { return !isNaN(n); }) : [];
        sel0 = em[2];
        continue;
      }
      var idxM = /^__IDX__(-?\d+)__(.*)$/.exec(sel0);
      if (idxM) { idx = parseInt(idxM[1], 10); idxSet = true; sel0 = idxM[2]; continue; }
      break;
    }
    selector = sel0;

    var s = splitPseudos(selector);
    var n = applyNegatedOps(s.selector);
    var clean = n.selector.trim();
    var nodes = [];
    var isRootEl = root.nodeType === 1;

    if (!clean || clean === '*') {
      // 裸 * ：取所有元素（Jsoup 的 tag.find() 语义）
      if (isRootEl) nodes.push(root);
      nodes = nodes.concat(Array.prototype.slice.call(root.querySelectorAll('*')));
    } else {
      // Jsoup 的 select() 含根元素自身，DOM 的 querySelectorAll 不含，补上
      if (isRootEl) {
        try { if (root.matches(clean)) nodes.push(root); } catch (e) { /* 非法选择器，走下面的兜底 */ }
      }
      try {
        nodes = nodes.concat(Array.prototype.slice.call(root.querySelectorAll(clean)));
      } catch (e) {
        // 站方经常写 Jsoup 独有的选择器组合，退化成按标签名兜底
        nodes = fallbackByTag(root, clean);
        if (isRootEl && !nodes.includes(root)) {
          try { if (root.matches(fallbackSelector(clean))) nodes.unshift(root); } catch (e2) {}
        }
      }
    }

    if (s.pseudos.length || n.negs.length) {
      nodes = nodes.filter(function (el) {
        for (var i = 0; i < s.pseudos.length; i++) if (!matchesPseudo(el, s.pseudos[i])) return false;
        for (var j = 0; j < n.negs.length; j++) if (!passesNeg(el, n.negs[j])) return false;
        return true;
      });
    }
    if (idxSet) {
      var pick = idx < 0 ? nodes[nodes.length + idx] : nodes[idx];
      nodes = pick ? [pick] : [];
    }
    // ⚠️ **Legado 的 `!N` 排除**（在索引之前应用：排除的是「原始列表」里的位置）
    if (excl && excl.length) {
      nodes = nodes.filter(function (_, i) { return excl.indexOf(i) < 0; });
    }
    return nodes;
  }

  /** 常见 HTML 标签，用来区分「标签名」和「属性名」 */
  var HTML_TAGS = ('a abbr address area article aside audio b base bdi bdo blockquote body br button canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hgroup hr html i iframe img input ins kbd label legend li link main map mark meta meter nav noscript object ol optgroup option output p param picture pre progress q rp rt ruby s samp script section select slot small source span strong style sub summary sup table tbody td template textarea tfoot th thead time title tr track u ul var video wbr area base br col embed hr img input link meta param source track wbr').split(' ');
  function isHtmlTag(name) { return HTML_TAGS.indexOf(String(name).toLowerCase()) >= 0; }

  function fallbackSelector(clean) {
    var m = /([a-zA-Z][\w-]*)/.exec(clean);
    return m ? m[1] : '*';
  }
  function fallbackByTag(root, selector) {
    try { return Array.prototype.slice.call(root.querySelectorAll(fallbackSelector(selector))); }
    catch (e) { return []; }
  }

  function hasTopLevelComma(s) {
    var depth = 0, q = false;
    for (var i = 0; i < s.length; i++) {
      var c = s[i];
      if (q) { if (c === '\\') i++; else if (c === '"') q = false; continue; }
      if (c === '"') q = true;
      else if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
      else if (c === ',' && depth === 0) return true;
    }
    return false;
  }

  function selectOne(root, selector) {
    var all = selectAll(root, selector);
    return all.length ? all[0] : null;
  }

  /* ---------------------------------------------------------
   * 取值
   * ------------------------------------------------------- */

  var ATTR_ALIAS = {
    text: '@@text', html: '@@html', owntext: '@@ownText', ownText: '@@ownText',
    tagname: '@@tag', tag: '@@tag', href: 'href', src: 'src'
  };

  /**
   * 按规则后缀从元素取值。
   *   @text @html @ownText @tag @href @src @data-xxx @Text##
   */
  function valueOf(node, suffix, baseUrl) {
    if (node == null) return '';
    if (typeof node !== 'object') return String(node);   // 已经是字符串结果

    var s = (suffix || '').trim();
    if (!s) return textOf(node);

    var low = s.toLowerCase();
    if (low === 'text') return textOf(node);
    if (low === 'html' || low === 'outerhtml') return node.outerHTML != null ? node.outerHTML : '';
    if (low === 'innerhtml') return node.innerHTML != null ? node.innerHTML : '';
    if (low === 'owntext') return ownTextOf(node);
    if (low === 'tag') return node.tagName ? node.tagName.toLowerCase() : '';
    if (low === 'outerhtml') return node.outerHTML || '';

    var name = ATTR_ALIAS[s] || s;
    if (name === '@@text' || name === '@@html' || name === '@@ownText' || name === '@@tag') {
      return valueOf(node, name.slice(2), baseUrl);
    }
    var v = node.getAttribute ? node.getAttribute(name) : null;
    if (v == null) return '';
    // href/src 自动补全
    if (/^(href|src|action|data-src|poster)$/i.test(name)) return absolutize(decodeEntities(v), baseUrl);
    return decodeEntities(v);
  }

  function decodeEntities(s) {
    if (!s || s.indexOf('&') < 0) return s;
    var el = document.createElement('textarea');
    el.innerHTML = s;
    return el.value;
  }

  /* ---------------------------------------------------------
   * HTML → 纯文本（正文清洗用）
   * ------------------------------------------------------- */

  function htmlToText(html) {
    if (html == null) return '';
    var doc = parseHTML(String(html), '');
    doc.querySelectorAll('script,style,noscript,iframe,ins,svg').forEach(function (e) { e.remove(); });
    var brs = doc.querySelectorAll('br');
    brs.forEach(function (b) { b.replaceWith(document.createTextNode('\n')); });
    doc.querySelectorAll('p,div,li,h1,h2,h3,h4,h5,h6,tr,section').forEach(function (e) {
      e.appendChild(document.createTextNode('\n'));
    });
    return normalizeWS(doc.body.textContent).replace(/\n{3,}/g, '\n\n');
  }

  /**
   * 这条规则还像不像选择器？
   * {{}} 插值后规则可能变成一个纯文本（{{$.id}} → 123），那种必须原样返回 ——
   * 再丢给选择器引擎的话，非法选择器会走 fallbackByTag 兜底成 '*'，
   * 结果把整页文本当成结果返回，比不解析还糟。
   */
  function isSelectorLike(s) {
    var t = String(s == null ? '' : s).trim();
    if (!t) return false;
    if (/[.#:@>\s*+~\[\]()|]/.test(t)) return true;
    var head = t.split(/[.#:@>\s]/)[0];
    return isHtmlTag(head);
  }

  QR.dom = {
    isSelectorLike: isSelectorLike,
    parseHTML: parseHTML,
    baseOf: baseOf,
    absolutize: absolutize,
    resolve: resolve,
    selectAll: selectAll,
    selectOne: selectOne,
    value: value,
    queryOne: queryOne,
    parseChain: parseChain,
    textOf: textOf,
    ownTextOf: ownTextOf,
    valueOf: valueOf,
    decodeEntities: decodeEntities,
    htmlToText: htmlToText,
    normalizeWS: normalizeWS
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
