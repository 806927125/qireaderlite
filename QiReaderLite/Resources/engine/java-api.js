/* ============================================================
 * java-api.js —— 站方书源里 java.* 的实现
 *
 * 一切出网请求都走原生桥（沙盒里的 fetch 会被 CORS/ATS 卡死，
 * 也没法复用 WKWebView 的 Cookie 罐），所以 java.ajax 这类必须
 * 转发给 NativeBridge。
 * ============================================================ */
(function (g) {
  'use strict';
  var QR = g.QR = g.QR || {};

  var seq = 0;
  var pending = {};

  function nativeCall(fn, args, timeoutMs) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      var h = g.webkit && g.webkit.messageHandlers && g.webkit.messageHandlers.qr;
      if (!h) { reject(new Error('原生桥不可用')); return; }
      var timer = setTimeout(function () {
        if (pending[id]) { delete pending[id]; reject(new Error('原生调用超时: ' + fn)); }
      }, timeoutMs || 40000);
      pending[id] = function (v) { clearTimeout(timer); resolve(v); };
      h.postMessage({ id: id, fn: fn, args: args || {} });
    });
  }
  g.__qrResolve = function (id, value) {
    var f = pending[id];
    if (!f) return;
    delete pending[id];
    f(value);
  };

  /* ---------------- 消息捕获：把站方吐出来的话留住 ---------------- */

  /**
   * 站方书源**只**用 java.toast / java.log 报结果，尤其是登录：
   *     java.toast("\n\n✅️登录成功")     ← 成功
   *     java.toast("\n\n💔登录失败，请重试！") ← 失败
   *     java.log(tips)                   ← 一整张会员卡片
   *
   * 以前这些只弹个 toast 就没了 → 用户只知道「执行完成」，
   * **完全不知道登录到底成没成功**（登录面板那句还是我们自己编的）。
   *
   * 所以 op 期间装一个 sink，把原文攒起来回传给原生侧。
   */
  QR.__qrMsgSink = null;

  /**
   * **暂存区** —— 两遍跑的第一遍，消息先存这儿，跑完再决定要不要交出去。
   *
   * 为什么需要：两遍跑的第一遍 ajax 是**假的**（只录 URL 不发），
   * 站方解析失败会报「登录失败 / JSON Parse error」—— 那是**假报错**，
   * 绝不能给用户看。
   *
   * 但「第一遍一律静音」有个致命副作用：**没用到 ajax 的第一遍，
   * 它的结果是真的，也被一起吃掉了**。
   *   典型：站方 login() 发现邮箱密码为空 → toast「请先填写邮箱和密码」
   *   → 这一遍没有 ajax → 没有第二遍 → 那句话永远不出现。
   *
   * 所以改成：跑完这一遍再看有没有录到 ajax
   *   · 录到了 → 这一遍是假的 → 消息丢掉
   *   · 没录到 → 这一遍是真的 → 消息交出去
   */
  var MSG_HOLD = null;

  function pushMsg(m, kind) {
    var s = String(m == null ? '' : m);
    if (MSG_HOLD) {
      try { MSG_HOLD.list.push(s); MSG_HOLD.kinds.push(kind || 'log'); } catch (e) {}
      return;
    }
    var sink = QR.__qrMsgSink;
    if (!sink) return;
    try { sink.push(s); } catch (e) {}
  }
  QR.__qrPushMsg = pushMsg;

  /** 开始暂存（runJs 每一遍调用） */
  QR.__qrHoldBegin = function () {
    MSG_HOLD = { list: [], kinds: [] };
    return MSG_HOLD;
  };

  /**
   * 结束暂存：keep=true 才把消息交出去（而且是**这一遍结束之后**才交）。
   *
   * ⚠️⚠️ 为什么「结束之后」才交：
   *    两遍跑里，中间遍的 ajax 结果是**假的**（还没抓回来）→ 站方据此报的错也是假的。
   *    真实例子（🍅番茄登录）：
   *        第 1 遍：弹浏览器 → 用户登录 → sessionid 合并回快照
   *        第 2 遍：ajax 的 URL 变了（带上了真 cookie）→ 又是假的 → 站方报
   *                 「未获取到登录凭据，登录失败」❌ **假报错**
   *        第 3 遍：ajax 命中缓存 → 真结果 → 「欢迎 XXX 登录成功」✅
   *    以前假报错**先弹出来**，用户会以为登录失败了。
   *    现在：只有**最后一遍**的消息会交出去（原生 toast/log + sink）✅
   */
  QR.__qrHoldEnd = function (keep) {
    var h = MSG_HOLD || { list: [], kinds: [] };
    MSG_HOLD = null;
    if (keep && h.list.length) {
      var sink = QR.__qrMsgSink;
      if (sink) { try { Array.prototype.push.apply(sink, h.list); } catch (e) {} }
      // 原生侧也在这时候才显示（之前是每遍都显示 → 中间遍的假报错会误导用户）
      for (var i = 0; i < h.list.length; i++) {
        try {
          if (h.kinds[i] === 'toast') nativeCall('toast', { msg: h.list[i] });
          else nativeCall('log', { msg: h.list[i] });
        } catch (e) {}
      }
    }
    return h.list;
  };

  /* ---------------- 同步原生通道（window.prompt） ---------------- */

  /**
   * **同步**调原生能力。
   *
   * 为什么需要：Legado 的部分 `java.*` 是**同步**语义，站方在同一个表达式里就用了：
   *     java.timeFormat(res.register_time*1000).padEnd(20, "\t")
   * `.padEnd` 必须当场拿到那个字符串 → postMessage（异步）做不到。
   * WKWebView 里唯一能同步拿到原生返回值的口子就是 `window.prompt`
   * （原生侧在 `RuleSandbox` 的 WKUIDelegate 里**同步**回 completionHandler）。
   *
   * 实现在 Swift（`Core/LegadoCompat.swift`），JS 这边只转发。
   */
  /**
   * ⚠️⚠️ **默认关闭！**
   *
   * window.prompt 是 WKWebView 里唯一能同步拿到原生返回值的口子，
   * 但它**有把 JS 线程永久卡死的风险**：万一原生那边没回调（WebKit 的行为、
   * 或 delegate 没被问到），`window.prompt` 就永远不返回 →
   * 站方 JS 线程死在那里 → 引擎彻底死掉 → 后面所有 op 排队 →
   * **App 点什么都没反应**（真机踩过：toast 闪一下，之后全卡）。
   *
   * ⇒ 默认走**纯 JS 兜底**（语义跟 Swift 侧一字不差，已被 Swift 单测验证），
   *    想要「原生 Swift 实现」可以在自检面板里打开开关试。
   *    ⚠️ 开关打开后如果又卡了 → 「重置引擎」按钮能救回来。
   */
  QR.__qrSyncEnabled = false;

  QR.__qrSync = function (fn, args) {
    if (!QR.__qrSyncEnabled) return null;
    try {
      if (typeof g.prompt !== 'function') return null;
      var raw = g.prompt('__qrSync__' + JSON.stringify({ fn: fn, args: args || {} }));
      if (raw == null) return null;
      return JSON.parse(raw);
    } catch (e) {
      return null;
    }
  };

  /**
   * Legado 的 cache（KV）—— 存储在 Swift 侧（UserDefaults）
   *
   * ⚠️ 这里**不用同步通道**（window.prompt）：cache 站方是当语句用的，
   *    返回值没人要 → 异步 nativeCall 就够 ✅
   *    而同步通道是**可能把 JS 线程卡死**的（prompt 不回调就永远挂着）
   *    → 少一个调用点少一个风险点。
   */
  g.cache = {
    put: function (k, v) {
      // 异步丢给原生（能力实现在 Swift：Core/LegadoCompat.swift 的 Cache）
      try { nativeCall('cachePut', { key: String(k), value: String(v == null ? '' : v) }); } catch (e) {}
      // ⚠️ 站方（🍅大灰狼）的 putLoginInfo 会把**加密后**的登录信息存进 cache，
      //    而它自己从来不读回（没有 cache.get）；轻阅的登录信息必须留在
      //    `source.putLoginInfo`（书源登录信息表），否则下次启动
      //    `login()` 读 `source.getLoginInfo()` 会拿到空 → **登录态丢失**。
      //    所以这里存完仍要抛错，好让站方走那条 fallback（行为零变化）。
      throw new Error('轻阅的登录信息请走 source.putLoginInfo（cache 仅作通用 KV）');
    },
    get: function (k, d) {
      // 同步读不到（异步桥）→ 返回默认值（站方读 cache 的场景极少）
      try { if (QR.__qrCacheSync && typeof QR.__qrCacheSync.get === 'function') { return QR.__qrCacheSync.get(k, d); } } catch (e) {}
      return d == null ? '' : d;
    },
    remove: function (k) {
      try { nativeCall('cacheRemove', { key: String(k) }); } catch (e) {}
      return true;
    }
  };

  /* ---------------- base64：三级兜底 ---------------- */

  /**
   * `java.timeFormat` 的**纯 JS 兜底**（同步通道不可用时用）。
   * 语义必须跟 Swift 侧（`Core/LegadoCompat.swift`）一致：
   * 数字 → "yyyy-MM-dd HH:mm:ss"；其它字符串 → epoch 毫秒。
   */
  function javaTimeFormatFallback(input) {
    var s = String(input == null ? '' : input).trim();
    if (!s) return 0;
    if (/^\d+$/.test(s)) {
      var n = parseInt(s, 10);
      var ms = (s.length <= 10 ? n * 1000 : n);
      return fmtDateTime(ms);
    }
    var m = s.match(/(\d{4})[-\/年](\d{1,2})[-\/月](\d{1,2})日?(?:[T\s]+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
    if (m) {
      return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
    }
    var d = new Date(s);
    var t = d.getTime();
    return isNaN(t) ? 0 : t;
  }

  function fmtDateTime(ms) {
    var d = new Date(ms);
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
           ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  /**
   * base64 载荷归一化 —— **URL 里被转义/换过字符的载荷也得能解**
   *
   * ⚠️⚠️ 真机 2026-10-21 踩到的：
   *   大灰狼的 bookUrl 是 `data:;base64,<载荷>`，载荷里**有 + 和 /**（中文摘要 base64 出来的）。
   *   这个字符串当 URL 走一圈，'+' 可能被 URL 解码成**空格**、或被转义成 **%2B**。
   *   而老的 b64decode：空格直接**删掉**、非法字符**静默跳过** →
   *   解出来是**乱码**（不报错！）→ 站方 `JSON.parse(...)` 抛
   *   「Unable to parse JSON string」→ 详情页整条规则静默失效。
   *   ⇒ 静默跳过是最坏的失败方式：看起来像服务器返回了坏数据。
   */
  function b64normalize(s) {
    s = String(s == null ? '' : s);
    // ① 百分号转义还原（只还原成 base64 合法字符的那些）
    try {
      s = s.replace(/%([0-9A-Fa-f]{2})/g, function (m, h) {
        var c = String.fromCharCode(parseInt(h, 16));
        return /[A-Za-z0-9+\/=_-]/.test(c) ? c : m;
      });
    } catch (e) { /* 忽略 */ }
    // ② URL 安全字符 → 标准 base64
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    // ③ 空格还原成 '+'（URL 解码把 '+' 变成空格的经典坑）
    s = s.replace(/ /g, '+');
    return s;
  }

  /** 解出来的东西「像不像人话」——有控制字符就是解歪了 */
  function looksLikeText(s) {
    if (!s) return false;
    return !/[\x00-\x08\x0B\x0C\x0E-\x1F]/.test(String(s));
  }

  function b64decode(s) {
    s = b64normalize(s).replace(/\s/g, '');
    // ⚠️⚠️⚠️ **先校验字符合法性**（2026-10-22 真机栽在这）
    //   以前非法字符被 `manualB64ToBytes` **静默跳过**（`if (v < 0) continue;`）
    //   ⇒ 返回的是**乱码**（不是失败！）⇒ 站方拿乱码去 `JSON.parse`
    //   ⇒ 炸出「天书错」⇒ 整条规则静默失效 ⇒ 🍅大灰狼**目录 0 章** ⭐
    //
    //   ⚠️ 关键：聚合源的 data: 伪 URL 里写着 `;base64,`，
    //      但**载荷其实是 hex**（站方用 `java.hexDecodeToString` 解，
    //      那个函数内部会「不是合法 hex 就按 base64 再试一次」）
    //   ⇒ 宿主**不能盲解 base64** ⇒ 解不了就**明确失败**，
    //      让上层（hexDecodeToString）改走 hex 分支 ✅
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s)) return '';
    // 1) 原生
    if (QR.java && QR.java._b64Dec) {
      try { var r = QR.java._b64Dec(s); if (r != null) return r; } catch (e) {}
    }
    // 2) atob（WKWebView 有，老 WebView 可能没有）
    if (typeof g.atob === 'function') {
      try {
        var bin = g.atob(s), arr = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
        return utf8Decode(arr);
      } catch (e) {}
    }
    // 3) 纯 JS 查表 + 分块，避免大字符串爆栈
    return utf8Decode(manualB64ToBytes(s));
  }

  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function manualB64ToBytes(s) {
    s = s.replace(/=+$/, '');
    var out = new Uint8Array(Math.floor(s.length * 3 / 4));
    var o = 0, buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      var v = B64C.indexOf(s[i]);
      if (v < 0) continue;
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; out[o++] = (buf >> bits) & 0xFF; }
    }
    return out.subarray(0, o);
  }

  function b64encode(str) {
    var bytes = utf8Encode(String(str == null ? '' : str));
    var CH = 0x8000, parts = [];
    for (var i = 0; i < bytes.length; i += CH) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CH)));
    }
    var bin = parts.join('');
    if (typeof g.btoa === 'function') { try { return g.btoa(bin); } catch (e) {} }
    var out = '';
    for (var j = 0; j < bin.length; j += 3) {
      var n = (bin.charCodeAt(j) << 16) | ((bin.charCodeAt(j + 1) || 0) << 8) | (bin.charCodeAt(j + 2) || 0);
      out += B64C[(n >> 18) & 63] + B64C[(n >> 12) & 63] + (j + 1 < bin.length ? B64C[(n >> 6) & 63] : '=') + (j + 2 < bin.length ? B64C[n & 63] : '=');
    }
    return out;
  }

  function utf8Encode(s) {
    if (typeof TextEncoder === 'function') return new TextEncoder().encode(s);
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        var c2 = s.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3FF) << 10) + (c2 & 0x3FF);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }

  function utf8Decode(bytes) {
    if (typeof TextDecoder === 'function') { try { return new TextDecoder('utf-8').decode(bytes); } catch (e) {} }
    var s = '', CH = 0x8000, parts = [];
    for (var i = 0; i < bytes.length; i += CH) parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CH)));
    return decodeURIComponent(escape(parts.join('')));
  }

  /* ---------------- HTTP ---------------- */

  /**
   * ⭐⭐⭐ **站方 jsLib 的线路列表**（`var host = [...]`）
   *
   * 站方 jsLib 是**间接 eval** 定义的 ⇒ `var host` 落在**全局作用域** ⇒ 这里能读到。
   * ⇒ 宿主就能在「这条线路挂了」时**自动换一条**，
   *    不依赖站方规则里有没有写 catch 换线 ⭐
   */
  function stationHosts() {
    // ⚠️⚠️ **只认 `QR.__qrStationHosts`**（由 ensureJsLib 从**当次书源**的 jsLib 里取）
    //   ⛔ **绝不能回落到全局 `host`** —— 那是 jsLib 的全局变量，
    //      换书源后**上一个源会残留** ⇒ 别的书源会被拿去做换线重试 ⇒ 串台 ❗
    //      （2026-10-22 用户反馈「用了大灰狼之后别的书源加载就有问题」的另一半）
    try {
      if (QR.__qrStationHosts && QR.__qrStationHosts.length) return QR.__qrStationHosts.slice();
    } catch (e) {}
    return null;
  }

  /** URL 里可能粘着 Legado 的 `,{json}` 选项后缀 ⇒ 换 host 时要保住它 */
  function splitUrlOption(url) {
    var s = String(url || '');
    var m = /,\s*\{/.exec(s);
    if (!m) return { url: s, opt: '' };
    return { url: s.slice(0, m.index), opt: s.slice(m.index) };
  }

  /** 把 URL 的 host 换成另一条线路（保住 path/query/选项后缀） */
  function swapHost(url, newHost) {
    var sp = splitUrlOption(url);
    try {
      var u = new URL(sp.url);
      var nh = new URL(newHost);
      u.protocol = nh.protocol;
      u.host = nh.host;
      u.port = nh.port;
      return u.href + sp.opt;
    } catch (e) {
      return url;
    }
  }

  /** 除当前 host 之外的其它候选线路 */
  function otherHosts(url) {
    var list = stationHosts();
    if (!list || !list.length) return [];
    var cur = '';
    try { cur = new URL(splitUrlOption(url).url).host; } catch (e) {}
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var h = String(list[i] || '');
      if (!h) continue;
      var hh = '';
      try { hh = new URL(h).host; } catch (e) { continue; }
      if (hh && hh === cur) continue;
      out.push(h);
    }
    return out;
  }

  function rawRequest(url, method, headers, data, timeout, _swapped) {
    // ⚠️⚠️⚠️ **`data:` 伪 URL 绝不能真去 fetch**（2026-10-22 真机栽在这）
    //   聚合源（🍅大灰狼）的 bookUrl / tocUrl / chapterUrl 全是这种：
    //       data:;base64,<载荷>,{"type":"qingtian2"}
    //   ⇒ 原生 URLSession 去 fetch 它 ⇒ Foundation 解 data: URL 的 base64
    //      ⇒ 载荷不是合法 base64 ⇒ 抛「**illegal base64 data at input byte 9**」
    //      ⇒ 还会**冒成一个 toast**（用户看到的就是这个）⇒ 规则整条挂掉 ⭐
    //   ⇒ 这里**直接把载荷当响应体返回**（跟引擎 fetchPage 的处理一致）：
    //      站方的语义就是「data: 伪 URL 的载荷 = 页面内容」✅
    {
      var __du = String(url == null ? '' : url);
      if (__du.indexOf('data:') === 0) {
        var __ci = __du.indexOf(',');
        var __pay = __ci >= 0 ? __du.slice(__ci + 1) : '';
        // 剥掉 Legado 的 URL 选项后缀 `,{"type":"x"}`（两种形态都认）
        var __mm = /,\s*(?=\{|%7B)/i.exec(__pay);
        if (__mm) __pay = __pay.slice(0, __mm.index);
        try {
          QR.java.log('[data:伪URL] 不发请求，直接把载荷当内容（长度 ' + __pay.length + '）');
        } catch (e2) {}
        return Promise.resolve({
          ok: true, code: 200, url: __du, _body: __pay, body: __pay,
          headers: {}, _code: 200, _url: __du
        });
      }
    }
    // ⚠️ 超时必须**显式**传给 nativeCall（默认 40s ❗）——
    //    站方（🍅大灰狼）有 8 个 host 的失败兜底，一个卡住就等满 40s × 7 = 几分钟。
    var __t = timeout ? timeout / 1000 : 12;
    // ⚠️⚠️⚠️ **JS 侧的等待时间必须覆盖原生侧的最坏耗时**（2026-10-21 真机实测）：
    //   原生侧 `nativeRequest` 会重试 3 次，且每次的超时是
    //     `per = max(3, timeout / (attempts - i))`  ⇒ **分母递减**
    //   ⇒ 三次的实际耗时 = timeout×(1/3 + 1/2 + 1) ≈ **1.83 × timeout**
    //     （12s ⇒ 4 + 6 + 12 = 22s，再加 2 次 0.3s 退避 ≈ **22.6 秒**）
    //   而这里原来只等 `__t + 3` = **15 秒** ⇒
    //   **原生侧还在跑第 3 次，JS 侧已经超时** ⇒ 报「原生调用超时: request」
    //   ⇒ 那个第 3 次其实**成功了，但已经没人要了**（真机日志实测：
    //      「第 1 次失败 / 第 2 次失败 / ⏱ op 23s 超时 / 重试成功（第 3 次）」）
    //   ⇒ 线路一慢，op 必挂 ⇒ 这就是「时好时坏」的另一半机制 ⭐
    //
    //   ⇒ 现在 JS 侧等 `__t × 2 + 5`（12s ⇒ 29 秒）⇒ **稳稳盖住原生侧的 22.6 秒** ✅
    var __waitMs = (__t * 2 + 5) * 1000;
    return nativeCall('request', {
      url: String(url || ''),
      method: String(method || 'GET').toUpperCase(),
      headers: headers || {},
      body: data == null ? '' : String(data),
      timeout: __t
    }, __waitMs).then(function (r) {
      if (!r || r.ok === false) throw new Error((r && r.error) || '请求失败');
      // ⚠️⚠️⚠️ **5xx ⇒ 这条线路挂了 ⇒ 自动换一条线路重试**（2026-10-22 真机「QQ 阅读目录出不来」）
      //   实测：`v5.langge.uk/catalog?source=svip_QQ阅读` **一直返 502**（Cloudflare 错误页）
      //   ⇒ 站方的 `ruleToc.chapterList` **没有 catch 换线兜底**（只有 `detail` 规则有）
      //   ⇒ 目录解析失败 ⇒ **0 章**
      //   ⇒ 这里替站方兜底：换 `host[]` 里的下一条线路重试**一次** ✅
      //
      //   ⚠️ 只换**一次**（`_swapped`）⇒ 不会变成「一次操作发 8 条」
      //   ⇒ 也不会重演「打爆站方限流」那个坑
      var __code = r.code || 0;
      if (__code >= 500 && !_swapped) {
        // ⚠️ 跳过**已经试过**的线路 ⇒ 全挂时不会在两条线之间来回打
        //    （两遍跑有 5 轮上限 ⇒ 最多覆盖 5 条不同线路）
        var alts = otherHosts(url);
        var picked = null;
        for (var ai = 0; ai < alts.length; ai++) {
          var hh = '';
          try { hh = new URL(alts[ai]).host; } catch (e) {}
          if (QR.__qrTriedHosts && QR.__qrTriedHosts[hh]) continue;
          picked = alts[ai];
          break;
        }
        if (!picked) picked = alts[0];
        if (picked) {
          var alt = swapHost(url, picked);
          try {
            if (!QR.__qrTriedHosts) QR.__qrTriedHosts = {};
            var curHost = '';
            try { curHost = new URL(splitUrlOption(url).url).host; } catch (e) {}
            if (curHost) QR.__qrTriedHosts[curHost] = true;
            QR.java.log('[换线] ' + __code + ' ⇒ 这条线路挂了 ⇒ 换 ' + picked
              + ' 重试一次：' + String(url).slice(0, 120));
          } catch (e) {}
          return rawRequest(alt, method, headers, data, timeout, true).then(function (r2) {
            // ⚠️ 换过去的那条**也失败**了 ⇒ 把它也记进「已试挂」
            //   （不记 ⇒ 每轮都在同样两条线之间来回打 ⇒ 白白多打一倍请求）
            try {
              var c2 = (r2 && r2.code) || 0;
              if (c2 >= 500) {
                if (!QR.__qrTriedHosts) QR.__qrTriedHosts = {};
                var ph = '';
                try { ph = new URL(splitUrlOption(alt).url).host; } catch (e) {}
                if (ph) QR.__qrTriedHosts[ph] = true;
              }
            } catch (e) {}
            return r2;
          });
        }
      }
      // ⚠️ 记住**最后一次响应** —— 站方 JS 崩的时候，日志里要能看出
      //    「它拿到的到底是啥」。否则只看到一句 `abstract.split` 这种天书，
      //    根本不知道服务器返回的是 502 还是「您的会员已过期」。
      try {
        QR.__qrLastAjax = {
          url: String(url || ''),
          code: r.code,
          body: String(r.body || '').slice(0, 600)
        };
      } catch (e) { /* 忽略 */ }
      return {
        _code: r.code,
        _url: r.url,
        _redirectUrl: r.redirectUrl,
        _headers: r.headers || {},
        _body: r.body || '',
        code: r.code,
        url: r.url,
        headers: r.headers || {},
        body: r.body || '',
        baseUrl: r.url,
        request: { url: String(url || ''), method: method },
        string: function () { return r.body || ''; },
        bytes: function () { return utf8Encode(r.body || ''); },
        byteStream: function () { return utf8Encode(r.body || ''); },
        charStream: function () { return r.body || ''; },
        contentType: function () { return (r.headers && (r.headers['Content-Type'] || r.headers['content-type'])) || ''; },
        cookie: function () { return (r.headers && (r.headers['Set-Cookie'] || r.headers['set-cookie'])) || ''; },
        header: function (n) { var h = r.headers || {}; return h[n] || h[n.toLowerCase()] || ''; },
        ok: function () { return r.code >= 200 && r.code < 400; }
      };
    });
  }

  /* ---------------- java.* ---------------- */

  function mkJsoupish(resp) {
    return QR.jsoup.Jsoup.parse(resp._body, resp._url || resp.url);
  }

  /* 本地变量存储：跨规则传递中间结果。
     {{java.put("cid",7)}} 必须同步返回，否则插值会变成 "[object Promise]"。
     注意 java.get(k) 取的是这里，跟发 HTTP 的 java.get(url) 是两个函数。 */
  function varStore() {
    if (!QR.runtime) QR.runtime = {};
    return QR.runtime.vars || (QR.runtime.vars = {});
  }

  var java = {
    // --- 网络 ---
    /**
     * Legado 的 `java.ajax` 是**同步**的：直接返回正文。
     * 站方大量这么写：`JSON.parse(java.ajax(url))`。
     * 我们的原生桥是异步的（只能 postMessage）→ 只能两遍跑：
     *   ① 录制模式：只记 URL，不真发（配合引擎的静音开关，不报假错）
     *   ② 引擎把 URL 抓回来放进缓存
     *   ③ 缓存命中 → **同步**返回正文
     */
    ajax: function (url) {
      var u = String((url && typeof url === 'object') ? (url.url || '') : (url || ''));
      // ⚠️⚠️ 顺序：**先查缓存，再进录制**。
      //    反过来的话每一遍都会重新录 → 缓存永远命中不了 →
      //    同一个请求被反复发（浏览器还会被反复弹）→ 循环里拿到的永远是空值。
      if (QR.__qrAjaxCache && Object.prototype.hasOwnProperty.call(QR.__qrAjaxCache, u)) {
        return QR.__qrAjaxCache[u];
      }
      if (QR.__qrAjaxRecord) { QR.__qrAjaxRecord(u, 'ajax', ''); return ''; }
      return applyUrlArg(url, function (x) { return java.get(x); });
    },
    get: function (url, headers) { return rawRequest(resolveUrl(url), 'GET', headers || {}, null, 20000).then(mkJsoupish); },
    post: function (url, body, headers) { return rawRequest(resolveUrl(url), 'POST', headers || {}, body, 20000).then(mkJsoupish); },
    put: function (url, body, headers) { return rawRequest(resolveUrl(url), 'PUT', headers || {}, body, 20000).then(mkJsoupish); },
    delete: function (url, headers) { return rawRequest(resolveUrl(url), 'DELETE', headers || {}, null, 20000).then(mkJsoupish); },
    head: function (url, headers) { return rawRequest(resolveUrl(url), 'HEAD', headers || {}, null, 20000).then(mkJsoupish); },
    ajaxAsync: function (url) { return applyUrlArg(url, function (u) { return java.getAsync(u); }); },
    getAsync: function (url) { return java.get(url); },
    postAsync: function (url, body, headers) { return java.post(url, body, headers); },
    getPromise: function (url) { return java.get(url); },
    postPromise: function (url, body, headers) { return java.post(url, body, headers); },
    ajaxPromise: function (url) { return java.get(url); },
    connect: function (url) { return new QR.jsoup.Connection(resolveUrl(url)); },
    connectAsync: function (url) { return java.connect(url).execute().then(mkJsoupish); },
    getStrResponse: function (url, headers) { return java.get(url, headers); },
    getSource: function (url) { return java.get(url).then(function (d) { return d.raw().documentElement.outerHTML; }); },
    webView: function (html, url) { return Promise.reject(new Error('当前版本未实现 webView 交互')); },
    /**
     * 内嵌浏览器（Legado 的 startBrowser / startBrowserAwait / showBrowser…）
     *
     * ⚠️ 站方是**同步**用的：
     *     let page = java.startBrowserAwait(url, '番茄登录');
     *     let html = page.body();
     *    → 我们的原生桥是异步的 → 同样走「两遍跑」：
     *      第一遍只记 URL（并静音 toast），原生侧弹浏览器等用户关掉，
     *      第二遍命中缓存 → 同步返回那个对象。
     *
     * ⚠️⚠️ **startBrowserAwait 在这个对象里只许定义一次！**
     *    以前定义了两遍（下面这份 + 后面那份），**后者覆盖前者**，
     *    而覆盖成的那份直连 nativeCall('showBrowser') → **绕过了两遍跑**
     *    → 原生侧没有 showBrowser → 异步 rejection 被静默吞掉
     *    → **浏览器根本不弹**（🍅番茄登录 / 注册 / 用户后台 / 打赏 / 设置中心 全废）。
     *    → 门禁 login-status.test.js 断言「只定义一次」✅
     */
    startBrowser: function (url, title) {
      var u = String((url && typeof url === 'object') ? (url.url || '') : (url || ''));
      if (QR.__qrAjaxRecord) { QR.__qrAjaxRecord(u, 'browser', String(title || '')); return ''; }
      // ⚠️⚠️⚠️ **没有两遍跑上下文时必须同步返回空串**（2026-10-21 真机实测）：
      //   站方会把 `java.startBrowser(...)` 直接写在 URL 模板里，例如
      //     "url": '{java.startBrowser("https://fanqienovel.com/","番茄登录");}'
      //   轻阅稍后**再解析这个 URL 模板**时，已经**不在两遍跑上下文里**了
      //   ⇒ `QR.__qrAjaxRecord` 不存在 ⇒ 走 `openBrowser` 直连 ⇒ **返回 Promise**
      //   ⇒ 那个 Promise 被字符串化塞进 URL ⇒ 变成 **`[object Promise]`**
      //   ⇒ explore 拿它当 URL 去请求 ⇒「URL 非法: [object Promise]」
      //   ⇒ **整个发现功能直接挂掉** ❗（真机日志实测，40 秒白等）
      //
      //   站方（Legado/栖阅）的 `java.startBrowser` 是**同步**的 ⇒ 返回值是空/无意义的
      //   ⇒ 这里同步返回 '' 才与站方一致 ⇒ 那个 kind 的 url 变成空串
      //   ⇒ 它的语义本来就是「点这个分类 = 打开浏览器」这种**纯动作项**，
      //      没有可请求的 URL ⇒ 空串才是对的 ✅
      //
      //   ⚠️ 这里**不弹浏览器**：登录流程走的是两遍跑（有 `QR.__qrAjaxRecord` 分支）
      //      ⇒ 原生侧在 fetchRecorded 里弹 ⇒ 行为不受影响；
      //      而在 URL 模板解析时弹 ⇒ 会**打断用户**（真机上一次 exploreKinds 弹了浏览器）。
      try { QR.java.log('[站方要求打开浏览器] ' + u.slice(0, 160)); } catch (e) {}
      return '';
    },
    showBrowser: function (url, content, title) {
      // ⚠️ 站方调用形式：`java.showBrowser(pageUrl, htmlContent, title)`（3 个参数）
      //    第三个才是标题。轻阅的浏览器只吃 URL，所以这里只传 URL。
      //    ⚠️ **必须走 startBrowser（两遍跑）**，不能直连原生 ——
      //    原生侧没有 showBrowser 这个 op，直连会被 default 分支拒掉，
      //    而且异步 rejection 站方接不到 → 浏览器静默不弹。
      return java.startBrowser(url, title || content || '');
    },
    showReadingBrowser: function (url, title) { return java.startBrowser(url, title); },
    startBrowserDp: function (url, title) { return java.startBrowser(url, title); },
    openBrowser: function (url, title) {
      return nativeCall('openBrowser', { url: resolveUrl(url), title: String(title || '') })
        .then(function (r) {
          // ⚠️ 失败要**抛**，别默默返回一个空页面 ——
          //    静默失败会变成「点了没反应」，根本查不出原因。
          if (r && r.ok === false) throw new Error(String(r.error || '打不开浏览器'));
          return mkBrowserLike((r && r.value) || {});
        });
    },
    openUrl: function (url) { return java.open(url); },
    open: function (url) { return java.open(url); },

    // --- 字符串 / 编码 ---
    base64Encode: function (s) { return b64encode(s); },
    base64Decode: function (s) { return b64decode(s); },
    base64DecodeToByteArray: function (s) {
      try { return manualB64ToBytes(String(s || '').replace(/\s/g, '')); } catch (e) { return new Uint8Array(0); }
    },
    md5Encode: function (s) { return hexDigest(String(s == null ? '' : s), 'md5'); },
    md5Encode16: function (s) { return hexDigest(String(s == null ? '' : s), 'md5').slice(0, 16); },
    sha1Encode: function (s) { return hexDigest(String(s == null ? '' : s), 'sha-1'); },
    encodeURI: function (s) { return g.encodeURI(String(s == null ? '' : s)); },
    encodeURIComponent: function (s) { return g.encodeURIComponent(String(s == null ? '' : s)); },
    escape: function (s) { return g.escape(String(s)); },
    unescape: function (s) { return g.unescape(String(s)); },
    htmlFormat: function (s) { return String(s == null ? '' : s); },
    regex: function (re, s) { try { return new RegExp(re).exec(String(s)); } catch (e) { return null; } },
    getString: function (arr) {
      if (Array.isArray(arr)) return java.getStringArray(arr);
      return nativeCall('getString', { str: String(arr == null ? '' : arr) }).then(function (r) { return b64decode(r.value); });
    },
    getStringArray: function (list) {
      var arr = list == null ? [] : (Array.isArray(list) ? list : [list]);
      return nativeCall('getStringArray', { list: arr.map(String) })
        .then(function (r) { return (r.value || []).map(b64decode); });
    },
    getStringWrapper: function (s) { return String(s == null ? '' : s); },
    /**
     * Legado 的 `java.timeFormat` —— **Long(epoch 毫秒) → "yyyy-MM-dd HH:mm:ss"**。
     *
     * ⚠️ **两种语义要分清**（站方拼会员卡片炸掉就是这个）：
     *   · 数字（epoch 毫秒）→ **格式化字符串**（Legado 语义）
     *     站方：`java.timeFormat(res.register_time*1000).padEnd(20,"\t")`
     *            `java.timeFormat(new Date()).slice(0,10) == java.timeFormat(res.last_read_time*1000).slice(0,10)`
     *     → 返回数字的话 `.padEnd` / `.slice` 都不存在 → 「检测登录失败」假报错
     *   · 其它字符串（"2026-10-20 14:16:34"）→ **epoch 毫秒**
     *     语料：`{{java.timeFormat(java.getString('$.updateDate'))}}` 当章节时间戳
     *
     * 实现在 Swift（`Core/LegadoCompat.swift`），这里只转发；
     * 同步通道不可用时退回纯 JS 兜底（语义保持一致）。
     */
    timeFormat: function (t) {
      var input;
      try {
        // Date 对象先取毫秒（JSON 过不去 Date）
        if (t && typeof t.getTime === 'function') input = String(t.getTime());
        else input = String(t == null ? '' : t).trim();
      } catch (e) { input = ''; }
      if (!input) return 0;
      var r = QR.__qrSync('timeFormat', { input: input });
      if (r && r.ok && r.value !== undefined && r.value !== null) return r.value;
      return javaTimeFormatFallback(input);
    },

    // 本地变量：跨规则传递中间结果。语料里 java.put/java.get 有 800+ 条
    put: function (k, v) { varStore()[String(k)] = v; return v; },
    get: function (k) {
      var st = varStore(), key = String(k);
      return Object.prototype.hasOwnProperty.call(st, key) ? st[key] : '';
    },
    getString: function (k) { return String(java.get(k)); },
    getInt: function (k) { return parseInt(java.get(k), 10) || 0; },
    getFloat: function (k) { return parseFloat(java.get(k)) || 0; },
    getObject: function (k) { var v = java.get(k); try { return JSON.parse(v); } catch (e) { return v; } },
    getList: function (k) { var v = java.get(k); return Array.isArray(v) ? v : String(v).split(/\n/); },
    del: function (k) { delete varStore()[String(k)]; },
    containsKey: function (k) { return String(k) in varStore(); },
    clear: function () { QR.runtime.vars = {}; },
    importScript: function (path) { return nativeCall('importScript', { path: String(path) }); },
    getWebViewUA: function () { return nativeCall('getWebViewUA', {}).then(function (r) { return r.value; }); },

    // --- DOM ---
    getElements: function (rule, base) { return QR.rule.getElements(rule, base); },
    getElement: function (rule, base) {
      var a = QR.rule.getElements(rule, base);
      return (a && a.length) ? a[0] : null;
    },
    setContent: function (html) { return nativeCall('setContent', { html: String(html == null ? '' : html) }); },

    // --- 补齐：125 源聚合包里用到、轻阅原本没有的 ---
    // 依据：运行时逐个 typeof java.X === 'function' 点名出来的，不是 grep 源码
    // （源码里赋值形态五花八门，grep 会误判 —— java.io / java.util 这些包引用更会误报）
    ajaxAll: function (urlList) {
      var urls = Array.isArray(urlList) ? urlList : [urlList];
      // 返回带 body()/bodyStr()/headers()/code() 的 StrResponse 数组，跟 Legado 对齐
      return Promise.all(urls.map(function (u) {
        return java.ajax(u).then(function (r) {
          return {
            url: String(u),
            code: r && r.code != null ? r.code : 200,
            bodyStr: function () { return r && r.body != null ? String(r.body) : ''; },
            body: function () { return { string: function () { return this.bodyStr(); } }; },
            headers: function () { return {}; },
            toString: function () { return this.bodyStr(); }
          };
        });
      }));
    },
    getAbsoluteURL: function (u, base) {
      try { return new URL(String(u), String(base || java.getString('$.baseUrl') || '')).href; }
      catch (e) { return String(u); }
    },
    // 简繁转换：轻阅不做真实 OpenCC，靠词表兜底；至少不是 undefined
    t2s: function (t) { return String(t == null ? '' : t); },
    // UTC 版 timeFormat：轻阅统一按本地时区，这里保持签名不报错
    timeFormatUTC: function (t, f) { return java.timeFormat(t, f); },
    hexDecodeToString: function (hex) {
      var s = String(hex == null ? '' : hex).trim();
      // ⚠️ 有些聚合源**拿 base64 的串去调 hexDecodeToString** ——
      //    🍅大灰狼就是：bookUrl 规则用 base64Encode 写进去，
      //    init 规则用 hexDecodeToString 读出来。严格按 hex 解会得到一堆乱码
      //    （"ÍàÊÎîQ…"），整条详情规则静默失效。
      //    所以：**不是合法 hex 就按 base64 再试一次**。
      var isHex = /^[0-9a-fA-F]*$/.test(s) && s.length % 2 === 0;
      if (!isHex) {
        // ⚠️ 多试几种还原方式（真机 2026-10-21）：
        //   载荷当 URL 走一圈可能被转义（%2B）/加号变空格 → 直接解会得到乱码，
        //   而乱码**不会报错**，只会在站方 JSON.parse 时炸出天书错。
        //   ⇒ 归一化后再解一次，挑**像人话**的那个。
        var cands = [s, b64normalize(s)];
        var last = null;
        for (var ci = 0; ci < cands.length; ci++) {
          try {
            var b64 = b64decode(cands[ci]);
            if (b64 == null) continue;
            if (looksLikeText(b64)) return b64;
            last = b64;
          } catch (e) { /* 落回 hex */ }
        }
        if (last != null) return last;
      }
      var h = s.replace(/[^0-9a-fA-F]/g, '');
      var out = '';
      for (var i = 0; i + 1 < h.length; i += 2) out += String.fromCharCode(parseInt(h.substr(i, 2), 16));
      try { return decodeURIComponent(escape(out)); } catch (e) { return out; }
    },
    randomUUID: function () {
      // 必须是 v4 格式：书源常拿它当签名 nonce
      if (g.crypto && g.crypto.randomUUID) return g.crypto.randomUUID();
      var b = new Uint8Array(16);
      if (g.crypto && g.crypto.getRandomValues) g.crypto.getRandomValues(b);
      else for (var i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
      b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
      var h = [];
      for (var j = 0; j < 16; j++) h.push((b[j] + 0x100).toString(16).substr(1));
      return h.slice(0, 4).join('') + '-' + h.slice(4, 6).join('') + '-' +
             h.slice(6, 8).join('') + '-' + h.slice(8, 10).join('') + '-' + h.slice(10).join('');
    },
    // 触发宿主动作：沙盒里没有真 UI，返回「不可用」而不是静默 undefined
    refreshExplore: function () { return nativeCall('refreshExplore', {}); },
    refreshTocUrl: function () { return nativeCall('refreshTocUrl', {}); },
    showBrowser: function (url) { return nativeCall('showBrowser', { url: resolveUrl(url) }); },
    startBrowserAwait: function (url, title) {
      // ⚠️⚠️⚠️ **这个对象里 startBrowserAwait 只许定义这一处**
      //    （以前定义了两遍，**后者覆盖前者** → 覆盖成的那份直连 nativeCall('showBrowser')，
      //      **绕过了两遍跑**）：
      //      · 原生侧根本没有 showBrowser 这个 op → default 分支拒掉
      //      · 而且是**异步 rejection**，站方的 try/catch 接不到 → 静默失败
      //    ⇒ **浏览器根本不弹** → 番茄登录 / 注册 / 用户后台 / 打赏 / 设置中心 /
      //      人机验证 全废（站方一共 15 处用 startBrowserAwait）。
      //
      //    正确做法：**缓存优先 → 再录制**，
      //    由两遍跑去弹浏览器，并把浏览器里登出来的 cookie 合并回快照
      //    （否则站方 `cookie.getKey('fanqienovel.com','sessionid')` 拿不到）。
      var u = String((url && typeof url === 'object') ? (url.url || '') : (url || ''));
      if (QR.__qrAjaxCache && Object.prototype.hasOwnProperty.call(QR.__qrAjaxCache, u)) {
        return QR.__qrAjaxCache[u];
      }
      if (QR.__qrAjaxRecord) { QR.__qrAjaxRecord(u, 'browser', String(title || '')); return mkBrowserLike({}); }
      return java.openBrowser(u, title).then(function (r) {
        return mkBrowserLike((r && r.value) || {});
      });
    },
    reLoginView: function (a) { return nativeCall('reLoginView', { msg: String(a == null ? '' : a) }); },
    searchBook: function (key) { return nativeCall('searchBook', { key: String(key == null ? '' : key) }); },
    toNumChapter: function (name) {
      // 「第 123 章」→ 123；书源拿它排序用
      var m = String(name == null ? '' : name).match(/(\d+)/);
      return m ? parseInt(m[1], 10) : -1;
    },
    createSymmetricCrypto: function (key, iv, mode) {
      // 对齐 java.createSymmetricCrypto(key, iv, transformation) 的形状。
      // 轻阅没有真 Cipher 实例，这里给一个能用 java.encryptBase64/decryptBase64 的壳
      var K = String(key == null ? '' : key), I = iv == null ? '' : String(iv);
      var MODE = String(mode == null ? 'AES/CBC/PKCS5Padding' : mode).toUpperCase();
      function pad(s, n) {
        var padLen = n - (s.length % n);
        var r = '';
        for (var i = 0; i < padLen; i++) r += String.fromCharCode(padLen);
        return s + r;
      }
      return {
        encrypt: function (text) { return nativeCall('symmetricCrypto', { op: 'encrypt', key: K, iv: I, mode: MODE, text: String(text == null ? '' : text), pad: true }); },
        decrypt: function (b64) { return nativeCall('symmetricCrypto', { op: 'decrypt', key: K, iv: I, mode: MODE, text: String(b64 == null ? '' : b64) }); },
        encryptBase64: function (text) { return nativeCall('symmetricCrypto', { op: 'encrypt', key: K, iv: I, mode: MODE, text: String(text == null ? '' : text), b64: true, pad: true }); },
        decryptBase64: function (b64) { return nativeCall('symmetricCrypto', { op: 'decrypt', key: K, iv: I, mode: MODE, text: String(b64 == null ? '' : b64) }); },
        getKey: function () { return K; },
        getIv: function () { return I; }
      };
    },
    getStringMatch: function (rule, text) { return QR.rule.stringMatchAll(rule, text); },

    // --- 杂项 ---
    log: function () {
      var msg = Array.prototype.map.call(arguments, function (a) {
        try {
          if (typeof a === 'string') return a;
          // ⚠️ Error 对象 JSON.stringify 出来是 "{}"（属性都不可枚举）→ 日志里啥都看不见。
          //    站方 catch 之后习惯 `java.log(e)` → 至少把 "Error: xxx" 露出来。
          if (a && typeof a === 'object' && typeof a.message === 'string'
              && (a.name === 'Error' || a instanceof Error)) {
            return String(a.name || 'Error') + ': ' + a.message;
          }
          return JSON.stringify(a);
        } catch (e) { return String(a); }
      }).join(' ');
      // ⚠️ 先收集（进暂存区），再决定要不要显示：
      //    站方 checkStatus() 那张**会员卡片**走的就是 java.log，
      //    它在第一遍是真结果（没 ajax）→ 不能被静音吃掉。
      pushMsg(msg, 'log');
      if (QR.__qrSuppressToast) return Promise.resolve('');
      return nativeCall('log', { msg: msg });
    },
    // ⚠️ 两遍跑的第一遍要**静音**：那一遍的 ajax 是假的，
    //    站方解析失败会弹「登录失败 / JSON Parse error」→ 用户看到假报错。
    // ⚠️ 但 pushMsg 在静音判断**之前** —— 消息先进暂存区，
    //    跑完这一遍再定夺（没 ajax 的真结果不能被吃掉）。
    longToast: function (s) {
      pushMsg(s, 'toast');
      if (QR.__qrSuppressToast) return Promise.resolve('');
      return nativeCall('toast', { msg: String(s) });
    },
    toast: function (s) {
      pushMsg(s, 'toast');
      if (QR.__qrSuppressToast) return Promise.resolve('');
      return nativeCall('toast', { msg: String(s) });
    },
    getCookie: function (url) { return nativeCall('getCookie', { url: resolveUrl(url) }).then(function (r) { return r.value; }); },
    setCookie: function (url, cookie) { return nativeCall('setCookie', { url: resolveUrl(url), cookie: String(cookie) }); },
    // ⚠️ 站方的「退出登录」靠它清 cookie —— 以前原生侧没实现 → 退出是空操作
    removeCookie: function (url) { return nativeCall('removeCookie', { url: resolveUrl(url) }); },
    cacheFile: function (path, content) { return nativeCall('cacheFile', { path: String(path), text: String(content == null ? '' : content) }).then(function (r) { return r.value === '1'; }); },
    cacheText: function (path) { return nativeCall('readCache', { path: String(path) }).then(function (r) { return r.value; }); },
    readFile: function (path) { return nativeCall('readFile', { path: String(path) }).then(function (r) { return r.value; }); },
    deviceID: function () { return nativeCall('deviceID', {}).then(function (r) { return r.value; }); },
    androidId: function () { return java.deviceID(); },
    getLang: function () { return 'zh-CN'; },
    isWhiteList: function () { return true; },
    startBrowser_: null,
    lang: g.navigator ? g.navigator.language : 'zh-CN'
  };

  java.cacheFileRaw = rawRequest;
  java.rawRequest = rawRequest;
  java._b64Dec = null;   // 原生 base64 通道，预留给将来的注入

  /** 浏览器返回的「页面对象」—— 站方调 .body() 拿 HTML */
  function mkBrowserLike(v) {
    var html = String((v && v.html) || '');
    return {
      body: function () { return html; },
      html: html,
      url: String((v && v.url) || ''),
      cookie: String((v && v.cookie) || ''),
      toString: function () { return html; }
    };
  }

  function applyUrlArg(url, fn) {
    if (url && typeof url === 'object') {
      return fn(resolveUrl(url.url)).then(function (d) {
        return d;
      });
    }
    return fn(resolveUrl(url));
  }

  function resolveUrl(u) {
    if (!u) return '';
    if (typeof u !== 'string') u = u.url || '';
    if (/^https?:\/\//i.test(u)) return u;
    var base = (QR.runtime && QR.runtime.baseUrl) || g.location.href;
    try { return new URL(u, base).href; } catch (e) { return u; }
  }

  /* md5 / sha-1 纯 JS 实现（Crypto.subtle 在 file:// 下不可用，不能指望） */
  function hexDigest(str, algo) {
    var bytes = utf8Encode(str);
    // SHA-1 走内联的验证过实现（见 sha1.js），别再手写轮函数
    if (algo === 'sha-1' || algo === 'sha1') return QR.sha1(bytes);
    return md5hex(bytes);
  }

  function md5hex(bytes) {
    var K = [], i, j;
    // 64 步的移位量表：四轮分别是 7,12,17,22 / 5,9,14,20 / 4,11,16,23 / 6,10,15,21
    var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
             5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
             4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
             6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    function rr(n, s) { return (n << s) | (n >>> (32 - s)); }
    for (i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296);
    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    var len = bytes.length;
    var withPad = new Uint8Array(((len + 8) >> 6) * 64 + 64);
    withPad.set(bytes);
    withPad[len] = 0x80;
    var bitsLo = (len << 3) >>> 0, bitsHi = Math.floor(len / 0x20000000);
    var dp = withPad.length - 8;
    withPad[dp] = bitsLo & 0xFF; withPad[dp + 1] = (bitsLo >>> 8) & 0xFF;
    withPad[dp + 2] = (bitsLo >>> 16) & 0xFF; withPad[dp + 3] = (bitsLo >>> 24) & 0xFF;
    withPad[dp + 4] = bitsHi & 0xFF; withPad[dp + 5] = (bitsHi >>> 8) & 0xFF;
    withPad[dp + 6] = (bitsHi >>> 16) & 0xFF; withPad[dp + 7] = (bitsHi >>> 24) & 0xFF;

    for (i = 0; i < withPad.length; i += 64) {
      var M = new Int32Array(16);
      for (j = 0; j < 16; j++) M[j] = withPad[i + j * 4] | (withPad[i + j * 4 + 1] << 8) | (withPad[i + j * 4 + 2] << 16) | (withPad[i + j * 4 + 3] << 24);
      var A = a0, B = b0, C = c0, D = d0;
      for (j = 0; j < 64; j++) {
        var F, g;
        if (j < 16) { F = (B & C) | (~B & D); g = j; }
        else if (j < 32) { F = (D & B) | (~D & C); g = (5 * j + 1) % 16; }
        else if (j < 48) { F = B ^ C ^ D; g = (3 * j + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * j) % 16; }
        F = (F + A + K[j] + M[g]) | 0;
        A = D; D = C; C = B;
        B = (B + rr(F, S[j])) | 0;
      }
      a0 = (a0 + A) | 0; b0 = (b0 + B) | 0; c0 = (c0 + C) | 0; d0 = (d0 + D) | 0;
    }
    return le32(a0) + le32(b0) + le32(c0) + le32(d0);
  }
  function le32(n) {
    return [n & 0xFF, (n >>> 8) & 0xFF, (n >>> 16) & 0xFF, (n >>> 24) & 0xFF]
      .map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join('');
  }
  g.java = g.java || {};
  for (var k in java) { if (typeof java[k] === 'function') g.java[k] = java[k]; }
  g.java.lang = { String: function (s) { return String(s); } };

  QR.java = java;
})(typeof globalThis !== 'undefined' ? globalThis : self);
