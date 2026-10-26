/* ============================================================
 * jsonpath.js —— JSONPath 子集
 *
 * 语料实测：9060 个真实书源里约 1.5 万条 JSONPath 规则，
 * 最常见的是递归下降 `$..list[*]`、切片 `[1:3]`、下标取负 `[-1]`。
 * 所以这几样是硬需求，不是锦上添花。
 *
 * 支持：$ .a  ['a'] ["a"]  ..a  ..*  ..[n]  [n]  [-n]  [a:b]  [a:b:c]  [*]  .*
 *       [a,b,c] 联合、?(基本比较) 过滤
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};

  function isObj(v) { return v !== null && typeof v === 'object'; }
  function toArr(v) { return Array.isArray(v) ? v : (v == null ? [] : [v]); }

  /** 把路径切成 step 序列 */
  function parse(path) {
    var s = String(path == null ? '' : path).trim();
    var steps = [], i = 0;

    if (s[0] === '$') i = 1;

    while (i < s.length) {
      var c = s[i];

      // 递归下降 ..
      if (c === '.' && s[i + 1] === '.') {
        i += 2;
        // 后面紧跟 [ 的情况交给循环里处理，这里只记「递归」
        if (s[i] === '*') { steps.push({ t: 'recurseAll' }); i++; continue; }
        var m = /^[\w\-一-龥]+/.exec(s.slice(i));
        if (m) { steps.push({ t: 'recurse', name: m[0] }); i += m[0].length; continue; }
        steps.push({ t: 'recurseAll' });   // 光秃秃的 ..
        continue;
      }

      // .name  或  .*
      if (c === '.') {
        i++;
        if (s[i] === '*') { steps.push({ t: 'wild' }); i++; continue; }
        var m2 = /^[\w\-一-龥]+/.exec(s.slice(i));
        if (m2) { steps.push({ t: 'child', name: m2[0] }); i += m2[0].length; continue; }
        continue;   // 落单的 '.'，跳过
      }

      // [ ... ]
      if (c === '[') {
        var end = s.indexOf(']', i);
        if (end < 0) break;
        var body = s.slice(i + 1, end).trim();
        steps.push(parseBracket(body));
        i = end + 1;
        continue;
      }

      // 裸 key（有些源不写 $）
      var m3 = /^[\w\-一-龥]+/.exec(s.slice(i));
      if (m3) { steps.push({ t: 'child', name: m3[0] }); i += m3[0].length; continue; }
      i++;
    }
    return steps;
  }

  function unquote(v) {
    v = String(v).trim();
    if ((v[0] === "'" && v[v.length - 1] === "'") || (v[0] === '"' && v[v.length - 1] === '"')) {
      return v.slice(1, -1);
    }
    return v;
  }

  function parseBracket(body) {
    // 过滤 ?(...)
    if (body[0] === '?') {
      return { t: 'filter', expr: body.slice(1).replace(/^\(|\)$/g, '') };
    }
    // 引号名
    if (/^['"]/.test(body)) return { t: 'child', name: unquote(body) };

    // 联合 a,b,c
    if (/^-?\d+\s*,\s*-?\d+/.test(body)) {
      return { t: 'union', items: body.split(',').map(function (x) { return parseInt(x, 10); }) };
    }
    // 切片 a:b:c
    if (body.indexOf(':') >= 0) {
      var parts = body.split(':');
      function num(x) {
        if (x === undefined || x === null) return null;
        x = String(x).trim();
        if (x === '') return null;
        var n = parseInt(x, 10);
        return isNaN(n) ? null : n;   // undefined→null，别变成 NaN 把整个切片吃掉
      }
      return { t: 'slice', a: num(parts[0]), b: num(parts[1]), c: num(parts[2]) };
    }
    if (body === '*') return { t: 'wild' };
    // 负下标
    if (/^-?\d+$/.test(body)) return { t: 'index', i: parseInt(body, 10) };
    return { t: 'child', name: unquote(body) };
  }

  /** 把「当前值」推进一步 */
  function apply(v, st, root) {
    switch (st.t) {
      case 'child':
        return isObj(v) && !(Array.isArray(v)) ? [v[st.name]].filter(function (x) { return x !== undefined; })
          : (Array.isArray(v) ? v.filter(function (e) { return isObj(e) && st.name in e; }).map(function (e) { return e[st.name]; }) : []);
      case 'wild':
        return Array.isArray(v) ? v.slice() : (isObj(v) ? Object.keys(v).map(function (k) { return v[k]; }) : []);
      case 'index':
        if (!Array.isArray(v)) return [];
        return [v[st.i < 0 ? v.length + st.i : st.i]].filter(function (x) { return x !== undefined; });
      case 'slice': {
        if (!Array.isArray(v)) return [];
        var n = v.length, a = st.a === null ? (st.c && st.c < 0 ? n : 0) : st.a;
        var b = st.b === null ? n : st.b;
        if (a < 0) a += n; if (b < 0) b += n;
        if (st.c === null || st.c === 1) return v.slice(Math.max(0, a), Math.max(0, b));
        var out = [];
        for (var k = a; st.c > 0 ? k < b : k > b; k += st.c) out.push(v[k]);
        return out;
      }
      case 'union':
        if (!Array.isArray(v)) return [];
        return st.items.map(function (i) { return v[i < 0 ? v.length + i : i]; })
          .filter(function (x) { return x !== undefined; });
      case 'filter':
        // 栖阅同款（Sextant 过滤表达式）优先；表达式解析不了就回落老实现，
        // 认不出来宁可放过也不误杀书源。
        if (QR.sextantFilter && QR.sextantFilter.canParse(st.expr)) {
          return toArr(v).filter(function (e) { return QR.sextantFilter.test(e, st.expr, root); });
        }
        return toArr(v).filter(function (e) { return testFilter(e, st.expr); });
      case 'recurse': {
        var out2 = [];
        (function walk(x) {
          if (!isObj(x)) return;
          if (!Array.isArray(x) && st.name in x) out2.push(x[st.name]);
          Object.keys(x).forEach(function (k) { walk(x[k]); });
        })(v);
        return out2;
      }
      case 'recurseAll': {
        var out3 = [];
        (function walk(x) {
          if (!isObj(x)) return;
          out3.push(x);
          Object.keys(x).forEach(function (k) { walk(x[k]); });
        })(v);
        return out3;
      }
      default: return [];
    }
  }

  /** ?(...) 里最常见的 @.field op value */
  function testFilter(el, expr) {
    var m = /^\s*@?\.?([\w\-\u4e00-\u9fa5]+)\s*(==|!=|>=|<=|>|<|=|!=)\s*(.+?)\s*$/.exec(String(expr));
    if (!m) return true;           // 认不出来的表达式一律放过，别误杀
    var key = m[1], op = m[2];
    var raw = m[3].trim().replace(/^['"]|['"]$/g, '');
    var num = parseFloat(raw), rhs = isNaN(num) ? raw : num;
    var val = isObj(el) ? el[key] : undefined;
    if (val === undefined) return false;
    switch (op) {
      case '==': case '=': return String(val) === String(rhs);
      case '!=': return String(val) !== String(rhs);
      case '>': return Number(val) > Number(rhs);
      case '<': return Number(val) < Number(rhs);
      case '>=': return Number(val) >= Number(rhs);
      case '<=': return Number(val) <= Number(rhs);
      default: return true;
    }
  }

  function query(data, path) {
    var p = String(path == null ? '' : path).trim();
    if (!p || p === '$') return isObj(data) ? [data] : toArr(data);
    var steps = parse(p);
    if (!steps.length) return [data];
    var cur = [data];
    for (var i = 0; i < steps.length; i++) {
      var next = [];
      for (var j = 0; j < cur.length; j++) {
        var r = apply(cur[j], steps[i], data);
        for (var k = 0; k < r.length; k++) if (next.indexOf(r[k]) < 0) next.push(r[k]);
      }
      cur = next;
      if (!cur.length) break;
    }
    return cur;
  }

  QR.jsonpath = {
    select: query,
    query: query,
    parsePath: parse,
    apply: apply,
    deepQuery: function (d, p) { return query(d, p); }
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
