#if canImport(JavaScriptCore) && !os(Linux)
import Foundation

/// 预置脚本：在 JavaScriptCore 中模拟书源常用的 Rhino/Java 能力
enum JSPrelude {
    /// 基础垫片（在注入 java/source 等对象之前执行）
    static let source = #"""
    (function (g) {
      function def(proto, name, fn) {
        if (Object.prototype.hasOwnProperty.call(proto, name)) return;
        Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true, enumerable: false });
      }
      // Java List 风格
      def(Array.prototype, 'size', function () { return this.length; });
      def(Array.prototype, 'get', function (i) { return this[i]; });
      def(Array.prototype, 'isEmpty', function () { return this.length === 0; });
      def(Array.prototype, 'add', function (a, b) {
        if (arguments.length > 1) { this.splice(a, 0, b); } else { this.push(a); }
        return true;
      });
      def(Array.prototype, 'addAll', function (list) { for (var i = 0; i < list.length; i++) this.push(list[i]); return true; });
      def(Array.prototype, 'contains', function (x) { return this.indexOf(x) >= 0; });
      def(Array.prototype, 'toArray', function () { return this.slice(); });
      def(Array.prototype, 'first', function () { return this[0]; });
      def(Array.prototype, 'last', function () { return this[this.length - 1]; });
      // jsoup Elements 风格
      def(Array.prototype, 'text', function () {
        return this.map(function (e) { return e && typeof e.text === 'function' ? e.text() : String(e); }).join(' ');
      });
      def(Array.prototype, 'attr', function (k) {
        for (var i = 0; i < this.length; i++) {
          var e = this[i];
          if (e && typeof e.hasAttr === 'function' && e.hasAttr(k)) return e.attr(k);
        }
        return '';
      });
      def(Array.prototype, 'select', function (css) {
        var out = [];
        this.forEach(function (e) { if (e && typeof e.select === 'function') out.push.apply(out, e.select(css)); });
        return out;
      });
      def(Array.prototype, 'html', function () {
        return this.map(function (e) { return e && typeof e.html === 'function' ? e.html() : String(e); }).join('\n');
      });
      def(Array.prototype, 'outerHtml', function () {
        return this.map(function (e) { return e && typeof e.outerHtml === 'function' ? e.outerHtml() : String(e); }).join('\n');
      });
      def(Array.prototype, 'eachText', function () {
        return this.map(function (e) { return e && typeof e.text === 'function' ? e.text() : String(e); });
      });
      // Java String 风格
      def(String.prototype, 'equals', function (o) { return String(this) === String(o); });
      def(String.prototype, 'equalsIgnoreCase', function (o) { return String(this).toLowerCase() === String(o).toLowerCase(); });
      def(String.prototype, 'isEmpty', function () { return this.length === 0; });
      def(String.prototype, 'contains', function (s) { return this.indexOf(String(s)) >= 0; });
      def(String.prototype, 'matches', function (re) { return new RegExp('^(?:' + re + ')$').test(String(this)); });

      // 带 Java Map 方法的对象
      g.__makeJavaMap = function (obj) {
        if (obj == null) return obj;
        function m(name, fn) { Object.defineProperty(obj, name, { value: fn, writable: true, configurable: true, enumerable: false }); }
        m('get', function (k) { var v = obj[k]; return v === undefined ? null : v; });
        m('getOrDefault', function (k, d) { return Object.prototype.hasOwnProperty.call(obj, k) ? obj[k] : d; });
        m('put', function (k, v) { var old = obj[k]; obj[k] = v; return old === undefined ? null : old; });
        m('putAll', function (o) { for (var k in o) obj[k] = o[k]; });
        m('containsKey', function (k) { return Object.prototype.hasOwnProperty.call(obj, k); });
        m('remove', function (k) { var old = obj[k]; delete obj[k]; return old === undefined ? null : old; });
        m('keySet', function () { return Object.keys(obj); });
        m('values', function () { return Object.keys(obj).map(function (k) { return obj[k]; }); });
        m('size', function () { return Object.keys(obj).length; });
        m('isEmpty', function () { return Object.keys(obj).length === 0; });
        m('entrySet', function () {
          return Object.keys(obj).map(function (k) {
            return { getKey: function () { return k; }, getValue: function () { return obj[k]; }, key: k, value: obj[k] };
          });
        });
        return obj;
      };

