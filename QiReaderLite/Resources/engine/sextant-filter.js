// ============================================================================
// sextant-filter.js —— Sextant 过滤表达式求值器（JS 版）
// ============================================================================
//
// 为什么有这个文件：
//   栖阅 2027.01.01 的书源规则引擎把 JSONPath **放在 Swift 侧**（Sextant 包），
//   所以栖阅书源能写这些过滤条件，而 Legado 安卓端写不了：
//
//     $[?(@.age > 18)]
//     $[?(@.color == 'blue')]
//     $[?(@.name =~ /foo.*?/i)]
//     $[?(@.size in ['S','M'])]
//     $[?(@.tags subsetof ['S','M','L'])]
//     $[?(@.tags anyof ['M','L'])]
//     $[?(@.tags noneof ['M','L'])]
//     $[?(@.enabled == true && @.price < 10)]
//     $[?(@.a == 1 || @.b == 2)]
//     $[?(@.name)]                    存在性
//     $[?(@.x empty)]
//     $.store.book.length()            尾部函数
//
//   轻阅的 JSONPath 跑在 WKWebView 的 JS 里（jsonpath.js），
//   原来的 testFilter 只有一个正则，只支持「单字段 + 简单比较」。
//   ⇒ 这个文件把它换成完整的 Sextant 语法，**零构建、零原生桥、零同步通道风险**。
//
// 语法（与 KittyMac/Sextant 的 FilterCompiler 对齐）：
//   逻辑     &&  ||  !
//   比较     ==  !=  <  <=  >  >=  =~        （=~ 是正则匹配）
//   集合     in  nin  subsetof  anyof  noneof
//   特殊     size  empty                      （前缀或中缀都行）
//   字面量   true false null  数字  '字符串'  "字符串"  /正则/i
//   路径     @.a.b  @['a']  @.a[0]  $.x（根）
//   尾部函数 min() max() avg() stddev() length() sum() keys() concat(x) append(x)
//
// 导出：QR.sextantFilter = { eval: evalFilter, test: testFilter }
//
// ⚠️ 语义约定（与栖阅/Legado 一致）：
//   · 「==」是**严格相等**：1 != '1'（数字和字符串不相等）
//   · 「in」右值是数组：左值 ∈ 右值
//   · 「subsetof」左值（数组）是右值（数组）的子集
// ============================================================================

