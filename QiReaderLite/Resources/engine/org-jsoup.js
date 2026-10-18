/* ============================================================
 * org-jsoup.js —— 给站方书源的 org.jsoup.* 垫一层
 *
 * 底层还是 QR.dom 那套 WebKit DOM，这里只把 Jsoup 的 Java 风格 API
 * 翻译过去：Document/Element/Elements/TextNode/Connection。
 * 书源里 `Jsoup.parse(html, baseUrl).select("div@id.content@html")`
 * 这类写法才能原样跑。
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};
  var dom = QR.dom;

  function toArray(v) { return Array.isArray(v) ? v : (v == null ? [] : [v]); }

  /* ---------------- Element ---------------- */

  function El(node, baseUrl) {
    this.n = node;
    this.base = baseUrl || dom.baseOf(node);
  }

  El.prototype.text = function () { return dom.textOf(this.n); };
  El.prototype.ownText = function () { return dom.ownTextOf(this.n); };
  El.prototype.hasText = function () { return dom.textOf(this.n).length > 0; };
  El.prototype.html = function () { return this.n && this.n.innerHTML != null ? this.n.innerHTML : ''; };
  El.prototype.outerHtml = function () { return this.n && this.n.outerHTML ? this.n.outerHTML : ''; };
  El.prototype.toString = function () { return this.outerHtml(); };
  El.prototype.tagName = function () { return this.n && this.n.tagName ? this.n.tagName.toLowerCase() : ''; };
  El.prototype.nodeName = function () { return this.tagName(); };

  El.prototype.attr = function (name, value) {
    if (!this.n) return '';
    if (arguments.length >= 2) { this.n.setAttribute(name, value); return ''; }
    // Jsoup 的 abs: 前缀 = 取绝对地址
    if (/^abs:/i.test(name)) {
      var raw = this.n.getAttribute(name.replace(/^abs:/i, ''));
      return raw == null ? '' : dom.absolutize(dom.decodeEntities(raw), this.base);
    }
    var v = this.n.getAttribute(name);
    return v == null ? '' : v;
  };
  El.prototype.absUrl = function (name) { return this.attr('abs:' + name); };
  El.prototype.id = function () { return this.attr('id'); };
  El.prototype.className = function () { return this.attr('class'); };
  El.prototype.classNames = function () { return this.attr('class').split(/\s+/).filter(Boolean); };
  El.prototype.val = function () { return this.attr('value'); };

  El.prototype.select = function (sel) { return makeElements(dom.resolve(this.n, sel).nodes.map(function (x) { return new El(x, this.base); }, this), this.base); };
  El.prototype.getElementsByTag = function (t) { return this.select('tag.' + t); };
  El.prototype.getElementById = function (i) { var e = dom.selectOne(this.n, '#' + i); return e ? new El(e, this.base) : null; };
  El.prototype.children = function () {
    return makeElements(Array.prototype.slice.call(this.n.children).map(function (c) { return new El(c, this.base); }, this), this.base);
  };
  El.prototype.parent = function () { return this.n.parentNode ? new El(this.n.parentNode, this.base) : null; };
  El.prototype.nextElementSibling = function () {
    var n = this.n.nextElementSibling; return n ? new El(n, this.base) : null;
  };
  El.prototype.prevElementSibling = function () {
    var n = this.n.previousElementSibling; return n ? new El(n, this.base) : null;
  };
  // Legado 那边叫 prevElementSibling，Jsoup 官方叫 previousElementSibling，两个都留着
  El.prototype.previousElementSibling = El.prototype.prevElementSibling;
  El.prototype.remove = function () { if (this.n && this.n.remove) this.n.remove(); };
  El.prototype.raw = function () { return this.n; };

  /* ---------------- Elements ---------------- */

  function makeElements(arr, baseUrl) {
    var e = arr.slice();
    e.size = function () { return e.length; };
    e.get = function (i) { return e[Number(i) || 0]; };
    e.isEmpty = function () { return e.length === 0; };
    e.first = function () { return e[0] || null; };
    e.last = function () { return e.length ? e[e.length - 1] : null; };
    e.each = function (fn) { e.forEach(function (x, i) { fn.call(x, x, i); }); return e; };
    e.toArray = function () { return e.slice(); };
    e.attr = function (n) { return e[0] ? e[0].attr(n) : ''; };
    e.text = function () { return e[0] ? e[0].text() : ''; };
    e.html = function () { return e[0] ? e[0].html() : ''; };
    e.ownText = function () { return e[0] ? e[0].ownText() : ''; };
    e.tagName = function () { return e[0] ? e[0].tagName() : ''; };
    e.select = function (s) { return e[0] ? e[0].select(s) : makeElements([], baseUrl); };
    e.eachAttr = function (n, fn) { e.forEach(function (x) { fn(x.attr(n), x); }); return e; };
    e.attrList = function (n) { return e.map(function (x) { return x.attr(n); }); };
    e.iterator = function () {
      var i = 0;
      return { hasNext: function () { return i < e.length; }, next: function () { return e[i++]; } };
    };
    e.toString = function () { return '[' + e.map(String).join(', ') + ']'; };
    return e;
  }

  function wrap(nodes, baseUrl) {
    return makeElements(nodes.map(function (n) { return new El(n, baseUrl); }), baseUrl);
  }

  /* ---------------- Document ---------------- */

  function Doc(node, baseUrl) {
    this.n = node;
    this.base = baseUrl || '';
  }
  Doc.prototype.select = function (sel) { return wrap(dom.resolve(this.n, sel).nodes, this.base); };
  Doc.prototype.selectFirst = function (sel) { var e = this.select(sel).first(); return e; };
  Doc.prototype.getElementById = function (i) { var e = dom.selectOne(this.n, '#' + i); return e ? new El(e, this.base) : null; };
  Doc.prototype.getElementsByTag = function (t) { return this.select('tag.' + t); };
  Doc.prototype.text = function () { return dom.textOf(this.n.body || this.n); };
  Doc.prototype.html = function () { return this.n && this.n.documentElement ? this.n.documentElement.outerHTML : ''; };
  Doc.prototype.toString = function () { return this.html(); };
  Doc.prototype.baseUri = function () { return this.base; };
  Doc.prototype.location = function () { return this.base; };
  Doc.prototype.title = function () { var t = this.n.querySelector('title'); return t ? t.textContent : ''; };
  Doc.prototype.body = function () { return this.n.body ? new El(this.n.body, this.base) : null; };
  Doc.prototype.head = function () { return this.n.head ? new El(this.n.head, this.base) : null; };
  Doc.prototype.children = function () { return wrap(this.n.children ? Array.prototype.slice.call(this.n.children) : [], this.base); };
  Doc.prototype.appendElement = function (tag) {
    var e = this.n.createElement(tag);
    if (this.n.body) this.n.body.appendChild(e);
    return new El(e, this.base);
  };
  Doc.prototype.appendChild = function (child) {
    if (child && child.n && this.n.body) this.n.body.appendChild(child.n);
    return child;
  };
  Doc.prototype.ownerDocument = function () { return this; };

  /* ---------------- TextNode ---------------- */

  function TextNode(text) { this.text_ = String(text == null ? '' : text); }
  TextNode.prototype.text = function () { return this.text_; };
  TextNode.prototype.toString = function () { return this.text_; };
  TextNode.prototype.toWholeText = function () { return this.text_; };
  TextNode.prototype.outerHtml = function () { return this.text_; };

  /* ---------------- Connection（够用即可） ---------------- */

  function Connection(url) {
    this.url = String(url || '');
    this.method = 'GET';
    this._headers = {};
    this._data = null;
    this._timeout = 20000;
    this.followRedirects = true;
  }
  var C = Connection.prototype;
  C.header = function (k, v) { if (arguments.length === 1) return this._headers[k] || ''; this._headers[k] = v; return this; };
  C.headers = function (h) { var s = this; for (var k in h) s.header(k, h[k]); return this; };
  C.data = function (d) { this._data = d == null ? null : String(d); return this; };
  C.method_ = function (m) { this.method = String(m).toUpperCase(); return this; };
  C.get_ = function () { this.method = 'GET'; return this; };
  C.post_ = function () { this.method = 'POST'; return this; };
  C.timeout = function (t) { if (arguments.length === 0) return this._timeout; this._timeout = t; return this; };
  C.userAgent = function (ua) { this._headers['User-Agent'] = ua; return this; };
  C.referrer = function (r) { this._headers['Referer'] = r; return this; };
  C.cookie = function (c) { this._headers['Cookie'] = c; return this; };
  C.execute = function () { return QR.java.rawRequest(this.url, this.method, this._headers, this._data, this._timeout); };

  /* ---------------- 挂到全局 ---------------- */

  var Jsoup = {
    parse: function (html, baseUrl) { return new Doc(dom.parseHTML(html, baseUrl), baseUrl); },
    connect: function (url) { return new Connection(url); },
    parseBodyFragment: function (html, baseUrl) { return new Doc(dom.parseHTML(html, baseUrl), baseUrl); },
    clean: function (html) { return dom.htmlToText(html); },
    isBlank: function (s) { return s == null || !String(s).trim(); },
    Selector: { select: function (sel) { return { selector: sel }; } },
    Connection: Connection,
    Method: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE', HEAD: 'HEAD' }
  };

  var org = g.org = g.org || {};
  org.jsoup = org.jsoup || {};
  org.jsoup.Jsoup = Jsoup;
  org.jsoup.Connection = Connection;
  org.jsoup.nodes = {
    Document: Doc, Element: El, TextNode: TextNode,
    Attributes: function () { return {}; }
  };
  org.jsoup.select = { Elements: makeElements, Selector: Jsoup.Selector, Evaluator: function () { return {}; } };
  org.jsoup.parser = { Parser: { parseHTML: function (h) { return Jsoup.parse(h); } } };

  QR.jsoup = { El: El, Doc: Doc, Elements: makeElements, wrap: wrap, Connection: Connection, Jsoup: Jsoup };
  /* ============================================================
   * XPath —— org.seimicrawler.xpath.{JXDocument,JXNode}
   *
   * 之前这层是「搬不动」就没做，理由是栖阅那份实现依赖 Swift/Kanna 的
   * live DOM 句柄（_jsoupParse / _xpathResults 那一堆 native）。
   * 那个判断是错的：**XPath 根本不需要桥，WebView 自带的
   * document.evaluate() 就是完整的 XPath 1.0 引擎**。
   *
   * 站方书源里的典型用法：
   *   var d = org.seimicrawler.xpath.JXDocument(java.getString(html))
   *   d.selN('//div[@class="c"]/text()').each(function(t){ ... })
   *   d.sel('//title').text()
   *   Jsoup.parse(html).xpath('//a/@href')   ← 这个之前直接是 undefined
   * ============================================================ */

  var XPATH_ORDERED = 7;   // ORDERED_NODE_SNAPSHOT_TYPE

  /** 跑一条 XPath；anyFlag 为 true 时按 XPathResult 自身类型求值（要标量时用） */
  function xpathEval(ctx, expr, resType) {
    if (typeof g.document === 'undefined' || !g.document.evaluate) {
      return resType === 2 ? '' : [];
    }
    try {
      return g.document.evaluate(expr, ctx, null, resType, null);
    } catch (e) {
      // 表达式有问题别炸书源，返回空
      if (typeof console !== 'undefined') console.log('[xpath] ' + expr + ' → ' + e);
      return resType === 2 ? '' : [];
    }
  }

  /** 返回 DOM 节点数组（不取 text()/@attr 的值） */
  function xpathNodes(ctx, expr) {
    var r = xpathEval(ctx, expr, XPATH_ORDERED);
    var out = [];
    if (!r || !r.snapshotLength) return out;
    for (var i = 0; i < r.snapshotLength; i++) {
      var n = r.snapshotItem(i);
      if (n) out.push(n);
    }
    return out;
  }

  /** 返回字符串数组（text() 节点 / @attr） */
  function xpathStrings(ctx, expr) {
    var nodes = xpathNodes(ctx, expr);
    var out = [];
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var v = n.nodeType === 2 ? n.value : (n.textContent != null ? n.textContent : n.nodeValue);
      out.push(v == null ? '' : String(v));
    }
    return out;
  }

  /**
   * 只要标量结果（count() / string(...) 这类）。
   *
   * ⚠️ document.evaluate() 返回的是 **XPathResult 对象**，不是值本身 ——
   *    直接 String(r) 会去调 XPathResult 的 toString，jsdom 里直接抛
   *    "Function.prototype.toString requires that 'this' be a Function"。
   *    标量要从 .stringValue / .numberValue / .booleanValue 取。
   *    XPathResultType: NUMBER=1, STRING=2, BOOLEAN=3
   */
  function xpathString(ctx, expr) {
    var r = xpathEval(ctx, expr, 2 /* STRING_TYPE */);
    if (!r || typeof r !== 'object') return r == null ? '' : String(r);
    if (r.stringValue != null) return String(r.stringValue);
    if (r.numberValue != null && !isNaN(r.numberValue)) return String(r.numberValue);
    if (typeof r.booleanValue === 'boolean') return String(r.booleanValue);
    return '';
  }

  /* ---------------- JXNode ---------------- */

  function JXNode(node) {
    this.node = node || null;
  }
  Object.defineProperty(JXNode, '__javaClassName', { value: 'JXNode', enumerable: false });
  JXNode.create = function (n) { return new JXNode(n); };

  JXNode.prototype._base = function () {
    var n = this.node;
    if (!n) return '';
    var d = n.ownerDocument;
    return d && d.documentURI ? d.documentURI : (QR.baseUrl || '');
  };
  /** Java 侧叫 getElement()，只有元素节点才有 */
  JXNode.prototype.getElement = function () {
    return this.node && this.node.nodeType === 1 ? new El(this.node, this._base()) : null;
  };
  JXNode.prototype.getNode = function () { return this.node; };
  JXNode.prototype.getTextValue = function () {
    var n = this.node;
    if (!n) return '';
    if (n.nodeType === 2) return String(n.value == null ? '' : n.value);
    return String(n.textContent == null ? (n.nodeValue || '') : n.textContent);
  };
  // 兼容各种叫法
  JXNode.prototype.getValue = JXNode.prototype.getTextValue;
  JXNode.prototype.getStringValue = JXNode.prototype.getTextValue;
  JXNode.prototype.text = JXNode.prototype.getTextValue;
  JXNode.prototype.asString = function () { return this.getTextValue(); };
  JXNode.prototype.toString = function () { return this.getTextValue(); };
  JXNode.prototype.isTextNode = function () {
    return !!this.node && (this.node.nodeType === 3 || this.node.nodeType === 4);
  };
  JXNode.prototype.getTagName = function () {
    return this.node && this.node.nodeType === 1 ? String(this.node.nodeName).toLowerCase() : '';
  };
  JXNode.prototype.getOuterHtml = function () {
    return this.node && this.node.outerHTML ? String(this.node.outerHTML) : this.getTextValue();
  };
  JXNode.prototype.getAttr = function (name) {
    var n = this.node;
    if (!n || !n.getAttribute) return '';
    var v = n.getAttribute(String(name));
    return v == null ? '' : String(v);
  };
  JXNode.prototype.getChildren = function () {
    var n = this.node;
    if (!n) return javaList([]);
    var cs = n.childNodes ? Array.prototype.slice.call(n.childNodes) : [];
    return javaList(cs.map(function (c) { return new JXNode(c); }));
  };
  JXNode.prototype.getChild = function (name) {
    var n = this.node;
    if (!n || !n.childNodes) return null;
    var tag = String(name).toLowerCase();
    for (var i = 0; i < n.childNodes.length; i++) {
      var c = n.childNodes[i];
      if (c.nodeType === 1 && String(c.nodeName).toLowerCase() === tag) return new JXNode(c);
    }
    return null;
  };
  /** 在自己的上下文里再跑一条 XPath */
  JXNode.prototype.sel = function (expr) { return new JXDocument(this.node, this._base()); };
  JXNode.prototype.xpath = function (expr) { return javaList(xpathNodes(this.node, expr).map(function (n) { return new JXNode(n); })); };
  JXNode.prototype.selN = JXNode.prototype.xpath;
  JXNode.prototype.selOne = function (expr) {
    var a = xpathNodes(this.node, expr);
    return a.length ? new JXNode(a[0]) : null;
  };
  JXNode.prototype.text = function () { return this.getTextValue(); };
  JXNode.prototype.outerHtml = function () { return this.getOuterHtml(); };

  /* ---------------- JXDocument ---------------- */

  function JXDocument(input, baseUrl) {
    var base = baseUrl;
    if (input instanceof Doc) { this.n = input.n; base = base || input.base; }
    else if (input instanceof El) { this.n = input.n; base = base || input.base; }
    else if (Array.isArray(input)) {
      // Elements：选第一个当上下文（JXDocument 的多根场景书源基本不用）
      this.n = input.length ? (input[0] && input[0].n) : null;
      base = base || (input.length && input[0] ? input[0].base : '');
    } else if (input && input.nodeType) { this.n = input; }
    else { this.n = dom.parseHTML(String(input == null ? '' : input), base); base = base || ''; }
    this.base = base || (this.n && dom.baseOf ? dom.baseOf(this.n) : '');
  }
  Object.defineProperty(JXDocument, '__javaClassName', { value: 'JXDocument', enumerable: false });
  JXDocument.create = function (input) { return new JXDocument(input); };

  /** selN → JXNode 列表（Java 返回 List<JXNode>） */
  JXDocument.prototype.selN = function (expr) {
    var self = this;
    return javaList(xpathNodes(this.n, expr).map(function (n) { return new JXNode(n); }));
  };
  /** sel → 第一个 JXNode，没有就是 null（Java 返回可空 JXNode） */
  JXDocument.prototype.sel = function (expr) {
    var a = xpathNodes(this.n, expr);
    return a.length ? new JXNode(a[0]) : null;
  };
  JXDocument.prototype.selOne = JXDocument.prototype.sel;
  /** 只要字符串（count() / string(...) 这类） */
  JXDocument.prototype.selString = function (expr) { return xpathString(this.n, expr); };
  JXDocument.prototype.selText = function (expr) {
    var s = xpathStrings(this.n, expr);
    return s.length ? s[0] : '';
  };
  JXDocument.prototype.xpath = JXDocument.prototype.selN;
  JXDocument.prototype.get = function (node) {
    return node instanceof JXNode ? new JXDocument(node.node, this.base) : new JXDocument(node);
  };
  JXDocument.prototype.text = function () { return dom.textOf(this.n.body || this.n); };
  JXDocument.prototype.getRootElement = function () { return new JXDocument(this.n, this.base); };
  JXDocument.prototype.getDocumentElement = function () {
    var de = this.n && this.n.documentElement;
    return de ? new JXDocument(de, this.base) : null;
  };
  JXDocument.prototype.select = function (sel) { return new Doc(this.n, this.base).select(sel); };
  JXDocument.prototype.selectFirst = function (sel) { return new Doc(this.n, this.base).selectFirst(sel); };
  JXDocument.prototype.html = function () {
    return this.n && this.n.documentElement ? this.n.documentElement.outerHTML : '';
  };
  JXDocument.prototype.outerHtml = JXDocument.prototype.html;
  JXDocument.prototype.toString = JXDocument.prototype.html;

  /** Java 的 List —— 书源里常 .each / .size / .get / .toArray */
  function javaList(arr) {
    var l = arr.slice();
    l.size = function () { return l.length; };
    l.isEmpty = function () { return l.length === 0; };
    l.get = function (i) { return l[Number(i) || 0]; };
    l.each = function (fn) { l.forEach(function (x, i) { fn(x, i); }); return l; };
    l.forEach = function (fn) { Array.prototype.forEach.call(l, function (x, i) { fn(x, i); }); return l; };
    l.map = function (fn) { return Array.prototype.map.call(l, fn); };
    l.toArray = function () { return l.slice(); };
    l.add = function (x) { l.push(x); return true; };
    l.stream = function () { return l[Symbol.iterator](); };
    return l;
  }

  /* ---------------- 把缺的 Jsoup 方法补上 ---------------- */

  Doc.prototype.xpath = function (expr) { return javaList(xpathNodes(this.n, expr).map(function (n) { return new JXNode(n); })); };
  Doc.prototype.selN = Doc.prototype.xpath;
  Doc.prototype.sel = function (expr) { var a = xpathNodes(this.n, expr); return a.length ? new JXNode(a[0]) : null; };
  Doc.prototype.outerHtml = Doc.prototype.html;
  Doc.prototype.toJSON = function () { return this.html(); };
  Doc.prototype.child = function (sel) { return this.select(sel).first(); };
  Doc.prototype.getElementsByClass = function (c) { return this.select('.' + String(c).split(/\s+/).join('.')); };
  // 属性选择器 '[href]' 走 QR.dom 的选择器解析器不一定认，直接用原生 DOM 更稳
  Doc.prototype.getElementsByAttribute = function (a) {
    var n = this.n;
    if (!n || !n.querySelectorAll) return wrap([], this.base);
    try { return wrap(Array.prototype.slice.call(n.querySelectorAll('[' + a + ']')), this.base); }
    catch (e) { return wrap([], this.base); }
  };

  El.prototype.xpath = function (expr) { return javaList(xpathNodes(this.n, expr).map(function (n) { return new JXNode(n); })); };
  El.prototype.selN = El.prototype.xpath;
  El.prototype.sel = function (expr) { var a = xpathNodes(this.n, expr); return a.length ? new JXNode(a[0]) : null; };
  El.prototype.selectFirst = function (s) { return this.select(s).first(); };
  El.prototype.child = function (s) { return this.select(s).first(); };
  El.prototype.childrenSize = function () { return this.n.children ? this.n.children.length : 0; };
  El.prototype.normalName = function () { return this.tagName().toLowerCase(); };
  El.prototype.hasAttr = function (n) { return !!this.n.hasAttribute(String(n)); };
  El.prototype.removeAttr = function (n) { this.n.removeAttribute(String(n)); return this; };
  El.prototype.attributes = function () {
    var out = {};
    if (!this.n.attributes) return out;
    for (var i = 0; i < this.n.attributes.length; i++) {
      var a = this.n.attributes[i];
      out[a.name] = String(a.value);
    }
    return out;
  };
  El.prototype.classNames = function () { return (this.attr('class') || '').split(/\s+/).filter(Boolean); };
  El.prototype.className = function () { return this.attr('class') || ''; };
  El.prototype.hasClass = function (c) {
    return (' ' + this.attr('class') + ' ').indexOf(' ' + c + ' ') >= 0;
  };
  El.prototype.addClass = function (c) { if (!this.hasClass(c)) this.attr('class', (this.attr('class') + ' ' + c).trim()); return this; };
  El.prototype.removeClass = function (c) {
    var v = this.classNames().filter(function (x) { return x !== c; }).join(' ');
    if (v) this.attr('class', v); else this.n.removeAttribute('class');
    return this;
  };
  El.prototype.textNodes = function () {
    var t = [], n = this.n.childNodes;
    for (var i = 0; n && i < n.length; i++) if (n[i].nodeType === 3) t.push(n[i].nodeValue);
    return javaList(t);
  };
  El.prototype.data = function () { return this.text(); };
  El.prototype.getElementsByClass = function (c) { return this.select('.' + String(c).split(/\s+/).join('.')); };
  El.prototype.getElementsByAttribute = function (a) {
    var n = this.n;
    if (!n || !n.querySelectorAll) return wrap([], this.base);
    try { return wrap(Array.prototype.slice.call(n.querySelectorAll('[' + a + ']')), this.base); }
    catch (e) { return wrap([], this.base); }
  };
  El.prototype.empty = function () { while (this.n.firstChild) this.n.removeChild(this.n.firstChild); return this; };
  El.prototype.clone = function () { return new El(this.n.cloneNode(true), this.base); };
  El.prototype.before = function (h) { var e = dom.parseHTML(String(h), this.base).body.firstChild; if (e) this.n.parentNode.insertBefore(e, this.n); return this; };
  El.prototype.after = function (h) { var e = dom.parseHTML(String(h), this.base).body.firstChild; if (e) this.n.parentNode.insertBefore(e, this.n.nextSibling); return this; };
  El.prototype.append = function (h) { var e = dom.parseHTML(String(h), this.base).body.firstChild; if (e) this.n.appendChild(e); return this; };
  El.prototype.prepend = function (h) { var e = dom.parseHTML(String(h), this.base).body.firstChild; if (e) this.n.insertBefore(e, this.n.firstChild); return this; };
  El.prototype.toJSON = function () { return this.outerHtml(); };

  // Elements 补齐
  var EP = makeElements;
  function patchElements(e) {
    // baseUrl 要从元素自己拿 —— 这里拿不到闭包里的那个（patchElements 只有 e）
    var b = e.length && e[0] ? e[0].base : '';
    e.eq = function (i) { return e[Number(i) || 0] || null; };
    e.map = function (fn) { return Array.prototype.map.call(e, fn); };
    e.filter = function (fn) { return EP(Array.prototype.filter.call(e, fn), b); };
    e.not = function (s) { return EP(e.filter(function (x) { return !(x.hasClass && x.hasClass(s)); }), b); };
    e.eachText = function (fn) { e.forEach(function (x, i) { fn(x.text(), i); }); return e; };
    e.subList = function (from, to) { return EP(e.slice(from, to), b); };
    e.outerHtml = function () { return e[0] ? e[0].outerHtml() : ''; };
    e.hasAttr = function (n) { return e[0] ? e[0].hasAttr(n) : false; };
    e.eachHtml = function (fn) { e.forEach(function (x, i) { fn(x.html(), i); }); return e; };
    e.eachTag = function (fn) { e.forEach(function (x, i) { fn(x.tagName(), i); }); return e; };
    e.remove = function () { e.forEach(function (x) { x.remove(); }); return e; };
    e.before = function (h) { e.forEach(function (x) { x.before(h); }); return e; };
    e.after = function (h) { e.forEach(function (x) { x.after(h); }); return e; };
    e.append = function (h) { e.forEach(function (x) { x.append(h); }); return e; };
    e.prepend = function (h) { e.forEach(function (x) { x.prepend(h); }); return e; };
    e.empty = function () { e.forEach(function (x) { x.empty(); }); return e; };
    e.addClass = function (c) { e.forEach(function (x) { x.addClass(c); }); return e; };
    e.removeClass = function (c) { e.forEach(function (x) { x.removeClass(c); }); return e; };
    e.hasClass = function (c) { return e.length > 0 && e.every(function (x) { return x.hasClass(c); }); };
    e.xpath = function (x) { return e[0] ? e[0].xpath(x) : javaList([]); };
    e.selN = e.xpath;
    e.sel = function (x) { return e[0] ? e[0].sel(x) : null; };
    e.selectFirst = function (s) { return e[0] ? e[0].selectFirst(s) : null; };
    return e;
  }
  var _makeElements = makeElements;
  makeElements = function (arr, baseUrl) { return patchElements(_makeElements(arr, baseUrl)); };
  // 前面已经建好的 wrap/select 走的是变量引用，这里同步补 Doc/El 之外的两个入口
  QR.jsoup.makeElements = makeElements;

  /* ---------------- 挂到全局 ---------------- */

  var org = g.org = g.org || {};
  org.jsoup = org.jsoup || {};
  org.jsoup.nodes = org.jsoup.nodes || {};
  org.jsoup.nodes.Document = Doc;
  org.jsoup.nodes.Element = El;
  org.jsoup.select = org.jsoup.select || {};
  org.jsoup.select.Elements = makeElements;
  org.jsoup.Connection = org.jsoup.Connection || org.jsoup.Connection;
  // 栖阅那边 Connection 是个接口桩，挂了个 Method 枚举；书源常写 Connection.Method.GET
  org.jsoup.Connection.Method = org.jsoup.Connection.Method ||
    (org.jsoup.Jsoup && org.jsoup.Jsoup.Method) || { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE', PATCH: 'PATCH', HEAD: 'HEAD' };


  org.seimicrawler = org.seimicrawler || {};
  org.seimicrawler.xpath = org.seimicrawler.xpath || {};
  org.seimicrawler.xpath.JXDocument = JXDocument;
  org.seimicrawler.xpath.JXNode = JXNode;
  org.seimicrawler.xpath.JXElements = javaList;

  // 栖阅那两个是挂在 Packages.* 上的别名
  var P = g.Packages = g.Packages || {};
  P.org = P.org || {};
  P.org.jsoup = P.org.jsoup || {};
  P.org.jsoup.nodes = P.org.jsoup.nodes || {};
  P.org.jsoup.nodes.Document = Doc;
  P.org.jsoup.nodes.Element = El;
  P.org.jsoup.select = P.org.jsoup.select || {};
  P.org.jsoup.select.Elements = makeElements;
  P.org.jsoup.Connection = org.jsoup.Connection;
  P.org.jsoup.Jsoup = org.jsoup.Jsoup;
  P.org.seimicrawler = P.org.seimicrawler || {};
  P.org.seimicrawler.xpath = P.org.seimicrawler.xpath || {};
  P.org.seimicrawler.xpath.JXDocument = JXDocument;
  P.org.seimicrawler.xpath.JXNode = JXNode;

  QR.jsoup = Object.assign(QR.jsoup || {}, {
    El: El, Doc: Doc, Elements: makeElements, wrap: wrap,
    Connection: org.jsoup.Connection, Jsoup: org.jsoup.Jsoup,
    JXDocument: JXDocument, JXNode: JXNode, javaList: javaList,
    xpathNodes: xpathNodes, xpathStrings: xpathStrings, xpathString: xpathString
  });
})(typeof globalThis !== 'undefined' ? globalThis : self);