      g.console = {
        log: function () { java.log(Array.prototype.join.call(arguments, ' ')); },
        info: function () { java.log(Array.prototype.join.call(arguments, ' ')); },
        warn: function () { java.log(Array.prototype.join.call(arguments, ' ')); },
        error: function () { java.log(Array.prototype.join.call(arguments, ' ')); },
        debug: function () {}
      };
    })(this);
    """#

    /// Java 类垫片（依赖 `__native` 原生辅助函数）
    static let packages = #"""
    (function (g) {
      var N = g.__native;
      function def(proto, name, fn) {
        if (Object.prototype.hasOwnProperty.call(proto, name)) return;
        Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true, enumerable: false });
      }
      def(String.prototype, 'getBytes', function (cs) { return N.strToBytes(String(this), cs ? String(cs) : 'UTF-8'); });

      // 直接调用返回原始字符串（被 JavaImporter 导入后会遮蔽全局 String），new 调用返回 String 对象
      function JString(a, b) {
        var s;
        if (arguments.length === 0) {
          s = '';
        } else if (a != null && typeof a === 'object' && typeof a.length === 'number' && !(a instanceof String)) {
          s = N.bytesToStr(Array.prototype.slice.call(a), b ? String(b) : 'UTF-8');
        } else {
          s = String(a);
        }
        return new.target ? new String(s) : s;
      }
      JString.prototype = String.prototype;
      JString.fromCharCode = String.fromCharCode;
      JString.fromCodePoint = String.fromCodePoint;
      JString.raw = String.raw;
      JString.valueOf = function (v) { return String(v); };
      JString.format = function (fmt) {
        var args = Array.prototype.slice.call(arguments, 1), i = 0;
        return String(fmt).replace(/%(\d+\$)?[-#+ 0,(]*\d*(?:\.\d+)?([sdfxXc%])/g, function (all, pos, t) {
          if (t === '%') return '%';
          var v = pos ? args[parseInt(pos) - 1] : args[i++];
          if (t === 'd') return String(Math.trunc(Number(v)));
          if (t === 'x') return (Number(v) >>> 0).toString(16);
          if (t === 'X') return (Number(v) >>> 0).toString(16).toUpperCase();
          return String(v);
        });
      };
      JString.join = function (sep, list) { return Array.prototype.slice.call(list).join(sep); };

      function JStringBuilder(init) {
        var s = init == null ? '' : String(init);
        return {
          append: function (x) { s += String(x); return this; },
          toString: function () { return s; },
          length: function () { return s.length; },
          reverse: function () { s = s.split('').reverse().join(''); return this; },
          insert: function (i, x) { s = s.slice(0, i) + String(x) + s.slice(i); return this; },
          setLength: function (n) { s = s.slice(0, n); },
          charAt: function (i) { return s.charAt(i); }
        };
      }

      var System = {
        arraycopy: function (src, sp, dest, dp, len) { for (var i = 0; i < len; i++) dest[dp + i] = src[sp + i]; },
        currentTimeMillis: function () { return Date.now(); },
        nanoTime: function () { return Date.now() * 1e6; },
        getProperty: function () { return null; },
        lineSeparator: function () { return '\n'; }
      };
      var Thread = { sleep: function (ms) { N.sleep(Number(ms) || 0); } };
      function pad(a, n) { while (a.length < n) a.push(0); return a; }
      var Arrays = {
        copyOf: function (a, n) { return pad(Array.prototype.slice.call(a, 0, n), n); },
        copyOfRange: function (a, s, e) { return pad(Array.prototype.slice.call(a, s, e), e - s); },
        toString: function (a) { return '[' + Array.prototype.join.call(a, ', ') + ']'; },
        equals: function (a, b) {
          if (a.length !== b.length) return false;
          for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
          return true;
        },
        fill: function (a, v) { for (var i = 0; i < a.length; i++) a[i] = v; },
        asList: function () { return Array.prototype.slice.call(arguments.length === 1 && Array.isArray(arguments[0]) ? arguments[0] : arguments); }
      };
      var Integer = {
        parseInt: function (s, r) { return parseInt(s, r || 10); },
        valueOf: function (s, r) { return parseInt(s, r || 10); },
        toHexString: function (n) { return (Number(n) >>> 0).toString(16); },
        toBinaryString: function (n) { return (Number(n) >>> 0).toString(2); },
        toString: function (n, r) { return Number(n).toString(r || 10); },
        MAX_VALUE: 2147483647, MIN_VALUE: -2147483648
      };
      var JLong = {
        parseLong: function (s, r) { return parseInt(s, r || 10); },
        valueOf: function (s) { return Number(s); },
        toString: function (n, r) { return Number(n).toString(r || 10); },
        toHexString: function (n) { return Number(n).toString(16); }
      };
      var JDouble = { parseDouble: function (s) { return parseFloat(s); }, valueOf: function (s) { return parseFloat(s); } };
      var JBoolean = { parseBoolean: function (s) { return String(s).toLowerCase() === 'true'; } };
      var UUID = { randomUUID: function () { return { toString: function () { return java.randomUUID(); } }; } };
      // 普通对象加 Map 方法，传给原生接口时按对象读取
      function JHashMap(init) {
        var obj = {};
        if (init) for (var k in init) obj[k] = init[k];
        return g.__makeJavaMap(obj);
      }

      function SecretKeySpec(key, alg) {
        return { key: key, algorithm: String(alg), getEncoded: function () { return key; }, getAlgorithm: function () { return String(alg); } };
      }
      function IvParameterSpec(iv) { return { iv: iv, getIV: function () { return iv; } }; }
      function GCMParameterSpec(tLen, iv) { return { tLen: tLen, iv: iv, getIV: function () { return iv; }, getTLen: function () { return tLen; } }; }
      var Cipher = {
        ENCRYPT_MODE: 1, DECRYPT_MODE: 2,
        getInstance: function (transformation) {
          return {
            transformation: String(transformation), opmode: 0, key: null, iv: null, tLen: 128, aad: [], buf: [],
            init: function (mode, key, spec) {
              this.opmode = mode;
              this.key = key && key.key !== undefined ? key.key : key;
              if (spec) {
                this.iv = spec.iv !== undefined ? spec.iv : spec;
                if (spec.tLen) this.tLen = spec.tLen;
              }
            },
            updateAAD: function (a) { this.aad = this.aad.concat(Array.prototype.slice.call(a)); },
            update: function (d) { this.buf = this.buf.concat(Array.prototype.slice.call(d)); return []; },
            doFinal: function (d) {
              var data = this.buf.concat(d ? Array.prototype.slice.call(typeof d === 'string' ? N.strToBytes(d, 'UTF-8') : d) : []);
              this.buf = [];
              return N.cipher(this.transformation, this.opmode, this.key, this.iv, this.tLen, this.aad, data);
            },
            getIV: function () { return this.iv; }
          };
        }
      };
      var MessageDigest = {
        getInstance: function (alg) {
          var buf = [];
          return {
            update: function (b) {
              if (typeof b === 'string') b = N.strToBytes(b, 'UTF-8');
              buf = buf.concat(Array.prototype.slice.call(b));
            },
            digest: function (b) {
              if (b !== undefined) this.update(b);
              var r = N.digest(String(alg), buf);
              buf = [];
              return r;
            },
            reset: function () { buf = []; }
          };
        }
      };
      var Mac = {
        getInstance: function (alg) {
          var key = null, buf = [];
          return {
            init: function (k) { key = k && k.key !== undefined ? k.key : k; },
            update: function (b) {
              if (typeof b === 'string') b = N.strToBytes(b, 'UTF-8');
              buf = buf.concat(Array.prototype.slice.call(b));
            },
            doFinal: function (b) {
              if (b !== undefined) this.update(b);
              var r = N.hmac(String(alg), key, buf);
              buf = [];
              return r;
            }
          };
        }
      };
      var Base64 = {
        DEFAULT: 0, NO_PADDING: 1, NO_WRAP: 2, CRLF: 4, URL_SAFE: 8, NO_CLOSE: 16,
        encodeToString: function (b, f) { return N.base64Encode(typeof b === 'string' ? N.strToBytes(b, 'UTF-8') : Array.prototype.slice.call(b), f || 0); },
        encode: function (b, f) { return N.strToBytes(Base64.encodeToString(b, f), 'UTF-8'); },
        decode: function (s, f) {
          if (typeof s !== 'string') s = N.bytesToStr(Array.prototype.slice.call(s), 'UTF-8');
          return N.base64Decode(String(s), f || 0);
        }
      };
      var JBase64 = {
        getEncoder: function () {
          return {
            encodeToString: function (b) { return Base64.encodeToString(b, 2); },
            encode: function (b) { return Base64.encode(b, 2); }
          };
        },
        getDecoder: function () { return { decode: function (s) { return Base64.decode(s, 0); } }; },
        getMimeDecoder: function () { return { decode: function (s) { return Base64.decode(s, 0); } }; },
        getUrlEncoder: function () {
          return {
            encodeToString: function (b) { return Base64.encodeToString(b, 10); },
            withoutPadding: function () { return { encodeToString: function (b) { return Base64.encodeToString(b, 11); } }; }
          };
        },
        getUrlDecoder: function () { return { decode: function (s) { return Base64.decode(s, 8); } }; }
      };
      var URLEncoder = { encode: function (s, enc) { return N.urlEncode(String(s), enc ? String(enc) : 'UTF-8'); } };
      var URLDecoder = { decode: function (s, enc) { return N.urlDecode(String(s), enc ? String(enc) : 'UTF-8'); } };
      function JURL(spec, rel) {
        var href = rel !== undefined ? N.resolveURL(String(spec), String(rel)) : String(spec);
        var p = N.parseURL(href);
        if (!p) throw new Error('java.net.MalformedURLException: ' + href);
        // Rhino 会把 getter 暴露为同名属性，这里两种写法都支持
        return {
          protocol: p.protocol, host: p.host, port: p.port, path: p.path, query: p.query, ref: p.ref,
          authority: p.authority, file: p.query == null ? p.path : p.path + '?' + p.query,
          getProtocol: function () { return p.protocol; },
          getHost: function () { return p.host; },
          getPort: function () { return p.port; },
          getDefaultPort: function () { return p.protocol === 'https' ? 443 : 80; },
          getPath: function () { return p.path; },
          getQuery: function () { return p.query; },
          getRef: function () { return p.ref; },
          getAuthority: function () { return p.authority; },
          getFile: function () { return p.query == null ? p.path : p.path + '?' + p.query; },
          toString: function () { return href; },
          toExternalForm: function () { return href; }
        };
      }
      var StandardCharsets = { UTF_8: 'UTF-8', ISO_8859_1: 'ISO-8859-1', US_ASCII: 'US-ASCII', UTF_16: 'UTF-16', UTF_16LE: 'UTF-16LE', UTF_16BE: 'UTF-16BE' };
      var Charset = { forName: function (n) { return String(n); }, defaultCharset: function () { return 'UTF-8'; } };
      var Jsoup = {
        parse: function (html, base) { return N.jsoupParse(String(html), base ? String(base) : ''); },
        parseBodyFragment: function (html) { return N.jsoupParse(String(html), ''); },
        clean: function (html) { return String(html).replace(/<[^>]+>/g, ''); }
      };

      var HttpUrl = {
        parse: function (u) {
          var p = N.parseURL(String(u));
          if (!p || (p.protocol !== 'http' && p.protocol !== 'https')) return null;
          return {
            host: function () { return p.host; },
            scheme: function () { return p.protocol; },
            port: function () { return p.port > 0 ? p.port : (p.protocol === 'https' ? 443 : 80); },
            encodedPath: function () { return p.path; },
            query: function () { return p.query; },
            topPrivateDomain: function () { return N.topPrivateDomain(p.host); },
            toString: function () { return String(u); }
          };
        }
      };

      var pkgs = {
        okhttp3: { HttpUrl: HttpUrl },
        java: {
          lang: {
            String: JString, StringBuilder: JStringBuilder, StringBuffer: JStringBuilder, System: System, Thread: Thread,
            Integer: Integer, Long: JLong, Double: JDouble, Boolean: JBoolean, Math: Math
          },
          util: { Arrays: Arrays, Base64: JBase64, UUID: UUID, Date: Date, HashMap: JHashMap, LinkedHashMap: JHashMap },
          net: { URLEncoder: URLEncoder, URLDecoder: URLDecoder, URL: JURL },
          nio: { charset: { StandardCharsets: StandardCharsets, Charset: Charset } },
          security: { MessageDigest: MessageDigest }
        },
        javax: { crypto: { Cipher: Cipher, Mac: Mac, spec: { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec, GCMParameterSpec: GCMParameterSpec } } },
        android: { util: { Base64: Base64 } },
        org: { jsoup: { Jsoup: Jsoup } }
      };
      (function tag(node, path) {
        for (var k in node) {
          var v = node[k];
          if (v == null) continue;
          if (/^[A-Z]/.test(k)) {
            try { Object.defineProperty(v, '__javaName', { value: k, enumerable: false, configurable: true }); } catch (e) {}
          } else if (typeof v === 'object') {
            tag(v, path + '.' + k);
          }
        }
      })(pkgs, '');
      g.Packages = pkgs;
      g.javax = pkgs.javax;
      g.org = pkgs.org;
      g.android = pkgs.android;

      function importInto(target, args) {
        for (var i = 0; i < args.length; i++) {
          var c = args[i];
          if (c == null) continue;
          if (c.__javaName) { target[c.__javaName] = c; continue; }
          for (var k in c) target[k] = c[k];
        }
      }
      g.JavaImporter = function () {
        var imp = {};
        Object.defineProperty(imp, 'importClass', { value: function () { importInto(imp, arguments); }, enumerable: false });
        Object.defineProperty(imp, 'importPackage', { value: function () { importInto(imp, arguments); }, enumerable: false });
        importInto(imp, arguments);
        return imp;
      };
      g.importClass = function () { importInto(g, arguments); };
      g.importPackage = function () { importInto(g, arguments); };
    })(this);
    """#
}

#endif  // #if canImport(JavaScriptCore) && !os(Linux)
