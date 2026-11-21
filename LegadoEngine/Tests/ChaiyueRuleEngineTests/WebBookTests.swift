import Foundation
import ChaiyueModels
import Testing
@testable import ChaiyueEngine

@Suite("请求与完整流程")
struct WebBookTests {
    @Test func analyzeUrlGetQueryAndPage() throws {
        let mock = MockTransport()
        mock.on("https://example.com/search", body: "ok")
        let env = makeEnvironment(mock)
        let session = makeSession(try makeSource(minimalSourceJSON), env: env)
        let url = try AnalyzeUrl("/search?q={{key}}&p=<1,2,3>&s=a b", key: "三体", page: 2,
                                 baseUrl: "https://example.com", session: session)
        _ = try url.getStrResponse()
        let req = try #require(mock.lastRequest)
        #expect(req.url == "https://example.com/search?q=%E4%B8%89%E4%BD%93&p=2&s=a+b")
        #expect(req.headers["User-Agent"] == SourceEnvironment.defaultUserAgent)
    }

    @Test func analyzeUrlPostOptions() throws {
        let mock = MockTransport()
        mock.on("https://example.com/api", body: #"{"code":0}"#, contentType: "application/json")
        let session = makeSession(try makeSource(minimalSourceJSON), env: makeEnvironment(mock))
        let json = try AnalyzeUrl(#"https://example.com/api,{"method":"POST","body":{"a":1},"headers":{"X-T":"1"}}"#, session: session)
        #expect(try json.getStrResponse().body() == #"{"code":0}"#)
        var req = try #require(mock.lastRequest)
        #expect(req.method == "POST")
        #expect(req.headers["Content-Type"] == "application/json; charset=UTF-8")
        #expect(req.headers["X-T"] == "1")
        #expect(String(decoding: req.body ?? Data(), as: UTF8.self) == #"{"a":1}"#)

        _ = try AnalyzeUrl("https://example.com/api,{'method':'POST','body':'k=你 好&x=1'}", session: session).getStrResponse()
        req = try #require(mock.lastRequest)
        #expect(String(decoding: req.body ?? Data(), as: UTF8.self) == "k=%E4%BD%A0+%E5%A5%BD&x=1")
        #expect(req.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test func dataURLWithTypeReturnsHex() throws {
        let session = makeSession(try makeSource(minimalSourceJSON), env: makeEnvironment())
        let b64 = Data(#"{"id":7}"#.utf8).base64EncodedString()
        let res = try AnalyzeUrl("data:;base64,\(b64),{\"type\":\"x\"}", session: session).getStrResponse()
        #expect(String(decoding: Hex.decode(res.body()) ?? Data(), as: UTF8.self) == #"{"id":7}"#)
    }

    @Test func headerJSAndLoginHeader() throws {
        let mock = MockTransport()
        mock.on("https://example.com", body: "ok")
        let source = try makeSource(#"""
        {"bookSourceUrl":"https://example.com","bookSourceName":"头测试",
         "header":"@js:JSON.stringify({'X-Token': String(source.getLoginHeader() || 'none'), 'X-Dev': java.deviceID()})"}
        """#)
        let env = makeEnvironment(mock)
        let session = makeSession(source, env: env)
        session.state.loginHeader = "tok123"
        _ = try AnalyzeUrl("https://example.com/a", session: session).getStrResponse()
        let req = try #require(mock.lastRequest)
        #expect(req.headers["X-Token"] == "tok123")
        #expect(req.headers["X-Dev"] == "test-device")
    }

    static let siteSource = #"""
    {
      "bookSourceUrl": "https://site.test",
      "bookSourceName": "模拟站",
      "searchUrl": "/search?wd={{key}}",
      "ruleSearch": {"bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                     "bookUrl": "tag.a@href", "kind": "class.tag@text", "wordCount": "class.wc@text"},
      "ruleBookInfo": {"intro": "id.intro@html", "tocUrl": "id.toc@href", "lastChapter": "id.last@text"},
      "ruleToc": {"chapterList": "id.list@tag.li", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href",
                  "nextTocUrl": "id.next@href"},
      "ruleContent": {"content": "id.content@html", "nextContentUrl": "text.下一页@href",
                      "replaceRegex": "##广告"}
    }
    """#

    @Test func fullFlowSearchInfoTocContent() async throws {
        let mock = MockTransport()
        mock.on("https://site.test/search", body: """
        <div class="book"><a href="/b/1"><h3>测试之书 作者：某人</h3></a><span class="author">作者：某人</span>
        <span class="tag">玄幻</span><span class="tag">连载</span><span class="wc">123456</span></div>
        <div class="book"><a href="/b/1"><h3>重复</h3></a></div>
        """)
        mock.on("https://site.test/b/1", body: """
        <p id="intro">第一段<br>第二段</p><a id="toc" href="/b/1/toc">目录</a><span id="last">第三章</span>
        """)
        mock.on("https://site.test/b/1/toc", body: """
        <ul id="list"><li><a href="/c/1">第一章</a></li><li><a href="/c/2">第二章</a></li></ul><a id="next" href="/b/1/toc2">下页</a>
        """)
        mock.on("https://site.test/b/1/toc2", body: """
        <ul id="list"><li><a href="/c/2">第二章</a></li><li><a href="/c/3">第三章</a></li></ul>
        """)
        mock.on("https://site.test/c/1", body: """
        <div id="content"><p>正文一</p><p>广告</p></div><a href="/c/1_2">下一页</a>
        """)
        mock.on("https://site.test/c/1_2", body: #"<div id="content"><p>正文二</p></div>"#)

        let webBook = WebBook(source: try makeSource(Self.siteSource), environment: makeEnvironment(mock))
        let results = try await webBook.searchBook("测试")
        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.name == "测试之书")
        #expect(first.author == "某人")
        #expect(first.kind == "玄幻,连载")
        #expect(first.wordCount == "12.3万字")
        #expect(first.bookUrl == "https://site.test/b/1")

        let book = try await webBook.getBookInfo(first.toBook())
        #expect(book.intro == "　　第一段\n　　第二段")
        #expect(book.tocUrl == "https://site.test/b/1/toc")
        #expect(book.latestChapterTitle == "第三章")

        let (updated, chapters) = try await webBook.getChapterList(book)
        #expect(chapters.map(\.title) == ["第一章", "第二章", "第三章"])
        #expect(chapters.map(\.index) == [0, 1, 2])
        #expect(updated.totalChapterNum == 3)

        let (content, _) = try await webBook.getContent(updated, chapter: chapters[0], nextChapterUrl: chapters[1].url)
        #expect(content == "　　正文一\n　　\n　　正文二")
    }
}
