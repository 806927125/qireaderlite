(() => {
  const scrollCore = globalThis.QiReaderScrollCore;
  if (!scrollCore) {
    throw new Error("QiReaderScrollCore is required before reader.js");
  }

  const marker = "\u200B";
  const progressReportThrottleMs = 260;
  const progressFlushDelayMs = 140;
  const root = document.getElementById("reader-root");
  const state = {
    settings: null,
    currentChapterIndex: null,
    maxWindow: 7,
    requested: new Set(),
    lastProgressAt: 0,
    lastVisibleReport: null,
    scrollTimer: null,
    scrollIdleTimer: null,
    scrollActive: false,
    restoring: false,
    allowProgressReports: false
  };

  function post(type, payload = {}) {
    try {
      window.webkit?.messageHandlers?.qiReader?.postMessage({ type, ...payload });
    } catch (_) {}
  }

  function debugLog(event, payload = {}) {
    post("debugLog", { event, ...payload });
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function cssPx(value) {
    const number = Number(value);
    return `${Number.isFinite(number) ? number : 0}px`;
  }

  function escapeAttr(value) {
    return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "\"": "&quot;",
      "'": "&#39;"
    }[ch]));
  }

  function applySettings(settings) {
    state.settings = settings;
    const doc = document.documentElement;
    let fontFace = document.getElementById("reader-font-face");
    if (!fontFace) {
      fontFace = document.createElement("style");
      fontFace.id = "reader-font-face";
      document.head.appendChild(fontFace);
    }
    const fontFaceCSS = String(settings.fontFaceCSS || "");
    if (fontFace.textContent !== fontFaceCSS) {
      fontFace.textContent = fontFaceCSS;
    }
    applyHighlightStyles(settings.highlightStyles || []);
    const fontFamily = settings.fontFamily && settings.fontFamily !== "System"
      ? `"${String(settings.fontFamily).replace(/"/g, "")}", -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif`
      : "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif";
    const fontSize = Number(settings.fontSize) || 18;
    const lineHeight = fontSize + (Number(settings.lineSpacing) || 0) + 4;
    const cssWeight = Math.round(clamp(400 + (Number(settings.fontWeight) || 0) * 500, 300, 760));

    doc.style.setProperty("--reader-font-family", fontFamily);
    doc.style.setProperty("--reader-font-size", cssPx(fontSize));
    doc.style.setProperty("--reader-font-weight", String(cssWeight));
    doc.style.setProperty("--reader-line-height", cssPx(lineHeight));
    doc.style.setProperty("--reader-paragraph-spacing", cssPx(Number(settings.paragraphSpacing) || 0));
    doc.style.setProperty("--reader-letter-spacing", cssPx(Number(settings.letterSpacing) || 0));
    doc.style.setProperty("--reader-text-indent", `${Number(settings.textIndent) || 0}em`);
    doc.style.setProperty("--reader-left-margin", cssPx(Number(settings.leftMargin) || 0));
    doc.style.setProperty("--reader-right-margin", cssPx(Number(settings.rightMargin) || 0));
    if (settings.fullScreen) {
      doc.style.setProperty("--reader-top-padding", "calc(env(safe-area-inset-top) + 18px)");
      doc.style.setProperty("--reader-bottom-padding", "calc(env(safe-area-inset-bottom) + 32px)");
    } else {
      doc.style.setProperty("--reader-top-padding", "18px");
      doc.style.setProperty("--reader-bottom-padding", "32px");
    }
    const hasBackgroundImage = Boolean(settings.hasBackgroundImage);
    doc.style.setProperty("--reader-text-color", `#${settings.textColorHex || "222222"}`);
    doc.style.setProperty("--reader-background-color", hasBackgroundImage ? "transparent" : `#${settings.backgroundColorHex || "FFFFFF"}`);
    doc.style.setProperty("--reader-align", settings.textAlign || "justify");

    if (!hasBackgroundImage && settings.backgroundImageDataURL) {
      doc.style.setProperty("--reader-background-image", `url("${settings.backgroundImageDataURL}")`);
    } else {
      doc.style.removeProperty("--reader-background-image");
    }

    const dark = !!settings.isDarkMode;
    doc.style.setProperty("--reader-card-tint", dark ? "rgba(255, 255, 255, 0.06)" : "rgba(0, 0, 0, 0.06)");
    doc.style.setProperty("--reader-card-line", dark ? "rgba(255, 255, 255, 0.06)" : "rgba(0, 0, 0, 0.06)");
    doc.style.setProperty("--reader-muted", dark ? "rgba(255, 255, 255, 0.58)" : "rgba(0, 0, 0, 0.52)");
    doc.style.setProperty("--reader-faint", dark ? "rgba(255, 255, 255, 0.36)" : "rgba(0, 0, 0, 0.32)");
  }

  function applyHighlightStyles(styles) {
    let styleNode = document.getElementById("reader-highlight-css");
    if (!styleNode) {
      styleNode = document.createElement("style");
      styleNode.id = "reader-highlight-css";
      document.head.appendChild(styleNode);
    }
    const css = (styles || []).map((style) => {
      const id = String(style.id || "").replace(/[^a-zA-Z0-9_-]/g, "");
      if (!id) return "";
      return `${style.fontFaceCSS || ""}\n.hl-${id}{${style.cssText || ""}}`;
    }).filter(Boolean).join("\n");
    if (styleNode.textContent !== css) {
      styleNode.textContent = css;
    }
  }

  function chapterElements() {
    return Array.from(root.querySelectorAll(".chapter"));
  }

  function spacerElement(side) {
    return root.querySelector(`.chapter-spacer[data-side="${side}"]`);
  }

  function ensureSpacer(side) {
    let spacer = spacerElement(side);
    if (spacer) return spacer;
    spacer = document.createElement("div");
    spacer.className = "chapter-spacer";
    spacer.dataset.side = side;
    spacer.setAttribute("aria-hidden", "true");
    spacer.style.height = "0px";
    if (side === "top") {
      root.insertBefore(spacer, root.firstChild);
    } else {
      root.appendChild(spacer);
    }
    return spacer;
  }

  function spacerHeight(side) {
    return Number(spacerElement(side)?.dataset.height || 0) || 0;
  }

  function setSpacerHeight(side, height) {
    const spacer = ensureSpacer(side);
    const next = Math.max(0, Number(height) || 0);
    spacer.dataset.height = String(next);
    spacer.style.height = cssPx(next);
    debugLog("spacer", {
      side,
      height: next,
      scrollY: window.scrollY
    });
  }

  function adjustSpacerHeight(side, delta) {
    const amount = Number(delta) || 0;
    if (Math.abs(amount) < 0.5) return;
    setSpacerHeight(side, spacerHeight(side) + amount);
  }

  function insertBeforeBottomSpacer(chapter) {
    root.insertBefore(chapter, spacerElement("bottom"));
  }

  function insertAfterTopSpacer(chapter) {
    const spacer = ensureSpacer("top");
    root.insertBefore(chapter, spacer.nextSibling);
  }

  function chapterElement(index) {
    return root.querySelector(`.chapter[data-chapter-index="${index}"]`);
  }

  function sortedChapterIndices() {
    return chapterElements()
      .map((el) => Number(el.dataset.chapterIndex))
      .filter(Number.isFinite)
      .sort((a, b) => a - b);
  }

  function probeY() {
    return window.innerHeight * 0.3;
  }

  function probeX() {
    return Math.max(1, window.innerWidth / 2);
  }

  function captureViewportAnchor() {
    const y = probeY();
    let node = document.elementFromPoint(probeX(), y);
    let chapter = node?.closest?.(".chapter") || currentChapterByProbe()?.el;
    if (!chapter) return null;

    let paragraph = node?.closest?.(".para");
    if (paragraph && !chapter.contains(paragraph)) {
      paragraph = null;
    }
    const chapterBlock = node?.closest?.(".chapter-title, .chapter-title-html, .chapter-state");
    const stableBlock = chapterBlock && chapter.contains(chapterBlock) ? chapterBlock : null;

    if (!paragraph && !stableBlock) {
      paragraph = paragraphAtProbe(chapter);
    }

    const anchorElement = paragraph || stableBlock || chapter;
    return {
      chapterIndex: Number(chapter.dataset.chapterIndex),
      kind: anchorKind(anchorElement),
      paragraphIndex: paragraph ? Number(paragraph.dataset.paragraphIndex) : null,
      top: anchorElement.getBoundingClientRect().top
    };
  }

  function anchorKind(element) {
    if (element?.classList?.contains("para")) return "paragraph";
    if (element?.classList?.contains("chapter-title")) return "chapterTitle";
    if (element?.classList?.contains("chapter-title-html")) return "chapterTitleHTML";
    if (element?.classList?.contains("chapter-state")) return "chapterState";
    return "chapter";
  }

  function anchorElement(anchor) {
    if (!anchor || !Number.isFinite(anchor.chapterIndex)) return null;
    const chapter = chapterElement(anchor.chapterIndex);
    if (!chapter) return null;
    if (anchor.kind === "paragraph" && Number.isFinite(anchor.paragraphIndex)) {
      const paragraph = Array.from(chapter.querySelectorAll(".para"))
        .find((item) => Number(item.dataset.paragraphIndex) === anchor.paragraphIndex);
      if (paragraph) return paragraph;
    }
    if (anchor.kind === "chapterTitle") {
      const title = chapter.querySelector(".chapter-title");
      if (title) return title;
    }
    if (anchor.kind === "chapterTitleHTML") {
      const title = chapter.querySelector(".chapter-title-html");
      if (title) return title;
    }
    if (anchor.kind === "chapterState") {
      const state = chapter.querySelector(".chapter-state");
      if (state) return state;
    }
    return chapter;
  }

  function restoreViewportAnchor(anchor, reason = null) {
    const element = anchorElement(anchor);
    if (!element) return;
    const scrollingElement = document.scrollingElement;
    const adjustment = scrollCore.viewportAnchorAdjustment({
      anchorTop: anchor.top,
      currentTop: element.getBoundingClientRect().top,
      scrollTop: scrollingElement.scrollTop
    });
    if (adjustment.shouldRestore) {
      debugLog("anchor.restore", {
        chapterIndex: anchor.chapterIndex,
        kind: anchor.kind,
        paragraphIndex: anchor.paragraphIndex,
        reason,
        delta: adjustment.delta,
        scrollY: window.scrollY,
        targetScrollY: adjustment.targetScrollTop
      });
      scrollingElement.scrollTop = adjustment.targetScrollTop;
    }
  }

  function mutatePreservingViewport(mutation, reason = null) {
    const anchor = captureViewportAnchor();
    mutation(anchor);
    restoreViewportAnchor(anchor, reason);
  }

  function resolveImageURL(src, baseURL) {
    const trimmed = String(src || "").trim();
    if (!trimmed) return "";
    try {
      return baseURL ? new URL(trimmed, baseURL).href : new URL(trimmed, location.href).href;
    } catch (_) {
      return trimmed;
    }
  }

  function appendHighlightedText(parent, text, baseOffset, highlightRanges) {
    if (!text) return;
    const tokenStart = Number(baseOffset) || 0;
    const tokenEnd = tokenStart + text.length;
    const overlaps = (highlightRanges || []).filter((range) => {
      const start = Number(range.startUTF16) || 0;
      const end = start + (Number(range.lengthUTF16) || 0);
      return start < tokenEnd && end > tokenStart;
    });

    if (!overlaps.length) {
      parent.appendChild(document.createTextNode(text));
      return;
    }

    const boundaries = new Set([0, text.length]);
    overlaps.forEach((range) => {
      const start = Number(range.startUTF16) || 0;
      const end = start + (Number(range.lengthUTF16) || 0);
      boundaries.add(clamp(start - tokenStart, 0, text.length));
      boundaries.add(clamp(end - tokenStart, 0, text.length));
    });

    const points = Array.from(boundaries).sort((a, b) => a - b);
    for (let i = 0; i < points.length - 1; i += 1) {
      const start = points[i];
      const end = points[i + 1];
      if (end <= start) continue;
      const absoluteStart = tokenStart + start;
      const absoluteEnd = tokenStart + end;
      const active = overlaps.filter((range) => {
        const rangeStart = Number(range.startUTF16) || 0;
        const rangeEnd = rangeStart + (Number(range.lengthUTF16) || 0);
        return rangeStart < absoluteEnd && rangeEnd > absoluteStart;
      });
      const segment = text.slice(start, end);
      if (!active.length) {
        parent.appendChild(document.createTextNode(segment));
        continue;
      }
      const span = document.createElement("span");
      span.className = ["hl", ...new Set(active.map((range) => `hl-${range.styleId}`))].join(" ");
      span.textContent = segment;
      parent.appendChild(span);
    }
  }

  function appendTextWithImages(parent, text, payload, baseOffset = 0, highlightRanges = []) {
    const pattern = /<img\b[^>]*>/gi;
    let cursor = 0;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      if (match.index > cursor) {
        appendHighlightedText(parent, text.slice(cursor, match.index), baseOffset + cursor, highlightRanges);
      }
      const tag = match[0];
      const template = document.createElement("template");
      template.innerHTML = tag;
      const sourceImage = template.content.querySelector("img");
      const rawSrc = sourceImage?.getAttribute("src") || sourceImage?.getAttribute("data-src") || "";
      const resolved = resolveImageURL(rawSrc, payload.imageBaseURL);
      if (resolved) {
        const img = document.createElement("img");
        img.className = "reader-img";
        img.src = resolved;
        img.alt = sourceImage?.getAttribute("alt") || "";
        img.loading = "lazy";
        img.decoding = "async";
        const width = sourceImage?.getAttribute("width");
        const height = sourceImage?.getAttribute("height");
        if (width) img.setAttribute("width", width);
        if (height) img.setAttribute("height", height);
        if (String(payload.imageStyle || "").toUpperCase() === "FULL") {
          img.style.width = "100%";
        }
        parent.appendChild(img);
      } else {
        parent.appendChild(document.createTextNode(tag));
      }
      cursor = match.index + tag.length;
    }
    if (cursor < text.length) {
      appendHighlightedText(parent, text.slice(cursor), baseOffset + cursor, highlightRanges);
    }
  }

  function createCommentNode(comment) {
    let node;
    switch (comment.kind) {
    case "bubble":
      node = createBubbleNode(comment);
      break;
    case "chapterEnd":
      node = createChapterEndNode(comment);
      break;
    case "authorSay":
      node = createAuthorSayNode(comment);
      break;
    case "hotReview":
    default:
      node = createHotReviewNode(comment);
      break;
    }
    node.classList.add("comment-node");
    node.dataset.commentIndex = String(comment.index);
    node.dataset.commentUrl = comment.url || "";
    node.dataset.hasAction = comment.clickActionScript ? "1" : "0";
    return node;
  }

  function createBubbleNode(comment) {
    const bubble = comment.bubble || {};
    const node = document.createElement("span");
    node.className = "comment-bubble";
    node.style.width = cssPx(bubble.width || 0);
    node.style.height = cssPx(bubble.height || 0);
    // NSTextAttachment yOffset is baseline-relative; CSS translateY uses the opposite direction.
    node.style.transform = `translateY(${cssPx(-(Number(bubble.yOffset) || 0))})`;
    node.innerHTML = bubble.svg || "";

    if (bubble.countText) {
      const count = document.createElement("span");
      count.className = "bubble-count";
      count.textContent = bubble.countText;
      count.style.left = cssPx(bubble.countX || 0);
      count.style.top = cssPx(bubble.countY || 0);
      count.style.fontSize = cssPx(bubble.countFontSize || 10);
      count.style.color = `#${bubble.countColorHex || "666666"}`;
      node.appendChild(count);
    }
    return node;
  }

  function createHotReviewNode(comment) {
    const node = document.createElement("span");
    node.className = "comment-card hot-review-card";
    node.innerHTML = `
      <span class="hot-review-inner">
        <span class="hot-review-badge">${escapeAttr(comment.hotReviewBadge || "热评")}</span>
        <span class="hot-review-text">${escapeAttr(comment.hotReviewText || comment.inlineText || "")}</span>
      </span>
    `;
    return node;
  }

  function createChapterEndNode(comment) {
    const info = comment.chapterEnd || { totalCount: 0, comments: [] };
    const node = document.createElement("span");
    node.className = "comment-card chapter-end-card";
    const rows = (info.comments || []).map((item) => `
      <span class="chapter-end-comment">
        <span class="chapter-end-name-row">
          <span class="chapter-end-name">${escapeAttr(item.userName || "")}</span>
          ${Number(item.likeCount) > 0 ? `<span class="chapter-end-like">♡ ${escapeAttr(item.likeCount)}</span>` : ""}
        </span>
        <span class="chapter-end-body">${escapeAttr(item.content || "")}</span>
      </span>
    `).join("");
    const countText = Number(info.totalCount) > 0 ? `${info.totalCount}条评论 ›` : "查看评论 ›";
    node.innerHTML = `
      <span class="chapter-end-header">
        <span class="chapter-end-title">本章说</span>
        <span class="chapter-end-count">${escapeAttr(countText)}</span>
      </span>
      ${rows}
    `;
    return node;
  }

  function createAuthorSayNode(comment) {
    const info = comment.authorSay || {};
    const node = document.createElement("span");
    node.className = "comment-card author-say-card";
    const reply = info.replyText ? `<span class="author-reply">${escapeAttr(info.replyText)} ›</span>` : "";
    const name = info.authorName ? `<span class="author-name">${escapeAttr(info.authorName)}</span>` : "";
    const expectLabel = info.expectLabel ? `<span class="author-expect-label">${escapeAttr(info.expectLabel)}</span>` : "";
    const expectText = info.expectText ? `<span class="author-expect-text">${escapeAttr(info.expectText)}</span>` : "";
    const expect = expectLabel || expectText ? `<span class="author-expect">${expectLabel}${expectText}</span>` : "";
    node.innerHTML = `
      <span class="author-say-top">
        <span class="author-head"><span class="author-badge">作家说</span>${name}</span>
        ${reply}
      </span>
      <span class="author-body">${escapeAttr(info.bodyText || "")}</span>
      ${expect}
    `;
    return node;
  }

  function renderParagraph(paragraphText, paragraphIndex, commentCursor, payload, totalTextLength, cumulativeStart, textLength) {
    const p = document.createElement("p");
    p.className = "para";
    p.dataset.paragraphIndex = String(paragraphIndex);
    p.dataset.textLength = String(textLength);
    p.dataset.cumulativeStart = String(cumulativeStart);
    p.dataset.totalTextLength = String(totalTextLength);

    const highlightRanges = (payload.highlightRanges || [])
      .filter((range) => Number(range.paragraphIndex) === paragraphIndex)
      .filter((range) => Number(range.lengthUTF16) > 0);

    let cursor = 0;
    while (cursor <= paragraphText.length) {
      const markerIndex = paragraphText.indexOf(marker, cursor);
      const end = markerIndex === -1 ? paragraphText.length : markerIndex;
      if (end > cursor) {
        appendTextWithImages(
          p,
          paragraphText.slice(cursor, end),
          payload,
          cursor,
          highlightRanges
        );
      }

      if (markerIndex === -1) {
        break;
      }

      const comment = payload.comments?.[commentCursor.value];
      commentCursor.value += 1;
      if (comment) {
        const node = createCommentNode(comment);
        p.appendChild(node);
        if (comment.kind !== "bubble") {
          p.classList.add("has-block-card");
        }
      }
      cursor = markerIndex + marker.length;
    }

    if (p.querySelector(".reader-img") && !p.textContent.trim()) {
      p.classList.add("image-only");
    }
    return p;
  }

  function normalizedParagraphs(text) {
    const cleaned = String(text || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
    const pieces = cleaned.split(/\n+/).map((line) => line.trim()).filter((line) => line.length > 0);
    return pieces.length ? pieces : [cleaned];
  }

  function renderChapter(payload) {
    const chapter = document.createElement("section");
    chapter.className = "chapter";
    chapter.dataset.chapterIndex = String(payload.chapterIndex);
    chapter.dataset.contentHash = payload.contentHash || "";

    const titleNode = createChapterTitleNode(payload);
    if (titleNode) {
      chapter.appendChild(titleNode);
    }

    if (payload.state !== "loaded") {
      const stateNode = document.createElement("div");
      stateNode.className = "chapter-state";
      stateNode.textContent = payload.state === "failed" ? (payload.text || "加载失败") : "加载中…";
      chapter.appendChild(stateNode);
      return chapter;
    }

    const body = document.createElement("div");
    body.className = "chapter-body";
    const paragraphs = normalizedParagraphs(payload.text);
    const totalTextLength = Math.max(1, paragraphs.reduce((sum, item) => sum + item.replaceAll(marker, "").length, 0));
    const commentCursor = { value: 0 };
    let cumulative = 0;
    paragraphs.forEach((paragraph, index) => {
      const textLength = paragraph.replaceAll(marker, "").length;
      body.appendChild(renderParagraph(paragraph, index, commentCursor, payload, totalTextLength, cumulative, textLength));
      cumulative += textLength;
    });
    chapter.appendChild(body);
    return chapter;
  }

  function createChapterTitleNode(payload) {
    const titlePayload = payload.chapterTitle;
    if (titlePayload && titlePayload.isEnabled === false) {
      return null;
    }

    if (titlePayload?.isHTMLMode && titlePayload.html) {
      const frame = document.createElement("div");
      frame.className = "chapter-title-html";
      frame.dataset.chapterIndex = String(payload.chapterIndex);
      frame.style.height = cssPx(scrollCore.normalizedTitleHeight(titlePayload.height));
      frame.style.marginTop = cssPx(titlePayload.topSpacing || 0);
      frame.style.marginBottom = cssPx(titlePayload.bottomSpacing || 0);

      const iframe = document.createElement("iframe");
      iframe.className = "chapter-title-frame";
      iframe.setAttribute("title", payload.title || "章节标题");
      iframe.setAttribute("sandbox", "allow-same-origin");
      iframe.setAttribute("scrolling", "no");
      iframe.addEventListener("load", () => {
        resizeChapterTitleFrame(frame, iframe);
      });
      iframe.srcdoc = titlePayload.html;
      frame.appendChild(iframe);
      return frame;
    }

    const title = document.createElement("h1");
    title.className = "chapter-title";
    title.textContent = payload.title || "";
    if (titlePayload) {
      title.style.marginTop = cssPx(titlePayload.topSpacing || 0);
      title.style.marginBottom = cssPx(titlePayload.bottomSpacing || 0);
    }
    return title;
  }

  function resizeChapterTitleFrame(frame, iframe) {
    try {
      const doc = iframe.contentDocument;
      if (!doc) return;
      const before = frame.getBoundingClientRect().height;
      const measured = Math.ceil(Math.max(
        doc.documentElement?.scrollHeight || 0,
        doc.body?.scrollHeight || 0
      ));
      if (!Number.isFinite(measured) || measured <= 0 || Math.abs(measured - before) < 1) return;
      mutatePreservingViewport(() => {
        debugLog("title.resize", {
          chapterIndex: Number(frame.dataset.chapterIndex),
          before,
          measured,
          scrollY: window.scrollY
        });
        frame.style.height = cssPx(measured);
      }, "title.resize");
      reportVisibleAndProgress(true);
    } catch (_) {}
  }

  function setInitial({ chapters, currentIndex, progress }) {
    state.restoring = true;
    state.allowProgressReports = false;
    state.scrollActive = false;
    const restoreTarget = progress || { chapterIndex: currentIndex, scrollRatio: 0 };
    root.replaceChildren();
    (chapters || []).sort((a, b) => a.chapterIndex - b.chapterIndex).forEach((payload) => {
      root.appendChild(renderChapter(payload));
    });
    state.currentChapterIndex = currentIndex;
    requestAnimationFrame(() => {
      restoreProgress(restoreTarget);
      trimWindow();
      requestAnimationFrame(() => {
        restoreProgress(restoreTarget);
        state.restoring = false;
        reportVisibleAndProgress(true, { includeProgress: false });
      });
    });
  }

  function upsertChapter({ payload, mode }) {
    if (!payload) return;
    mutatePreservingViewport((anchor) => {
      const existing = chapterElement(payload.chapterIndex);
      debugLog("upsert.start", {
        chapterIndex: payload.chapterIndex,
        mode,
        existing: existing ? 1 : 0,
        anchorChapterIndex: anchor?.chapterIndex,
        anchorKind: anchor?.kind,
        window: sortedChapterIndices().join(","),
        scrollY: window.scrollY
      });
      if (existing) {
        existing.replaceWith(renderChapter(payload));
      } else {
        const chapter = renderChapter(payload);
        const indices = sortedChapterIndices();
        const first = indices[0];

        if (mode === "prepend" || (Number.isFinite(first) && payload.chapterIndex < first)) {
          const firstChapter = chapterElements()[0];
          const firstTop = firstChapter?.getBoundingClientRect().top;
          insertAfterTopSpacer(chapter);
          if (firstChapter && Number.isFinite(firstTop) && spacerHeight("top") > 0) {
            adjustSpacerHeight("top", firstTop - firstChapter.getBoundingClientRect().top);
          }
        } else {
          const beforeHeight = document.body.scrollHeight;
          insertBeforeBottomSpacer(chapter);
          if (spacerHeight("bottom") > 0) {
            adjustSpacerHeight("bottom", beforeHeight - document.body.scrollHeight);
          }
        }
      }
      requestWindowCompaction(anchor, existing ? null : mode);
      debugLog("upsert.end", {
        chapterIndex: payload.chapterIndex,
        mode,
        window: sortedChapterIndices().join(","),
        scrollY: window.scrollY
      });
    });
    reportVisibleAndProgress(true);
  }

  function refreshChapters({ chapters }) {
    mutatePreservingViewport(() => {
      (chapters || []).forEach((payload) => {
        const existing = chapterElement(payload.chapterIndex);
        if (existing) {
          existing.replaceWith(renderChapter(payload));
        }
      });
    });
    requestAnimationFrame(() => {
      reportVisibleAndProgress(true);
    });
  }

  function requestWindowCompaction(anchor = null, mode = null) {
    trimWindow(anchor, mode);
  }

  function removeFirstChapterPreservingGeometry(first) {
    const next = chapterElements().find((chapter) => chapter !== first);
    const nextTop = next?.getBoundingClientRect().top;
    const fallbackHeight = first.getBoundingClientRect().height;
    first.remove();
    if (next && Number.isFinite(nextTop)) {
      adjustSpacerHeight("top", nextTop - next.getBoundingClientRect().top);
    } else {
      adjustSpacerHeight("top", fallbackHeight);
    }
  }

  function removeLastChapterPreservingGeometry(last) {
    const beforeHeight = document.body.scrollHeight;
    const fallbackHeight = last.getBoundingClientRect().height;
    last.remove();
    const removedHeight = beforeHeight - document.body.scrollHeight;
    adjustSpacerHeight("bottom", Number.isFinite(removedHeight) && removedHeight > 0
      ? removedHeight
      : fallbackHeight);
  }

  function trimWindow(anchor = null, mode = null) {
    const activeAnchor = anchor || captureViewportAnchor();
    let chapters = chapterElements();
    while (chapters.length > state.maxWindow) {
      const current = Number.isFinite(activeAnchor?.chapterIndex)
        ? activeAnchor.chapterIndex
        : currentChapterByProbe()?.index ?? state.currentChapterIndex ?? Number(chapters[Math.floor(chapters.length / 2)]?.dataset.chapterIndex);
      const first = chapters[0];
      const last = chapters[chapters.length - 1];
      const removalSide = scrollCore.chooseTrimRemovalSide({
        firstIndex: first.dataset.chapterIndex,
        lastIndex: last.dataset.chapterIndex,
        anchorIndex: current,
        mode
      });
      const removing = removalSide === "first" ? first : last;
      debugLog("trim", {
        mode,
        anchorChapterIndex: activeAnchor?.chapterIndex,
        current,
        firstIndex: first.dataset.chapterIndex,
        lastIndex: last.dataset.chapterIndex,
        removalSide,
        removingIndex: removing.dataset.chapterIndex,
        window: chapters.map((chapter) => chapter.dataset.chapterIndex).join(","),
        scrollY: window.scrollY
      });

      if (removalSide === "first") {
        removeFirstChapterPreservingGeometry(first);
      } else {
        removeLastChapterPreservingGeometry(last);
      }
      chapters = chapterElements();
    }
    if (!anchor) {
      restoreViewportAnchor(activeAnchor);
    }
  }

  function currentChapterByProbe() {
    const y = probeY();
    let el = document.elementFromPoint(probeX(), y)?.closest?.(".chapter");
    if (!el) {
      el = chapterElements().find((chapter) => {
        const rect = chapter.getBoundingClientRect();
        return rect.top <= y && rect.bottom >= y;
      });
    }
    if (!el) {
      const beforeProbe = chapterElements().filter((chapter) => chapter.getBoundingClientRect().top <= y);
      el = beforeProbe[beforeProbe.length - 1] || chapterElements()[0];
    }
    if (!el) return null;
    return { el, index: Number(el.dataset.chapterIndex) };
  }

  function paragraphAtProbe(chapter) {
    const y = probeY();
    const paragraphs = Array.from(chapter.querySelectorAll(".para"));
    if (!paragraphs.length) return null;
    let candidate = paragraphs[0];
    for (const para of paragraphs) {
      if (para.getBoundingClientRect().top <= y) {
        candidate = para;
      } else {
        break;
      }
    }
    return candidate;
  }

  function currentProgress() {
    const current = currentChapterByProbe();
    if (!current) {
      return {
        chapterIndex: state.currentChapterIndex ?? 0,
        paragraphIndex: 0,
        utf16Offset: 0,
        textProgress: 0,
        scrollRatio: 0,
        contentHash: ""
      };
    }

    const chapter = current.el;
    const chapterTop = chapter.getBoundingClientRect().top + window.scrollY;
    const localScroll = Math.max(0, window.scrollY + probeY() - chapterTop);
    const scrollable = Math.max(1, chapter.offsetHeight - window.innerHeight * 0.7);
    const scrollRatio = clamp(localScroll / scrollable, 0, 1);
    const para = paragraphAtProbe(chapter);
    const paraIndex = Number(para?.dataset.paragraphIndex || 0);
    const paraLength = Math.max(1, Number(para?.dataset.textLength || 1));
    const paraRect = para?.getBoundingClientRect();
    const paraFraction = paraRect ? clamp((probeY() - paraRect.top) / Math.max(1, paraRect.height), 0, 1) : 0;
    const cumulativeStart = Number(para?.dataset.cumulativeStart || 0);
    const totalTextLength = Math.max(1, Number(para?.dataset.totalTextLength || 1));
    const utf16Offset = Math.round(paraLength * paraFraction);
    const textProgress = clamp((cumulativeStart + utf16Offset) / totalTextLength, 0, 1);

    return {
      chapterIndex: current.index,
      paragraphIndex: paraIndex,
      utf16Offset,
      textProgress,
      scrollRatio,
      contentHash: chapter.dataset.contentHash || ""
    };
  }

  function restoreProgress(progress) {
    if (!progress) return;
    const chapter = chapterElement(progress.chapterIndex);
    if (!chapter) return;

    const scrollRatio = Number(progress.scrollRatio);
    const scrollable = Math.max(1, chapter.offsetHeight - window.innerHeight * 0.7);
    const chapterTop = chapter.getBoundingClientRect().top + window.scrollY;
    const targetY = chapterTop + scrollable * clamp(scrollRatio || 0, 0, 1) - probeY();
    window.scrollTo({ top: Math.max(0, targetY), left: 0, behavior: "auto" });
  }

  function reportVisibleAndProgress(force = false, options = {}) {
    if (state.restoring && !force) return;
    const progress = currentProgress();
    const previousChapterIndex = state.currentChapterIndex;
    const chapterChanged = previousChapterIndex !== progress.chapterIndex;
    if (chapterChanged) {
      state.currentChapterIndex = progress.chapterIndex;
    }
    if (force || state.lastVisibleReport !== progress.chapterIndex) {
      state.lastVisibleReport = progress.chapterIndex;
      post("visibleChapter", { chapterIndex: progress.chapterIndex });
    }

    const now = Date.now();
    const includeProgress = options.includeProgress !== false && state.allowProgressReports && !state.restoring;
    const forceProgress = force || options.forceProgress === true;
    const shouldReportProgress = scrollCore.shouldReportProgress({
      includeProgress,
      chapterChanged,
      force: forceProgress,
      lastProgressAt: state.lastProgressAt,
      now,
      minDelay: progressReportThrottleMs
    });
    if (chapterChanged || force || forceProgress) {
      debugLog("report", {
        previousChapterIndex,
        chapterIndex: progress.chapterIndex,
        paragraphIndex: progress.paragraphIndex,
        textProgress: progress.textProgress,
        scrollRatio: progress.scrollRatio,
        force,
        forceProgress,
        allowProgressReports: state.allowProgressReports,
        restoring: state.restoring,
        includeProgress,
        progressDelay: state.lastProgressAt > 0 ? now - state.lastProgressAt : null,
        progressSent: shouldReportProgress,
        scrollY: window.scrollY
      });
    }
    if (shouldReportProgress) {
      state.lastProgressAt = now;
      post("progress", progress);
    }
  }

  function scheduleProgressFlush() {
    if (state.scrollIdleTimer) {
      window.clearTimeout(state.scrollIdleTimer);
    }
    state.scrollIdleTimer = window.setTimeout(() => {
      state.scrollIdleTimer = null;
      state.scrollActive = false;
      debugLog("progress.flush", {
        scrollY: window.scrollY,
        currentChapterIndex: state.currentChapterIndex
      });
      reportVisibleAndProgress(false, { forceProgress: true });
    }, progressFlushDelayMs);
  }

  function markUserScrollIntent() {
    state.allowProgressReports = true;
  }

  function maybeRequestMoreChapters() {
    const indices = sortedChapterIndices();
    if (!indices.length) return;

    const chapters = chapterElements();
    const firstChapter = chapters[0];
    const lastChapter = chapters[chapters.length - 1];
    const bottomDistance = lastChapter.getBoundingClientRect().bottom - window.innerHeight;
    if (bottomDistance < window.innerHeight * 2) {
      requestChapter(indices[indices.length - 1] + 1, "append");
    }
    const topDistance = firstChapter.getBoundingClientRect().top;
    if (topDistance > -window.innerHeight * 1.5) {
      requestChapter(indices[0] - 1, "prepend");
    }
  }

  function requestChapter(index, mode) {
    if (!Number.isFinite(index) || index < 0) return;
    const key = `${mode}:${index}`;
    if (state.requested.has(key) || chapterElement(index)) return;
    state.requested.add(key);
    debugLog("request", {
      chapterIndex: index,
      mode,
      window: sortedChapterIndices().join(","),
      scrollY: window.scrollY
    });
    post("requestChapter", { chapterIndex: index, mode });
  }

  function markChapterRequestFinished({ index, mode }) {
    state.requested.delete(`${mode}:${index}`);
    debugLog("request.finished", {
      chapterIndex: index,
      mode,
      window: sortedChapterIndices().join(","),
      scrollY: window.scrollY
    });
  }

  document.addEventListener("scroll", () => {
    state.scrollActive = true;
    scheduleProgressFlush();
    if (state.scrollTimer) return;
    state.scrollTimer = window.requestAnimationFrame(() => {
      state.scrollTimer = null;
      reportVisibleAndProgress(false);
      maybeRequestMoreChapters();
    });
  }, { passive: true });

  document.addEventListener("touchmove", markUserScrollIntent, { passive: true });
  document.addEventListener("wheel", markUserScrollIntent, { passive: true });
  document.addEventListener("keydown", (event) => {
    const scrollKeys = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "]);
    if (scrollKeys.has(event.key)) {
      markUserScrollIntent();
    }
  });

  document.addEventListener("click", (event) => {
    const comment = event.target.closest?.(".comment-node");
    if (comment) {
      const chapter = comment.closest(".chapter");
      post("commentTap", {
        chapterIndex: Number(chapter?.dataset.chapterIndex),
        commentIndex: Number(comment.dataset.commentIndex),
        url: comment.dataset.commentUrl || "",
        hasAction: comment.dataset.hasAction === "1"
      });
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    post("tap", {});
  });

  let longPressTimer = null;
  document.addEventListener("touchstart", (event) => {
    const comment = event.target.closest?.(".comment-node");
    if (!comment) return;
    const chapter = comment.closest(".chapter");
    longPressTimer = window.setTimeout(() => {
      post("commentLongPress", {
        chapterIndex: Number(chapter?.dataset.chapterIndex),
        commentIndex: Number(comment.dataset.commentIndex),
        url: comment.dataset.commentUrl || ""
      });
    }, 520);
  }, { passive: true });

  ["touchend", "touchmove", "touchcancel"].forEach((name) => {
    document.addEventListener(name, () => {
      if (longPressTimer) {
        window.clearTimeout(longPressTimer);
        longPressTimer = null;
      }
    }, { passive: true });
  });

  window.QiReader = {
    applySettings,
    setInitial,
    upsertChapter,
    refreshChapters,
    markChapterRequestFinished
  };

  post("ready", {});
})();
