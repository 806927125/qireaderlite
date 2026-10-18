(function installQiReaderScrollCore(root, factory) {
  const core = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = core;
    return;
  }
  root.QiReaderScrollCore = core;
})(typeof globalThis !== "undefined" ? globalThis : this, function makeQiReaderScrollCore() {
  function finiteNumber(value) {
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  }

  function oppositeSide(side) {
    return side === "first" ? "last" : "first";
  }

  function edgeIndex(side, first, last) {
    return side === "first" ? first : last;
  }

  function directionPreferredRemovalSide(mode) {
    if (mode === "append") return "first";
    if (mode === "prepend") return "last";
    return null;
  }

  function distancePreferredRemovalSide(first, last, anchor) {
    if (anchor === null) return "first";
    const firstDistance = Math.abs(first - anchor);
    const lastDistance = Math.abs(last - anchor);
    return firstDistance >= lastDistance ? "first" : "last";
  }

  function chooseTrimRemovalSide({ firstIndex, lastIndex, anchorIndex, mode }) {
    const first = finiteNumber(firstIndex);
    const last = finiteNumber(lastIndex);
    const anchor = finiteNumber(anchorIndex);
    if (first === null || last === null) return "last";

    const preferred = directionPreferredRemovalSide(mode)
      || distancePreferredRemovalSide(first, last, anchor);
    if (anchor !== null && edgeIndex(preferred, first, last) === anchor) {
      return oppositeSide(preferred);
    }
    return preferred;
  }

  function trimChapterWindow(indices, maxWindow, anchorIndex, mode) {
    const kept = Array.from(indices || []);
    const removed = [];
    const limit = Math.max(0, Number(maxWindow) || 0);

    while (kept.length > limit) {
      const side = chooseTrimRemovalSide({
        firstIndex: kept[0],
        lastIndex: kept[kept.length - 1],
        anchorIndex,
        mode
      });
      removed.push(side === "first" ? kept.shift() : kept.pop());
    }

    return { kept, removed };
  }

  function shouldReportProgress({
    includeProgress,
    chapterChanged,
    force,
    lastProgressAt,
    now,
    minDelay = 260
  }) {
    if (!includeProgress) return false;
    if (chapterChanged || force) return true;

    const last = Number(lastProgressAt) || 0;
    if (last <= 0) return true;

    const current = Number(now) || 0;
    return current - last > minDelay;
  }

  function viewportAnchorAdjustment({
    anchorTop,
    currentTop,
    scrollTop,
    minDelta = 0.5
  }) {
    const anchor = finiteNumber(anchorTop);
    const current = finiteNumber(currentTop);
    const scroll = finiteNumber(scrollTop);
    if (anchor === null || current === null || scroll === null) {
      return { delta: 0, targetScrollTop: scroll || 0, shouldRestore: false };
    }

    const delta = current - anchor;
    return {
      delta,
      targetScrollTop: scroll + delta,
      shouldRestore: Math.abs(delta) >= minDelta
    };
  }

  function normalizedTitleHeight(value) {
    const height = finiteNumber(value);
    return height !== null && height > 0 ? height : 0;
  }

  return {
    chooseTrimRemovalSide,
    normalizedTitleHeight,
    shouldReportProgress,
    trimChapterWindow,
    viewportAnchorAdjustment
  };
});
