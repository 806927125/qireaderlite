import Foundation
import ChaiyueModels
import Testing
@testable import ChaiyueEngine

/// 收集书源通知与日志
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [SourceEvent] = []
    private var storedLogs: [String] = []

    var events: [SourceEvent] { lock.withLock { storedEvents } }
    var logs: [String] { lock.withLock { storedLogs } }

    func attach(_ env: SourceEnvironment) {
        env.setEventHandler { [self] event in lock.withLock { storedEvents.append(event) } }
        env.setLogger { [self] _, message in lock.withLock { storedLogs.append(message) } }
    }
}

/// 记录界面类接口的调用
private final class RecordingUI: SourceUIDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [String] = []
    var calls: [String] { lock.withLock { storedCalls } }
    private func record(_ s: String) { lock.withLock { storedCalls.append(s) } }

    func renderWebView(_ request: WebViewRequest) throws -> String { throw RuleError.message("no webview") }
    func startBrowser(url: String, title: String, html: String?, sourceKey: String) { record("startBrowser:\(url)") }
    func startBrowserAwait(url: String, title: String, html: String?, sourceKey: String) throws -> BrowserResult {
        throw RuleError.message("no browser")
    }
    func showBrowser(_ sheet: BrowserSheet) { record("showBrowser:\(sheet.url)") }
    func verificationCode(imageURL: String, sourceKey: String) throws -> String { throw RuleError.message("no captcha") }
    func toast(_ message: String, long: Bool) {}
    func copyText(_ text: String) { record("copy:\(text)") }
    func openURL(_ url: String, mimeType: String?, sourceKey: String) { record("open:\(url)|\(mimeType ?? "")") }
    func openVideoPlayer(url: String, title: String?, floating: Bool, sourceKey: String) {
        record("video:\(url)|\(title ?? "")|\(floating)")
    }
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../_reference/sources/new4/\(name).json").standardized
}

private func fixture(_ name: String) throws -> BookSource {
    try SourceImport.bookSources(from: Data(contentsOf: fixtureURL(name)))[0]
}

private let callBackSourceJSON = #"""
{"bookSourceUrl":"https://cb.example.com","bookSourceName":"回调源","eventListener":true,"customButton":true,
 "ruleContent":{"content":"$.c","callBackJs":"source.put('ev', event); source.put('bn', book ? book.name : 'none'); source.put('ch', chapter ? chapter.title : 'none'); if (event == 'clickCustomButton') java.open('login');"}}
