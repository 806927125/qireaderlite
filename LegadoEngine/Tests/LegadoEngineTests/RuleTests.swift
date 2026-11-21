import XCTest
@testable import LegadoEngine

final class RuleTests: XCTestCase {

    // MARK: - BookSource 解析

    func testParseBookSourceArrayAndSingle() throws {
        let json = """
        [{"bookSourceUrl":"https://a.com","bookSourceName":"A","bookSourceType":"0","enabled":1,
          "ruleSearch":{"bookList":"class.item","name":"tag.a@text"},"weight":"5"},
         {"bookSourceUrl":"https://b.com","bookSourceName":"B"}]
        """
        let sources = try BookSource.parse(Data(json.utf8))
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].bookSourceName, "A")
        XCTAssertEqual(sources[0].bookSourceType, 0)
        XCTAssertTrue(sources[0].enabled)
        XCTAssertEqual(sources[0].weight, 5)
        XCTAssertEqual(sources[0].ruleSearch?.bookList, "class.item")

        let single = try BookSource.parse(Data(#"{"bookSourceUrl":"https://c.com","bookSourceName":"C"}"#.utf8))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].bookSourceName, "C")
    }

    func testSourceVariable() {
        // ⭐⭐⭐⭐⭐ **站方变量的【两套语义】**（2026-11-19 移植 柴阅/Chaiyue 实证）⭐⭐⭐
        //
        //   权威规格 = Chaiyue `SourceState`（RuleSession.swift）：
        //     · 站方变量 `source.getVariable()/setVariable()` ⇒ **一整串**（键 `sourceVariable_<key>`）⭐⭐⭐
        //     · 书源变量 `source.get(k)/put(k,v)`      ⇒ **每 k 一个独立项**（键 `v_<key>_<k>`）⭐⭐⭐
        //
        //   ⇒ 之前我们把 `getVariable(key:)` 实现成「从 variable 整串里取项」⇒ **语义错位** ⭐⭐⭐
        //     ⇒ 站方 `source.put('nhAuthed', h)` 与站方变量混在一格 ⇒ 真机「发现页 0 分类」⭐⭐⭐
        var s = BookSource(bookSourceUrl: "https://x.com", bookSourceName: "X")

        // ① 书源变量 ⇒ 落在**独立的 sourceVars 格**
        s.putVariable(key: "token", value: "abc")
        XCTAssertEqual(s.getVariable(key: "token"), "abc")
        XCTAssertEqual(s.sourceVars["token"], "abc")
        // ⭐ **不污染站方变量的整串**
        XCTAssertEqual(s.getVariable(), "")

        // ② 站方变量 ⇒ 整串
        s.setVariable(#"{"a":"1"}"#)
        XCTAssertEqual(s.getVariable(), #"{"a":"1"}"#)
        // ⭐⭐⭐ **两格互不干扰**（★ 这条是本移植的核心断言）⭐⭐⭐
        XCTAssertEqual(s.getVariable(key: "token"), "abc", "站方变量整串不得吞掉书源变量")
        XCTAssertEqual(s.sourceVars["token"], "abc", "书源变量不得被站方变量整串覆盖")

        // ③ 站方整串里的项 **读不到**（语义已分离 ⇒ 不再"两套互通"）
        XCTAssertEqual(s.getVariable(key: "a"), "", "★ 站方整串的项不得被当成书源变量（★ 语义错位已消除）")
    }

    // MARK: - RuleSplitter

    func testSplitOrAnd() {
        // Kotlin 语义：首个出现的分隔符决定 elementsType，整串按它切分
        let sp = RuleSplitter()
        XCTAssertEqual(sp.splitRule("a||b&&c", "||", "&&"), ["a", "b&&c"])
        XCTAssertEqual(sp.elementsType, "||")
        let sp2 = RuleSplitter()
        XCTAssertEqual(sp2.splitRule("a&&b||c", "||", "&&"), ["a", "b||c"])
        XCTAssertEqual(sp2.elementsType, "&&")
    }

    func testSplitProtectsJS() {
        let sp = RuleSplitter()
        let parts = sp.splitRule("@js:var x = 'a||b'; x||tag.a@text", "||")
        XCTAssertEqual(parts.count, 1) // @js: 之后整段视为代码
        XCTAssertTrue(parts[0].hasPrefix("@js:"))
        let sp2 = RuleSplitter()
        let parts2 = sp2.splitRule("<js>'a||b'</js>||tag.a@text", "||")
        XCTAssertEqual(parts2.count, 2)
    }

    // MARK: - ByDefault（SwiftSoup）

    static let html = """
    <html><body>
      <div class="list">
        <div class="item"><a href="/book/1">书名一</a><span class="author">作者一</span></div>
        <div class="item"><a href="/book/2">书名二</a><span class="author">作者二</span></div>
        <div class="item"><a href="/book/3">书名三</a><span class="author">作者三</span></div>
      </div>
      <p id="intro">简介内容</p>
    </body></html>
    """

    func testDefaultRules() throws {
        let d = ByDefault(Self.html, baseUrl: "https://x.com/")
        let items = d.getElements("class.item")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(d.getString("class.item.0@tag.a@text"), "书名一")
        XCTAssertEqual(d.getString("class.item.-1@tag.a@text"), "书名三")
        XCTAssertEqual(d.getString("id.intro@text"), "简介内容")
        let hrefs = d.getStringList("class.item@tag.a@href")
        XCTAssertEqual(hrefs, ["https://x.com/book/1", "https://x.com/book/2", "https://x.com/book/3"])
    }

    func testDefaultIndexSyntax() throws {
        let d = ByDefault(Self.html)
        XCTAssertEqual(d.getElements("class.item.[0,2]").count, 2)
        XCTAssertEqual(d.getElements("class.item.[0:2]").count, 2)
        XCTAssertEqual(d.getElements("class.item.!0").count, 2)
    }

    // MARK: - ByJSONPath

    static let json = """
    {"store":{"book":[
      {"title":"T1","price":5,"tags":["a","b"]},
      {"title":"T2","price":15},
      {"title":"T3","price":25}]},
    "code":0,"msg":"ok"}
    """

    func testJSONPath() throws {
        let j = ByJSONPath(Self.json)
        XCTAssertEqual(j.getString("$.store.book[0].title"), "T1")
        XCTAssertEqual(j.getStringList("$.store.book[*].title"), ["T1", "T2", "T3"])
        XCTAssertEqual(j.getStringList("$.store.book[?(@.price > 10)].title"), ["T2", "T3"])
        XCTAssertEqual(j.getString("$.store.book[-1].title"), "T3")
        XCTAssertEqual(j.getString("$.code"), "0")
        XCTAssertEqual(j.getStringList("$..title").count, 3)
    }

    func testJSONPathAlternatives() throws {
        let j = ByJSONPath(Self.json)
        XCTAssertEqual(j.getString("$.nope||$.msg"), "ok")
    }

    // MARK: - ByRegex

    func testRegex() {
        let text = "abc123def456"
        let all = ByRegex.getElements(text, ["([a-z]+)(\\d+)", "$1", "$2"], 0)
        XCTAssertEqual(all, [["abc", "123"], ["def", "456"]])
        XCTAssertEqual(ByRegex.getElement(text, ["\\d+"], 1), ["123"])
        XCTAssertEqual(ByRegex.getElement(text, ["\\d+"], -1), ["456"])
        XCTAssertEqual(ByRegex.replace("a1b2", pattern: "\\d", replacement: "#", firstOnly: false), "a#b#")
        XCTAssertEqual(ByRegex.replace("a1b2", pattern: "\\d", replacement: "#", firstOnly: true), "a#b2")
    }

    // MARK: - AnalyzeRule 全链路（本地内容，不联网）

    func testAnalyzeRuleGetString() throws {
        let rule = AnalyzeRule()
        rule.setContent(Self.html, baseUrl: "https://x.com/")
        XCTAssertEqual(try rule.getString("class.item.0@tag.a@text"), "书名一")
        XCTAssertEqual(try rule.getString("class.item.0@tag.a@href", isUrl: true), "https://x.com/book/1")
        // || 取第一个非空
        XCTAssertEqual(try rule.getString("class.none@text||class.item.1@tag.a@text"), "书名二")
        // && 拼接
        XCTAssertEqual(try rule.getString("class.item.0@tag.a@text&&class.item.0@tag.span@text"), "书名一作者一")
    }

    func testPutGet() throws {
        let rule = AnalyzeRule()
        rule.setContent(Self.html, baseUrl: "https://x.com/")
        _ = try rule.getString("@put:{\"first\":\"class.item.0@tag.a@text\"}class.item.1@tag.a@text")
        XCTAssertEqual(try rule.getString("@get:{first}"), "书名一")
    }

    func testReplaceRegexRule() throws {
        let rule = AnalyzeRule()
        rule.setContent(Self.html)
        let v = try rule.getString("class.item.0@tag.a@text##书名##《")
        XCTAssertEqual(v, "《一")
        let first = try rule.getString("id.intro@text##内容##X###")
        XCTAssertEqual(first, "简介X")
    }

    func testJSONContentAutoMode() throws {
        let rule = AnalyzeRule()
        rule.setContent(Self.json)
        XCTAssertEqual(try rule.getString("$.store.book[1].title"), "T2")
        XCTAssertEqual(try rule.getStringList("$.store.book[*].title").count, 3)
    }

    func testGetStringListCombinators() throws {
        let rule = AnalyzeRule()
        rule.setContent(Self.html)
        let names = try rule.getStringList("class.item@tag.a@text")
        XCTAssertEqual(names, ["书名一", "书名二", "书名三"])
        let inter = try rule.getStringList("class.item@tag.a@text%%class.item@tag.span@text")
        XCTAssertEqual(inter, ["书名一", "作者一", "书名二", "作者二", "书名三", "作者三"])
    }

    // MARK: - AnalyzeUrl（不联网，只验证 URL 构造）

    func testAnalyzeUrlTemplates() throws {
        let au = try AnalyzeUrl(ruleUrl: "https://x.com/s?q={{key}}&p={{page}}", key: "小说", page: 2)
        XCTAssertTrue(au.url.contains("q="))
        XCTAssertTrue(au.url.contains("p=2"))
        XCTAssertEqual(au.method, "GET")
    }

    func testAnalyzeUrlPostOptions() throws {
        let au = try AnalyzeUrl(ruleUrl: "https://x.com/api,{\"method\":\"POST\",\"body\":\"k={{key}}\"}", key: "v")
        XCTAssertEqual(au.method, "POST")
        XCTAssertEqual(au.body, "k=v")
    }

    func testAnalyzeUrlPageMath() throws {
        let au = try AnalyzeUrl(ruleUrl: "https://x.com/p/{{page-1}}", page: 3)
        XCTAssertTrue(au.url.hasSuffix("/p/2"))
    }

    // MARK: - 发现分类解析

    func testExploreKinds() {
        var s = BookSource(bookSourceUrl: "https://x.com", bookSourceName: "X")
        s.exploreUrl = "玄幻::https://x.com/f1?page={{page}}\n都市::https://x.com/f2"
        let kinds = LegadoEngine.exploreKinds(source: s)
        XCTAssertEqual(kinds.count, 2)
        XCTAssertEqual(kinds[0].title, "玄幻")
        XCTAssertEqual(kinds[1].url, "https://x.com/f2")

        s.exploreUrl = #"[{"title":"A","url":"https://x.com/a"}]"#
        XCTAssertEqual(LegadoEngine.exploreKinds(source: s).first?.title, "A")
    }

    // MARK: - 正文图片处理

    func testImagesToLinks() {
        let html = "前文<img src=\"https://x.com/1.jpg\" alt=\"图\">后文"
        let out = LegadoEngine.imagesToLinks(html)
        XCTAssertTrue(out.contains("https://x.com/1.jpg"))
        XCTAssertFalse(out.contains("<img"))
    }

    // MARK: - JS 桥（Apple 平台跑真 JS；Linux 验证 stub 抛错）

    func testJSBridge() {
        let bridge = JSBridge(source: nil, book: nil, chapter: nil, variables: RuleVariables())
        #if canImport(JavaScriptCore) && !os(Linux)
        XCTAssertEqual(try bridge.eval("1 + 2") as? Int, 3)
        XCTAssertEqual(try bridge.eval("java.base64Encode('abc')") as? String, "YWJj")
        XCTAssertEqual(try bridge.eval("java.md5Encode('abc')") as? String, "900150983cd24fb0d6963f7d28e17f72")
        // AES 往返
        let enc = try bridge.eval("java.aesEncodeToBase64String('hello', '1234567890123456', 'AES/ECB/PKCS5Padding', null)") as? String
        XCTAssertNotNil(enc)
        let dec = try bridge.eval("java.aesDecodeToString('\(enc!)', '1234567890123456', 'AES/ECB/PKCS5Padding', null)") as? String
        XCTAssertEqual(dec, "hello")
        // cache
        _ = try bridge.eval("cache.put('k1', 'v1')")
        XCTAssertEqual(try bridge.eval("cache.get('k1')") as? String, "v1")
        // jsoup
        XCTAssertEqual(try bridge.eval("org.jsoup.Jsoup.parse('<p>hi</p>').select('p').text()") as? String, "hi")
        // Rhino 兼容：.length()
        XCTAssertEqual(try bridge.eval("var s = 'abc'; s.length()") as? Int, 3)
        // @put/@get 桥
        _ = try bridge.eval("java.put('kk', 'vv')")
        XCTAssertEqual(try bridge.eval("java.get('kk')") as? String, "vv")
        #else
        XCTAssertThrowsError(try bridge.eval("1"))
        #endif
    }
}