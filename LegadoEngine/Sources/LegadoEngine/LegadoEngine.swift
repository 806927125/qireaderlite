import Foundation

/// 引擎门面：书源 JSON → 搜索/发现/详情/目录/正文。
/// 流程语义对齐 Legado WebBook.kt。
public enum LegadoEngine {

    // MARK: - 搜索

    public static func search(source: BookSource, key: String, page: Int = 1,
                             variables: RuleVariables? = nil) async throws -> [SearchBook] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            throw LegadoError("书源缺少 searchUrl")
        }
        let vars = variables ?? RuleVariables()
        let au = try AnalyzeUrl(ruleUrl: searchUrl, key: key, page: page,
                                source: source, variables: vars)
        let resp = try await au.fetch()
        let rule = AnalyzeRule(source: source, variables: vars)
        rule.key = key
        rule.page = page
        rule.setContent(resp.body, baseUrl: resp.url.absoluteString)
        guard let rs = source.ruleSearch, let bookList = rs.bookList, !bookList.isEmpty else {
            throw LegadoError("书源缺少 ruleSearch.bookList")
        }
        return try parseBookList(rule, elements: rule.getElements(bookList),
                                 baseUrl: resp.url.absoluteString, source: source,
                                 name: rs.name, author: rs.author, kind: rs.kind,
                                 wordCount: rs.wordCount, lastChapter: rs.lastChapter,
                                 intro: rs.intro, coverUrl: rs.coverUrl, bookUrl: rs.bookUrl)
    }

    // MARK: - 发现

    /// 解析 exploreUrl：支持 JSON 数组 [{title,url}] 或 `标题::url` 行（\n / && 分隔）。
    public static func exploreKinds(source: BookSource) -> [ExploreKind] {
        guard let raw = source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        var out: [ExploreKind] = []
        if raw.hasPrefix("["), let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in arr {
                let title = item["title"].map { "\($0)" } ?? ""
                let url = item["url"].map { "\($0)" } ?? ""
                if !url.isEmpty { out.append(ExploreKind(title: title, url: url)) }
            }
            return out
        }
        let lines = raw.components(separatedBy: "&&").flatMap { $0.components(separatedBy: "\n") }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if let sep = t.range(of: "::") {
                let title = String(t[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let url = String(t[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !url.isEmpty { out.append(ExploreKind(title: title, url: url)) }
            } else {
                out.append(ExploreKind(title: "", url: t))
            }
        }
        return out
    }

    public static func explore(source: BookSource, kind: ExploreKind, page: Int = 1,
                              variables: RuleVariables? = nil) async throws -> [SearchBook] {
        let vars = variables ?? RuleVariables()
        let au = try AnalyzeUrl(ruleUrl: kind.url, page: page, source: source, variables: vars)
        let resp = try await au.fetch()
        let rule = AnalyzeRule(source: source, variables: vars)
        rule.page = page
        rule.setContent(resp.body, baseUrl: resp.url.absoluteString)
        guard let re = source.ruleExplore, let bookList = re.bookList, !bookList.isEmpty else {
            throw LegadoError("书源缺少 ruleExplore.bookList")
        }
        return try parseBookList(rule, elements: rule.getElements(bookList),
                                 baseUrl: resp.url.absoluteString, source: source,
                                 name: re.name, author: re.author, kind: re.kind,
                                 wordCount: re.wordCount, lastChapter: re.lastChapter,
                                 intro: re.intro, coverUrl: re.coverUrl, bookUrl: re.bookUrl)
    }

    private static func parseBookList(_ rule: AnalyzeRule, elements: [Any], baseUrl: String,
                                      source: BookSource, name: String?, author: String?, kind: String?,
                                      wordCount: String?, lastChapter: String?, intro: String?,
                                      coverUrl: String?, bookUrl: String?) throws -> [SearchBook] {
        var out: [SearchBook] = []
        for el in elements {
            rule.setContent(el, baseUrl: baseUrl)
            var sb = SearchBook()
            sb.name = (try? rule.getString(name)) ?? ""
            sb.author = (try? rule.getString(author)) ?? ""
            sb.kind = try? rule.getString(kind)
            sb.wordCount = try? rule.getString(wordCount)
            sb.lastChapter = try? rule.getString(lastChapter)
            sb.intro = try? rule.getString(intro)
            sb.coverUrl = try? rule.getString(coverUrl, isUrl: true)
            sb.bookUrl = (try? rule.getString(bookUrl, isUrl: true)) ?? ""
            sb.origin = source.bookSourceUrl
            sb.originName = source.bookSourceName
            if sb.name.isEmpty && sb.bookUrl.isEmpty { continue }
            if sb.bookUrl.isEmpty { continue }
            out.append(sb)
        }
        return out
    }

    // MARK: - 书籍详情

    public static func bookInfo(source: BookSource, book: Book,
                                variables: RuleVariables? = nil) async throws -> Book {
        let vars = variables ?? RuleVariables()
        let au = try AnalyzeUrl(ruleUrl: book.bookUrl, source: source, book: book, variables: vars)
        let resp = try await au.fetch()
        let rule = AnalyzeRule(book: book, source: source, variables: vars)
        rule.setContent(resp.body, baseUrl: resp.url.absoluteString)
        let ri = source.ruleBookInfo
        // init 规则先处理内容
        if let initRule = ri?.`init`, !initRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let processed = try rule.getString(initRule)
            if !processed.isEmpty { rule.setContent(processed, baseUrl: resp.url.absoluteString) }
        }
        let result = book
        result.origin = source.bookSourceUrl
        result.originName = source.bookSourceName
        if let v = try? rule.getString(ri?.name), !v.isEmpty { result.name = v }
        if let v = try? rule.getString(ri?.author), !v.isEmpty { result.author = v }
        if let v = try? rule.getString(ri?.intro), !v.isEmpty { result.intro = v }
        if let v = try? rule.getString(ri?.kind), !v.isEmpty { result.kind = v }
        if let v = try? rule.getString(ri?.coverUrl, isUrl: true), !v.isEmpty { result.coverUrl = v }
        if let v = try? rule.getString(ri?.lastChapter), !v.isEmpty { result.latestChapterTitle = v }
        if let v = try? rule.getString(ri?.wordCount), !v.isEmpty { result.wordCount = v }
        if let v = try? rule.getString(ri?.updateTime), !v.isEmpty { result.latestChapterTitle = result.latestChapterTitle ?? v }
        let toc = (try? rule.getString(ri?.tocUrl, isUrl: true)) ?? ""
        result.tocUrl = toc.isEmpty ? resp.url.absoluteString : toc
        if result.name.isEmpty { result.name = book.name }
        return result
    }

    // MARK: - 目录（含 nextTocUrl 翻页，URL 去重防死循环）

    public static func chapters(source: BookSource, book: Book,
                                 variables: RuleVariables? = nil) async throws -> [BookChapter] {
        guard let rt = source.ruleToc else { throw LegadoError("书源缺少 ruleToc") }
        let start = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        guard !start.isEmpty else { throw LegadoError("书籍缺少 tocUrl/bookUrl") }
        let vars = variables ?? RuleVariables()
        var out: [BookChapter] = []
        var visited = Set<String>()
        var queue = [start]
        var guardCount = 0
        while !queue.isEmpty {
            let url = queue.removeFirst()
            if visited.contains(url) { continue }
            visited.insert(url)
            guardCount += 1
            if guardCount > 1000 { break }

            let au = try AnalyzeUrl(ruleUrl: url, baseUrl: book.bookUrl,
                                    source: source, book: book, variables: vars)
            let resp = try await au.fetch()
            let rule = AnalyzeRule(book: book, source: source, variables: vars)
            rule.setContent(resp.body, baseUrl: resp.url.absoluteString)

            if let pre = rt.preUpdateJs, !pre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let v = try? rule.evalJS(pre, result: resp.body), let s = v as? String, !s.isEmpty {
                    rule.setContent(s, baseUrl: resp.url.absoluteString)
                }
            }

            if let listRule = rt.chapterList, !listRule.isEmpty {
                let elements = (try? rule.getElements(listRule)) ?? []
                for el in elements {
                    rule.setContent(el, baseUrl: resp.url.absoluteString)
                    let ch = BookChapter()
                    ch.title = (try? rule.getString(rt.chapterName)) ?? ""
                    ch.url = (try? rule.getString(rt.chapterUrl, isUrl: true)) ?? ""
                    ch.baseUrl = resp.url.absoluteString
                    ch.index = out.count
                    if let f = rt.formatJs, !f.isEmpty,
                       let v = try? rule.evalJS(f, result: ch.title) {
                        ch.title = AnalyzeRule.stringify(v)
                    }
                    if let v = try? rule.getString(rt.isVolume), !v.isEmpty, v != "false", v != "0" { ch.isVolume = true }
                    if let v = try? rule.getString(rt.isVip), !v.isEmpty, v != "false", v != "0" { ch.isVip = true }
                    if let v = try? rule.getString(rt.isPay), !v.isEmpty, v != "false", v != "0" { ch.isPay = true }
                    if ch.title.isEmpty && ch.url.isEmpty { continue }
                    out.append(ch)
                }
            }

            if let nextRule = rt.nextTocUrl, !nextRule.isEmpty {
                let nexts = (try? rule.getStringList(nextRule, isUrl: true)) ?? []
                for n in nexts where !n.isEmpty && !visited.contains(n) { queue.append(n) }
            }
        }
        return out
    }

    // MARK: - 正文（含 nextContentUrl 翻页 + replaceRegex 净化 + imageStyle）

    public static func content(source: BookSource, book: Book, chapter: BookChapter,
                              variables: RuleVariables? = nil,
                               nextChapterUrl: String? = nil) async throws -> String {
        guard let rc = source.ruleContent, let contentRule = rc.content, !contentRule.isEmpty else {
            throw LegadoError("书源缺少 ruleContent.content")
        }
        let vars = variables ?? RuleVariables()
        var parts: [String] = []
        var visited = Set<String>()
        var queue = [chapter.url]
        var guardCount = 0
        while !queue.isEmpty {
            let url = queue.removeFirst()
            if url.isEmpty || visited.contains(url) { continue }
            visited.insert(url)
            guardCount += 1
            if guardCount > 200 { break }

            let au = try AnalyzeUrl(ruleUrl: url, baseUrl: chapter.baseUrl.isEmpty ? book.tocUrl : chapter.baseUrl,
                                    source: source, book: book, chapter: chapter, variables: vars)
            let resp = try await au.fetch(webJs: rc.webJs, sourceRegex: rc.sourceRegex)
            let rule = AnalyzeRule(book: book, source: source, variables: vars)
            rule.chapter = chapter
            rule.nextChapterUrl = nextChapterUrl
            rule.setContent(resp.body, baseUrl: resp.url.absoluteString)
            parts.append(try rule.getString(contentRule))

            if let nextRule = rc.nextContentUrl, !nextRule.isEmpty {
                let nexts = (try? rule.getStringList(nextRule, isUrl: true)) ?? []
                for n in nexts where !n.isEmpty && !visited.contains(n) { queue.append(n) }
            }
        }
        var text = parts.joined(separator: "\n")

        // replaceRegex（##正则##替换### 语法）
        if let rr = rc.replaceRegex, !rr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rule = AnalyzeRule(book: book, source: source, variables: vars)
            let srs = rule.splitSourceRule("##" + rr)
            for sr in srs {
                for re in sr.replaceRegex {
                    text = ByRegex.replace(text, pattern: re, replacement: sr.replacement, firstOnly: sr.replaceFirst)
                }
            }
        }

        // imageStyle：FULL 保留 <img>；默认把图片转成链接文本
        if rc.imageStyle?.uppercased() != "FULL" {
            text = Self.imagesToLinks(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func imagesToLinks(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<img[^>]*?\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#,
                                                options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out = html
        for m in matches.reversed() {
            let src = ns.substring(with: m.range(at: 1))
            out = (out as NSString).replacingCharacters(in: m.range, with: "\n\(src)\n")
        }
        return out
    }
}