"""#

@Suite("书源事件回调与扩展接口")
struct SourceCallBackTests {
    @Test func callBackDispatchesEventWithBookAndChapter() async throws {
        let env = makeEnvironment()
        let recorder = Recorder()
        recorder.attach(env)
        let source = try makeSource(callBackSourceJSON)
        let webBook = WebBook(source: source, environment: env)
        #expect(webBook.hasCallBack)

        let book = Book(bookUrl: "https://cb.example.com/b/1", origin: source.bookSourceUrl, name: "测试书")
        let chapter = BookChapter(url: "/c/1", title: "第一章", bookUrl: book.bookUrl)
        await webBook.callBack(event: .clickCustomButton, book: book, chapter: chapter)
        let state = SourceState(key: source.bookSourceUrl, env: env)
        #expect(state.get("ev") == "clickCustomButton")
        #expect(state.get("bn") == "测试书")
        #expect(state.get("ch") == "第一章")
        let opened = recorder.events.contains {
            if case .open(let name, _, _, let key) = $0 { return name == "login" && key == source.bookSourceUrl }
            return false
        }
        #expect(opened)

        await webBook.callBack(event: .delBookShelf, book: book)
        #expect(state.get("ev") == "delBookShelf")
        #expect(state.get("ch") == "none")
        #expect(recorder.logs.isEmpty)
    }

    @Test func callBackRequiresEventListener() async throws {
        let env = makeEnvironment()
        var source = try makeSource(callBackSourceJSON)
        source.eventListener = false
        let webBook = WebBook(source: source, environment: env)
        #expect(!webBook.hasCallBack)
        await webBook.callBack(event: .addBookShelf, book: Book(bookUrl: "u", origin: source.bookSourceUrl))
        #expect(SourceState(key: source.bookSourceUrl, env: env).get("ev") == "")
    }

    @Test func callBackErrorsAreLoggedNotThrown() async throws {
        let env = makeEnvironment()
        let recorder = Recorder()
        recorder.attach(env)
        var source = try makeSource(callBackSourceJSON)
        source.ruleContent?.callBackJs = "throw new Error('boom')"
        await WebBook(source: source, environment: env).callBack(event: .startRead, book: nil)
        #expect(recorder.logs.contains { $0.contains("callBack(startRead)") && $0.contains("boom") })
    }

    @Test func eventFieldsRoundTrip() throws {
        let source = try makeSource(callBackSourceJSON)
        #expect(source.eventListener && source.customButton)
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(BookSource.self, from: data)
        #expect(decoded.eventListener && decoded.customButton)
        #expect(decoded.ruleContent?.callBackJs == source.ruleContent?.callBackJs)
    }

    // MARK: - 3DES

    @Test func tripleDESMatchesOpenSSLVectors() throws {
        let session = makeSession(try makeSource(minimalSourceJSON), env: makeEnvironment())
        func eval(_ js: String) throws -> String { AnalyzeUrl.stringify(try session.evalSourceJS(js)) }
        let key = "0821CAAD409B84020821CAAD"
        // openssl enc -des-ede3-cbc -K <key 的 hex> -iv 0000000000000000
        #expect(try eval("java.tripleDESEncodeBase64Str('hello|知秋', '\(key)', 'CBC', 'PKCS5Padding', java.base64Decode('AAAAAAAAAAA='))")
            == "biaATyjj0wdncJSZDJ3OXA==")
        #expect(try eval("java.tripleDESEncodeBase64Str('hello|知秋', '\(key)', 'ECB', 'PKCS5Padding', '')") == "biaATyjj0we5zzd+Uu+8rg==")
        #expect(try eval("java.tripleDESEncodeBase64Str('12345678', '\(key)', 'CBC', 'NoPadding', 'abcdefgh')") == "XjmKbpB/rGM=")
        #expect(try eval("java.tripleDESDecodeStr('biaATyjj0we5zzd+Uu+8rg==', '\(key)', 'ECB', 'PKCS5Padding', '')") == "hello|知秋")

        let keyB64 = Data(key.utf8).base64EncodedString(), ivB64 = Data("abcdefgh".utf8).base64EncodedString()
        #expect(try eval("java.tripleDESEncodeArgsBase64Str('12345678', '\(keyB64)', 'CBC', 'NoPadding', '\(ivB64)')") == "XjmKbpB/rGM=")
        #expect(try eval("java.tripleDESDecodeArgsBase64Str('XjmKbpB/rGM=', '\(keyB64)', 'CBC', 'NoPadding', '\(ivB64)')") == "12345678")
    }

    // MARK: - 界面与通知类接口

    @Test func uiBridgesForwardToDelegate() throws {
        let env = makeEnvironment()
        let ui = RecordingUI()
        env.setUIDelegate(ui)
        let recorder = Recorder()
        recorder.attach(env)
        let session = makeSession(try makeSource(minimalSourceJSON), env: env)
        _ = try session.evalSourceJS("""
        java.copyText('bid'); java.openUrl('qdreader://app/showBook'); java.openUrl('https://a.com/v.mp4', 'video/*');
        java.openVideoPlayer('https://a.com/v.mp4,{"headers":{"Referer":"x"}}', '彩蛋', true);
        java.addBook('https://m.qidian.com/book/1'); java.refreshContent(); java.refreshcontent();
        source.putConcurrent('1/1000');
        """)
        #expect(ui.calls == [
            "copy:bid", "open:qdreader://app/showBook|", "open:https://a.com/v.mp4|video/*",
            #"video:https://a.com/v.mp4,{"headers":{"Referer":"x"}}|彩蛋|true"#,
        ])
        let events = recorder.events
        #expect(events.contains { if case .addBook(let url, _) = $0 { return url == "https://m.qidian.com/book/1" }; return false })
        #expect(events.filter { if case .refreshContent = $0 { return true }; return false }.count == 2)
        #expect(try session.evalSourceJS("typeof java.qread") as? String == "undefined")
    }

    @Test func loginExtensionsOnlyInLoginContext() async throws {
        let env = makeEnvironment()
        let recorder = Recorder()
        recorder.attach(env)
        let source = try makeSource(#"""
        {"bookSourceUrl":"https://login.example.com","bookSourceName":"登录源",
         "loginUrl":"function sw(){ var m = new Packages.java.util.HashMap(); m.put('◎ 接口', '知秋'); m.put('空', null); java.upLoginData(m); source.put('t', typeof java.reLoginView); java.reLoginView(); }",
         "loginUi":"[{\"name\":\"账号\",\"type\":\"text\"},{\"name\":\"◎ 接口\",\"type\":\"text\"},{\"name\":\"切换\",\"type\":\"button\",\"action\":\"sw()\"}]"}
        """#)
        let webBook = WebBook(source: source, environment: env)
        #expect(try await webBook.evalJS("typeof java.reLoginView + typeof java.upLoginData") == "undefinedundefined")

        try await webBook.runLoginAction("sw()", formData: ["账号": "a@b.c"])
        #expect(webBook.savedLoginInfo == ["账号": "a@b.c", "◎ 接口": "知秋"])
        #expect(SourceState(key: source.bookSourceUrl, env: env).get("t") == "function")
        let events = recorder.events
        #expect(events.contains {
            if case .upLoginData(let data, _) = $0 { return data == ["◎ 接口": "知秋", "空": ""] }
            return false
        })
        #expect(events.contains { if case .reLoginView = $0 { return true }; return false })
        // 登录脚本结束后不再暴露
        #expect(try await webBook.evalJS("typeof java.upLoginData") == "undefined")
    }

    @Test func jsLoginUiIsEvaluated() async throws {
        let env = makeEnvironment()
        let source = try makeSource(#"""
        {"bookSourceUrl":"https://ui.example.com","bookSourceName":"动态登录",
         "loginUi":"@js:var tag = String(source.get('menuTag') || 'main'); source.put('menuTag', ''); result = JSON.stringify([{name: '菜单:' + tag, type: 'button', action: 'x()'}]);"}
        """#)
        let webBook = WebBook(source: source, environment: env)
        #expect(webBook.loginRows.isEmpty)
        SourceState(key: source.bookSourceUrl, env: env).put("menuTag", "bookDetail")
        #expect(try await webBook.resolveLoginRows().map(\.name) == ["菜单:bookDetail"])
        #expect(try await webBook.resolveLoginRows().map(\.name) == ["菜单:main"])
    }

    // MARK: - 样本书源（离线）

    @Test(.enabled(if: ["guangyu", "shushan", "qidian_zhiqiu", "qidian_qdgo"].allSatisfy { FileManager.default.fileExists(atPath: fixtureURL($0).path) }, "需要本地书源样本"), arguments: ["guangyu", "shushan", "qidian_zhiqiu", "qidian_qdgo"])
    func sampleSourcesLoadJsLibAndRunCallBacks(name: String) async throws {
        let mock = MockTransport()
        mock.on("http") { req in HTTPResponse(url: req.url, statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)) }
        let env = makeEnvironment(mock)
        env.setUIDelegate(RecordingUI())
        let recorder = Recorder()
        recorder.attach(env)
        let source = try fixture(name)
        let webBook = WebBook(source: source, environment: env)
        // jsLib 在首次执行时加载
        let libFunction = ["guangyu": "checkEnv", "shushan": "isBookSyncEnabled", "qidian_zhiqiu": "xlcSourceGet",
                           "qidian_qdgo": "buyChapter"][name]!
        #expect(try await webBook.evalJS("typeof \(libFunction)") == "function")
        #expect(try await webBook.evalJS("typeof java.qread") == "undefined")
        if name == "guangyu" {
            // 登录界面以外没有 reLoginView，光遇据此判断为 iOS 环境
            #expect(try await webBook.evalJS("checkEnv.call(this)") == "苹果")
        }

        let tocUrl = "data:catalogUrl;base64," + Data(#"{"source":"番茄小说","bookid":"7000000000000000001"}"#.utf8).base64EncodedString()
        var book = Book(bookUrl: "https://m.qidian.com/book/1035420986", origin: source.bookSourceUrl, name: "测试书", author: "作者")
        book.tocUrl = tocUrl
        let chapter = BookChapter(url: "data:chapterUrl;base64," + Data(#"{"commentUrl":"https://x.example/c?a=1"}"#.utf8).base64EncodedString(),
                                  title: "第一章", bookUrl: book.bookUrl)
        for event in [SourceCallBackEvent.addBookShelf, .delBookShelf, .clickCustomButton, .longClickCustomButton, .startRead, .endRead] {
            await webBook.callBack(event: event, book: book, chapter: event == .clickCustomButton ? chapter : nil)
        }
        #expect(webBook.hasCallBack == (name == "shushan" || name == "qidian_zhiqiu"))
        #expect(!recorder.logs.contains { $0.contains("callBack(") }, "\(recorder.logs.filter { $0.contains("callBack(") })")
        #expect(mock.requests.allSatisfy { !$0.url.isEmpty })

        if name == "qidian_zhiqiu" {
            // 自定义按钮打开登录界面，详情菜单由 JS loginUi 按 menuTag 生成
            #expect(recorder.events.contains { if case .open(let n, _, _, _) = $0 { return n == "login" }; return false })
            #expect(SourceState(key: source.bookSourceUrl, env: env).get("tempBookName") == "测试书")
            let rows = try await webBook.resolveLoginRows()
            #expect(!rows.isEmpty)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: fixtureURL("qidian_qdgo").path), "需要本地书源样本")) func qdgo目录和段评用离线样本() async throws {
        let mock = MockTransport()
        mock.on("https://qdgo.qimo.host/api/content", body: #"{"code":0,"content":"第一段\n第二段\n第三段"}"#)
        mock.on("https://qdgo.qimo.host/api/summary", body: #"{"code":0,"data":{"list":[{"segmentId":1,"reviewNum":12}]}}"#)
        mock.on("https://qdgo.qimo.host/api/godcomments", body: #"{"Data":{"Reviews":[{"ParagraphId":2,"Content":"好看"}]}}"#)
        mock.on("https://qdgo.qimo.host/api/activity", body: #"{"Data":{"Getchapterendcomments":{"TotalCount":2,"DataList":[{"UserName":"读者","Content":"不错","AgreeAmount":1}]}}}"#)
        let env = makeEnvironment(mock)
        let webBook = WebBook(source: try fixture("qidian_qdgo"), environment: env)

        let tocJSON = #"{"Data":{"BookId":101,"CanReadFree":1,"VipLen":0,"TotalPrice":0,"Volumes":[{"VolumeCode":"v1","VolumeName":"第一卷"}],"Chapters":[{"Vc":"v1","N":"第一章 绯红","C":1001,"W":2400,"DisplayTime":0}]}}"#
        var tocScript = webBook.source.tocRule.chapterList ?? ""
        if tocScript.hasPrefix("<js>") { tocScript.removeFirst(4) }
        if tocScript.hasSuffix("</js>") { tocScript.removeLast(5) }
        let toc = try await webBook.evalJS("var result = \(tocJSON.debugDescription);\n" + tocScript)
        #expect(toc.contains("第一章 绯红"))
        #expect(toc.contains("\"isVip\":false") || toc.contains("\"isVip\": false"))

        let hex = Data("101,1001".utf8).map { String(format: "%02x", $0) }.joined()
        var contentScript = webBook.source.contentRule.content ?? ""
        if contentScript.hasPrefix("<js>") { contentScript.removeFirst(4) }
        if contentScript.hasSuffix("</js>") { contentScript.removeLast(5) }
        let prelude = """
        java.put('dev', 'ios');
        var book = { name: '书', author: '作者', intro: '简介', getVariable: function() { return ''; } };
        var result = '\(hex)';
        """
        let content = try await webBook.evalJS(prelude + contentScript)
        #expect(content.contains("<div rs-native>第一段"))
        #expect(content.contains("<comment count=\"12\""))
        #expect(content.contains("起点段评"))
        #expect(content.contains("本章讨论"))
        #expect(!mock.requests.contains { $0.url.contains("token=") })
    }
}