(function (g) {
  'use strict';
  if (typeof g === 'undefined') g = (typeof globalThis !== 'undefined' ? globalThis : this);
  var QR = g.QR = g.QR || {};

  // ─────────────────────────────────────────────────────────────
  // 词法：把表达式切成 token
  // ─────────────────────────────────────────────────────────────

  // ⭐ 运算符表 —— 严格照 KittyMac/Sextant 的 RelationalOperator.swift：
  //    单词运算符**大小写不敏感**（源码用 hitch.uppercase() 匹配）
  //    字符运算符：== != === !== < <= > >= =~
  //    单词运算符：IN NIN CONTAINS ALL SIZE EXISTS TYPE EMPTY SUBSETOF ANYOF NONEOF
  //    逻辑：&& || !
  var WORD_OPS = ['SUBSETOF', 'NONEOF', 'ANYOF', 'CONTAINS', 'EXISTS',
                  'NIN', 'IN', 'SIZE', 'EMPTY', 'TYPE', 'ALL'];
  var CHAR_OPS = ['===', '!==', '==', '!=', '>=', '<=', '=~', '<', '>', '&&', '||', '!'];
  var RE_OPS = WORD_OPS.concat(CHAR_OPS);

  function tokenize(src) {
    var toks = [], i = 0, s = String(src == null ? '' : src);
    while (i < s.length) {
      var c = s[i];
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') { i++; continue; }
      // 字符串
      if (c === '"' || c === "'") {
        var j = i + 1, buf = '';
        while (j < s.length && s[j] !== c) {
          if (s[j] === '\\') { buf += s[j + 1]; j += 2; }
          else { buf += s[j]; j++; }
        }
        toks.push({ t: 'str', v: buf });
        i = j + 1;
        continue;
      }
      // 正则字面量 /.../flags
      if (c === '/') {
        var k = i + 1, rb = '';
        var inCls = false;
        while (k < s.length) {
          if (rb === '' && s[k] === '\\') { rb += s[k] + (s[k + 1] || ''); k += 2; continue; }
          if (rb === '' && s[k] === '[') { inCls = true; rb += s[k]; k++; continue; }
          if (rb === '' && s[k] === ']') { inCls = false; rb += s[k]; k++; continue; }
          if (!inCls && s[k] === '/') break;
          rb += s[k]; k++;
        }
        if (k < s.length) {
          var fl = '';
          var m2 = /^[a-z]*/.exec(s.slice(k + 1));
          if (m2) { fl = m2[0]; i = k + 1 + fl.length; }
          else i = k + 1;
          toks.push({ t: 'regex', v: rb, flags: fl });
          continue;
        }
      }
      // 数字
      if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(s[i + 1] || ''))) {
        var mn = /^[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?/.exec(s.slice(i));
        if (mn) { toks.push({ t: 'num', v: parseFloat(mn[0]) }); i += mn[0].length; continue; }
      }
      // 单词运算符（大小写不敏感）—— 必须排在标识符分支之前，
      // 否则 "in" / "size" 会被当成属性名，运算符整个失效。
      var upper = s.slice(i).toUpperCase();
      var wordOp = null;
      for (var w = 0; w < WORD_OPS.length; w++) {
        if (upper.startsWith(WORD_OPS[w])) {
          // 后面不能紧跟标识符字符（避免 "inside" 被当成 "IN"+"side"）
          var after = s[i + WORD_OPS[w].length] || ' ';
          if (!/[A-Za-z0-9_$\u4e00-\u9fa5]/.test(after)) { wordOp = WORD_OPS[w]; break; }
        }
      }
      if (wordOp) { toks.push({ t: 'op', v: wordOp }); i += wordOp.length; continue; }
      // 标识符 / 路径片段
      if (/[A-Za-z_$@\u4e00-\u9fa5]/.test(c)) {
        var mi = /^[A-Za-z_$@\u4e00-\u9fa5][A-Za-z0-9_$\u4e00-\u9fa5]*/.exec(s.slice(i));
        if (mi) { toks.push({ t: 'id', v: mi[0] }); i += mi[0].length; continue; }
      }
      // 运算符
      var matched = null;
      for (var o = 0; o < RE_OPS.length; o++) {
        if (s.substr(i, RE_OPS[o].length) === RE_OPS[o]) { matched = RE_OPS[o]; break; }
      }
      if (matched) { toks.push({ t: 'op', v: matched }); i += matched.length; continue; }
      // 其它符号（. [ ] ( ) , 等）
      toks.push({ t: 'punct', v: c });
      i++;
    }
    return toks;
  }

  // ─────────────────────────────────────────────────────────────
  // 路径求值：@.a.b[0]['x']  /  $.root
  // ─────────────────────────────────────────────────────────────

  function isObj(v) { return v !== null && typeof v === 'object'; }

  function getPath(root, cur, pathStr) {
    // pathStr 形如 ".a.b" / "['a']" / "[0]" / ".a[0].b"
    var s = String(pathStr || '');
    var val = cur;
    var i = 0;
    while (i < s.length) {
      var c = s[i];
      if (c === '.') {
        var m = /^\.([A-Za-z_$@\u4e00-\u9fa5][A-Za-z0-9_$\u4e00-\u9fa5]*)/.exec(s.slice(i));
        if (!m) { i++; continue; }
        var key = m[1];
        val = (isObj(val) && !Array.isArray(val)) ? val[key] : undefined;
        if (val === undefined) return undefined;
        i += m[0].length;
        continue;
      }
      if (c === '[') {
        var e = s.indexOf(']', i);
        if (e < 0) return undefined;
        var body = s.slice(i + 1, e).trim();
        if (body[0] === "'" || body[0] === '"') {
          var k2 = body.slice(1, -1);
          val = (isObj(val) && !Array.isArray(val)) ? val[k2] : undefined;
        } else if (body === '*') {
          val = Array.isArray(val) ? val.slice()
            : (isObj(val) ? Object.keys(val).map(function (x) { return val[x]; }) : []);
        } else {
          var ix = parseInt(body, 10);
          if (isNaN(ix)) return undefined;
          if (Array.isArray(val)) {
            var j = ix < 0 ? val.length + ix : ix;
            val = val[j];
          } else return undefined;
        }
        if (val === undefined) return undefined;
        i = e + 1;
        continue;
      }
      i++;
    }
    return val;
  }

  // ─────────────────────────────────────────────────────────────
  // 值语义
  // ─────────────────────────────────────────────────────────────

  function deepEqual(a, b) {
    if (a === b) return true;
    if (typeof a === 'number' && typeof b === 'number') return a === b;
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false;
      for (var i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
      return true;
    }
    if (isObj(a) && isObj(b) && !Array.isArray(a) && !Array.isArray(b)) {
      var ka = Object.keys(a), kb = Object.keys(b);
      if (ka.length !== kb.length) return false;
      for (var j = 0; j < ka.length; j++) {
        if (!(ka[j] in b)) return false;
        if (!deepEqual(a[ka[j]], b[ka[j]])) return false;
      }
      return true;
    }
    return false;
  }

  function sizeOf(v) {
    if (v == null) return -1;
    if (Array.isArray(v) || typeof v === 'string') return v.length;
    if (typeof v === 'object') return Object.keys(v).length;
    return -1;
  }

  function isEmpty(v) {
    if (v == null) return true;
    if (Array.isArray(v) || typeof v === 'string') return v.length === 0;
    if (typeof v === 'object') return Object.keys(v).length === 0;
    return false;
  }

  function toArray(v) {
    if (v === undefined || v === null) return [];
    return Array.isArray(v) ? v : [v];
  }

  function numOf(v) {
    if (typeof v === 'number') return v;
    if (typeof v === 'string' && v !== '' && !isNaN(Number(v))) return Number(v);
    return NaN;
  }

  // ─────────────────────────────────────────────────────────────
  // 递归下降求值
  // ─────────────────────────────────────────────────────────────

  function Parser(toks, root, cur) {
    this.t = toks; this.i = 0; this.root = root; this.cur = cur;
  }
  Parser.prototype.peek = function () { return this.t[this.i]; };
  Parser.prototype.next = function () { return this.t[this.i++]; };
  Parser.prototype.eof = function () { return this.i >= this.t.length; };

  Parser.prototype.parseExpr = function () { return this.parseOr(); };

  Parser.prototype.parseOr = function () {
    var left = this.parseAnd();
    while (!this.eof() && this.peek().t === 'op' && this.peek().v === '||') {
      this.next();
      var right = this.parseAnd();
      left = truthy(left) || truthy(right);
    }
    return left;
  };

  Parser.prototype.parseAnd = function () {
    var left = this.parseUnary();
    while (!this.eof() && this.peek().t === 'op' && this.peek().v === '&&') {
      this.next();
      var right = this.parseUnary();
      left = truthy(left) && truthy(right);
    }
    return left;
  };

  Parser.prototype.parseUnary = function () {
    if (!this.eof() && this.peek().t === 'op' && this.peek().v === '!') {
      this.next();
      return !truthy(this.parseUnary());
    }
    return this.parseComparison();
  };

  Parser.prototype.parseComparison = function () {
    var left = this.parseOperand();
    if (this.eof()) return left;
    var tk = this.peek();
    if (tk.t !== 'op') return left;
    var op = tk.v;
    // size / empty 是**二元**运算符（Sextant 语义）：
    //   @.tags size 3      → 左边 size == 3
    //   @.tags empty true  → 左边为空 == true
    if (op === 'SIZE' || op === 'EMPTY') {
      this.next();
      var right2 = this.parseOperand();
      if (op === 'SIZE') return sizeOf(left) === numOf(right2);
      return isEmpty(left) === truthy(right2);
    }
    this.next();
    var right = this.parseOperand();
    switch (op) {
      case '==': return deepEqual(left, right);
      case '!=': return !deepEqual(left, right);
      case '===': return deepEqual(left, right) && typeTag(left) === typeTag(right);
      case '!==': return !(deepEqual(left, right) && typeTag(left) === typeTag(right));
      case '<':  return cmpNum(left, right) < 0;
      case '<=': return cmpNum(left, right) <= 0;
      case '>':  return cmpNum(left, right) > 0;
      case '>=': return cmpNum(left, right) >= 0;
      case '=~': {
        // Sextant：模式在左或在右都支持
        if (left && left.__regex) return left.__regex.test(String(right == null ? '' : right));
        if (right && right.__regex) return right.__regex.test(String(left == null ? '' : left));
        return false;
      }
      case 'IN': return containsVal(right, left);
      case 'NIN': return !containsVal(right, left);
      case 'SUBSETOF': return subsetOf(left, right);
      case 'ANYOF': return anyOf(left, right);
      case 'NONEOF': return !anyOf(left, right);
      case 'EXISTS': return truthy(right) ? (left !== undefined) : (left === undefined);
      default: return false;
    }
  };

  function typeTag(v) {
    if (v === null || v === undefined) return 'null';
    if (Array.isArray(v)) return 'array';
    if (typeof v === 'number') return Number.isInteger(v) ? 'int' : 'double';
    if (typeof v === 'boolean') return 'boolean';
    if (typeof v === 'string') return 'string';
    if (typeof v === 'object') return 'object';
    return typeof v;
  }

  function truthy(v) {
    if (v === undefined || v === null) return false;
    if (typeof v === 'boolean') return v;
    if (typeof v === 'number') return v !== 0;
    if (typeof v === 'string') return v.length > 0;
    if (Array.isArray(v)) return v.length > 0;
    return true;
  }

  function cmpNum(a, b) {
    var x = numOf(a), y = numOf(b);
    if (isNaN(x) || isNaN(y)) return NaN;
    return x < y ? -1 : (x > y ? 1 : 0);
  }

  function containsVal(hay, needle) {
    if (!Array.isArray(hay)) return false;
    for (var i = 0; i < hay.length; i++) if (deepEqual(hay[i], needle)) return true;
    return false;
  }

  function subsetOf(sub, sup) {
    if (!Array.isArray(sub) || !Array.isArray(sup)) return false;
    for (var i = 0; i < sub.length; i++) {
      var found = false;
      for (var j = 0; j < sup.length; j++) if (deepEqual(sub[i], sup[j])) { found = true; break; }
      if (!found) return false;
    }
    return true;
  }

  function anyOf(a, b) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) if (deepEqual(a[i], b[j])) return true;
    }
    return false;
  }

  // 操作数：字面量 / 路径 / 尾部函数
  /** 抓一段配平的括号内容（返回含括号的内容） */
  Parser.prototype.captureBalanced = function (open, close) {
    var depth = 0, out = '', started = false;
    while (!this.eof()) {
      var t = this.next();
      if (t.t === 'punct' && t.v === open) { depth++; started = true; }
      if (t.t === 'punct' && t.v === close) { depth--; }
      // 统一输出成 **JSON 合法**的双引号字符串（单引号 JSON.parse 不认）
      if (t.t === 'str') { out += '"' + t.v.replace(/"/g, '\\"') + '"'; continue; }
      if (t.t === 'num') { out += t.v; continue; }
      if (t.t === 'id') { out += (t.v === 'true' ? 'true' : (t.v === 'false' ? 'false' : (t.v === 'null' ? 'null' : '"' + t.v + '"'))); continue; }
      if (t.t === 'op') { out += t.v; continue; }
      if (t.t === 'punct') { out += t.v; continue; }
      if (started) { /* 忽略其它 */ }
    }
    // out 里已经含 open/close，别再包一层
    return started ? out : null;
  };

  Parser.prototype.parseOperand = function () {
    var tk = this.next();
    if (!tk) return undefined;
    if (tk.t === 'num') return tk.v;
    if (tk.t === 'str') return tk.v;
    if (tk.t === 'regex') {
      try { return { __regex: new RegExp(tk.v, tk.flags || '') }; } catch (e) { return undefined; }
    }
    if (tk.t === 'id') {
      var name = tk.v;
      // true / false / null
      if (name === 'true') return true;
      if (name === 'false') return false;
      if (name === 'null') return null;
      if (name === 'size' || name === 'empty') {
        // 裸 size / empty（后面跟操作数）→ 当一元
        if (name === 'size') return sizeOf(this.parseOperand());
        return isEmpty(this.parseOperand());
      }
      // 路径：@ / $ 开头，或普通标识符（当属性名）
      var path = name;
      // 继续吃 .a.b / [0] / ['x'] 片段
      while (!this.eof()) {
        var p = this.peek();
        if (p.t === 'punct' && p.v === '.') {
          var nx = this.t[this.i + 1];
          if (nx && nx.t === 'id') { path += '.' + this.t[this.i + 1].v; this.i += 2; continue; }
          break;
        }
        if (p.t === 'punct' && p.v === '[') {
          // 找配对的 ]
          var depth = 0, j = this.i;
          while (j < this.t.length) {
            if (this.t[j].t === 'punct' && this.t[j].v === '[') depth++;
            else if (this.t[j].t === 'punct' && this.t[j].v === ']') { depth--; if (depth === 0) break; }
            j++;
          }
          if (j >= this.t.length) break;
          path += this.t.slice(this.i, j + 1).map(function (x) { return x.v; }).join('');
          this.i = j + 1;
          continue;
        }
        break;
      }
      // 尾部函数：path.min() / path.length()
      if (!this.eof() && this.peek().t === 'punct' && this.peek().v === '(') {
        var fname = path.split('.').pop();
        // 吃掉 ( args )
        this.next();
        var args = [];
        while (!this.eof() && !(this.peek().t === 'punct' && this.peek().v === ')')) {
          if (this.peek().t === 'punct' && this.peek().v === ',') { this.next(); continue; }
          args.push(this.parseOperand());
        }
        if (!this.eof()) this.next();   // )
        var base = (path === '@' || path === '$') ? this.cur : getPath(this.root, this.cur, path);
        return applyTailFn(fname, base, args);
      }
      if (path === '@') return this.cur;
      if (path === '$') return this.root;
      if (path.charAt(0) === '@') return getPath(this.root, this.cur, path.slice(1));
      if (path.charAt(0) === '$') return getPath(this.root, this.root, path.slice(1));
      return getPath(this.root, this.cur, '.' + path);
    }
    if (tk.t === 'punct' && tk.v === '(') {
      var v = this.parseExpr();
      if (!this.eof() && this.peek().t === 'punct' && this.peek().v === ')') this.next();
      return v;
    }
    // 数组字面量 [ ... ]  /  对象字面量 { ... }
    // ⭐ 栖阅(Sextant 路径层)在这里会切坏嵌套方括号，轻阅这层不受影响 → 轻阅比栖阅/An��顿都强
    if (tk.t === 'punct' && (tk.v === '[' || tk.v === '{')) {
      var open = tk.v, close = open === '[' ? ']' : '}';
      // ⚠️ this.next() 已经把 open 消费掉了 → 回退一个 token，
      //    否则 captureBalanced 看不到起始括号，started 永远是 false。
      this.i--;
      var raw = this.captureBalanced(open, close);
      if (raw !== null) {
        try { return JSON.parse(raw); } catch (e) { return undefined; }
      }
    }
    return undefined;
  };

  function applyTailFn(fname, base, args) {
    var arr = toArray(base);
    switch (fname) {
      case 'length': return Array.isArray(base) || typeof base === 'string' ? base.length : sizeOf(base);
      case 'min': return arr.length ? Math.min.apply(null, arr.map(numOf).filter(function (x) { return !isNaN(x); })) : undefined;
      case 'max': return arr.length ? Math.max.apply(null, arr.map(numOf).filter(function (x) { return !isNaN(x); })) : undefined;
      case 'avg': {
        var ns = arr.map(numOf).filter(function (x) { return !isNaN(x); });
        return ns.length ? ns.reduce(function (a, b) { return a + b; }, 0) / ns.length : undefined;
      }
      case 'stddev': {
        var vs = arr.map(numOf).filter(function (x) { return !isNaN(x); });
        if (!vs.length) return undefined;
        var m = vs.reduce(function (a, b) { return a + b; }, 0) / vs.length;
        var sd = Math.sqrt(vs.reduce(function (a, b) { return a + (b - m) * (b - m); }, 0) / vs.length);
        return sd;
      }
      case 'sum': return arr.map(numOf).filter(function (x) { return !isNaN(x); })
        .reduce(function (a, b) { return a + b; }, 0);
      case 'keys': return isObj(base) && !Array.isArray(base) ? Object.keys(base) : undefined;
      case 'concat': return arr.concat(args.length ? [args[0]] : []);
      case 'append': return arr.concat(args.length ? [args[0]] : []);
      default: return undefined;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 对外
  // ─────────────────────────────────────────────────────────────

  /** 求值一条过滤表达式（不含 ?( )），当前节点 cur */
  function evalFilter(expr, root, cur) {
    try {
      var toks = tokenize(expr);
      if (!toks.length) return false;
      var p = new Parser(toks, root, cur);
      return truthy(p.parseExpr());
    } catch (e) {
      return false;
    }
  }

  /** 判断一个元素是否满足过滤条件（root 是整棵 JSON，用于 $ 引用） */
  function testFilter(el, expr, root) {
    return evalFilter(expr, root === undefined ? el : root, el);
  }

  /** 表达式能否被完整解析（用来决定走新实现还是回落老实现） */
  function canParse(expr) {
    try {
      var toks = tokenize(expr);
      if (!toks.length) return false;
      // 用 dummy 上下文做**纯语法检查**：
      // 原来传 undefined 会让路径求值抛异常 → canParse 永远 false → 全部降级到老实现
      var p = new Parser(toks, {}, {});
      p.parseExpr();
      return p.eof();
    } catch (e) {
      return false;
    }
  }

  QR.sextantFilter = {
    eval: evalFilter,
    test: testFilter,
    canParse: canParse,
    tokenize: tokenize,
    _internals: { getPath: getPath, deepEqual: deepEqual, sizeOf: sizeOf, isEmpty: isEmpty }
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
