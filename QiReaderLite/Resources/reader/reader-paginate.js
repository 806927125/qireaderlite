/// 翻页模式（真·分页）—— **轻阅自带的补丁**，不是栖阅的东西。
///
/// 栖阅那四个文件（reader.html / reader.css / reader.js / reader-scroll-core.js）
/// 是原样搬来的，分页能力它们没有（实测 reader.js 里只有 PageUp/PageDown 和 tap，
/// 没有任何 column / paginate 逻辑），所以这个模块由原生在 `ready` 之后注入，
/// **一个字都不改那四个文件**。
///
/// ── 原理 ──────────────────────────────────────────────
/// CSS 多列 + transform 平移，是 Web 上做分页阅读的标准做法：
///   1. 把当前章的 `.chapter-body` 设成固定高度的**多列容器**
///      （column-width = 一页宽），文字自动往右边流出成一页页
///   2. 外面套一层 overflow:hidden 的"视口"
///   3. 翻页 = `transform: translateX(-页码 × 页宽)`
///
/// ── 翻页方式（对应参考 App 的「仿真 / 滑动 / 平移 / 无动画 / 上下滚动」）──
///   slide   滑动     整页平移，跟手度一般但最稳
///   flip    仿真     带 3D 翻页透视
///   none    无动画   直接跳
///   scroll  上下滚动 关闭分页，回到原来的连续滚动
///
/// ── 兼容性 ────────────────────────────────────────────
/// 任何一步失败都静默退回「上下滚动」，绝不把正文搞没。
(function () {
  if (window.__qrPaginate) return;

  var root = document.getElementById('reader-root');
  if (!root) return;

  var state = {
    on: false,
    mode: 'slide',
    chapter: null,      // 当前分页的 section.chapter
    page: 0,
    pageCount: 1,
    pageW: 0,
    busy: false,
    onPage: null,       // (pageIndex, pageCount) => void  回调给原生
    onEdge: null,       // (direction) => void            到头/到尾
    onMode: null,       // (mode) => void
    onFail: null        // (reason) => void
  };

  function post(type, payload) {
    try {
      window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.qiReader &&
        window.webkit.messageHandlers.qiReader.postMessage(Object.assign({ type: type }, payload || {}));
    } catch (_) {}
  }

  // ── 几何：视口尺寸要扣掉 #reader-root 的内边距 ──
  function metrics() {
    var cs = getComputedStyle(root);
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var pt = parseFloat(cs.paddingTop) || 0;
    var pb = parseFloat(cs.paddingBottom) || 0;
    var pageW = Math.max(120, root.clientWidth - pl - pr);
    var pageH = Math.max(120, window.innerHeight - pt - pb);
    return { pageW: pageW, pageH: pageH, pl: pl, pr: pr };
  }

  // ── 给某个章节装上分页 ──
  function paginate(chapter) {
    unpaginate(state.chapter);
    if (!chapter) { state.chapter = null; return false; }

    var body = chapter.querySelector('.chapter-body');
    if (!body) return false;

    var m = metrics();
    var gap = 0;

    body.classList.add('qr-paged');
    body.style.height = m.pageH + 'px';
    body.style.columnWidth = m.pageW + 'px';
    body.style.columnGap = gap + 'px';
    body.style.columnFill = 'auto';
    body.style.overflow = 'visible';
    body.style.width = m.pageW + 'px';
    body.style.willChange = 'transform';
    body.style.transition = 'none';
    body.style.overflowWrap = 'break-word';
    body.style.wordBreak = 'break-word';

    // 多列的宽度由 columnWidth 推算，浏览器会把内容排到 width 之外。
    // 用 scrollWidth 反推真实页数：溢出宽度 / 页宽。
    var totalW = body.scrollWidth;
    // ceil 而不是 round：整页宽是 pageW，最后一页常常不满，
    // round 会把它并进前一页 → 最后一页永远翻不到
    var count = Math.max(1, Math.ceil(totalW / m.pageW - 0.01));

    state.chapter = chapter;
    state.pageW = m.pageW;
    state.pageCount = count;
    state.page = 0;
    render(0, false);
    return true;
  }

  function unpaginate(chapter) {
    if (!chapter) return;
    var body = chapter.querySelector('.chapter-body');
    if (!body) return;
    body.classList.remove('qr-paged');
    body.style.height = body.style.columnWidth = body.style.columnGap = '';
    body.style.columnFill = body.style.overflow = body.style.width = '';
    body.style.transform = body.style.transition = body.style.willChange = '';
  }

  function render(page, animate) {
    var body = state.chapter && state.chapter.querySelector('.chapter-body');
    if (!body) return;
    var p = Math.max(0, Math.min(page, state.pageCount - 1));
    state.page = p;
    var x = -p * state.pageW;

    body.style.transition = animate
      ? (state.mode === 'flat' ? 'transform 160ms linear' : transitionFor(state.mode))
      : 'none';
    body.style.transform = transformFor(state.mode, x, p);

    if (state.onPage) state.onPage(p, state.pageCount);
  }

  function transitionFor(mode) {
    if (mode === 'none' || mode === 'scroll') return 'none';
    if (mode === 'flip') return 'transform 340ms cubic-bezier(.2,.7,.25,1)';
    return 'transform 220ms ease-out';
  }

  // flat = 「平移」：跟滑动一样是整页平移，只是过渡更干脆（没有 cubic-bezier 缓动尾巴）


  function transformFor(mode, x, p) {
    if (mode === 'flip') {
      // 轻微 3D 透视：越靠后翻得越"立"一点
      var tilt = p % 2 === 0 ? 3 : -3;
      return 'perspective(1400px) rotateY(' + tilt + 'deg) translateX(' + x + 'px)';
    }
    return 'translateX(' + x + 'px)';
  }

  // ── 翻页 ──
  function go(delta) {
    if (!state.on || state.busy) return;
    var next = state.page + delta;
    if (next < 0) {
      // 本章第一页往右翻 → 交给原生去上一章
      if (state.onEdge) state.onEdge(-1);
      return;
    }
    if (next >= state.pageCount) {
      if (state.onEdge) state.onEdge(1);
      return;
    }
    render(next, true);
  }

  // ── 手势：只认横向，纵向一律放行给正文滚动 ──
  var t0x = 0, t0y = 0, t0t = 0, tracking = false;
  function onTouchStart(e) {
    if (!state.on) return;
    if (!e.touches || e.touches.length !== 1) { tracking = false; return; }
    tracking = true;
    t0x = e.touches[0].clientX; t0y = e.touches[0].clientY; t0t = Date.now();
  }
  function onTouchEnd(e) {
    if (!state.on || !tracking) return;
    tracking = false;
    var t = e.changedTouches && e.changedTouches[0];
    if (!t) return;
    var dx = t.clientX - t0x;
    var dy = t.clientY - t0y;
    var dt = Date.now() - t0t;
    // 横向位移要**明显大于**纵向，且够快/够长，避免跟滚动打架
    if (Math.abs(dx) < 40 || Math.abs(dx) < Math.abs(dy) * 1.8) return;
    if (dt > 700) return;
    go(dx < 0 ? 1 : -1);
  }

  // ── 点击：左边上一章 / 右边下一章（翻页模式下翻页优先）──
  function onClick(e) {
    if (!state.on) return;
    var t = e.target;
    if (t && t.closest && t.closest('.comment-node')) return;
    var m = metrics();
    var x = (e.clientX || 0);
    // 只在左右 1/4 触发翻页，中间留给"出菜单"（原生 tap 会处理）
    if (x < m.pl + m.pageW * 0.25) { e.preventDefault(); go(-1); }
    else if (x > m.pl + m.pageW * 0.75) { e.preventDefault(); go(1); }
  }

  // ── 视口变化（旋转 / 分屏）要重排 ──
  var resizeTimer = null;
  function onResize() {
    if (!state.on || !state.chapter) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { paginate(state.chapter); }, 160);
  }

  document.addEventListener('touchstart', onTouchStart, { passive: true });
  document.addEventListener('touchend', onTouchEnd, { passive: true });
  document.addEventListener('click', onClick, true);
  window.addEventListener('resize', onResize);

  // 翻页模式下只显示当前章，其余章藏起来（否则会看到下面几章的标题）
  function soloChapter(chapter) {
    var all = root.querySelectorAll('section.chapter');
    for (var i = 0; i < all.length; i++) {
      var on = all[i] === chapter;
      all[i].style.display = on ? '' : 'none';
    }
  }

  window.QiReaderPaginate = {
    enable: function (chapterIndex, mode) {
      try {
        state.mode = mode || 'slide';
        var chapter = root.querySelector('section.chapter[data-chapter-index="' + chapterIndex + '"]');
        if (!chapter) return false;
        soloChapter(chapter);
        var ok = paginate(chapter);
        if (!ok) throw new Error('chapter-body 找不到');
        state.on = true;
        document.documentElement.classList.add('qr-page-mode');
        return true;
      } catch (e) {
        if (state.onFail) state.onFail(String(e && e.message || e));
        return false;
      }
    },
    disable: function () {
      state.on = false;
      document.documentElement.classList.remove('qr-page-mode');
      unpaginate(state.chapter);
      state.chapter = null;
      var all = root.querySelectorAll('section.chapter');
      for (var i = 0; i < all.length; i++) all[i].style.display = '';
    },
    /** 原生知道「加载好了 / 换章了」，让它重新分一次 */
    refresh: function (chapterIndex) {
      if (!state.on) return false;
      var chapter = root.querySelector('section.chapter[data-chapter-index="' + chapterIndex + '"]');
      if (!chapter) return false;
      soloChapter(chapter);
      return paginate(chapter);
    },
    setMode: function (mode) { state.mode = mode || 'slide'; render(state.page, true); },
    current: function () { return { page: state.page, count: state.pageCount, mode: state.mode }; },
    onPage: function (fn) { state.onPage = fn; },
    onEdge: function (fn) { state.onEdge = fn; },
    onFail: function (fn) { state.onFail = fn; }
  };
  post('paginateReady', {});
})();
;void 0;
