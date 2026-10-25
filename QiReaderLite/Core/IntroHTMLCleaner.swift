import Foundation

// MARK: - ⭐⭐⭐ 详情页简介的 HTML 清洗

/// ⭐⭐⭐⭐⭐ **简介里的 HTML 标签要转成纯文本**（2026-10-25 真机）
///
/// **症状**：大灰狼详情页的简介直接显示 `<p></p>` / `<p>"一觉醒来，…`
/// ⇒ 站方的 `abstract` 字段**带 HTML**（`<p>` 段落）⇒ 原样显示很难看 ⭐⭐⭐
///
/// ⭐ **为什么放在【App 显示层】而不是引擎**：
/// · 引擎输出保持原样 ⇒ **沙盒对拍（逐字比）不受影响** ⇒ 零回归风险 ⭐⭐⭐
/// · 老引擎也不清理（只有正文清理）⇒ 但老引擎是**参考实现不是权威**
///   （Legado 规格 + 栖阅原生实现才是）⇒ 显示层美化是**App 的自由度** ⭐⭐⭐
///
/// ⭐ **只处理标签，不动文字**：
/// · `<p>` / `<br>` ⇒ 换行（段落各占一行）
/// · 其余标签（`<b>` / `<span>` / `<a href=…>` …）⇒ **去掉标签，保留内容** ⭐⭐⭐
/// ⇒ 不能用正则一把梭（会误伤 `<` `>` 文本）⇒ 走**简易标签扫描** ⭐
enum IntroHTMLCleaner {

    /// ⭐⭐⭐ **HTML ⇒ 纯文本**（标签去掉，段落换行）
    static func plainText(_ raw: String) -> String {
        // ⚠️⚠️ **不能因为「没有标签」就原样返回**（2026-10-25 门禁抓到）
        //   ⇒ 站方 `abstract` 可能带**裸换行**（`<p>` 被剥掉后剩下的）
        //   ⇒ 原样返回 ⇒ 连续空行撑出一大片空白 ⭐⭐⭐
        //   ⇒ 所以：**即使没有标签，也要走后面的空白归一** ⭐⭐⭐

        var out = ""
        var i = raw.startIndex
        let n = raw.endIndex
        var pendingBreak = false

        while i < n {
            let c = raw[i]
            if c == "<" {
                // ⭐ 找配对的 `>`（跳过引号里的 `>`）
                var j = raw.index(after: i)
                var inQuote: Character? = nil
                while j < n {
                    let d = raw[j]
                    if let q = inQuote {
                        if d == q { inQuote = nil }
                    } else if d == "\"" || d == "'" {
                        inQuote = d
                    } else if d == ">" {
                        break
                    }
                    j = raw.index(after: j)
                }
                guard j < n else {
                    // ⚠️ 没有配对的 `>` ⇒ 当普通文本
                    out.append(c)
                    i = raw.index(after: i)
                    continue
                }
                let tag = String(raw[raw.index(after: i)..<j])
                let lower = tag.lowercased()
                if lower.hasPrefix("br") || lower.hasPrefix("/p") || lower.hasPrefix("/div")
                    || lower.hasPrefix("/li") || lower.hasPrefix("/h") {
                    pendingBreak = true
                } else if lower.hasPrefix("p") || lower.hasPrefix("div") || lower.hasPrefix("li")
                            || lower.hasPrefix("h1") || lower.hasPrefix("h2") || lower.hasPrefix("h3")
                            || lower.hasPrefix("h4") || lower.hasPrefix("h5") || lower.hasPrefix("h6")
                            || lower.hasPrefix("tr") || lower.hasPrefix("section") {
                    pendingBreak = true
                }
                // ⭐ 跳过整个标签
                i = raw.index(after: j)
                continue
            }
            if pendingBreak {
                if !out.isEmpty, !out.hasSuffix("\n") { out.append("\n") }
                pendingBreak = false
            }
            out.append(c)
            i = raw.index(after: i)
        }

        // ⭐ 收尾：归一空白（三个以上换行压成两个）+ 去掉首尾空白
        //   ⚠️ **无条件执行**（哪怕一个标签都没有）⇒ 裸换行也要归一 ⭐⭐⭐
        var s = out
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
