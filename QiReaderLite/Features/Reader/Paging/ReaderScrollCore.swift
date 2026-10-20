import Foundation

/// 阅读器「滚动模式」的纯逻辑内核。
///
/// 这是 `reader-scroll-core.js` 的 **1:1 Swift 翻译** —— 那个文件是 118 行
/// **零 DOM 依赖**的纯函数集（章节窗口裁剪、进度上报节流、视口锚点修正），
/// 所以能逐函数对译，并用同一批用例做行为对照。
///
/// 之所以要把它从 JS 里搬出来：阅读渲染层整体迁到 Swift 后，
/// 这些逻辑不该再留在 WebView 里。**规则引擎那边（engine.js）仍然跑 JS**，
/// 那个是站方书源规则要求的，跟阅读渲染无关。
///
/// ⚠️ 语义对齐要求（跟 JS 版逐条对应，别"顺手优化"）：
///   · JS 的 `Number(x)`：`null → 0`、`"" → 0`、`undefined → NaN`（→ nil）
///   · `chooseTrimRemovalSide` 的 `first`/`last` 为 null 时**返回 "last"**（不是 "first"）
///   · `distancePreferredRemovalSide` 用的是 `>=`（相等时取 "first"）
///   · `trimChapterWindow` 的 limit 是 `max(0, Number(maxWindow) || 0)`
///   · `shouldReportProgress` 的默认节流是 **260ms**，`now - last > minDelay`（严格大于）
enum ReaderScrollCore {

    // MARK: - 基础

    /// JS: `finiteNumber(value)` —— 非有限数返回 nil。
    /// 注意 `Number(null)` 在 JS 里是 **0**（不是 NaN），`Number("")` 也是 0。
    static func finiteNumber(_ value: Any?) -> Double? {
        switch value {
        case nil:
            return 0                       // JS: Number(null) === 0
        case let d as Double:
            return d.isFinite ? d : nil
        case let i as Int:
            return Double(i)
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }       // JS: Number("") === 0
            return Double(t).flatMap { $0.isFinite ? $0 : nil }
        default:
            return nil
        }
    }

    /// JS: `oppositeSide(side)`
    static func oppositeSide(_ side: String) -> String {
        side == "first" ? "last" : "first"
    }

    /// JS: `edgeIndex(side, first, last)`
    static func edgeIndex(_ side: String, _ first: Double, _ last: Double) -> Double {
        side == "first" ? first : last
    }

    // MARK: - 章节窗口裁剪

    /// JS: `directionPreferredRemovalSide(mode)`
    static func directionPreferredRemovalSide(_ mode: String?) -> String? {
        switch mode {
        case "append":  return "first"
        case "prepend": return "last"
        default:        return nil
        }
    }

    /// JS: `distancePreferredRemovalSide(first, last, anchor)`
    static func distancePreferredRemovalSide(_ first: Double, _ last: Double, _ anchor: Double) -> String {
        let firstDistance = abs(first - anchor)
        let lastDistance = abs(last - anchor)
        return firstDistance >= lastDistance ? "first" : "last"
    }

    /// JS: `chooseTrimRemovalSide({ firstIndex, lastIndex, anchorIndex, mode })`
    ///
    /// 返回 "first" 或 "last" —— 表示这一轮从**哪一端**摘掉一章。
    static func chooseTrimRemovalSide(firstIndex: Double?,
                                      lastIndex: Double?,
                                      anchorIndex: Double?,
                                      mode: String?) -> String {
        guard let first = firstIndex, let last = lastIndex else { return "last" }
        let anchor = anchorIndex
        let preferred = directionPreferredRemovalSide(mode)
            ?? distancePreferredRemovalSide(first, last, anchor ?? first)
        if let anchor, edgeIndex(preferred, first, last) == anchor {
            return oppositeSide(preferred)
        }
        return preferred
    }

    /// JS: `trimChapterWindow(indices, maxWindow, anchorIndex, mode)`
    ///
    /// 返回保留下来的章号和被摘掉的章号（摘掉的顺序 = 摘除顺序）。
    static func trimChapterWindow(indices: [Int],
                                  maxWindow: Int,
                                  anchorIndex: Int?,
                                  mode: String?) -> (kept: [Int], removed: [Int]) {
        var kept = indices
        var removed: [Int] = []
        let limit = max(0, maxWindow)
        while kept.count > limit {
            let first = kept.first.map(Double.init)
            let last = kept.last.map(Double.init)
            let side = chooseTrimRemovalSide(firstIndex: first,
                                             lastIndex: last,
                                             anchorIndex: anchorIndex.map(Double.init),
                                             mode: mode)
            if side == "first" { removed.append(kept.removeFirst()) }
            else { removed.append(kept.removeLast()) }
        }
        return (kept, removed)
    }

    // MARK: - 进度上报

    /// JS: `shouldReportProgress({ includeProgress, chapterChanged, force, lastProgressAt, now, minDelay = 260 })`
    static func shouldReportProgress(includeProgress: Bool,
                                     chapterChanged: Bool,
                                     force: Bool,
                                     lastProgressAt: Double,
                                     now: Double,
                                     minDelay: Double = 260) -> Bool {
        if !includeProgress { return false }
        if chapterChanged || force { return true }
        let last = lastProgressAt.isFinite ? lastProgressAt : 0
        if last <= 0 { return true }
        let current = now.isFinite ? now : 0
        return current - last > minDelay
    }

    // MARK: - 视口锚点

    /// JS: `viewportAnchorAdjustment({ anchorTop, currentTop, scrollTop, minDelta = 0.5 })`
    static func viewportAnchorAdjustment(anchorTop: Double?,
                                         currentTop: Double?,
                                         scrollTop: Double?,
                                         minDelta: Double = 0.5)
        -> (delta: Double, targetScrollTop: Double, shouldRestore: Bool) {
        guard let anchor = anchorTop, let current = currentTop, let scroll = scrollTop else {
            return (0, scrollTop ?? 0, false)
        }
        let delta = current - anchor
        return (delta, scroll + delta, abs(delta) >= minDelta)
    }

    /// JS: `normalizedTitleHeight(value)`
    static func normalizedTitleHeight(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }
}
