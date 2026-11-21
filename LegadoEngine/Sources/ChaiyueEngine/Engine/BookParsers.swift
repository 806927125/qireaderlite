import Foundation
import ChaiyueModels

enum BookHelp {
    static func formatBookName(_ name: String) -> String {
        name.replacingRegex(#"\s+作\s*者.*|\s+\S+\s+著"#, with: "").trimmedControl
    }

    static func formatBookAuthor(_ author: String) -> String {
        author.replacingRegex(#"^\s*作\s*者[:：\s]+|\s+著"#, with: "").trimmedControl
    }

    /// 纯数字字数格式化为「n字」或「#.#万字」
    static func wordCountFormat(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        guard text.allSatisfy(\.isASCIIDigitCharacter), let words = Int(text) else { return text }
        guard words > 0 else { return "" }
        if words > 10_000 {
            let value = (Double(words) / 10_000 * 10).rounded() / 10
            let formatted = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return formatted + "万字"
        }
        return "\(words)字"
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}

extension BookChapter {
    /// 章节的绝对地址：仅对 `,{选项}` 之前的部分做绝对化
    var absoluteURL: String {
        if isVolume, url.hasPrefix(title) { return baseUrl }
        guard let m = url.firstMatch(URLUtils.paramPattern) else {
            return URLUtils.absoluteURL(base: baseUrl, relative: url)
        }
        let ns = url as NSString
        let before = ns.substring(to: m.range.location)
        let options = ns.substring(from: m.range.location + m.range.length)
        return URLUtils.absoluteURL(base: baseUrl, relative: before) + "," + options
    }
}

// MARK: - 搜索 / 发现列表

enum BookListParser {
    static func analyze(session: RuleSession, ruleData: RuleData, analyzeUrl: AnalyzeUrl, baseUrl: String, body: String,
                        isSearch: Bool, isRedirect: Bool) throws -> [SearchBook] {
        guard let source = session.source.bookSource else { return [] }
        let analyzeRule = AnalyzeRule(session: session, ruleData: ruleData)
        _ = try analyzeRule.setContent(body).setBaseUrl(baseUrl)
        _ = analyzeRule.setRedirectUrl(baseUrl)
        let variable = VariableCoding.encode(ruleData.variables)

        if isSearch, let pattern = source.bookUrlPattern, !pattern.isBlank, baseUrl.matches("^(?:\(pattern))$") {
            session.env.log(source.bookSourceUrl, "≡链接为详情页")
            if var book = try infoItem(session: session, analyzeRule: analyzeRule, analyzeUrl: analyzeUrl, body: body,
                                       baseUrl: baseUrl, variable: variable, isRedirect: isRedirect) {
                book.infoHtml = body
                return [book]
            }
            return []
        }

        let listRule: SearchRuleFields
        if isSearch || source.exploreRule.bookList.isNilOrBlank {
            listRule = SearchRuleFields(source.searchRule)
        } else {
            listRule = SearchRuleFields(source.exploreRule)
        }
        var ruleList = listRule.bookList ?? ""
        var reverse = false
        if ruleList.hasPrefix("-") {
            reverse = true
            ruleList.removeFirst()
        }
        if ruleList.hasPrefix("+") { ruleList.removeFirst() }
        let collections = try analyzeRule.getElements(ruleList)
        try session.checkCancelled()

        var books: [SearchBook] = []
        if collections.isEmpty, source.bookUrlPattern.isNilOrEmpty {
            session.env.log(source.bookSourceUrl, "└列表为空，按详情页解析")
            if var book = try infoItem(session: session, analyzeRule: analyzeRule, analyzeUrl: analyzeUrl, body: body,
                                       baseUrl: baseUrl, variable: variable, isRedirect: isRedirect) {
                book.infoHtml = body
                books.append(book)
            }
            return books
        }
        let rules = (
            name: analyzeRule.splitSourceRule(listRule.name),
            bookUrl: analyzeRule.splitSourceRule(listRule.bookUrl),
            author: analyzeRule.splitSourceRule(listRule.author),
            coverUrl: analyzeRule.splitSourceRule(listRule.coverUrl),
            intro: analyzeRule.splitSourceRule(listRule.intro),
            kind: analyzeRule.splitSourceRule(listRule.kind),
            lastChapter: analyzeRule.splitSourceRule(listRule.lastChapter),
            wordCount: analyzeRule.splitSourceRule(listRule.wordCount)
        )
        var seen = Set<String>()
        for item in collections {
            try session.checkCancelled()
            var book = Book(bookUrl: "", origin: source.bookSourceUrl)
            book.variable = variable
            book.type = source.bookSourceType
            book.originName = source.bookSourceName
            book.originOrder = source.customOrder
            let ref = BookRef(book)
            analyzeRule.ruleData = ref
            _ = try analyzeRule.setContent(item)
            ref.book.name = BookHelp.formatBookName(try analyzeRule.getString(rules.name))
            guard !ref.book.name.isEmpty else { continue }
            ref.book.author = BookHelp.formatBookAuthor(try analyzeRule.getString(rules.author))
            ref.book.kind = attempt(session) { try analyzeRule.getStringList(rules.kind)?.joined(separator: ",") } ?? nil
            ref.book.wordCount = attempt(session) { BookHelp.wordCountFormat(try analyzeRule.getString(rules.wordCount)) }
            ref.book.latestChapterTitle = attempt(session) { try analyzeRule.getString(rules.lastChapter) }
            ref.book.intro = attempt(session) { HTMLFormatter.format(try analyzeRule.getString(rules.intro)) }
            if let cover = attempt(session, { try analyzeRule.getString(rules.coverUrl) }), !cover.isEmpty {
                ref.book.coverUrl = URLUtils.absoluteURL(base: baseUrl, relative: cover)
            }
            ref.book.bookUrl = try analyzeRule.getString(rules.bookUrl, isUrl: true)
            if ref.book.bookUrl.isEmpty { ref.book.bookUrl = baseUrl }
            var searchBook = ref.book.toSearchBook()
            if baseUrl == searchBook.bookUrl { searchBook.infoHtml = body }
            if seen.insert(searchBook.bookUrl).inserted { books.append(searchBook) }
        }
        if reverse { books.reverse() }
        return books
    }

    private static func infoItem(session: RuleSession, analyzeRule: AnalyzeRule, analyzeUrl: AnalyzeUrl, body: String,
                                 baseUrl: String, variable: String?, isRedirect: Bool) throws -> SearchBook? {
        guard let source = session.source.bookSource else { return nil }
        var book = Book(bookUrl: isRedirect ? baseUrl : URLUtils.absoluteURL(base: analyzeUrl.url, relative: analyzeUrl.ruleUrl),
                        origin: source.bookSourceUrl)
        book.variable = variable
        book.originName = source.bookSourceName
        book.originOrder = source.customOrder
        book.type = source.bookSourceType
        let ref = BookRef(book)
        analyzeRule.ruleData = ref
        try BookInfoParser.analyze(session: session, ref: ref, body: body, analyzeRule: analyzeRule,
                                   baseUrl: baseUrl, redirectUrl: baseUrl, canReName: false)
        return ref.book.name.isBlank ? nil : ref.book.toSearchBook()
    }

    /// 次要字段解析失败只记录日志，不影响整条结果
    static func attempt<T>(_ session: RuleSession, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            session.env.log(session.source.key, "└\(error)")
            return nil
        }
    }
}

/// 搜索规则与发现规则共有的字段
struct SearchRuleFields {
    var bookList, name, author, intro, kind, lastChapter, bookUrl, coverUrl, wordCount: String?

    init(_ r: SearchRule) {
        bookList = r.bookList; name = r.name; author = r.author; intro = r.intro; kind = r.kind
        lastChapter = r.lastChapter; bookUrl = r.bookUrl; coverUrl = r.coverUrl; wordCount = r.wordCount
    }

    init(_ r: ExploreRule) {
        bookList = r.bookList; name = r.name; author = r.author; intro = r.intro; kind = r.kind
        lastChapter = r.lastChapter; bookUrl = r.bookUrl; coverUrl = r.coverUrl; wordCount = r.wordCount
    }
}

// MARK: - 详情

enum BookInfoParser {
    static func analyze(session: RuleSession, ref: BookRef, body: String, baseUrl: String, redirectUrl: String,
                        canReName: Bool) throws {
        let analyzeRule = AnalyzeRule(session: session, ruleData: ref)
        _ = try analyzeRule.setContent(body).setBaseUrl(baseUrl)
        _ = analyzeRule.setRedirectUrl(redirectUrl)
        try analyze(session: session, ref: ref, body: body, analyzeRule: analyzeRule, baseUrl: baseUrl,
                    redirectUrl: redirectUrl, canReName: canReName)
    }

    static func analyze(session: RuleSession, ref: BookRef, body: String, analyzeRule: AnalyzeRule, baseUrl: String,
                        redirectUrl: String, canReName: Bool) throws {
        guard let source = session.source.bookSource else { return }
        let rule = source.bookInfoRule
        if let initRule = rule.initRule, !initRule.isBlank {
            try session.checkCancelled()
            _ = try analyzeRule.setContent(try analyzeRule.getElement(initRule))
        }
        let mCanReName = canReName && !rule.canReName.isNilOrBlank
        try session.checkCancelled()
        let name = BookHelp.formatBookName(try analyzeRule.getString(rule.name))
        if !name.isEmpty, mCanReName || ref.book.name.isEmpty { ref.book.name = name }
        let author = BookHelp.formatBookAuthor(try analyzeRule.getString(rule.author))
        if !author.isEmpty, mCanReName || ref.book.author.isEmpty { ref.book.author = author }
        if let kind = BookListParser.attempt(session, { try analyzeRule.getStringList(rule.kind)?.joined(separator: ",") }),
           let kind, !kind.isEmpty {
            ref.book.kind = kind
        }
        if let wc = BookListParser.attempt(session, { BookHelp.wordCountFormat(try analyzeRule.getString(rule.wordCount)) }), !wc.isEmpty {
            ref.book.wordCount = wc
        }
        if let last = BookListParser.attempt(session, { try analyzeRule.getString(rule.lastChapter) }), !last.isEmpty {
            ref.book.latestChapterTitle = last
        }
        if let intro = BookListParser.attempt(session, { HTMLFormatter.format(try analyzeRule.getString(rule.intro)) }), !intro.isEmpty {
            ref.book.intro = intro
        }
        if let cover = BookListParser.attempt(session, { try analyzeRule.getString(rule.coverUrl) }), !cover.isEmpty {
            ref.book.coverUrl = URLUtils.absoluteURL(base: redirectUrl, relative: cover)
        }
        try session.checkCancelled()
        ref.book.tocUrl = try analyzeRule.getString(rule.tocUrl, isUrl: true)
        if ref.book.tocUrl.isEmpty { ref.book.tocUrl = baseUrl }
        if ref.book.tocUrl == baseUrl { ref.book.tocHtml = body }
        if let downloadRule = rule.downloadUrls, !downloadRule.isBlank {
            ref.book.downloadUrls = BookListParser.attempt(session) { try analyzeRule.getStringList(downloadRule, isUrl: true) } ?? nil
        }
    }
}

// MARK: - 目录

enum ChapterListParser {
    static func analyze(session: RuleSession, ref: BookRef, baseUrl: String, redirectUrl: String, body: String) throws -> [BookChapter] {
        guard let source = session.source.bookSource else { return [] }
        let tocRule = source.tocRule
        var listRule = tocRule.chapterList ?? ""
        var reverse = false
        if listRule.hasPrefix("-") {
            reverse = true
            listRule.removeFirst()
        }
        if listRule.hasPrefix("+") { listRule.removeFirst() }

        var chapters: [BookChapter] = []
        var visited = [redirectUrl]
        var page = try analyzePage(session: session, ref: ref, baseUrl: baseUrl, redirectUrl: redirectUrl, body: body,
                                   rule: tocRule, listRule: listRule, getNextUrl: true)
        chapters += page.chapters
        if page.next.count == 1 {
            var nextUrl = page.next[0]
            while !nextUrl.isEmpty, !visited.contains(nextUrl) {
                try session.checkCancelled()
                visited.append(nextUrl)
                let res = try AnalyzeUrl(nextUrl, session: session, ruleData: ref).getStrResponse()
                page = try analyzePage(session: session, ref: ref, baseUrl: nextUrl, redirectUrl: nextUrl, body: res.body(),
                                       rule: tocRule, listRule: listRule, getNextUrl: true)
                nextUrl = page.next.first ?? ""
                chapters += page.chapters
            }
        } else if page.next.count > 1 {
            for url in page.next {
                try session.checkCancelled()
                let res = try AnalyzeUrl(url, session: session, ruleData: ref).getStrResponse()
                chapters += try analyzePage(session: session, ref: ref, baseUrl: url, redirectUrl: res.url(), body: res.body(),
                                            rule: tocRule, listRule: listRule, getNextUrl: false).chapters
            }
        }
        guard !chapters.isEmpty else { throw RuleError.message("目录为空") }

        // 去重：保留先出现的章节；倒序规则先翻转
        if !reverse { chapters.reverse() }
        var seen = Set<String>()
        var list = chapters.filter { seen.insert($0.url).inserted }
        if !(ref.book.readConfig?.reverseToc ?? false) { list.reverse() }
        for i in list.indices { list[i].index = i }

        if let formatJs = tocRule.formatJs, !formatJs.isBlank {
            for i in list.indices {
                let chapterRef = ChapterRef(list[i])
                var bindings = JSBindings(host: nil)
                bindings.chapter = chapterRef
                bindings.title = list[i].title
                bindings.extra = ["gInt": 0, "index": i + 1]
                do {
                    if let v = try session.evalJS(formatJs, bindings: bindings) {
                        list[i] = chapterRef.chapter
                        list[i].title = AnalyzeUrl.stringify(v)
                    }
                } catch {
                    session.env.log(source.bookSourceUrl, "格式化标题出错：\(error)")
                }
            }
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if ref.book.totalChapterNum < list.count {
            ref.book.lastCheckCount = list.count - ref.book.totalChapterNum
            ref.book.latestChapterTime = now
        }
        ref.book.lastCheckTime = now
        ref.book.totalChapterNum = list.count
        ref.book.durChapterTitle = list.indices.contains(ref.book.durChapterIndex) ? list[ref.book.durChapterIndex].title : list.last?.title
        ref.book.latestChapterTitle = list.last?.title
        return list
    }

    private static func analyzePage(session: RuleSession, ref: BookRef, baseUrl: String, redirectUrl: String, body: String,
                                    rule: TocRule, listRule: String, getNextUrl: Bool) throws -> (chapters: [BookChapter], next: [String]) {
        let analyzeRule = AnalyzeRule(session: session, ruleData: ref)
        _ = try analyzeRule.setContent(body).setBaseUrl(baseUrl)
        _ = analyzeRule.setRedirectUrl(redirectUrl)
        let elements = try analyzeRule.getElements(listRule)
        var next: [String] = []
        if getNextUrl, let nextRule = rule.nextTocUrl, !nextRule.isEmpty {
            for item in try analyzeRule.getStringList(nextRule, isUrl: true) ?? [] where item != redirectUrl {
                next.append(item)
            }
        }
        try session.checkCancelled()
        var chapters: [BookChapter] = []
        guard !elements.isEmpty else { return (chapters, next) }
        let nameRule = analyzeRule.splitSourceRule(rule.chapterName)
        let urlRule = analyzeRule.splitSourceRule(rule.chapterUrl)
        let vipRule = analyzeRule.splitSourceRule(rule.isVip)
        let payRule = analyzeRule.splitSourceRule(rule.isPay)
        let timeRule = analyzeRule.splitSourceRule(rule.updateTime)
        let volumeRule = analyzeRule.splitSourceRule(rule.isVolume)
        for (index, item) in elements.enumerated() {
            try session.checkCancelled()
            _ = try analyzeRule.setContent(item)
            let chapterRef = ChapterRef(BookChapter(bookUrl: ref.book.bookUrl, baseUrl: redirectUrl))
            analyzeRule.chapter = chapterRef
            chapterRef.chapter.title = try analyzeRule.getString(nameRule)
            chapterRef.chapter.url = try analyzeRule.getString(urlRule)
            chapterRef.chapter.tag = try analyzeRule.getString(timeRule)
            chapterRef.chapter.isVolume = isTrueValue(try analyzeRule.getString(volumeRule))
            if chapterRef.chapter.url.isEmpty {
                chapterRef.chapter.url = chapterRef.chapter.isVolume ? chapterRef.chapter.title + "\(index)" : baseUrl
            }
            if !chapterRef.chapter.title.isEmpty {
                if isTrueValue(try analyzeRule.getString(vipRule)) { chapterRef.chapter.isVip = true }
                if isTrueValue(try analyzeRule.getString(payRule)) { chapterRef.chapter.isPay = true }
                chapters.append(chapterRef.chapter)
            }
        }
        analyzeRule.chapter = nil
        return (chapters, next)
    }
}

// MARK: - 正文

enum ContentParser {
    static func analyze(session: RuleSession, ref: BookRef, chapter: ChapterRef, baseUrl: String, redirectUrl: String,
                        body: String, nextChapterUrl: String?) throws -> String {
        guard let source = session.source.bookSource else { return "" }
        let rule = source.contentRule
        let analyzeRule = AnalyzeRule(session: session, ruleData: ref)
        _ = try analyzeRule.setContent(body, baseUrl: baseUrl)
        _ = analyzeRule.setRedirectUrl(redirectUrl)
        analyzeRule.chapter = chapter
        analyzeRule.nextChapterUrl = nextChapterUrl

        if let titleRule = rule.title, !titleRule.isBlank,
           let title = BookListParser.attempt(session, { try analyzeRule.getString(titleRule) }), !title.isBlank {
            chapter.chapter.title = title
        }

        var contents: [String] = []
        var visited = [redirectUrl]
        var page = try analyzePage(session: session, ref: ref, chapter: chapter, baseUrl: baseUrl, redirectUrl: redirectUrl,
                                   body: body, rule: rule, nextChapterUrl: nextChapterUrl, getNextPageUrl: true)
        contents.append(page.content)
        if page.next.count == 1 {
            var nextUrl = page.next[0]
            while !nextUrl.isEmpty, !visited.contains(nextUrl) {
                if let nextChapterUrl, !nextChapterUrl.isEmpty,
                   URLUtils.absoluteURL(base: redirectUrl, relative: nextUrl) == URLUtils.absoluteURL(base: redirectUrl, relative: nextChapterUrl) {
                    break
                }
                try session.checkCancelled()
                visited.append(nextUrl)
                let res = try AnalyzeUrl(nextUrl, session: session, ruleData: ref).getStrResponse()
                page = try analyzePage(session: session, ref: ref, chapter: chapter, baseUrl: nextUrl, redirectUrl: res.url(),
                                       body: res.body(), rule: rule, nextChapterUrl: nextChapterUrl, getNextPageUrl: true)
                nextUrl = page.next.first ?? ""
                contents.append(page.content)
            }
        } else if page.next.count > 1 {
            for url in page.next {
                try session.checkCancelled()
                let res = try AnalyzeUrl(url, session: session, ruleData: ref).getStrResponse()
                contents.append(try analyzePage(session: session, ref: ref, chapter: chapter, baseUrl: url, redirectUrl: res.url(),
                                                body: res.body(), rule: rule, nextChapterUrl: nextChapterUrl,
                                                getNextPageUrl: false).content)
            }
        }

        var content = contents.joined(separator: "\n")
        if let replaceRegex = rule.replaceRegex, !replaceRegex.isEmpty {
            content = content.components(separatedBy: .newlines).map(\.trimmedWhitespace).joined(separator: "\n")
            content = try analyzeRule.getString(replaceRegex, content: content)
            content = content.components(separatedBy: .newlines).map { "　　" + $0 }.joined(separator: "\n")
        }
        if !chapter.chapter.isVolume, content.isBlank { throw RuleError.message("正文内容为空") }
        return content
    }

    private static func analyzePage(session: RuleSession, ref: BookRef, chapter: ChapterRef, baseUrl: String, redirectUrl: String,
                                    body: String, rule: ContentRule, nextChapterUrl: String?,
                                    getNextPageUrl: Bool) throws -> (content: String, next: [String]) {
        let analyzeRule = AnalyzeRule(session: session, ruleData: ref)
        _ = try analyzeRule.setContent(body, baseUrl: baseUrl)
        _ = analyzeRule.setRedirectUrl(redirectUrl)
        analyzeRule.nextChapterUrl = nextChapterUrl
        analyzeRule.chapter = chapter
        var content = try analyzeRule.getString(rule.content, unescape: false)
        content = HTMLFormatter.formatKeepImg(content, baseURL: redirectUrl)
        if content.contains("&") { content = HTMLEntities.unescape(content) }
        var next: [String] = []
        if getNextPageUrl, let nextRule = rule.nextContentUrl, !nextRule.isEmpty {
            next = try analyzeRule.getStringList(nextRule, isUrl: true) ?? []
        }
        return (content, next)
    }
}
