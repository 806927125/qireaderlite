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
})(typeof globalThis !== 'undefined' ? globalThis : self);
