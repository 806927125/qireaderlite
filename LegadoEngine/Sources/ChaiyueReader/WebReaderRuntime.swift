import Foundation

/// 网页模式的页面骨架与分页运行时。
///
/// 翻页模式：`#viewport` 铺满整页。覆盖和平移时它是横向滚动容器（按页吸附）；仿真时由原生把整页截图卷过去，网页自己不滚动。
/// 上一章、本章、下一章各是一个 `.chapter`，按 CSS 多栏分页后并排放在 `#track` 上，跨章翻页与章内翻页一样连续；
/// 当前章另带 `id="chapter"`。段落带 `data-o`（章内稳定偏移）与 `data-len`，进度、书签、朗读按稳定偏移与原生模式互通。
enum WebReaderRuntime {
    /// 页面骨架。主题样式表在基础样式之后，基础样式全部用 `:where()` 包住（特异度为 0），主题随便写都盖得过
    static func shell(css: String, js: String, html: String, fontFaces: String) -> String {
        let safeCSS = css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <style id="font-faces">\(fontFaces)</style>
        <style>\(baseCSS)</style>
        <style id="theme-style">\(safeCSS)</style>
        <style>\(typographyCSS)</style>
        </head>
        <body>
        <div class="page" id="page">
          <div id="decor">\(html)</div>
          <div class="header" id="header"><span class="left"></span><span class="center"></span><span class="right"></span></div>
          <div id="viewport"><div id="track"><div id="snaps"></div></div></div>
          <div class="footer" id="footer"><span class="left"></span><span class="center"></span><span class="right"></span></div>
        </div>
        <script>\(runtimeJS)</script>
        <script>
        \(safeJS)
        </script>
        <script>window.reader.__boot();</script>
        </body>
        </html>
        """
    }

    /// 排在主题样式表之后：正文的字体、字号、行高始终跟排版面板走（章名等装饰仍可用主题字体）
    /// 排在主题之后，正文排版跟阅读器走。标点挤压、避头尾、中西文间距只作用在段落上，章名留给主题
    static let typographyCSS = """
    .chapter { font-family: var(--reader-font) !important; font-size: var(--reader-font-size) !important; line-height: var(--reader-line-height) !important; }
    .chapter p {
      font-family: inherit !important; line-height: inherit !important;
      line-break: strict; overflow-wrap: break-word;
      text-spacing-trim: space-all;
      text-autospace: ideograph-alpha ideograph-numeric;
    }
    """

    static let baseCSS = """
    :root { --progress: 0; --chapter-progress: 0; --battery: 1; --safe-top: 47px; --safe-bottom: 34px; }
    :where(html, body) {
      margin: 0; padding: 0; height: 100%; overflow: hidden;
      -webkit-text-size-adjust: 100%; -webkit-tap-highlight-color: transparent;
      -webkit-touch-callout: none;
    }
    :where(body) {
      font-family: var(--reader-font); font-size: var(--reader-font-size);
      line-height: var(--reader-line-height); color: var(--reader-ink); background-color: var(--reader-paper);
    }
    :where(.page) {
      position: fixed; inset: 0; overflow: hidden; box-sizing: border-box;
      padding: 30px 26px 25px; background-color: var(--reader-paper); color: inherit;
      background-size: cover; background-position: center;
    }
    :where(#decor) { position: absolute; inset: 0; pointer-events: none; }
    #viewport { position: absolute; inset: 0; overflow: hidden; scrollbar-width: none; overscroll-behavior: contain; }
    #viewport::-webkit-scrollbar { display: none; }
    #viewport { --progress: 0; --chapter-progress: 0; --battery: 1; will-change: scroll-position; }
    .paged #viewport { overflow-x: scroll; overflow-y: hidden; scroll-snap-type: x mandatory; }
    /* 仿真由盖在上面的系统卷页负责。挡住手指把正文拖走，选字和页码条仍可点；程序里改 scrollLeft 不受影响 */
    .curl.paged #viewport { overflow: hidden; scroll-snap-type: none; }
    .scroll-mode #viewport { overflow-x: hidden; overflow-y: auto; }
    .static #viewport { overflow: hidden; }
    #track { position: relative; min-height: 100%; }
    .paged #track { height: 100%; }
    #snaps { position: absolute; top: 0; left: 0; width: 0; height: 1px; pointer-events: none; }
    #snaps > i { position: absolute; top: 0; width: 1px; height: 1px; scroll-snap-align: start; scroll-snap-stop: always; }
    :where(.chapter) { box-sizing: border-box; }
    :where(.chapter p) {
      margin: 0 0 var(--reader-para); text-indent: var(--reader-indent); text-align: var(--reader-align);
      letter-spacing: var(--reader-kern); white-space: pre-wrap; line-break: strict; overflow-wrap: break-word;
      text-spacing-trim: space-all; orphans: 1; widows: 1;
    }
    :where(.chap-head) { break-inside: avoid; margin-bottom: 34px; }
    :where(.chap-no) {
      font-size: .68em; letter-spacing: .15em; color: var(--reader-secondary); margin: 11px 0 10px; line-height: 1.3;
    }
    :where(.chap-title) { font-size: 1.4em; font-weight: 700; letter-spacing: 1.5px; margin: 0; line-height: 1.35; }
    :where(.chapter figure) { margin: 0 0 var(--reader-para); text-align: center; break-inside: avoid; }
    :where(.chapter figure img) { max-width: 100%; max-height: calc(var(--reader-page-height) - 8px); object-fit: contain; }
    :where(.chapter img.inline) { height: 1em; width: auto; vertical-align: -.12em; }
    :where(.comment) {
      display: inline-block; min-width: 1.2em; padding: 0 .4em; margin-left: .3em; border-radius: .8em;
      font-size: .62em; line-height: 1.6; text-indent: 0; vertical-align: .2em; text-align: center;
      color: var(--reader-secondary); border: 1px solid currentColor;
    }
    :where(.header, .footer) {
      position: absolute; display: flex; justify-content: space-between; align-items: center;
      font-size: 11px; line-height: 14px; letter-spacing: .5px; color: var(--reader-secondary);
      white-space: nowrap; pointer-events: none; font-family: -apple-system, "PingFang SC", sans-serif;
    }
    :where(.header, .footer) > .center { position: absolute; left: 50%; transform: translateX(-50%); }
    :where(.header, .footer) > span { overflow: hidden; text-overflow: ellipsis; max-width: 60%; }
    :where(.placeholder) {
      display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px;
      height: var(--reader-page-height); text-align: center; color: var(--reader-secondary); font-size: 15px;
    }
    :where(.placeholder) b { font-size: 20px; color: var(--reader-ink); font-weight: 600; }
    :where(.placeholder) button {
      font: inherit; color: var(--reader-ink); background: rgba(127,127,127,.14); border: 0;
      border-radius: 20px; padding: 9px 26px;
    }
    :where(.chap-end) { padding: 3em 0 40vh; text-align: center; font-size: 13px; color: var(--reader-secondary); text-indent: 0; }
    .paged .chap-end { display: none; }
    :where([data-scrub]) { container-type: inline-size; }
    :where([data-scrub-ticks]) { position: absolute; inset: 0; pointer-events: none; }
    :where([data-scrub-ticks] > i) { position: absolute; top: 50%; left: calc(var(--k) * 100%); }
    #scrub-hit { position: absolute; z-index: 5; touch-action: none; -webkit-user-select: none; user-select: none; background: rgba(0,0,0,.002); will-change: transform; }
    #scrub-hit[hidden] { display: none; }
    :where(#scrub-tip) {
      position: absolute; z-index: 6; box-sizing: border-box; width: min(232px, 70vw); padding: 9px 12px 10px;
      border-radius: 14px; background: var(--reader-paper); color: var(--reader-ink);
      box-shadow: 0 8px 28px rgba(0,0,0,.18), 0 0 0 .5px rgba(0,0,0,.1);
      font: 12px/1.5 -apple-system, "PingFang SC", sans-serif; text-indent: 0; pointer-events: none;
      opacity: 0; transform: translate(-50%, 8px) scale(.96); transform-origin: 50% 100%;
      transition: opacity .16s, transform .22s cubic-bezier(.3, 1.3, .5, 1);
    }
    :where(#scrub-tip) b { display: block; font-size: 13px; font-weight: 600; margin-bottom: 2px; font-variant-numeric: tabular-nums; }
    :where(#scrub-tip) span {
      display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; color: var(--reader-secondary);
    }
    .scrubbing #scrub-tip { opacity: 1; transform: translate(-50%, 0) scale(1); }
    ::highlight(speak) { background-color: var(--reader-mark); }
    """

    /// 分页运行时：`window.reader` 由原生调用，`webkit.messageHandlers.reader` 回传事件
    static let runtimeJS = #"""
    (function () {
      'use strict';
      const post = (type, data) => {
        try { webkit.messageHandlers.reader.postMessage(Object.assign({ type: type }, data || {})); } catch (e) {}
      };
      window.__reportError = e => post('error', { message: String(e && e.message || e) + (e && e.line ? '（第 ' + e.line + ' 行）' : '') });
      window.addEventListener('error', e => post('error', { message: (e.message || '脚本错误') + (e.lineno ? '（第 ' + e.lineno + ' 行）' : '') }));
      console.log = function () { post('log', { message: Array.prototype.map.call(arguments, String).join(' ') }); };
      console.error = console.warn = console.log;

      const R = window.reader = {};
      const $ = id => document.getElementById(id);
      /// 停在章末的稳定偏移（原生按「超过章长」处理）
      const END = 1 << 30;
      let page, viewport, track, snaps, headerEl, footerEl, fontStyle, decorEl;
      let cfg = { mode: 'page', turn: 'slide', safeTop: 47, safeBottom: 34, menu: false, tapBoth: false, interactive: true, vars: {} };
      /// 仿真翻页截下一页时为 true：滚动只为截图，不上报阅读位置，也不改当前章
      let quiet = false;
      /// 仍有效的截图代号。作废后，晚到的 arm / hold / jump 不准再把正文拖走
      let minShot = 0, shotToken = 0;
      /// 用户真正在读的位置。截图滚到邻页时 cur 不变，重排也回到这里，避免章节乱跳
      let spot = null;
      /// 定位失败时用来取消过期的重试
      let pin = 0;
      /// 按章序排列：{ index, key, meta, el, start（首页在轨道上的页号）, count, fromEnd（占位页是从后一章翻回来的） }
      let chapters = [];
      let cur = null;
      let W = 1, H = 1, padL = 0, padR = 0, textTop = 0, textBottom = 0, total = 1, shown = -1, shownCh = null;
      /// 手指按着或滚动没停时不动排版，新内容与重排排队到停稳后
      let touching = false, scrolling = false, scrollTimer = 0, queued = null, dirty = false;
      let reportTimer = 0;
      /// 定位目标那一章还是占位页时先记住偏移，等正文到了再定位过去
      let pendingFocus = null;

      const hook = name => typeof window[name] === 'function' ? window[name] : null;
      const call = (fn, args) => { try { return fn.apply(null, args); } catch (e) { window.__reportError(e); return null; } };
      const paged = () => cfg.mode !== 'scroll';
      const busy = () => touching || scrolling;
      const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

      // MARK: 布局

      function measure() {
        const cs = getComputedStyle(page);
        const num = v => parseFloat(v) || 0;
        const top = Math.max(cfg.safeTop, 24), bottom = Math.max(cfg.safeBottom, 12);
        padL = num(cs.paddingLeft);
        padR = num(cs.paddingRight);
        headerEl.style.top = top + 'px';
        footerEl.style.bottom = (bottom + 1) + 'px';
        [headerEl, footerEl].forEach(el => { el.style.left = padL + 'px'; el.style.right = padR + 'px'; });
        textTop = top + num(cs.paddingTop);
        textBottom = bottom + 15 + num(cs.paddingBottom) - 4;
        page.style.setProperty('--safe-top', top + 'px');
        page.style.setProperty('--safe-bottom', bottom + 'px');
        page.style.setProperty('--text-top', textTop + 'px');
        page.style.setProperty('--text-bottom', textBottom + 'px');
        W = Math.max(1, Math.round(page.clientWidth));
        H = Math.max(1, Math.round(page.clientHeight - textTop - textBottom));
        document.documentElement.style.setProperty('--reader-page-height', H + 'px');
        page.classList.toggle('paged', paged());
        page.classList.toggle('scroll-mode', !paged());
        page.classList.toggle('static', !cfg.interactive);
        page.classList.toggle('curl', paged() && cfg.turn === 'curl');
        viewport.style.top = paged() ? '0' : textTop + 'px';
        viewport.style.bottom = paged() ? '0' : textBottom + 'px';
      }

      function layout() {
        measure();
        if (!paged()) {
          chapters.forEach(ch => {
            ch.el.style.cssText = ch === cur ? 'position:relative;padding:0 ' + padR + 'px 0 ' + padL + 'px' : 'display:none';
            ch.start = 0;
            ch.count = 1;
          });
          total = 1;
          track.style.width = '';
          snaps.innerHTML = '';
          placeScrub();
          return;
        }
        const gap = padL + padR, colW = Math.max(1, W - gap);
        let start = 0;
        chapters.forEach(ch => {
          ch.el.style.cssText = 'position:absolute;top:' + textTop + 'px;left:' + (start * W + padL) + 'px;width:' + colW
            + 'px;height:' + H + 'px;column-width:' + colW + 'px;column-gap:' + gap + 'px;column-fill:auto';
          ch.start = start;
          // 多栏宽度理论值是整数页。floor 比 round 稳，差一两个像素不会多出一页、把章界挤歪
          ch.count = ch.meta.placeholder ? 1 : Math.max(1, Math.floor((ch.el.scrollWidth + gap) / W + 0.02));
          start += ch.count;
        });
        total = Math.max(1, start);
        track.style.width = total * W + 'px';
        let marks = '';
        for (let i = 0; i < total; i++) marks += '<i style="left:' + i * W + 'px"></i>';
        snaps.innerHTML = marks;
        placeScrub();
      }

      let scrubBoxKey = '';
      function publishScrubBox() {
        if (!scrubHit) return;
        const hidden = !!scrubHit.hidden;
        const box = hidden ? 'x' : [scrubHit.style.left, scrubHit.style.top, scrubHit.style.width, scrubHit.style.height].join(',');
        if (box === scrubBoxKey) return;
        scrubBoxKey = box;
        post('scrubbox', hidden ? { hidden: true } : {
          x: parseFloat(scrubHit.style.left) || 0, y: parseFloat(scrubHit.style.top) || 0,
          w: parseFloat(scrubHit.style.width) || 0, h: parseFloat(scrubHit.style.height) || 0, hidden: false
        });
      }

      const pageNow = () => paged() ? clamp(Math.round(viewport.scrollLeft / W), 0, total - 1) : 0;

      function locate(g) {
        for (const ch of chapters) if (g < ch.start + ch.count) return ch;
        return chapters[chapters.length - 1] || null;
      }

      function setCurrent(ch) {
        if (!ch || ch === cur) return;
        if (cur && ch.meta.placeholder) ch.fromEnd = ch.index < cur.index;
        if (pendingFocus && pendingFocus.chapter !== ch.index) pendingFocus = null;
        if (cur) cur.el.removeAttribute('id');
        cur = ch;
        ch.el.id = 'chapter';
      }

      /// commit 为 false 时只挪滚动（截图），不改当前章
      function scrollToPage(g, smooth, commit) {
        g = clamp(g, 0, Math.max(0, total - 1));
        if (smooth) {
          viewport.scrollTo({ left: g * W, behavior: 'smooth' });
          return;
        }
        viewport.scrollLeft = g * W;
        if (commit !== false) {
          setCurrent(locate(g));
          remember();
        }
      }

      // MARK: 偏移

      const blocks = ch => ch.el.querySelectorAll('[data-o]');

      /// 稳定偏移 → 文本里的点 {node, offset}
      function point(ch, offset) {
        let target = null;
        for (const el of blocks(ch)) { if (+el.dataset.o <= offset) target = el; else break; }
        if (!target) return null;
        let remain = Math.min(offset - +target.dataset.o, +target.dataset.len);
        const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
        let node, last = null;
        while ((node = walker.nextNode())) {
          if (node.nodeType === 1) {
            if (node.classList.contains('comment')) break;
            if (node.tagName === 'IMG') { if (remain < 1) return { node: node, img: true }; remain -= 1; }
            continue;
          }
          if (node.parentElement.closest('.comment')) break;
          last = node;
          if (remain < node.length) return { node: node, offset: remain };
          remain -= node.length;
        }
        if (last) return { node: last, offset: last.length };
        return { node: target, el: true };
      }

      function rectOf(ch, offset) {
        const p = point(ch, offset);
        if (!p) return null;
        if (p.img || p.el) return p.node.getClientRects()[0] || p.node.getBoundingClientRect();
        const r = document.createRange();
        r.setStart(p.node, p.offset);
        r.setEnd(p.node, Math.min(p.node.length, p.offset + 1));
        const rects = r.getClientRects();
        return rects[0] || r.getBoundingClientRect();
      }

      /// 文本里的点 → 稳定偏移
      function offsetAt(node, inner) {
        const el = (node.nodeType === 1 ? node : node.parentElement).closest('[data-o]');
        if (!el) return null;
        const r = document.createRange();
        r.setStart(el, 0);
        try { r.setEnd(node, inner); } catch (e) { return +el.dataset.o; }
        const images = r.cloneContents().querySelectorAll('img.inline').length;
        return +el.dataset.o + Math.min(+el.dataset.len, r.toString().length + images);
      }

      function caret(ch, cx, cy) {
        const range = document.caretRangeFromPoint(cx, cy);
        if (!range || !ch.el.contains(range.startContainer)) return null;
        return offsetAt(range.startContainer, range.startOffset);
      }

      /// 正文区在屏幕上的范围
      function textRect() {
        if (!paged()) return viewport.getBoundingClientRect();
        return { left: padL, right: W - padR, top: textTop, bottom: textTop + H };
      }

      /// 屏幕上能看到的稳定偏移范围
      function visibleRange(ch) {
        if (ch.meta.placeholder) return ch.fromEnd ? [END, END + 1] : [0, 1];
        const v = textRect();
        let first = null, lastEl = null;
        for (const el of blocks(ch)) {
          const rects = el.getClientRects();
          for (const r of rects) {
            if (r.right > v.left + 1 && r.left < v.right - 1 && r.bottom > v.top + 1 && r.top < v.bottom - 1) {
              if (!first) first = { el: el, r: r };
              lastEl = { el: el, r: r };
            }
          }
          if (first && rects.length && (paged() ? rects[0].left > v.right : rects[0].top > v.bottom)) break;
        }
        if (!first) return null;
        const fr = first.r;
        let start = caret(ch, Math.max(fr.left, v.left) + 2, Math.max(fr.top, v.top) + 6);
        if (start == null || start < +first.el.dataset.o) start = +first.el.dataset.o;
        const lr = lastEl.r;
        let end = caret(ch, Math.min(lr.right, v.right) - 2, Math.min(lr.bottom, v.bottom) - 6);
        if (end == null || end < start) end = +lastEl.el.dataset.o + +lastEl.el.dataset.len;
        return [start, Math.max(start + 1, end)];
      }

      /// 翻页模式：偏移在本章第几页；滚动模式：偏移离顶部的距离。这一帧量不到字时返回 null，调用方不许当成第 0 页
      function pageOf(ch, offset) {
        const r = rectOf(ch, offset);
        if (!r || (!r.width && !r.height)) return null;
        if (!paged()) return r.top - viewport.getBoundingClientRect().top + viewport.scrollTop;
        const g = Math.floor((r.left + viewport.scrollLeft - padL + 1) / W);
        return clamp(g - ch.start, 0, ch.count - 1);
      }

      /// 字体还没排出来时晚一帧再定位。截图进行中先等它结束，不把这次定位丢掉，也不许滚掉正在截的那一页
      function laterGo(token, ch, offset, localHint, tries, waits) {
        requestAnimationFrame(() => {
          if (token !== pin || cur !== ch) return;
          if (quiet) {
            if (waits > 90) { dirty = true; return; }
            laterGo(token, ch, offset, localHint, tries, waits + 1);
            return;
          }
          goTo(ch, offset, localHint, tries + 1);
        });
      }

      function goTo(ch, offset, localHint, tries) {
        if (!ch || quiet) return;
        tries = tries || 0;
        const token = ++pin;
        const length = ch.meta.length || 0;
        const atEnd = !ch.meta.placeholder && length > 0 && offset >= length;
        if (!paged()) {
          if (ch.meta.placeholder || offset <= 0) viewport.scrollTop = 0;
          else if (atEnd) viewport.scrollTop = viewport.scrollHeight;
          else {
            const y = pageOf(ch, offset);
            if (y == null) {
              if (tries < 8) laterGo(token, ch, offset, localHint, tries, 0);
              return;
            }
            viewport.scrollTop = Math.max(0, y - 4);
          }
          remember();
          return;
        }
        let local = 0;
        if (atEnd) local = ch.count - 1;
        else if (!ch.meta.placeholder && offset > 0) {
          const measured = pageOf(ch, offset);
          if (measured == null) {
            const hint = localHint != null ? localHint : (spot && spot.chapter === ch.index ? spot.local : null);
            if (hint == null && tries < 8) { laterGo(token, ch, offset, localHint, tries, 0); return; }
            local = hint == null ? 0 : clamp(hint, 0, ch.count - 1);
          } else local = measured;
        }
        scrollToPage(ch.start + local, false, true);
      }

      /// 记下用户正在读的章和页。截图滚动、量不到字时不覆盖
      function remember() {
        if (quiet || !cur) return;
        if (cur.meta.placeholder) {
          spot = { chapter: cur.index, offset: cur.fromEnd ? END : 0, local: 0 };
          return;
        }
        const r = visibleRange(cur);
        if (!r) return;
        spot = { chapter: cur.index, offset: r[0], local: clamp(pageNow() - cur.start, 0, Math.max(0, cur.count - 1)) };
      }

      /// 当前看到的位置，重排后据此回到原处。截图时屏幕上是邻页，必须用记下的位置
      function anchor() {
        if ((quiet || !cur) && spot) return spot;
        if (!cur) return null;
        const r = visibleRange(cur);
        if (!r) return (spot && spot.chapter === cur.index) ? spot : { chapter: cur.index, offset: 0, local: 0 };
        const local = paged() ? clamp(pageNow() - cur.start, 0, Math.max(0, cur.count - 1)) : 0;
        return { chapter: cur.index, offset: r[0], local: local };
      }

      function rebuild(a) {
        const ch = (a && chapters.find(c => c.index === a.chapter)) || (chapters.includes(cur) ? cur : null) || chapters[0] || null;
        if (cur && cur !== ch) cur.el.removeAttribute('id');
        cur = ch;
        if (ch) ch.el.id = 'chapter';
        layout();
        if (ch) goTo(ch, a && a.chapter === ch.index ? a.offset : 0, a && a.chapter === ch.index ? a.local : null);
        shown = -1;
        report();
        // 版式或图片变了，通知原生把盖住的那一页重新截一次。页号没变时 pages 不会再发
        if (cfg.turn === 'curl') post('repaint');
      }

      let relayoutTimer = 0;
      function relayout() {
        clearTimeout(relayoutTimer);
        relayoutTimer = setTimeout(() => {
          if (busy() || quiet) { dirty = true; return; }
          rebuild(anchor());
        }, 60);
      }
      R.relayout = relayout;

      /// 停稳后补上排队的内容与重排
      function flush() {
        if (queued) {
          const q = queued;
          queued = null;
          dirty = false;
          apply(q[0], q[1]);
        } else if (dirty) {
          dirty = false;
          rebuild(anchor());
        }
      }

      // MARK: 页眉页脚与进度

      /// 屏幕上（过半即算）是哪一章的第几页：翻页模式是轨道页号，滚动模式是第几屏
      function where() {
        if (paged()) { const g = pageNow(); return { ch: locate(g), g: g }; }
        return { ch: cur, g: Math.floor(viewport.scrollTop / Math.max(1, viewport.clientHeight)) };
      }

      function context(ch, g) {
        const m = ch ? ch.meta : {};
        let pageNo = 1, pages = 1, fraction = 1;
        if (ch && paged()) {
          pages = ch.count;
          pageNo = clamp(g - ch.start + 1, 1, pages);
          fraction = pageNo / pages;
        } else if (ch) {
          const vh = Math.max(1, viewport.clientHeight);
          pages = Math.max(1, Math.ceil(viewport.scrollHeight / vh) - 1);
          pageNo = Math.min(pages, g + 1);
          fraction = viewport.scrollHeight > vh ? viewport.scrollTop / (viewport.scrollHeight - vh) : 1;
        }
        const total = Math.max(1, m.chapterCount || 1);
        const d = new Date();
        const pad = n => (n < 10 ? '0' : '') + n;
        return {
          book: m.book || '', author: m.author || '', chapter: m.title || '',
          chapterIndex: m.index || 0, chapterCount: total, page: pageNo, pages: pages,
          percent: Math.min(100, ((m.index || 0) + fraction) / total * 100),
          chapterProgress: Math.min(1, fraction),
          time: pad(d.getHours()) + ':' + pad(d.getMinutes()), battery: m.battery == null ? -1 : m.battery
        };
      }

      function fill(el, value) {
        const spans = el.children;
        const set = (i, t) => { spans[i].textContent = t == null ? '' : String(t); };
        if (value == null) value = {};
        if (typeof value !== 'object') value = { left: value };
        set(0, value.left); set(1, value.center); set(2, value.right);
      }

      const vars = {};
      function setVar(name, value) {
        if (vars[name] === value) return;
        vars[name] = value;
        page.style.setProperty(name, value);
      }

      function fillIfChanged(el, value) {
        const key = JSON.stringify(value);
        if (el.__key === key) return;
        el.__key = key;
        fill(el, value);
      }

      /// 页眉页脚、页面类名与 readerpage 事件。滑动途中过半就换（此时装饰正好淡到最弱），不等停稳
      function chrome() {
        const at = where();
        shown = at.g;
        shownCh = at.ch;
        const ctx = context(at.ch, at.g);
        R.ctx = ctx;
        const h = hook('header'), f = hook('footer');
        let head = h ? call(h, [ctx]) : null;
        let foot = f ? call(f, [ctx]) : null;
        if (head == null) head = { left: ctx.page === 1 ? ctx.book : ctx.chapter };
        if (foot == null) foot = { left: ctx.page + ' / ' + ctx.pages, right: ctx.percent.toFixed(1) + '%' };
        if (!at.ch || at.ch.meta.placeholder) { head = { left: ctx.book }; foot = {}; }
        fillIfChanged(headerEl, head);
        fillIfChanged(footerEl, foot);
        setVar('--progress', (ctx.percent / 100).toFixed(4));
        setVar('--chapter-progress', ctx.chapterProgress.toFixed(4));
        setVar('--battery', ctx.battery < 0 ? '1' : (ctx.battery / 100).toFixed(2));
        if (page.dataset.page !== String(ctx.page)) page.dataset.page = ctx.page;
        if (page.classList.contains('first-page') !== (ctx.page === 1)) page.classList.toggle('first-page', ctx.page === 1);
        if (page.classList.contains('last-page') !== (ctx.page === ctx.pages)) page.classList.toggle('last-page', ctx.page === ctx.pages);
        document.dispatchEvent(new CustomEvent('readerpage', { detail: ctx }));
        motion();
        scrubState();
      }

      /// 每帧只写一个变量 --page-pos（当前页在本章的位置：首页 0、末页 1），而且只写在页码条上：
      /// 自定义属性一变，它所在元素的整棵子树都要重算样式，写在整个装饰层上每帧要多花几倍时间。
      /// 没有页码条的主题只在页码变化时写到 #decor 上
      let posTarget = null, posValue = '';
      function setPos(value) {
        const v = value.toFixed(4);
        const el = scrubEl || decorEl;
        if (!el || (posValue === v && posTarget === el)) return;
        posValue = v;
        posTarget = el;
        el.style.setProperty('--page-pos', v);
      }
      function motion() {
        if (scrub) return;
        const ch = shownCh;
        let pos = 1;
        if (ch && ch.meta.placeholder) pos = 0;
        else if (ch && paged()) {
          const x = scrubEl ? viewport.scrollLeft / W : pageNow();
          pos = ch.count > 1 ? clamp((x - ch.start) / (ch.count - 1), 0, 1) : 1;
        } else if (ch) {
          const max = viewport.scrollHeight - viewport.clientHeight;
          pos = max > 0 ? clamp(viewport.scrollTop / max, 0, 1) : 1;
        }
        setPos(pos);
      }

      let motionFrame = 0;
      function follow() {
        motionFrame = 0;
        const at = where();
        if (at.g !== shown || at.ch !== shownCh) chrome();
        else if (scrubEl) motion();
      }

      // MARK: 页码条（装饰层里带 data-scrub 的元素）

      /// 拖动中：{ ch, n（本章页数）, p（指着第几页，从 0 起）, texts（每页开头的文字） }
      let scrub = null, scrubEl = null, scrubHit = null, scrubTip = null, ticksKey = '';

      /// 本章可以拖到的页数：翻页模式是本章页数，滚动模式按屏算
      function scrubPages(ch) {
        if (!ch || ch.meta.placeholder) return 1;
        if (paged()) return ch.count;
        const vh = Math.max(1, viewport.clientHeight), max = viewport.scrollHeight - vh;
        return max > 0 ? Math.ceil(max / vh) + 1 : 1;
      }

      function scrubIndex(ch) {
        if (!ch) return 0;
        if (paged()) return clamp(pageNow() - ch.start, 0, ch.count - 1);
        const vh = Math.max(1, viewport.clientHeight), max = viewport.scrollHeight - vh;
        return viewport.scrollTop >= max - 1 ? scrubPages(ch) - 1 : Math.floor(viewport.scrollTop / vh);
      }

      /// 每页开头的一小段文字：段落在多栏里每跨一栏有一个矩形，按矩形高度估算这一栏从第几个字开始
      function pageTexts(ch, n) {
        const out = new Array(n).fill('');
        if (!ch || ch.meta.placeholder) return out;
        const vr = viewport.getBoundingClientRect(), vh = Math.max(1, viewport.clientHeight);
        const at = r => paged()
          ? Math.floor((r.left - vr.left + viewport.scrollLeft - padL + 1) / W) - ch.start
          : Math.floor((r.top - vr.top + viewport.scrollTop) / vh);
        for (const el of blocks(ch)) {
          const rects = Array.from(el.getClientRects()).filter(r => r.height > 0);
          if (!rects.length) continue;
          const text = el.textContent.replace(/\s+/g, ' ');
          const sum = rects.reduce((s, r) => s + r.height, 0);
          let before = 0;
          for (const r of rects) {
            const p = at(r);
            if (p >= 0 && p < n && !out[p]) {
              const from = Math.floor(before / sum * text.length);
              const rest = text.slice(from).replace(/^[\s，。、；：！？,.;:!?”」』）)]+/, '').slice(0, 60);
              out[p] = from > 0 ? '…' + rest : rest;
            }
            before += r.height;
          }
        }
        for (let i = 1; i < n; i++) if (!out[i]) out[i] = out[i - 1];
        return out;
      }

      /// 刻度：每页一个 <i>，style 里的 --k 是位置（0…1）；已读过的带 .read，当前页带 .now。超过 80 页时隔几页画一个
      function paintTicks(ch) {
        const box = scrubEl && scrubEl.querySelector('[data-scrub-ticks]');
        if (!box) return;
        const n = scrubPages(ch), step = Math.max(1, Math.ceil(n / 80));
        const key = (ch ? ch.key : '') + '|' + n + '|' + paged();
        if (key !== ticksKey) {
          ticksKey = key;
          let html = '';
          for (let i = 0; i < n; i += step) html += '<i data-p="' + i + '" style="--k:' + (n > 1 ? i / (n - 1) : 0).toFixed(4) + '"></i>';
          box.innerHTML = html;
        }
        const now = scrub ? scrub.p : scrubIndex(ch);
        for (const t of box.children) {
          const p = +t.dataset.p;
          if (t.classList.contains('read') !== (p < now)) t.classList.toggle('read', p < now);
          if (t.classList.contains('now') !== (p === now)) t.classList.toggle('now', p === now);
        }
      }

      /// 透明的触摸区盖在页码条上（比它高一圈，好按），拖动不会带动正文
      function placeScrub() {
        if (!scrubEl) return;
        const r = scrubEl.getBoundingClientRect(), pr = page.getBoundingClientRect();
        const h = Math.max(44, r.height + 28);
        let top = r.top - pr.top + r.height / 2 - h / 2;
        const bottom = top + h;
        // iOS 上原生滚动区先于网页判断触摸：翻页模式让滚动区的底边停在触摸区上方，两者不重叠，拖页码条才不会变成翻页。
        // 触摸区最多往上伸到正文区底边，不挡正文
        if (paged() && r.top - pr.top >= pr.height - textBottom - 20) {
          top = Math.max(top, pr.height - textBottom);
          viewport.style.bottom = (pr.height - top) + 'px';
        }
        Object.assign(scrubHit.style, {
          left: (r.left - pr.left - 12) + 'px', width: (r.width + 24) + 'px', top: top + 'px', height: Math.max(24, bottom - top) + 'px'
        });
        publishScrubBox();
      }

      function scrubState() {
        if (!scrubEl) return;
        const off = !cfg.interactive || !shownCh || shownCh.meta.placeholder || scrubPages(shownCh) < 2;
        if (scrubHit.hidden !== off) { scrubHit.hidden = off; publishScrubBox(); }
        paintTicks(shownCh);
      }

      function scrubMove(x) {
        const r = scrubEl.getBoundingClientRect();
        const f = clamp((x - r.left) / Math.max(1, r.width), 0, 1);
        const p = Math.round(f * (scrub.n - 1));
        setPos(f);
        scrubEl.style.setProperty('--scrub', f.toFixed(4));
        if (p === scrub.p) return;
        scrub.p = p;
        scrubTip.firstChild.textContent = (p + 1) + ' / ' + scrub.n;
        scrubTip.lastChild.textContent = scrub.texts[p] || '';
        const pr = page.getBoundingClientRect(), half = scrubTip.offsetWidth / 2;
        const cx = r.left - pr.left + (scrub.n > 1 ? p / (scrub.n - 1) : 0) * r.width;
        scrubTip.style.left = clamp(cx, half + 10, W - half - 10) + 'px';
        scrubTip.style.bottom = (pr.bottom - r.top + 14) + 'px';
        paintTicks(scrub.ch);
        post('tick');
        document.dispatchEvent(new CustomEvent('readerscrub', { detail: { active: true, page: p + 1, pages: scrub.n, fraction: f } }));
      }

      function scrubStart(e) {
        e.stopPropagation();
        e.preventDefault();
        const ch = shownCh;
        if (!ch || busy()) return;
        const n = scrubPages(ch);
        scrub = { ch: ch, n: n, p: -1, texts: pageTexts(ch, n) };
        page.classList.add('scrubbing');
        post('scrubbing', { active: true });
        scrubMove(e.touches[0].clientX);
      }

      function scrubDrag(e) {
        e.stopPropagation();
        e.preventDefault();
        if (scrub) scrubMove(e.touches[0].clientX);
      }

      function scrubEnd(e) {
        e.stopPropagation();
        if (!scrub || e.touches.length) return;
        const s = scrub;
        scrub = null;
        page.classList.remove('scrubbing');
        post('scrubbing', { active: false });
        document.dispatchEvent(new CustomEvent('readerscrub', { detail: { active: false, page: s.p + 1, pages: s.n, fraction: s.n > 1 ? s.p / (s.n - 1) : 0 } }));
        if (s.ch !== shownCh) return motion();
        if (paged()) scrollToPage(s.ch.start + s.p, false);
        else viewport.scrollTop = Math.min(viewport.scrollHeight - viewport.clientHeight, s.p * viewport.clientHeight);
        report();
      }

      function setupScrub() {
        scrubEl = decorEl.querySelector('[data-scrub]');
        if (!scrubEl) return;
        scrubHit = document.createElement('div');
        scrubHit.id = 'scrub-hit';
        scrubTip = document.createElement('div');
        scrubTip.id = 'scrub-tip';
        scrubTip.innerHTML = '<b></b><span></span>';
        page.appendChild(scrubHit);
        page.appendChild(scrubTip);
        scrubHit.addEventListener('touchstart', scrubStart, { passive: false });
        scrubHit.addEventListener('touchmove', scrubDrag, { passive: false });
        scrubHit.addEventListener('touchend', scrubEnd);
        scrubHit.addEventListener('touchcancel', scrubEnd);
      }


      function report() {
        if (quiet) return;
        chrome();
        if (!cur) return;
        clearTimeout(reportTimer);
        reportTimer = setTimeout(() => {
          if (quiet || !cur) return;
          if (cur.meta.placeholder) {
            remember();
            const o = cur.fromEnd ? END : 0;
            post('position', { chapter: cur.index, start: o, end: o + 1 });
            return;
          }
          const r = visibleRange(cur);
          if (!r) return;
          remember();
          post('position', { chapter: cur.index, start: r[0], end: r[1] });
        }, 30);
        publishPages();
      }

      /// 进入截图：清掉还没发出的位置，避免定时器在滚到邻页之后把那一章报上去
      function holdQuiet(token) {
        quiet = true;
        if (token) shotToken = +token;
        clearTimeout(reportTimer);
        clearTimeout(scrollTimer);
        scrolling = false;
      }

      function endQuiet() {
        quiet = false;
        if (queued || dirty) flush();
        else report();
      }

      /// 把当前页号告诉原生卷页。quiet 时是在截图，不能把临时页号发出去
      let postedPage = -1, postedTotal = -1;
      function publishPages() {
        if (cfg.turn !== 'curl' || quiet || !paged()) return;
        const index = pageNow();
        if (index === postedPage && total === postedTotal) return;
        postedPage = index;
        postedTotal = total;
        post('pages', { index: index, total: total });
      }
      R.publish = function () { postedPage = -1; publishPages(); };

      // MARK: 翻页

      /// 主题写了 `--page-turn: none` 时，平移点按不播滑动。仿真由阅读器设置决定，不看这个值
      const themeStill = () => getComputedStyle(page).getPropertyValue('--page-turn').trim() === 'none';

      function turn(forward) {
        if (!cur) return;
        if (!paged()) {
          viewport.scrollBy({ top: (forward ? 1 : -1) * viewport.clientHeight * 0.88, behavior: 'smooth' });
          return;
        }
        const target = pageNow() + (forward ? 1 : -1);
        if (target < 0 || target >= total) return post('edge', { dir: forward ? 'next' : 'prev' });
        if (cfg.turn === 'curl') return post('curl', { phase: 'tap', forward: !!forward, from: pageNow(), to: target });
        const instant = cfg.turn === 'none' || themeStill();
        scrollToPage(target, !instant);
        if (instant) report();
      }

      R.turn = turn;
      R.settle = () => { if (paged()) scrollToPage(pageNow(), true); };
      /// 截下一页时先把正文滚过去，截完再滚回来。token 小于 minShot 的是已经作废的截图，不准再滚
      R.arm = function (on, token) {
        token = +token || 0;
        if (token && token < minShot) return;
        if (on) { holdQuiet(token); return; }
        if (token && shotToken && token !== shotToken) return;
        if (!quiet) return;
        endQuiet();
      };
      R.hold = function (g, token) {
        token = +token || 0;
        if (!quiet || (token && token < minShot)) {
          post('held', { token: token });
          return;
        }
        curlPin = null;
        scrollToPage(g, false, false);
        chrome();
        requestAnimationFrame(function () { requestAnimationFrame(function () { post('held', { token: token }); }); });
      };
      R.jump = function (g, token) {
        token = +token || 0;
        if (!quiet || (token && token < minShot)) return;
        scrollToPage(g, false, false);
        chrome();
      };
      /// 截图被取消。先作废旧代号，再滚回用户真正在读的那一页，然后才许上报位置
      R.abortQuiet = function (min) {
        if (min) minShot = Math.max(minShot, +min || 0);
        clearTimeout(reportTimer);
        clearTimeout(scrollTimer);
        scrolling = false;
        const was = quiet;
        quiet = false;
        if (!was) return;
        if (spot && paged()) {
          const ch = chapters.find(c => c.index === spot.chapter);
          if (ch) goTo(ch, spot.offset, spot.local);
        }
        if (queued || dirty) flush();
        else report();
      };
      /// 轨道尽头才算换章。邻页截图还没好时松手不算到了章界
      R.atEdge = function (forward) {
        if (!paged() || quiet) return false;
        const target = pageNow() + (forward ? 1 : -1);
        return target < 0 || target >= total;
      };
      /// 滚回真正停着的那一页，并恢复位置上报。揭开遮罩前用它，避免揭开时还停在截图用的邻页
      R.rest = function (g) {
        quiet = true;
        scrollToPage(g, false, true);
        quiet = false;
        remember();
        endQuiet();
      };
      R.land = function (g) {
        quiet = true;
        scrollToPage(g, false, true);
        quiet = false;
        remember();
        endQuiet();
      };
      R.edgeGo = function (forward) { post('edge', { dir: forward ? 'next' : 'prev' }); };
      /// 点在系统卷页上时，先问网页这下是翻页、菜单，还是贴纸
      R.hit = function (x, y) {
        const target = document.elementFromPoint(x, y);
        const closest = sel => target && target.closest && target.closest(sel);
        if (closest('#scrub-hit, [data-scrub]')) return 'scrub';
        const comment = closest('[data-comment]');
        if (comment) { post('action', { paragraph: +comment.dataset.comment }); return 'used'; }
        if (closest('[data-retry]')) { post('retry'); return 'used'; }
        const tap = closest('[data-tap]');
        if (tap) {
          tap.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: x, clientY: y }));
          return 'used';
        }
        if (closest('a, button, input')) return 'used';
        if (cfg.menu || (x > W / 3 && x < W * 2 / 3)) return 'menu';
        return (cfg.tapBoth || x >= W * 2 / 3) ? 'next' : 'prev';
      };
      /// 长按选词：交给系统的词粒度，选中后网页自己弹出选区
      R.selectWord = function (x, y) {
        const hit = document.elementFromPoint(x, y);
        if (!hit || (hit.closest && hit.closest('#scrub-hit, [data-scrub], [data-tap], button, a'))) return;
        let range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (!range && document.caretPositionFromPoint) {
          const pos = document.caretPositionFromPoint(x, y);
          if (pos) { range = document.createRange(); range.setStart(pos.offsetNode, pos.offset); range.collapse(true); }
        }
        if (!range) return;
        const sel = getSelection();
        sel.removeAllRanges();
        sel.collapse(range.startContainer, range.startOffset);
        try {
          sel.modify('move', 'backward', 'word');
          sel.modify('extend', 'forward', 'word');
        } catch (e) {}
        if (sel.isCollapsed) return;
      };

      function hasSelection() {
        const s = window.getSelection();
        return s && !s.isCollapsed && s.toString().length > 0;
      }

      /// 与原生一致：左三分之一上一页、右三分之一下一页、中间呼出菜单
      function tap(cx) {
        if (cfg.menu || !paged()) return post('menu');
        if (cx > W / 3 && cx < W * 2 / 3) return post('menu');
        turn(cfg.tapBoth || cx >= W * 2 / 3);
      }

      let touch = null;
      /// 仿真拖动：{ forward, from, to, progress, edge }
      let curl = null;
      /// 卷页手势进行中把正文钉在起始页，避免手指把横向滚动容器带走；截下一页前会放开
      let curlPin = null;
      function onStart(e) {
        touching = e.touches.length > 0;
        if (!cfg.interactive || e.touches.length > 1) { touch = null; return; }
        const t = e.touches[0];
        const el = e.target.nodeType === 1 ? e.target : e.target.parentElement;
        const scrubbing = !!(el && el.closest && el.closest('#scrub-hit, [data-scrub]'));
        touch = { x: t.clientX, y: t.clientY, dy: 0, t: Date.now(), left: viewport.scrollLeft, top: viewport.scrollTop,
                  moved: false, selecting: hasSelection(), scrubbing: scrubbing };
      }
      function onMove(e) {
        if (!touch) return;
        const t = e.touches[0];
        const dx = t.clientX - touch.x;
        touch.dy = t.clientY - touch.y;
        if (Math.abs(dx) > 10 || Math.abs(touch.dy) > 10) touch.moved = true;
        // 仿真由盖在上面的系统卷页跟手。覆盖和平移靠滚动容器自己滑，这里不再卷
      }
      function endCurl() {
        if (!curl) return;
        const drag = curl;
        curl = null;
        curlPin = null;
        if (drag.edge) { if (drag.fire) post('edge', { dir: drag.forward ? 'next' : 'prev' }); return; }
        const dt = Math.max(1, Date.now() - (drag.t || Date.now()));
        const velocity = (drag.forward ? -(drag.dx || 0) : (drag.dx || 0)) / dt * 1000 / Math.max(1, W);
        post('curl', { phase: 'end', progress: drag.progress, velocity: velocity, forward: drag.forward, from: drag.from, to: drag.to });
      }
      function onEnd(e) {
        touching = e.touches.length > 0;
        const tt = touch;
        touch = null;
        if (curl) { endCurl(); return; }
        if (!busy()) flush();
        if (!tt) return;
        if (!paged() && cur && !cur.meta.placeholder) {
          const max = viewport.scrollHeight - viewport.clientHeight;
          if (tt.dy < -70 && tt.top >= max - 2 && cur.meta.hasNext) return post('edge', { dir: 'next' });
          if (tt.dy > 70 && tt.top <= 0 && cur.meta.hasPrev) return post('edge', { dir: 'prev' });
        }
        const scrolled = Math.abs(viewport.scrollLeft - tt.left) > 2 || Math.abs(viewport.scrollTop - tt.top) > 2;
        if (tt.moved || scrolled || Date.now() - tt.t > 380) return;
        if (tt.selecting || hasSelection()) { window.getSelection().removeAllRanges(); return; }
        const target = e.target;
        if (target.closest && target.closest('[data-comment]')) {
          return post('action', { paragraph: +target.closest('[data-comment]').dataset.comment });
        }
        if (target.closest && target.closest('[data-retry]')) return post('retry');
        if (target.closest && target.closest('a, button, input, [data-tap]')) return;
        // 装饰层在正文滚动区下面：按坐标找到可点的贴纸，替它派发 click
        const under = document.elementsFromPoint(tt.x, tt.y)
          .map(el => el.closest && el.closest('[data-tap]'))
          .find(el => el && !viewport.contains(el));
        if (under) {
          under.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: tt.x, clientY: tt.y }));
          return;
        }
        tap(tt.x);
      }

      function settled() {
        clearTimeout(scrollTimer);
        scrolling = false;
        if (quiet || touching) return;
        if (paged()) setCurrent(locate(pageNow()));
        flush();
        report();
      }

      /// 滑动途中只更新装饰层（每帧一次）；换章、上报位置、排队的重排都等停稳。截图滚动不排队
      function onScroll() {
        if (quiet) return;
        scrolling = true;
        if (!motionFrame) motionFrame = requestAnimationFrame(follow);
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(settled, 100);
      }

      // MARK: 原生调用

      R.configure = function (c) {
        const a = anchor();
        quiet = false;
        cfg = Object.assign(cfg, c);
        const root = document.documentElement.style;
        Object.keys(cfg.vars || {}).forEach(k => root.setProperty(k, cfg.vars[k]));
        rebuild(a);
      };

      R.setMenu = v => { cfg.menu = v; };

      R.setFonts = css => { fontStyle.textContent = css; relayout(); };

      function classify(el) {
        const fn = hook('paragraphClass');
        if (!fn) return;
        el.querySelectorAll('p[data-i]').forEach(p => {
          const name = call(fn, [p.textContent, +p.dataset.i]);
          if (name) String(name).split(/\s+/).filter(Boolean).forEach(n => p.classList.add(n));
        });
      }

      const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

      function render(ch, item) {
        const el = ch.el;
        el.className = 'chapter';
        el.dataset.chapter = ch.index;
        if (item.placeholder) {
          const p = item.placeholder;
          el.innerHTML = '<div class="placeholder"><b>' + esc(p.title) + '</b><span>' + esc(p.message) + '</span>'
            + (p.failed ? '<button data-retry>重试</button>' : '') + '</div>';
          return;
        }
        el.innerHTML = item.html + (ch.meta.hasNext ? '<div class="chap-end">上拉进入下一章</div>' : '');
        classify(el);
        const ready = hook('chapterReady');
        const m = ch.meta;
        if (ready) call(ready, [el, { index: m.index || 0, title: m.title || '', book: m.book || '', author: m.author || '', chapterCount: m.chapterCount || 1 }]);
        el.querySelectorAll('img').forEach(img => {
          img.decoding = 'async';
          if (!img.complete) img.addEventListener('load', relayout, { once: true });
        });
      }

      /// 换上新的章节窗口（上一章、本章、下一章）。未变的章原样保留，排版后回到原来看到的位置；
      /// `focus.force` 时（打开、目录跳转）改为定位到 focus 指定的偏移
      function apply(list, focus) {
        if (focus.force) pendingFocus = { chapter: focus.chapter, offset: focus.offset };
        let a = focus.force ? pendingFocus : (anchor() || { chapter: focus.chapter, offset: focus.offset });
        if (!focus.force && pendingFocus && cur && cur.index === pendingFocus.chapter) a = pendingFocus;
        const old = new Map(chapters.map(c => [c.index, c]));
        const next = [];
        list.forEach(item => {
          const index = item.meta.index;
          const prev = old.get(index);
          old.delete(index);
          if (prev && prev.key === item.key) {
            prev.meta = item.meta;
            next.push(prev);
            return;
          }
          const ch = { index: index, key: item.key, meta: item.meta, el: prev ? prev.el : document.createElement('article'),
                       start: 0, count: 1, fromEnd: prev ? prev.fromEnd : false };
          if (cur === prev) cur = ch;
          render(ch, item);
          next.push(ch);
        });
        old.forEach(c => { if (cur === c) cur = null; c.el.remove(); });
        chapters = next.sort((x, y) => x.index - y.index);
        chapters.forEach(c => { if (c.el.parentNode !== track) track.appendChild(c.el); });
        rebuild(a);
        const target = pendingFocus && chapters.find(c => c.index === pendingFocus.chapter);
        if (target && !target.meta.placeholder) pendingFocus = null;
        applySpeak();
      }

      R.setChapters = function (list, focus) {
        if ((busy() || quiet) && !(focus && focus.force)) { queued = [list, focus]; return; }
        if (focus && focus.force) quiet = false;
        queued = null;
        apply(list, focus);
      };

      R.goPage = n => { if (cur) { scrollToPage(cur.start + n, false); report(); } };

      let spoken = null;
      function applySpeak() {
        if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') return;
        CSS.highlights.delete('speak');
        const ch = spoken && chapters.find(c => c.index === spoken.chapter);
        if (!ch || ch.meta.placeholder) return;
        const a = point(ch, spoken.start), b = point(ch, spoken.end);
        if (!a || !b || a.img || b.img || a.el || b.el) return;
        const r = document.createRange();
        r.setStart(a.node, a.offset);
        r.setEnd(b.node, b.offset);
        CSS.highlights.set('speak', new Highlight(r));
      }
      R.speak = function (chapter, start, end) {
        spoken = chapter == null ? null : { chapter: chapter, start: start, end: end };
        applySpeak();
      };
      /// 朗读走到当前页之外时翻过去（下一页用动画）
      R.reveal = function (chapter, offset) {
        const ch = chapters.find(c => c.index === chapter);
        if (!ch || ch.meta.placeholder || busy()) return;
        if (!paged()) {
          if (ch !== cur) return;
          const v = viewport.getBoundingClientRect(), r = rectOf(ch, offset);
          const y = pageOf(ch, offset);
          if (r && y != null && (r.top < v.top || r.bottom > v.bottom)) viewport.scrollTo({ top: Math.max(0, y - 40), behavior: 'smooth' });
          return;
        }
        const local = pageOf(ch, offset);
        if (local == null) return;
        const target = ch.start + local, g = pageNow();
        if (target === g) return;
        if (cfg.turn === 'curl' && Math.abs(target - g) === 1) {
          return post('curl', { phase: 'tap', forward: target > g, from: g, to: target });
        }
        if (target === g + 1) scrollToPage(target, true);
        else { scrollToPage(target, false); report(); }
      };

      R.__boot = function () {
        page = $('page'); viewport = $('viewport'); track = $('track'); snaps = $('snaps');
        headerEl = $('header'); footerEl = $('footer'); fontStyle = $('font-faces'); decorEl = $('decor');
        document.addEventListener('touchstart', onStart, { passive: true });
        document.addEventListener('touchmove', onMove, { passive: true });
        document.addEventListener('touchend', onEnd, { passive: true });
        document.addEventListener('touchcancel', e => {
          touching = e.touches.length > 0;
          if (curl) endCurl();
          touch = null;
          if (!busy()) flush();
        });
        let selOn = false;
        document.addEventListener('selectionchange', () => {
          const sel = getSelection();
          const on = !!(sel && !sel.isCollapsed && String(sel).length > 0);
          if (on === selOn) return;
          selOn = on;
          post('selection', { active: on });
        });
        viewport.addEventListener('scroll', onScroll, { passive: true });
        viewport.addEventListener('scrollend', () => { if (scrolling) settled(); });
        window.addEventListener('resize', relayout);
        if (window.matchMedia) matchMedia('(prefers-color-scheme: dark)').addEventListener('change', relayout);
        if (document.fonts) document.fonts.addEventListener('loadingdone', relayout);
        document.querySelectorAll('#decor img').forEach(img => { img.decoding = 'async'; });
        setupScrub();
        setInterval(() => { if (!busy()) chrome(); }, 30000);
        measure();
        post('ready');
      };
    })();
    """#
}
